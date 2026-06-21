classdef WSN_ClusterHead_FeatureExport
    % =========================================================
    % CH FEATURE-EXPORT MODULE
    % =========================================================
    % Outbound 5.2 SENSOR_AGG construction/fragmentation and 5.3 ACK
    % handling - the pipeline that exports locally-aggregated sensor
    % readings upward toward the parent GWN/CH. Extracted from
    % WSN_ClusterHead.m; operates on the CH instance (obj) passed in by
    % the caller. Stateless itself - all state lives on obj.
    %
    % Inbound ingestion/merge lives in WSN_ClusterHead_Registry
    % (CH/Registry/) - this module only builds and tracks outbound
    % fragments.
    % =========================================================

    methods (Static)
        function msgs = createSensorAgg(obj, t)
            % Create 5.2 SENSOR_AGG message(s) - fragment if needed
            % Payload format: [TotalFrags(1), FragIdx(1), NumSensors(1), {SensorData} x N]
            msgs = [];

            if isempty(obj.sensorTable) || isempty(obj.parent)
                return;
            end

            % Sort sensors by RSSI (strongest first for priority)
            [~, sortIdx] = sort([obj.sensorTable.rssi], 'descend');
            sortedSensors = obj.sensorTable(sortIdx);

            % Fragment into messages with max sensors per fragment
            numSensors = numel(sortedSensors);
            numFragments = ceil(numSensors / WSN_Config.MAX_SENSORS_PER_FRAGMENT);
            if numFragments == 0
                numFragments = 1;  % At least 1 fragment even if empty
            end

            for fragIdx = 1:numFragments
                startIdx = (fragIdx - 1) * WSN_Config.MAX_SENSORS_PER_FRAGMENT + 1;
                endIdx = min(fragIdx * WSN_Config.MAX_SENSORS_PER_FRAGMENT, numSensors);
                fragSensors = sortedSensors(startIdx:endIdx);

                msg = WSN_Message();
                msg.type = WSN_Config.MSG_TYPE_CH_HELLO;
                msg.subtype = WSN_Config.SENSOR_SUB_AGG;  % 5.2
                msg.src = hex2dec(obj.hexID);
                msg.dst = obj.parent;
                msg.ttl = 5;
                msg.seq = mod(t + fragIdx, 256);

                % Build payload with Fragment ID header:
                % [TotalFragments(1), FragmentIndex(1), NumSensors(1), {SensorID(2), Time(2), Value(2), RSSI(1), Battery(1)} x N]
                payload = [uint8(numFragments), uint8(fragIdx), uint8(numel(fragSensors))];
                for i = 1:numel(fragSensors)
                    s = fragSensors(i);
                    sensorEntry = [ ...
                        typecast(uint16(s.id), 'uint8'), ...        % 2 bytes
                        typecast(uint16(s.lastTime), 'uint8'), ...  % 2 bytes
                        typecast(uint16(s.value), 'uint8'), ...     % 2 bytes
                        uint8(round(s.rssi * 10)), ...              % 1 byte (scaled)
                        uint8(s.battery)];                          % 1 byte
                    payload = [payload, sensorEntry]; %
                end

                msg.payload = payload;
                msg.payloadLen = numel(payload);

                % LOCAL ENCRYPTION: Only if CH has localKey (parent is GWN)
                % CH-CH has no key exchange, so localKey is empty -> no encryption
                if ~isempty(obj.localKey)
                    msg.payload = WSN_Crypto.encrypt(payload, obj.localKey);
                    msg.payloadLen = numel(msg.payload);
                    msg.setEncrypted(true);
                end

                msg.addChecksum();
                msg.color = [0.6 0.2 0.8];  % Violet for 5.2 SENSOR_AGG

                msgs = [msgs, msg]; %

                obj.addLog(sprintf('t=%d [5.2_FRAG] Fragment %d/%d: %d sensors', ...
                    t, fragIdx, numFragments, numel(fragSensors)));

                % Store first fragment as pending (for ACK tracking)
                if fragIdx == 1
                    obj.pendingAgg = msg;
                    obj.pendingAggSeq = msg.seq;
                    obj.aggRetryCount = 0;
                    obj.lastAggRetryTime = t;
                    obj.pendingFragments = (1:numFragments);  % Track all pending frags
                end
            end

            obj.addLog(sprintf('t=%d [5.2_TX] %d sensors in %d fragments -> %s', ...
                t, numSensors, numFragments, dec2hex(uint16(obj.parent), 4)));
        end

        function handleAggACK(obj, msg, t)
            % 5.3 CH_ACK received - clear pending fragment
            % Payload: [TotalFrags(1), AckedFragIdx(1)]
            if msg.payloadLen >= 2
                totalFrags = msg.payload(1);
                ackedFrag = msg.payload(2);
                obj.addLog(sprintf('t=%d [5.3_RX] ACK for fragment %d/%d', t, ackedFrag, totalFrags));

                % Remove this fragment from pending list
                if isprop(obj, 'pendingFragments') && ~isempty(obj.pendingFragments)
                    obj.pendingFragments(obj.pendingFragments == ackedFrag) = [];

                    % All fragments ACKed?
                    if isempty(obj.pendingFragments)
                        obj.addLog(sprintf('t=%d [5.3_RX] All %d fragments ACKed', t, totalFrags));
                        obj.pendingAgg = [];
                        obj.aggRetryCount = 0;
                    end
                end
            else
                % Legacy ACK format (no fragment info)
                if ~isempty(obj.pendingAgg) && msg.seq == obj.pendingAggSeq
                    obj.addLog(sprintf('t=%d [5.3_RX] ACK for seq=%d', t, msg.seq));
                    obj.pendingAgg = [];
                    obj.aggRetryCount = 0;
                end
            end
        end

        function msg = createAggACK(obj, dst, seq, t, fragIdx, totalFrags)
            % Create 5.3 CH_ACK message with fragment info
            % Payload: [TotalFrags(1), AckedFragIdx(1)]
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_HELLO;
            msg.subtype = WSN_Config.SENSOR_SUB_ACK;  % 5.3
            msg.src = hex2dec(obj.hexID);
            msg.dst = dst;
            msg.ttl = 1;
            msg.seq = seq;  % Echo back the sequence number

            % Default to single fragment if not specified
            if nargin < 5 || isempty(fragIdx)
                fragIdx = 1;
                totalFrags = 1;
            end
            payload = [uint8(totalFrags), uint8(fragIdx)];

            % CH 5.3 ACK is NOT encrypted
            % CH has no shared key with child CHs (no key exchange in CH-CH)

            msg.payload = payload;
            msg.payloadLen = numel(payload);
            msg.addChecksum();
            msg.color = [1.0 0.7 0.2];  % Amber for 5.3 AGG_ACK
        end

        % ----------------------------------------------------------
        % DORMANT: trust-aware feature snapshot (not yet wired in)
        % ----------------------------------------------------------
        function row = getTrustFeatureSnapshot(obj, neighborID)
            % Placeholder per-neighbor feature row combining sensorTable
            % stats with neighbor trust, intended as a future input column
            % set for ML-IDS feature export once the trust decision matrix
            % (see WSN_ClusterHead_Enforcement.buildTrustMatrix) is active.
            row = struct( ...
                'neighborID', neighborID, ...
                'neighborTrust', obj.getNeighborTrust(neighborID), ...
                'sensorsTracked', numel(obj.sensorTable));
        end
    end
end
