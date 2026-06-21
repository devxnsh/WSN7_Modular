classdef WSN_Sink_Registry
    % =========================================================
    % SINK REGISTRY MODULE
    % =========================================================
    % Node & sensor registry tracking, route tracing, and the terminal
    % handshake/aggregation handlers that populate those registries.
    % Extracted from WSN_Sink.m; operates on the Sink instance (obj)
    % passed in by the caller. Stateless itself - all state lives on obj.
    % =========================================================

    methods (Static)
        function handleEncHello(obj, msg, t)
            % Terminal handshake: extract route info and advance
            % Extended ENC_HELLO contains: srcID, parentID, localKey, chCnt, snCnt,
            %                              gwChildren, chChildren, secondaryChildren
            % Payload is encrypted with global key
            %
            % FSM Locking Protocol:
            % - Child sends ENC_HELLO to parent with encrypted payload (global key)
            % - Parent forwards to its parent, only modifying src/dst (not payload)
            % - Chain continues until Sink decrypts and extracts originalSender from payload
            % - Registry MUST use originalSender (s.srcID), not msg.src (immediate forwarder)

            immediateSender = msg.src;  % Who forwarded this message
            obj.handshakePartner = [];
            obj.radio.clearLock('SUCCESS');

            % Decrypt payload with global key first to get originalSender
            if msg.isEncrypted() && ~isempty(obj.encryptionKey)
                msg.payload = WSN_Crypto.decrypt(msg.payload, obj.encryptionKey);
            end

            % Parse payload to get original sender ID
            s = msg.getEncHelloPayload();
            originalSender = s.srcID;  % True source from encrypted payload
            nodeHex = dec2hex(originalSender, 4);
            parentHex = dec2hex(s.parentID, 4);

            % Determine if this is a DIRECT ENC_HELLO from Sink's recruit
            % or a FORWARDED ENC_HELLO from a deeper node
            isDirectFromRecruit = (originalSender == immediateSender);

            if isDirectFromRecruit
                % DIRECT ENC_HELLO: Apply pendingChildren security check
                isPending = ~isempty(obj.pendingChildren) && any([obj.pendingChildren.id] == immediateSender);
                if isPending
                    obj.pendingChildren([obj.pendingChildren.id] == immediateSender) = [];
                    if ~ismember(immediateSender, obj.children)
                        obj.children(end+1) = immediateSender;
                        obj.addLog(sprintf('t=%d [SINK] Promoted %s to children (DIRECT ENC_HELLO)', ...
                            t, dec2hex(uint16(immediateSender), 4)));
                    end
                elseif ~ismember(immediateSender, obj.children)
                    % Not pending and not already a child - security violation
                    obj.addLog(sprintf('t=%d [SECURITY] DROP ENC_HELLO from %s - not in pendingChildren', ...
                        t, dec2hex(uint16(immediateSender), 4)));
                    return;
                end
            else
                % FORWARDED ENC_HELLO: Verify forwarder is our child
                if ~ismember(immediateSender, obj.children)
                    obj.addLog(sprintf('t=%d [SECURITY] DROP forwarded ENC_HELLO - forwarder %s not in children', ...
                        t, dec2hex(uint16(immediateSender), 4)));
                    return;
                end
                obj.addLog(sprintf('t=%d [SINK] FORWARDED ENC_HELLO: orig=%s via %s', ...
                    t, nodeHex, dec2hex(uint16(immediateSender), 4)));
            end

            % Update or insert registry entry with extended info
            idx = find(strcmp({obj.nodeRegistry.hexID}, nodeHex), 1);
            if isempty(idx)
                obj.nodeRegistry(end+1) = struct(...
                    'hexID', nodeHex, 'parent', parentHex, 'route', '', 'localKey', s.localKeyHex, ...
                    'chCount', s.chCount, 'snCount', s.snCount, ...
                    'gwChildren', s.gwChildren, 'chChildren', s.chChildren, ...
                    'secondaryChildren', s.secondaryChildren, 'lastUpdate', t);
            else
                obj.nodeRegistry(idx).parent = parentHex;
                obj.nodeRegistry(idx).localKey = s.localKeyHex;
                obj.nodeRegistry(idx).chCount = s.chCount;
                obj.nodeRegistry(idx).snCount = s.snCount;
                obj.nodeRegistry(idx).gwChildren = s.gwChildren;
                obj.nodeRegistry(idx).chChildren = s.chChildren;
                obj.nodeRegistry(idx).secondaryChildren = s.secondaryChildren;
                obj.nodeRegistry(idx).lastUpdate = t;
            end

            % Compute and store route for the sender
            idx = find(strcmp({obj.nodeRegistry.hexID}, nodeHex), 1);
            obj.nodeRegistry(idx).route = WSN_Sink_Registry.traceRoute(obj, nodeHex);

            % UPDATE ROUTES FOR CHILD NODES mentioned in payload
            % This ensures routing info is available even before children send their own ENC_HELLO
            allChildren = [s.gwChildren, s.chChildren, s.secondaryChildren];
            for childID = allChildren
                if childID == 0, continue; end
                childHex = dec2hex(childID, 4);
                childIdx = find(strcmp({obj.nodeRegistry.hexID}, childHex), 1);
                if isempty(childIdx)
                    % Create placeholder entry for child (will be updated when child sends ENC_HELLO)
                    obj.nodeRegistry(end+1) = struct(...
                        'hexID', childHex, 'parent', nodeHex, 'route', '', 'localKey', '', ...
                        'chCount', 0, 'snCount', 0, 'gwChildren', [], ...
                        'chChildren', [], 'secondaryChildren', [], 'lastUpdate', t);
                    childIdx = numel(obj.nodeRegistry);
                else
                    % ONLY update parent if:
                    % 1. Parent is not set (empty or invalid), OR
                    % 2. Child has no localKey (placeholder entry, not from direct ENC_HELLO)
                    existingParent = obj.nodeRegistry(childIdx).parent;
                    existingKey = obj.nodeRegistry(childIdx).localKey;
                    isPlaceholder = isempty(existingKey);
                    parentNotSet = isempty(existingParent) || ~ischar(existingParent) || numel(existingParent) ~= 4;

                    if parentNotSet || isPlaceholder
                        obj.nodeRegistry(childIdx).parent = nodeHex;
                    end
                    % Note: If child already sent ENC_HELLO with its own parent info,
                    % we trust that more than inferred parent from another node's children list
                end
                % Compute route for child
                obj.nodeRegistry(childIdx).route = WSN_Sink_Registry.traceRoute(obj, childHex);
            end

            % Log extended info
            gwChStr = '';
            if ~isempty(s.gwChildren)
                gwChStr = sprintf('gwCh=[%s]', strjoin(arrayfun(@(x)dec2hex(x,4), s.gwChildren, 'UniformOutput', false), ','));
            end
            chChStr = '';
            if ~isempty(s.chChildren)
                chChStr = sprintf('chCh=[%s]', strjoin(arrayfun(@(x)dec2hex(x,4), s.chChildren, 'UniformOutput', false), ','));
            end
            secChStr = '';
            if ~isempty(s.secondaryChildren)
                secChStr = sprintf('secCh=[%s]', strjoin(arrayfun(@(x)dec2hex(x,4), s.secondaryChildren, 'UniformOutput', false), ','));
            end

            % Advance recruitment ONLY for direct ENC_HELLOs from Sink's own recruits
            % Forwarded ENC_HELLOs should not affect Sink's recruitment state
            if isDirectFromRecruit
                obj.currentRecruit = uint16(0);
                obj.behavior.retryTarget = [];
                obj.behavior.retryCount = 0;
                obj.recruitPtr = obj.recruitPtr + 1;
                obj.state = WSN_Config.STATE_SECURE;  % Sink always returns to SECURE
            end

            obj.addLog(sprintf('t=%d [SINK] ENC_HELLO from %s (parent=%s): sn=%d %s %s %s', ...
                t, nodeHex, parentHex, s.snCount, gwChStr, chChStr, secChStr));
        end

        function handleCHHello(obj, msg, t)
            % CH_HELLO (Type 5): Terminal - extract CH info and update registry
            % Payload: CH ID (2 bytes), Parent GWN ID (2 bytes)

            if msg.payloadLen < 4
                obj.addLog(sprintf('t=%d [SINK] CH_HELLO payload too short', t));
                return;
            end

            % Extract CH ID and Parent GWN ID from payload
            chID = typecast(uint8(msg.payload(1:2)), 'uint16');
            parentGwnID = typecast(uint8(msg.payload(3:4)), 'uint16');

            chHex = dec2hex(chID, 4);
            parentHex = dec2hex(parentGwnID, 4);

            % Update or insert registry entry for the CH
            idx = find(strcmp({obj.nodeRegistry.hexID}, chHex), 1);
            if isempty(idx)
                % New CH entry - no localKey for CH (uses parent's key)
                % Include all fields to match extended nodeRegistry structure
                obj.nodeRegistry(end+1) = struct(...
                    'hexID', chHex, 'parent', parentHex, 'route', '', 'localKey', '', ...
                    'chCount', 0, 'snCount', 0, 'gwChildren', [], ...
                    'chChildren', [], 'secondaryChildren', [], 'lastUpdate', t);
            else
                % Update existing entry
                obj.nodeRegistry(idx).parent = parentHex;
                obj.nodeRegistry(idx).lastUpdate = t;
            end

            % Compute and store route
            idx = find(strcmp({obj.nodeRegistry.hexID}, chHex), 1);
            obj.nodeRegistry(idx).route = WSN_Sink_Registry.traceRoute(obj, chHex);

            obj.addLog(sprintf('t=%d [SINK] CH_HELLO: CH %s joined via GWN %s', ...
                t, chHex, parentHex));
        end

        function routeStr = traceRoute(obj, targetHex)
            % Trace route from target node back to Sink
            % Returns: "SINK -> GWN1 -> GWN2 -> target"
            path = {};
            curr = targetHex;
            hops = 0;
            sinkHex = obj.hexID;

            while hops < 20
                % Stop if current is empty or invalid
                if isempty(curr) || ~ischar(curr) || numel(curr) ~= 4
                    break;
                end

                % Stop if we reached the Sink (route complete)
                if strcmp(curr, sinkHex)
                    path{end+1} = curr;
                    break;
                end

                path{end+1} = curr;
                idx = find(strcmp({obj.nodeRegistry.hexID}, curr), 1);

                % Stop if node not in registry
                if isempty(idx)
                    break;
                end

                % Get parent and check validity
                parentHex = obj.nodeRegistry(idx).parent;
                if isempty(parentHex) || ~ischar(parentHex) || numel(parentHex) ~= 4
                    break;  % No valid parent, stop here
                end

                curr = parentHex;
                hops = hops + 1;
            end

            routeStr = strjoin(flip(path), ' -> ');
        end

        function localKeyHex = deriveRemoteLocalKey(obj, remoteID)
            % Derive the local key for a remote GWN based on its ID and parent
            % Used for double-decryption of 5.2 SENSOR_AGG messages
            localKeyHex = '';

            if isempty(obj.encryptionKey)
                return;
            end

            % Find remote node's parent from registry
            remoteHex = dec2hex(uint16(remoteID), 4);
            idx = find(strcmp({obj.nodeRegistry.hexID}, remoteHex), 1);
            if isempty(idx)
                return;  % Unknown node, can't derive key
            end

            parentHex = obj.nodeRegistry(idx).parent;
            if isempty(parentHex)
                return;
            end
            parentID = hex2dec(parentHex);

            % Derive local key: globalKey XOR nodeID XOR parentID
            gk = uint8(hex2dec(reshape(obj.encryptionKey, 2, [])'));
            idBytes = typecast(uint16(remoteID), 'uint8');
            pBytes = typecast(uint16(parentID), 'uint8');
            seed = [gk; idBytes(:); pBytes(:)];
            lk = gk(1:8);
            for i = 1:numel(seed)
                lk(mod(i-1, 8)+1) = bitxor(lk(mod(i-1, 8)+1), seed(i));
            end
            localKeyHex = upper(reshape(dec2hex(lk, 2).', 1, []));
        end

        function handleDirectSensor(obj, msg, t, rssi)
            % Type 1: Direct sensor data from SN -> Sink
            % Terminates directly into sensorRegistry (no 5.2 aggregation needed)
            sender = msg.src;

            % Parse payload: [SensorValue(2), Battery(1)]
            if msg.payloadLen < 3
                return;
            end
            sensorValue = double(typecast(msg.payload(1:2), 'uint16'));
            sensorBattery = double(msg.payload(3));

            senderHex = dec2hex(uint16(sender), 4);

            % Skip invalid sensor IDs (FF/AA prefixes are GWN/CH, not sensors)
            if startsWith(senderHex, 'FF') || startsWith(senderHex, 'AA')
                return;
            end

            % Update or add to sensor registry (same as 5.2 but simpler)
            idx = find([obj.sensorRegistry.id] == sender, 1);
            if isempty(idx)
                % New sensor - create entry with route "DIRECT"
                % Determine RSSI quality for direct sensor
                if rssi > -50
                    directQuality = 'EXCELLENT';
                elseif rssi > -70
                    directQuality = 'GOOD';
                elseif rssi > -85
                    directQuality = 'FAIR';
                else
                    directQuality = 'POOR';
                end
                newEntry = struct( ...
                    'id', sender, ...
                    'hexID', senderHex, ...
                    'parentCH', hex2dec(obj.hexID), ... % Direct to Sink
                    'routeHistory', {{'SINK(direct)'}}, ...
                    'rssiQuality', directQuality, ...
                    'TrustScore', 50, ... % Default trust for new sensor
                    'timeseries', struct('time', t, 'value', sensorValue, ...
                                        'rssi', rssi, 'battery', sensorBattery));
                if isempty(obj.sensorRegistry)
                    obj.sensorRegistry = newEntry;
                else
                    % Ensure TrustScore field exists before appending
                    if ~isfield(obj.sensorRegistry, 'TrustScore')
                        [obj.sensorRegistry.TrustScore] = deal(50);
                    end
                    obj.sensorRegistry(end+1) = newEntry;
                end

                % Update global trust registry
                obj.updateGlobalTrust(sender, senderHex, 'SENSOR', t, true);

                obj.addLog(sprintf('t=%d [SENSOR_DIRECT] NEW %s [%s] val=%d bat=%d%% rssi=%.1f', ...
                    t, senderHex, directQuality, sensorValue, sensorBattery, rssi));
            else
                % Existing sensor - append to timeseries
                newPoint = struct('time', t, 'value', sensorValue, ...
                                 'rssi', rssi, 'battery', sensorBattery);
                obj.sensorRegistry(idx).timeseries(end+1) = newPoint;

                % Increment trust for successful data reception
                if ~isfield(obj.sensorRegistry, 'TrustScore')
                    [obj.sensorRegistry.TrustScore] = deal(50);
                end
                obj.sensorRegistry(idx).TrustScore = min(100, obj.sensorRegistry(idx).TrustScore + 1);

                % Update global trust registry
                obj.updateGlobalTrust(sender, dec2hex(uint16(sender), 4), 'SENSOR', t, true);

                % Update RSSI quality (ensure field exists)
                if rssi > -50
                    directQuality = 'EXCELLENT';
                elseif rssi > -70
                    directQuality = 'GOOD';
                elseif rssi > -85
                    directQuality = 'FAIR';
                else
                    directQuality = 'POOR';
                end
                if ~isfield(obj.sensorRegistry, 'rssiQuality')
                    [obj.sensorRegistry.rssiQuality] = deal('UNKNOWN');
                end
                obj.sensorRegistry(idx).rssiQuality = directQuality;

                % Update route if changed to direct
                if obj.sensorRegistry(idx).parentCH ~= hex2dec(obj.hexID)
                    obj.sensorRegistry(idx).parentCH = hex2dec(obj.hexID);
                    if ~any(strcmp(obj.sensorRegistry(idx).routeHistory, 'SINK(direct)'))
                        obj.sensorRegistry(idx).routeHistory{end+1} = 'SINK(direct)';
                    end
                    obj.addLog(sprintf('t=%d [SENSOR_DIRECT] %s REROUTED to SINK (was via GWN/CH)', ...
                        t, senderHex));
                end

                % Limit timeseries to last 100 points
                if numel(obj.sensorRegistry(idx).timeseries) > 100
                    obj.sensorRegistry(idx).timeseries(1) = [];
                end
            end
        end

        function handleSensorAgg(obj, msg, t)
            % 5.2 SENSOR_AGG: Parse and store sensor data with RSSI grouping
            % Supports double-encrypted data (global key + local key from GWN)
            % Payload format: [TotalFrags(1), FragIdx(1), NumGroups(1),
            %                  {GroupID(1), NumInGroup(1), {SensorData x N}...} x G]
            % RSSI Groups: 1=Excellent(>-50), 2=Good(-50 to -70), 3=Fair(-70 to -85), 4=Poor(<-85)
            sender = msg.src;

            % Layered decryption: get original sender and decrypted payload
            [payload, originalSender] = msg.decryptLayered(obj.encryptionKey, WSN_Sink_Registry.deriveRemoteLocalKey(obj, sender));

            if numel(payload) < 3
                return;
            end

            % Parse fragment header
            totalFrags = double(payload(1));
            fragIdx = double(payload(2));
            numGroups = double(payload(3));
            offset = 4;  % Start after header bytes

            % RSSI quality labels for logging
            rssiLabels = {'EXCELLENT', 'GOOD', 'FAIR', 'POOR'};
            totalSensors = 0;
            groupSummary = '';

            obj.addLog(sprintf('t=%d [5.2_FRAG] Processing fragment %d/%d with %d RSSI groups from %s (original: %s)', ...
                t, fragIdx, totalFrags, numGroups, dec2hex(uint16(sender), 4), dec2hex(uint16(originalSender), 4)));

            for g = 1:numGroups
                % Read group header: GroupID (1 byte), NumInGroup (1 byte)
                if offset + 1 > numel(payload)
                    obj.addLog(sprintf('t=%d [5.2_PARSE] Incomplete group header at offset %d', t, offset));
                    break;
                end

                groupID = double(payload(offset));
                numInGroup = double(payload(offset + 1));
                offset = offset + 2;

                % Get quality label for this group
                if groupID >= 1 && groupID <= 4
                    qualityLabel = rssiLabels{groupID};
                else
                    qualityLabel = sprintf('GROUP%d', groupID);
                end

                obj.addLog(sprintf('t=%d [5.2_GROUP] RSSI Group %d (%s): %d sensors', ...
                    t, groupID, qualityLabel, numInGroup));

                % Track for summary
                if ~isempty(groupSummary)
                    groupSummary = [groupSummary ', ']; %
                end
                groupSummary = [groupSummary sprintf('%s:%d', qualityLabel(1:3), numInGroup)]; %

                senderHex = dec2hex(uint16(originalSender), 4);

                for i = 1:numInGroup
                    % Need 8 bytes for each sensor entry
                    if offset + 7 > numel(payload)
                        obj.addLog(sprintf('t=%d [5.2_PARSE] Incomplete entry %d/%d in group %d at offset %d (payload=%d bytes)', ...
                            t, i, numInGroup, groupID, offset, numel(payload)));
                        break;
                    end

                    % Extract sensor entry (8 bytes each)
                    sensorID = double(typecast(uint8(payload(offset:offset+1)), 'uint16'));
                    sensorTime = double(typecast(uint8(payload(offset+2:offset+3)), 'uint16'));
                    sensorValue = double(typecast(uint8(payload(offset+4:offset+5)), 'uint16'));
                    sensorRSSI = -double(payload(offset+6));  % Stored as absolute, convert back to negative
                    sensorBattery = min(100, double(payload(offset+7)));  % Clamp to 100%
                    offset = offset + 8;
                    totalSensors = totalSensors + 1;

                    % Skip invalid sensor IDs (FF/AA prefixes are GWN/CH, not sensors)
                    sensorHex = dec2hex(uint16(sensorID), 4);
                    if startsWith(sensorHex, 'FF') || startsWith(sensorHex, 'AA')
                        obj.addLog(sprintf('t=%d [5.2_SKIP] Invalid sensor ID %s (is GWN/CH)', t, sensorHex));
                        continue;
                    end

                    % Update or add to sensor registry
                    idx = find([obj.sensorRegistry.id] == sensorID, 1);
                    if isempty(idx)
                        % New sensor - create entry with route history and RSSI quality
                        % parentCH is the ORIGINAL aggregating GWN, not the immediate forwarder
                        newEntry = struct( ...
                            'id', sensorID, ...
                            'hexID', dec2hex(uint16(sensorID), 4), ...
                            'parentCH', originalSender, ...
                            'routeHistory', {{senderHex}}, ...
                            'rssiQuality', qualityLabel, ...
                            'TrustScore', 50, ... % Default trust for new sensor
                            'timeseries', struct('time', sensorTime, 'value', sensorValue, ...
                                                'rssi', sensorRSSI, 'battery', sensorBattery));
                        if isempty(obj.sensorRegistry)
                            obj.sensorRegistry = newEntry;
                        else
                            % Ensure TrustScore and rssiQuality fields exist before appending
                            if ~isfield(obj.sensorRegistry, 'rssiQuality')
                                [obj.sensorRegistry.rssiQuality] = deal('UNKNOWN');
                            end
                            if ~isfield(obj.sensorRegistry, 'TrustScore')
                                [obj.sensorRegistry.TrustScore] = deal(50);
                            end
                            obj.sensorRegistry(end+1) = newEntry;
                        end

                        % Update global trust registry for new sensor
                        obj.updateGlobalTrust(sensorID, sensorHex, 'SENSOR', t, true);

                        obj.addLog(sprintf('t=%d [5.2_RX] NEW sensor %s [%s] val=%d bat=%d%% rssi=%ddBm via %s', ...
                            t, sensorHex, qualityLabel, sensorValue, sensorBattery, sensorRSSI, senderHex));
                    else
                        % Existing sensor - append to timeseries
                        newPoint = struct('time', sensorTime, 'value', sensorValue, ...
                                         'rssi', sensorRSSI, 'battery', sensorBattery);
                        obj.sensorRegistry(idx).timeseries(end+1) = newPoint;

                        % Increment trust for successful data reception
                        if ~isfield(obj.sensorRegistry, 'TrustScore')
                            [obj.sensorRegistry.TrustScore] = deal(50);
                        end
                        obj.sensorRegistry(idx).TrustScore = min(100, obj.sensorRegistry(idx).TrustScore + 1);

                        % Update global trust registry
                        obj.updateGlobalTrust(sensorID, sensorHex, 'SENSOR', t, true);

                        % Update RSSI quality (ensure field exists first)
                        if ~isfield(obj.sensorRegistry, 'rssiQuality')
                            [obj.sensorRegistry.rssiQuality] = deal('UNKNOWN');
                        end
                        obj.sensorRegistry(idx).rssiQuality = qualityLabel;

                        % APPEND to route history if parent changed (don't purge)
                        % Compare against originalSender (aggregating GWN), not immediate forwarder
                        if obj.sensorRegistry(idx).parentCH ~= originalSender
                            obj.sensorRegistry(idx).parentCH = originalSender;
                            % Append new route to history (not overwrite)
                            if ~isfield(obj.sensorRegistry(idx), 'routeHistory') || isempty(obj.sensorRegistry(idx).routeHistory)
                                obj.sensorRegistry(idx).routeHistory = {senderHex};
                            elseif ~any(strcmp(obj.sensorRegistry(idx).routeHistory, senderHex))
                                % Only add if not already in history
                                obj.sensorRegistry(idx).routeHistory{end+1} = senderHex;
                            end
                            obj.addLog(sprintf('t=%d [5.2_RX] Sensor %s REROUTED to %s (history: %s)', ...
                                t, sensorHex, senderHex, strjoin(obj.sensorRegistry(idx).routeHistory, '->')));
                        end

                        % Limit timeseries to last 100 points
                        if numel(obj.sensorRegistry(idx).timeseries) > 100
                            obj.sensorRegistry(idx).timeseries(1) = [];
                        end
                    end
                end
            end

            % Extract token ID from end of payload (last 2 bytes)
            tokenID = 0;  % Default for backward compatibility
            if numel(payload) >= offset + 1  % At least 2 bytes remaining
                tokenID = typecast(uint8(payload(end-1:end)), 'uint16');
                obj.addLog(sprintf('t=%d [5.2_TOKEN] Message associated with token #%d from %s', ...
                    t, tokenID, dec2hex(uint16(originalSender), 4)));
            end

            obj.addLog(sprintf('t=%d [5.2_RX] Aggregated %d sensors from %s (via %s) | Groups: [%s]', ...
                t, totalSensors, dec2hex(uint16(originalSender), 4), dec2hex(uint16(sender), 4), groupSummary));

            % Update global trust for aggregating GWN
            obj.updateGlobalTrust(originalSender, dec2hex(uint16(originalSender), 4), 'GWN', t, true);
        end
    end
end
