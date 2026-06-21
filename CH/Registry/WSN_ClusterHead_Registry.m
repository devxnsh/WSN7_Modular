classdef WSN_ClusterHead_Registry
    % =========================================================
    % CH REGISTRY MODULE
    % =========================================================
    % Sensor data ingestion: direct SN->CH readings, inbound 5.2
    % SENSOR_AGG from child CHs, and merging that data into the local
    % sensorTable. Extracted from WSN_ClusterHead.m; operates on the CH
    % instance (obj) passed in by the caller. Stateless itself - all
    % state lives on obj.
    %
    % The outbound side (building/transmitting/ACKing 5.2 fragments) is
    % WSN_ClusterHead_FeatureExport (CH/FeatureExport/) - this module only
    % ingests/merges.
    % =========================================================

    methods (Static)
        function handleSensorData(obj, msg, t, rssi)
            % Type 1: Receive raw sensor data from sensor node
            sender = msg.src;

            % Parse payload: [SensorValue(2), Battery(1)]
            if msg.payloadLen < 3
                return;
            end
            sensorValue = double(typecast(msg.payload(1:2), 'uint16'));
            sensorBattery = double(msg.payload(3));

            % Update or add to sensor table (overwrite if exists)
            idx = find([obj.sensorTable.id] == sender, 1);
            if isempty(idx)
                obj.sensorTable(end+1) = struct( ...
                    'id', sender, ...
                    'lastTime', t, ...
                    'value', sensorValue, ...
                    'rssi', rssi, ...
                    'battery', sensorBattery);
                obj.addLog(sprintf('t=%d [SENSOR_RX] NEW %s val=%d bat=%d%%', ...
                    t, dec2hex(uint16(sender), 4), sensorValue, sensorBattery));
            else
                obj.sensorTable(idx).lastTime = t;
                obj.sensorTable(idx).value = sensorValue;
                obj.sensorTable(idx).rssi = rssi;
                obj.sensorTable(idx).battery = sensorBattery;
                % Silent update for existing sensors
            end
        end

        function msgs = processSensorAggregation(obj, t)
            % Process 5.2 aggregation and transmission
            msgs = [];

            % Must have parent to send to
            if isempty(obj.parent)
                return;
            end

            % === ATTACK: BLACKHOLE/GRAYHOLE CHECK ===
            % Malicious CH may drop data packets instead of forwarding
            if WSN_Attack.isMaliciousNode(obj.id)
                attackType = WSN_Attack.getAttackType(obj.id);
                if attackType == WSN_Attack.ATTACK_BLACKHOLE
                    if WSN_Attack.shouldDropBlackhole(obj.id, t)
                        % Add ghost link to parent (dropped aggregation)
                        if ~isempty(obj.parent)
                            WSN_Attack.addGhostLink(obj.id, obj.parent, t + 3, 'AGG');
                        end
                        % Silently drop - no TX logged means no forward happened
                        obj.sensorTable = struct('id',{}, 'lastTime',{}, 'value',{}, 'rssi',{}, 'battery',{});
                        return;  % Drop all - forward nothing
                    end
                elseif attackType == WSN_Attack.ATTACK_GRAYHOLE
                    if WSN_Attack.shouldDropGrayhole(obj.id, t)
                        % Add ghost link to parent (dropped aggregation)
                        if ~isempty(obj.parent)
                            WSN_Attack.addGhostLink(obj.id, obj.parent, t + 3, 'AGG');
                        end
                        % Silently drop - no TX logged means no forward happened
                        obj.sensorTable = struct('id',{}, 'lastTime',{}, 'value',{}, 'rssi',{}, 'battery',{});
                        return;  % Drop this batch
                    end
                end
            end

            % Initialize aggregation period on first call
            if obj.aggPeriod == 0
                obj.aggPeriod = randi([WSN_Config.AGG_PERIOD_MIN, WSN_Config.AGG_PERIOD_MAX]);
                obj.nextAggTX = t + obj.aggPeriod;
            end

            % --- PENDING 5.2 RETRY LOGIC ---
            if ~isempty(obj.pendingAgg)
                % Check if retry needed
                if (t - obj.lastAggRetryTime) >= WSN_Config.AGG_RETRY_INTERVAL
                    if obj.aggRetryCount >= WSN_Config.AGG_MAX_RETRIES
                        % Max retries - discard batch
                        obj.addLog(sprintf('t=%d [5.2_DROPPED] seq=%d after %d retries', ...
                            t, obj.pendingAggSeq, obj.aggRetryCount));
                        % ML-IDS: parent never ACKed -- distrust it. NOTE: this does NOT
                        % catch Blackhole/Grayhole specifically -- that attack fake-ACKs
                        % every child (see handleSensorAgg's stealth-ACK branch below), so
                        % this only fires for a genuinely unresponsive/dead/out-of-range
                        % parent. Blackhole/Grayhole is caught by the parent-side
                        % reporting-silence detector (WSN_Gateway.checkCensusTriggers).
                        if ~isempty(obj.parent)
                            obj.updateNeighborTrust(obj.parent, -WSN_Config.TRUST_DELTA_FAIL_HARD);
                        end
                        obj.pendingAgg = [];
                        obj.aggRetryCount = 0;
                    else
                        % Retransmit
                        obj.aggRetryCount = obj.aggRetryCount + 1;
                        obj.lastAggRetryTime = t;
                        msgs = [msgs, obj.pendingAgg];
                        obj.addLog(sprintf('t=%d [5.2_RETRY] seq=%d attempt=%d/%d', ...
                            t, obj.pendingAggSeq, obj.aggRetryCount, WSN_Config.AGG_MAX_RETRIES));
                    end
                end
                return;  % Don't create new 5.2 while pending
            end

            % --- NEW 5.2 TRANSMISSION ---
            if t >= obj.nextAggTX && ~isempty(obj.sensorTable)
                aggMsgs = obj.createSensorAgg(t);
                msgs = [msgs, aggMsgs];

                % Schedule next aggregation
                obj.nextAggTX = t + obj.aggPeriod;
            end
        end

        function response = handleSensorAgg(obj, msg, t, rssi)
            % 5.2 SENSOR_AGG from child CH - ACK and forward
            response = [];
            sender = msg.src;

            % === ATTACK: BLACKHOLE/GRAYHOLE on relay ===
            % Malicious CH may refuse to relay child CH data
            if WSN_Attack.isMaliciousNode(obj.id)
                attackType = WSN_Attack.getAttackType(obj.id);
                if attackType == WSN_Attack.ATTACK_BLACKHOLE
                    if WSN_Attack.shouldDropBlackhole(obj.id, t)
                        % Add ghost link to parent (dropped relay)
                        if ~isempty(obj.parent)
                            WSN_Attack.addGhostLink(obj.id, obj.parent, t + 3, 'RELAY');
                        end
                        % Log RX, send ACK (appears normal), but no forward
                        obj.addLog(sprintf('t=%d [RX] 5.2_AGG <- %s', t, dec2hex(uint16(sender), 4)));
                        totalFrags = 1; fragIdx = 1;
                        if msg.payloadLen >= 2
                            totalFrags = msg.payload(1); fragIdx = msg.payload(2);
                        end
                        response = obj.createAggACK(sender, msg.seq, t, fragIdx, totalFrags);
                        obj.addLog(sprintf('t=%d [TX] 5.2_ACK -> %s', t, dec2hex(uint16(sender), 4)));
                        return;  % ACK but don't merge/forward
                    end
                elseif attackType == WSN_Attack.ATTACK_GRAYHOLE
                    if WSN_Attack.shouldDropGrayhole(obj.id, t)
                        % Add ghost link to parent (dropped relay)
                        if ~isempty(obj.parent)
                            WSN_Attack.addGhostLink(obj.id, obj.parent, t + 3, 'RELAY');
                        end
                        % Log RX, send ACK (appears normal), but no forward
                        obj.addLog(sprintf('t=%d [RX] 5.2_AGG <- %s', t, dec2hex(uint16(sender), 4)));
                        totalFrags = 1; fragIdx = 1;
                        if msg.payloadLen >= 2
                            totalFrags = msg.payload(1); fragIdx = msg.payload(2);
                        end
                        response = obj.createAggACK(sender, msg.seq, t, fragIdx, totalFrags);
                        obj.addLog(sprintf('t=%d [TX] 5.2_ACK -> %s', t, dec2hex(uint16(sender), 4)));
                        return;  % ACK but don't merge/forward
                    end
                end
            end

            % Extract fragment info from payload
            totalFrags = 1;
            fragIdx = 1;
            if msg.payloadLen >= 2
                totalFrags = msg.payload(1);
                fragIdx = msg.payload(2);
            end

            % Send 5.3 ACK with fragment info
            ackMsg = obj.createAggACK(sender, msg.seq, t, fragIdx, totalFrags);
            response = ackMsg;

            obj.addLog(sprintf('t=%d [5.2_RX] from %s frag %d/%d, sending 5.3 ACK', ...
                t, dec2hex(uint16(sender), 4), fragIdx, totalFrags));

            % Parse and merge into our sensor table
            obj.mergeSensorAgg(msg, t, rssi);

            % Will be forwarded to parent on next aggregation cycle
        end

        function mergeSensorAgg(obj, msg, t, rssi)
            % Merge received 5.2 sensor data into our table
            % Payload format: [TotalFrags(1), FragIdx(1), NumSensors(1), {SensorData} x N]
            if msg.payloadLen < 3
                return;
            end

            totalFrags = msg.payload(1);
            fragIdx = msg.payload(2);
            numSensors = msg.payload(3);
            offset = 4;  % Start after header bytes

            obj.addLog(sprintf('t=%d [5.2_MERGE] Fragment %d/%d with %d sensors', ...
                t, fragIdx, totalFrags, numSensors));

            for i = 1:numSensors
                if offset + 7 > msg.payloadLen + 1
                    break;  % Incomplete entry
                end

                sensorID = typecast(msg.payload(offset:offset+1), 'uint16');
                sensorTime = typecast(msg.payload(offset+2:offset+3), 'uint16');
                sensorValue = typecast(msg.payload(offset+4:offset+5), 'uint16');
                sensorRSSI = double(msg.payload(offset+6)) / 10;
                sensorBattery = double(msg.payload(offset+7));
                offset = offset + 8;

                % Update or add to our sensor table
                idx = find([obj.sensorTable.id] == sensorID, 1);
                if isempty(idx)
                    obj.sensorTable(end+1) = struct( ...
                        'id', double(sensorID), ...
                        'lastTime', double(sensorTime), ...
                        'value', double(sensorValue), ...
                        'rssi', sensorRSSI, ...
                        'battery', sensorBattery);
                else
                    % Overwrite if newer
                    if sensorTime > obj.sensorTable(idx).lastTime
                        obj.sensorTable(idx).lastTime = double(sensorTime);
                        obj.sensorTable(idx).value = double(sensorValue);
                        obj.sensorTable(idx).rssi = sensorRSSI;
                        obj.sensorTable(idx).battery = sensorBattery;
                    end
                end
            end
        end
    end
end
