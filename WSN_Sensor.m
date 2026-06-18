classdef WSN_Sensor < WSN_Node
    properties
        % --- SENSOR DATA TRANSMISSION ---
        sensorPeriod = 0           % Fixed random period 3-7 TFs (set once)
        nextSensorTX = 0           % Next scheduled sensor TX time
        sensorValue = 0            % Current sensor reading (random 0-100)
        prevSensorValue = 50       % Previous sensor value for priority calculation
        
        % --- ORPHAN STATE & EXTENDED SLEEP ---
        isOrphaned = false         % True if no CH/GWN found for extended period
        orphanCheckCount = 0       % Counter for consecutive failed target searches
        orphanThreshold = 5        % Consecutive failures before orphan mode
        
        % --- RADIO STATE ---
        radioState = 'RX'          % 'RX', 'TX', 'SLEEP' - default RX when awake
        
        % --- PANIC HANDLING ---
        lastPanicTime = -1000      % Last time a panic was sent (cooldown)
        panicCooldown = 500        % Min timeframes between panic signals (very rare)
        seenPanicUIDs = []         % UIDs of already-processed panic messages (dedup)
        
        % --- TRUST STUB (Placeholder for future trust model) ---
        neighborTrust = struct('id',{}, 'score',{})  % Trust scores per neighbor

        % --- ML-IDS CENSUS PROTOCOL (ML_IDS_PLAN.md Phase 4) ---
        censusActivePolls = struct('pollUID',{}, 'suspectID',{}, 'startTick',{}, 'yesCount',{}, 'totalVoters',{}, 'voterIDs',{})
        censusSeenPolls = []   % pollUIDs already voted on (dedup)
    end
    
    methods
        function obj = WSN_Sensor(id, pos)
            if nargin == 0, id=0; pos=[0 0]; end
            obj@WSN_Node(id, pos, WSN_Config.TIER_SENSOR);
            obj.typeStr = 'SENSOR';
            obj.txPower = WSN_Config.TxPower_Sensor;
            
            % Initialize sensor period (fixed random 3-7)
            obj.sensorPeriod = randi([WSN_Config.SENSOR_PERIOD_MIN, WSN_Config.SENSOR_PERIOD_MAX]);
        end
        
        function updatePhysics(obj, t)
            if obj.battery <= 0, obj.isAwake = false; obj.radioState = 'SLEEP'; return; end
            
            % Determine wake window based on orphan state
            if obj.isOrphaned
                % Extended sleep mode: 75% longer sleep cycles
                wakeWindow = WSN_Config.SENSOR_ORPHAN_WAKE_WINDOW;
                sleepCycleFactor = 1 + WSN_Config.SENSOR_ORPHAN_SLEEP_FACTOR;
                cycleLength = round(20 * sleepCycleFactor);  % Extended cycle
            else
                wakeWindow = WSN_Config.SENSOR_NORMAL_WAKE_WINDOW;
                cycleLength = 20;  % Normal cycle
            end
            
            % Wake cycle: sensor wakes briefly during TX window
            if mod(t + obj.offset, cycleLength) < wakeWindow
                obj.isAwake = true;
                obj.radioState = 'RX';  % Default to RX mode when awake (listening)
                % Awake: idle cost
                obj.battery = max(0, obj.battery - WSN_Config.IdleCost);
            else
                obj.isAwake = false;
                obj.radioState = 'SLEEP';
                % Sleep: very low discharge
                obj.battery = max(0, obj.battery - WSN_Config.SleepCost);
            end
        end
        
        function msgs = step(obj, t, ~, ~)
            msgs = [];
            if obj.isBlacklisted, return; end

            % --- ML-IDS CENSUS: trigger polls / finalize timed-out polls ---
            censusMsgs = obj.checkCensusTriggers(t);
            if ~isempty(censusMsgs), msgs = [msgs, censusMsgs]; end

            % === ATTACK: FLOODING (Hello Flood) ===
            % Malicious sensor broadcasts excessive HELLO messages with inflated TX power
            if WSN_Attack.isMaliciousNode(obj.id) && ...
               WSN_Attack.getAttackType(obj.id) == WSN_Attack.ATTACK_FLOODING
                floodCount = WSN_Attack.getFloodingBurstCount(obj.id, t);
                if floodCount > 0
                    % Temporarily inflate TX power for flooding
                    originalPower = obj.txPower;
                    obj.txPower = WSN_Attack.getFloodingTxPower(obj.id);
                    
                    % Broadcast multiple HELLO messages
                    for fi = 1:floodCount
                        floodMsg = obj.createHelloMessage(t);
                        floodMsg.uid = randi(1e9);  % Unique ID per flood message
                        msgs = [msgs, floodMsg];
                        obj.addLog(sprintf('t=%d [HELLO_TX] bat=%d%% nbr=%d', ...
                            t, uint8(obj.battery), numel(obj.neighborTable)));
                    end
                    
                    % Restore original power
                    obj.txPower = originalPower;
                end
            end
            
            % === ATTACK: PANIC FLOOD (Sinkhole Variant) ===
            % Malicious sensor broadcasts fake emergency alerts
            if WSN_Attack.isMaliciousNode(obj.id) && ...
               WSN_Attack.getAttackType(obj.id) == WSN_Attack.ATTACK_PANIC_FLOOD
                if WSN_Attack.shouldPanicFlood(obj.id, t)
                    panicMsg = WSN_Attack.createFakePanicBeacon(obj.id, obj.hexID, t);
                    if ~isempty(panicMsg)
                        msgs = [msgs, panicMsg];
                        obj.addLog(sprintf('t=%d [PANIC_TX] type=%d sev=%d', ...
                            t, panicMsg.subtype, 2));
                    end
                end
            end
            
            % --- PHASE 2: HELLO BURST ---
            if t >= 0 && t == obj.nextHelloBurst
                helloMsg = obj.createHelloMessage(t);
                msgs = [msgs, helloMsg];
                obj.radioState = 'TX';  % Mark as transmitting
                % Local log only (no global event bus for Hello)
                obj.addLog(sprintf('t=%d [HELLO_TX] bat=%d%% nbr=%d', ...
                    t, uint8(obj.battery), numel(obj.neighborTable)));
                obj.scheduleNextHelloBurst(t);
            end
            
            % --- SENSOR DATA TRANSMISSION (Type 1) ---
            if t >= WSN_Config.SENSOR_START_TIME
                % Initialize first TX time
                if obj.nextSensorTX == 0
                    jitter = randi([WSN_Config.SENSOR_JITTER_MIN, WSN_Config.SENSOR_JITTER_MAX]);
                    obj.nextSensorTX = t + obj.sensorPeriod + jitter;
                end
                
                % Time to transmit?
                if t >= obj.nextSensorTX
                    % Find best target (closest verified CH or GWN)
                    target = obj.findBestSensorTarget();
                    
                    if ~isempty(target)
                        % Reset orphan state - we have connectivity
                        if obj.isOrphaned
                            obj.addLog(sprintf('t=%d [ORPHAN_RECOVERED] Found target %s', ...
                                t, dec2hex(uint16(target), 4)));
                        end
                        obj.isOrphaned = false;
                        obj.orphanCheckCount = 0;
                        
                        % Generate new sensor reading (realistic: gradual drift with rare spikes)
                        % Normal operation: small random walk around current value
                        drift = randi([-5, 5]);  % Small drift: -5 to +5
                        newValue = max(0, min(100, obj.prevSensorValue + drift));
                        
                        % Rare anomaly event: 0.5% chance of extreme spike (actual emergency)
                        if rand() < 0.005
                            % Extreme spike: jump to very high or very low value
                            if rand() < 0.5
                                newValue = randi([90, 100]);  % Spike high
                            else
                                newValue = randi([0, 10]);    % Spike low
                            end
                        end
                        
                        % === ANOMALY DETECTION ===
                        % Check for significant deviation from previous value
                        % With gradual drift, this should ONLY trigger on actual spikes
                        anomalyDetected = false;
                        if obj.prevSensorValue > 0
                            pctChange = abs(newValue - obj.prevSensorValue) / obj.prevSensorValue * 100;
                            if pctChange >= WSN_Config.PANIC_ANOMALY_THRESHOLD
                                anomalyDetected = true;
                            end
                        end
                        
                        % Check critical battery
                        batteryCritical = obj.battery <= WSN_Config.PANIC_BATTERY_CRIT_LEVEL;
                        
                        % === PANIC SIGNAL GENERATION ===
                        if (anomalyDetected || batteryCritical) && ...
                           (t - obj.lastPanicTime) >= obj.panicCooldown
                            
                            % Determine panic type and severity
                            if anomalyDetected && batteryCritical
                                panicType = WSN_Config.PANIC_SUB_ANOMALY;
                                panicSeverity = WSN_Config.PANIC_SEV_HIGH;
                            elseif batteryCritical
                                panicType = WSN_Config.PANIC_SUB_BATTERY_CRIT;
                                panicSeverity = WSN_Config.PANIC_SEV_MEDIUM;
                            else
                                panicType = WSN_Config.PANIC_SUB_ANOMALY;
                                panicSeverity = WSN_Config.PANIC_SEV_MEDIUM;
                            end
                            
                            % Create and send panic message
                            panicMsg = obj.createPanicMessage(t, target, panicType, panicSeverity, newValue);
                            msgs = [msgs, panicMsg];
                            obj.lastPanicTime = t;
                            obj.radioState = 'TX';
                            
                            obj.addLog(sprintf('t=%d [PANIC_TX] type=%d sev=%d val=%d -> %s', ...
                                t, panicType, panicSeverity, newValue, dec2hex(uint16(target), 4)));
                        end
                        
                        % Calculate priority based on value change (2-bit field)
                        % Priority 0: default, 1: 20% change, 2: 45% change, 3: reserved
                        priority = 0;
                        if obj.prevSensorValue > 0
                            pctChange = abs(newValue - obj.prevSensorValue) / obj.prevSensorValue * 100;
                            if pctChange >= 45
                                priority = 2;
                            elseif pctChange >= 20
                                priority = 1;
                            end
                        end
                        obj.prevSensorValue = newValue;
                        obj.sensorValue = newValue;
                        
                        % Update parent to current target (shows in Network Table)
                        if isempty(obj.parent) || obj.parent ~= target
                            oldParent = obj.parent;
                            obj.parent = target;
                            if ~isempty(oldParent)
                                obj.addLog(sprintf('t=%d [PARENT_CHANGE] %s -> %s', ...
                                    t, dec2hex(uint16(oldParent), 4), dec2hex(uint16(target), 4)));
                            end
                        end
                        
                        % Create and send sensor message with priority
                        sensorMsg = obj.createSensorMessage(t, target, priority);
                        msgs = [msgs, sensorMsg];
                        obj.radioState = 'TX';  % Mark as transmitting
                        
                        obj.addLog(sprintf('t=%d [SENSOR_TX] val=%d bat=%d%% pri=%d -> %s', ...
                            t, obj.sensorValue, uint8(obj.battery), priority, dec2hex(uint16(target), 4)));
                    else
                        % No target found - increment orphan counter
                        obj.orphanCheckCount = obj.orphanCheckCount + 1;
                        
                        if obj.orphanCheckCount >= obj.orphanThreshold && ~obj.isOrphaned
                            obj.isOrphaned = true;
                            obj.addLog(sprintf('t=%d [ORPHAN_MODE] No CH/GWN found - entering extended sleep (75%%)', t));
                            
                            % Send LINK_LOSS panic as broadcast flood
                            if (t - obj.lastPanicTime) >= obj.panicCooldown
                                panicMsg = obj.createPanicMessage(t, [], ...
                                    WSN_Config.PANIC_SUB_LINK_LOSS, WSN_Config.PANIC_SEV_HIGH, 0);
                                msgs = [msgs, panicMsg];
                                obj.lastPanicTime = t;
                                obj.radioState = 'TX';
                                obj.addLog(sprintf('t=%d [PANIC_TX] LINK_LOSS broadcast', t));
                            end
                        end
                    end
                    
                    % Schedule next TX with jitter
                    jitter = randi([WSN_Config.SENSOR_JITTER_MIN, WSN_Config.SENSOR_JITTER_MAX]);
                    obj.nextSensorTX = t + obj.sensorPeriod + jitter;
                end
            end
            
            % Return to RX mode after TX operations
            if ~strcmp(obj.radioState, 'SLEEP')
                obj.radioState = 'RX';
            end
        end
        
        function target = findBestSensorTarget(obj)
            % Find closest verified CH or GWN
            % SN prefers GWN if GWN is significantly closer
            target = [];
            
            if isempty(obj.neighborTable)
                return;
            end
            
            % Ensure isVerified field exists
            if ~isfield(obj.neighborTable, 'isVerified')
                return;
            end
            
            % Find verified CHs (tier 2) and GWNs (tier 3)
            verified = [obj.neighborTable.isVerified];
            tiers = [obj.neighborTable.tier];
            rssis = [obj.neighborTable.rssi];
            
            % Verified CHs
            chMask = verified & (tiers == WSN_Config.TIER_CH);
            % Verified GWNs
            gwnMask = verified & (tiers == WSN_Config.TIER_GWN);
            
            bestCH = [];
            bestCH_rssi = -Inf;
            if any(chMask)
                chRssis = rssis(chMask);
                [bestCH_rssi, idx] = max(chRssis);
                chIds = [obj.neighborTable(chMask).id];
                bestCH = chIds(idx);
            end
            
            bestGWN = [];
            bestGWN_rssi = -Inf;
            if any(gwnMask)
                gwnRssis = rssis(gwnMask);
                [bestGWN_rssi, idx] = max(gwnRssis);
                gwnIds = [obj.neighborTable(gwnMask).id];
                bestGWN = gwnIds(idx);
            end
            
            % Decision: prefer GWN if RSSI is better by threshold factor
            % Higher RSSI = closer distance (in log scale)
            if ~isempty(bestGWN) && ~isempty(bestCH)
                % RSSI is in log scale, so compare directly
                % GWN wins if its RSSI >= CH_RSSI * factor (factor < 1 means GWN can be weaker)
                % But for distance: higher RSSI = closer, so GWN wins if RSSI is higher
                % Use distance factor: GWN preferred if GWN closer by factor
                % RSSI ~ -10*n*log10(d), so higher RSSI = shorter distance
                % GWN preferred if d_GWN < d_CH * factor
                % Equivalent: RSSI_GWN > RSSI_CH + offset
                rssiOffset = 10 * 2.4 * log10(1/WSN_Config.SN_GWN_DISTANCE_FACTOR);  % ~4.8 dB for 0.8 factor
                if bestGWN_rssi > (bestCH_rssi + rssiOffset)
                    target = bestGWN;
                else
                    target = bestCH;
                end
            elseif ~isempty(bestCH)
                target = bestCH;
            elseif ~isempty(bestGWN)
                target = bestGWN;
            end
        end
        
        function msg = createSensorMessage(obj, t, target, priority)
            % Create Type 1 sensor message
            % Payload: [SensorValue(2), Battery(1), Priority(1)] - priority is 2-bit in byte
            if nargin < 4, priority = 0; end
            
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_SENSOR;
            msg.subtype = bitand(priority, 3);  % 2-bit priority in subtype field
            msg.src = hex2dec(obj.hexID);
            msg.dst = target;
            msg.ttl = 1;  % Single hop
            msg.seq = mod(t, 256);
            
            % Payload: sensor value (2 bytes) + battery (1 byte)
            sensorBytes = typecast(uint16(obj.sensorValue), 'uint8');
            batteryByte = uint8(round(obj.battery));
            msg.payload = [sensorBytes, batteryByte];
            msg.payloadLen = 3;
            
            msg.addChecksum();
            msg.color = [0.3 0.5 1.0];  % Blue for Type 1 sensor data
        end
        
        function response = receive(obj, msg, t, rssi)
            response = [];
            if obj.isBlacklisted, return; end

            % Only process if awake and in RX mode
            if ~obj.isAwake || strcmp(obj.radioState, 'SLEEP')
                return;
            end
            
            % === ATTACK: BLACKHOLE/GRAYHOLE CHECK ===
            % Malicious sensor may drop messages instead of processing/forwarding
            if WSN_Attack.isMaliciousNode(obj.id)
                attackType = WSN_Attack.getAttackType(obj.id);
                if attackType == WSN_Attack.ATTACK_BLACKHOLE
                    if WSN_Attack.shouldDropBlackhole(obj.id, t)
                        % Log RX only - no forward/TX logged (stealth)
                        obj.addLog(sprintf('t=%d [RX] type=%d.%d <- %s (no action)', ...
                            t, msg.type, msg.subtype, dec2hex(uint16(msg.src), 4)));
                        return;  % Drop message
                    end
                elseif attackType == WSN_Attack.ATTACK_GRAYHOLE
                    if WSN_Attack.shouldDropGrayhole(obj.id, t)
                        % Log RX only - no forward/TX logged (stealth)
                        obj.addLog(sprintf('t=%d [RX] type=%d.%d <- %s (no action)', ...
                            t, msg.type, msg.subtype, dec2hex(uint16(msg.src), 4)));
                        return;  % Drop message selectively
                    end
                end
            end
            
            % Destination filtering for broadcast/multicast
            myID = hex2dec(obj.hexID);
            dst = msg.dst;
            isBroadcast = isempty(dst) || dst == 0 || dst == hex2dec('FFFF');
            isForMe = (dst == myID);
            
            % --- PHASE 2: HELLO MESSAGE (Type 0) ---
            if msg.type == 0 && isBroadcast && msg.verifyChecksum()
                obj.handleHelloReception(msg, t, rssi);
                return;
            end

            % --- ML-IDS CENSUS (Type 11) ---
            if msg.type == WSN_Config.MSG_TYPE_CENSUS && msg.verifyChecksum()
                response = obj.handleCensusMessage(msg, t);
                return;
            end

            % --- ML-IDS SHUTDOWN (Type 12) ---
            if msg.type == WSN_Config.MSG_TYPE_SHUTDOWN && isForMe && msg.verifyChecksum()
                obj.handleShutdownMessage(msg, t);
                return;
            end

            % --- PANIC MESSAGE (Type 2) ---
            if msg.type == WSN_Config.MSG_TYPE_PANIC && msg.verifyChecksum()
                response = obj.handlePanicReception(msg, t, rssi);
                return;
            end
        end
        
        function response = handlePanicReception(obj, msg, t, rssi)
            % Handle incoming panic message - decide to forward or discard
            response = [];
            sender = msg.src;
            
            % Check if already seen this panic (deduplication by UID)
            if ismember(msg.uid, obj.seenPanicUIDs)
                return;  % Already processed
            end
            obj.seenPanicUIDs = [obj.seenPanicUIDs, msg.uid];
            
            % Prune old UIDs (keep last 50)
            if numel(obj.seenPanicUIDs) > 50
                obj.seenPanicUIDs = obj.seenPanicUIDs(end-49:end);
            end
            
            % Check TTL
            if msg.ttl <= 0
                obj.addLog(sprintf('t=%d [PANIC_DROP] TTL expired from %s', ...
                    t, dec2hex(uint16(sender), 4)));
                return;
            end
            
            % === TRUST-BASED FORWARDING DECISION (STUB) ===
            trustScore = obj.getNeighborTrust(sender);
            if trustScore < 10  % Very low trust - discard
                obj.addLog(sprintf('t=%d [PANIC_DROP] Low trust (%.1f) from %s', ...
                    t, trustScore, dec2hex(uint16(sender), 4)));
                return;
            end
            
            obj.addLog(sprintf('t=%d [PANIC_RX] type=%d sev=%d from %s trust=%.1f', ...
                t, msg.subtype, msg.prio, dec2hex(uint16(sender), 4), trustScore));
            
            % Forward panic to parent (if connected) or broadcast
            if ~isempty(obj.parent)
                % Unicast forward to parent
                fwdMsg = obj.createPanicForward(msg, obj.parent);
                response = fwdMsg;
                obj.addLog(sprintf('t=%d [PANIC_FWD] -> parent %s (TTL=%d)', ...
                    t, dec2hex(uint16(obj.parent), 4), fwdMsg.ttl));
            elseif msg.prio >= WSN_Config.PANIC_SEV_HIGH
                % High severity: broadcast flood
                fwdMsg = obj.createPanicForward(msg, []);
                response = fwdMsg;
                obj.addLog(sprintf('t=%d [PANIC_FWD] -> broadcast (TTL=%d)', t, fwdMsg.ttl));
            end
        end
        
        function fwdMsg = createPanicForward(obj, origMsg, dst)
            % Create forwarded panic message with decremented TTL
            fwdMsg = WSN_Message();
            fwdMsg.type = WSN_Config.MSG_TYPE_PANIC;
            fwdMsg.subtype = origMsg.subtype;
            fwdMsg.src = hex2dec(obj.hexID);  % Immediate forwarder
            fwdMsg.dst = dst;  % Can be empty for broadcast
            fwdMsg.ttl = origMsg.ttl - 1;  % Decrement TTL
            fwdMsg.prio = origMsg.prio;
            fwdMsg.seq = origMsg.seq;
            fwdMsg.uid = origMsg.uid;  % Preserve UID for deduplication
            
            % Copy payload (contains original sender + data)
            fwdMsg.payload = origMsg.payload;
            fwdMsg.payloadLen = origMsg.payloadLen;
            
            fwdMsg.addChecksum();
            fwdMsg.color = [1.0 0.2 0.2];  % Red for panic
        end
        
        function msg = createPanicMessage(obj, t, target, panicType, severity, sensorValue)
            % Create Type 2 PANIC message
            % Payload: [OriginalSrc(2), SensorValue(2), Battery(1), Timestamp(2)]
            % Fields:
            %   - type: MSG_TYPE_PANIC (2)
            %   - subtype: panic type (ANOMALY, BATTERY_CRIT, INTRUSION, LINK_LOSS)
            %   - prio: severity level (LOW, MEDIUM, HIGH, CRITICAL)
            %   - ttl: time-to-live for flood propagation
            %   - payload: sensor data context
            
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_PANIC;
            msg.subtype = uint8(panicType);
            msg.src = hex2dec(obj.hexID);
            msg.dst = target;  % Can be empty for broadcast flood
            msg.prio = uint8(severity);
            msg.seq = mod(t, 256);
            
            % Set TTL based on severity
            if severity >= WSN_Config.PANIC_SEV_HIGH
                msg.ttl = WSN_Config.PANIC_DEFAULT_TTL;
            else
                msg.ttl = 1;  % Low/medium: single hop to parent
            end
            
            % Payload: original sender (2) + sensor value (2) + battery (1) + timestamp (2)
            origSrcBytes = typecast(uint16(hex2dec(obj.hexID)), 'uint8');
            valueBytes = typecast(uint16(sensorValue), 'uint8');
            batteryByte = uint8(round(obj.battery));
            timeBytes = typecast(uint16(mod(t, 65536)), 'uint8');
            msg.payload = [origSrcBytes, valueBytes, batteryByte, timeBytes];
            msg.payloadLen = 7;
            
            msg.addChecksum();
            msg.color = [1.0 0.2 0.2];  % Red for panic
        end
        
        % =====================================================
        % TRUST STUB (Placeholder for future trust model)
        % =====================================================
        function score = getNeighborTrust(obj, neighborID)
            % STUB: Returns trust score for a neighbor
            % Future implementation will use historical behavior analysis
            %
            % Trust factors to consider (NOT YET IMPLEMENTED):
            % - Message delivery success rate
            % - Consistency of reported values
            % - Energy consumption patterns
            % - Response time to queries
            % - Anomalous behavior detection
            
            idx = find([obj.neighborTrust.id] == neighborID, 1);
            if isempty(idx)
                % Default trust for unknown neighbors
                score = 50;  % Neutral trust
            else
                score = obj.neighborTrust(idx).score;
            end
        end
        
        function updateNeighborTrust(obj, neighborID, delta)
            % Update trust score for neighbor (rule-based, no ML).
            % delta > 0: increase trust (good behavior)
            % delta < 0: decrease trust (suspicious behavior)

            idx = find([obj.neighborTrust.id] == neighborID, 1);
            if isempty(idx)
                obj.neighborTrust(end+1) = struct('id', neighborID, 'score', WSN_Config.TRUST_INITIAL + delta);
            else
                newScore = max(WSN_Config.TRUST_MIN, min(WSN_Config.TRUST_MAX, obj.neighborTrust(idx).score + delta));
                obj.neighborTrust(idx).score = newScore;
            end
        end

        % =====================================================
        % ML-IDS CENSUS / SHUTDOWN PROTOCOL (ML_IDS_PLAN.md Phase 4)
        % Daisy-chain trust polling + blacklist enforcement, rule-based.
        % =====================================================
        function msgs = checkCensusTriggers(obj, t)
            msgs = [];

            % --- Trigger new polls for any newly-distrusted neighbor ---
            for i = 1:numel(obj.neighborTrust)
                suspectID = obj.neighborTrust(i).id;
                if obj.neighborTrust(i).score >= WSN_Config.TRUST_CENSUS_TRIGGER
                    continue;
                end
                already = ~isempty(obj.censusActivePolls) && any([obj.censusActivePolls.suspectID] == suspectID);
                if already, continue; end

                pollUID = randi(65535);
                pollMsg = WSN_Message(WSN_Config.MSG_TYPE_CENSUS, hex2dec(obj.hexID), hex2dec('FFFF'), []);
                pollMsg.subtype = WSN_Config.CENSUS_POLL_INITIATE;
                pollMsg.ttl = 1;
                pollMsg.setCensusPollPayload(suspectID, pollUID, 1);
                pollMsg.addChecksum();
                msgs = [msgs, pollMsg]; %#ok<AGROW>

                obj.censusActivePolls(end+1) = struct('pollUID', pollUID, 'suspectID', suspectID, ...
                    'startTick', t, 'yesCount', 0, 'totalVoters', 0, 'voterIDs', []);
                obj.addLog(sprintf('t=%d [CENSUS_INITIATE] suspect=%s trust=%.1f pollUID=%d', ...
                    t, dec2hex(uint16(suspectID), 4), obj.neighborTrust(i).score, pollUID));
            end

            % --- Finalize any polls past timeout ---
            if isempty(obj.censusActivePolls), return; end
            ages = t - [obj.censusActivePolls.startTick];
            doneIdx = find(ages >= WSN_Config.CENSUS_POLL_TIMEOUT);
            for k = fliplr(doneIdx)
                poll = obj.censusActivePolls(k);
                if poll.totalVoters < WSN_Config.CENSUS_MIN_VOTERS
                    verdict = 2; % inconclusive
                elseif poll.yesCount / poll.totalVoters >= WSN_Config.CENSUS_QUORUM_YES_RATIO
                    verdict = 1; % malicious
                    obj.updateNeighborTrust(poll.suspectID, WSN_Config.TRUST_MIN - WSN_Config.TRUST_INITIAL);
                else
                    verdict = 0; % cleared
                    idx = find([obj.neighborTrust.id] == poll.suspectID, 1);
                    if ~isempty(idx)
                        obj.neighborTrust(idx).score = WSN_Config.TRUST_INITIAL;
                    end
                end

                if ~isempty(obj.parent)
                    completeMsg = WSN_Message(WSN_Config.MSG_TYPE_CENSUS, hex2dec(obj.hexID), obj.parent, []);
                    completeMsg.subtype = WSN_Config.CENSUS_POLL_COMPLETE;
                    completeMsg.ttl = 5;
                    completeMsg.setCensusCompletePayload(poll.suspectID, verdict, poll.yesCount, poll.totalVoters);
                    completeMsg.addChecksum();
                    msgs = [msgs, completeMsg]; %#ok<AGROW>
                end

                obj.addLog(sprintf('t=%d [CENSUS_COMPLETE] suspect=%s verdict=%d (%d/%d votes)', ...
                    t, dec2hex(uint16(poll.suspectID), 4), verdict, poll.yesCount, poll.totalVoters));
                obj.censusActivePolls(k) = [];
            end
        end

        function response = handleCensusMessage(obj, msg, t)
            response = [];
            sender = msg.src;

            if msg.subtype == WSN_Config.CENSUS_POLL_INITIATE
                if ismember(msg.uid, obj.censusSeenPolls), return; end
                obj.censusSeenPolls = [obj.censusSeenPolls, msg.uid];
                if numel(obj.censusSeenPolls) > 50
                    obj.censusSeenPolls = obj.censusSeenPolls(end-49:end);
                end

                [suspectID, pollUID, ~] = msg.getCensusPollPayload();
                idx = find([obj.neighborTrust.id] == suspectID, 1);
                if isempty(idx), return; end % no opinion on this suspect -> silently abstain

                voteMsg = WSN_Message(WSN_Config.MSG_TYPE_CENSUS, hex2dec(obj.hexID), sender, []);
                if obj.neighborTrust(idx).score < WSN_Config.TRUST_CENSUS_TRIGGER
                    voteMsg.subtype = WSN_Config.CENSUS_POLL_YES;
                else
                    voteMsg.subtype = WSN_Config.CENSUS_POLL_NO;
                end
                voteMsg.ttl = 1;
                voteMsg.setCensusPollPayload(suspectID, pollUID, 0);
                voteMsg.addChecksum();
                response = voteMsg;
                return;
            end

            if msg.subtype == WSN_Config.CENSUS_POLL_YES || msg.subtype == WSN_Config.CENSUS_POLL_NO
                [suspectID, pollUID, ~] = msg.getCensusPollPayload();
                pIdx = find([obj.censusActivePolls.pollUID] == pollUID & [obj.censusActivePolls.suspectID] == suspectID, 1);
                if isempty(pIdx), return; end
                if ismember(sender, obj.censusActivePolls(pIdx).voterIDs), return; end

                obj.censusActivePolls(pIdx).voterIDs = [obj.censusActivePolls(pIdx).voterIDs, sender];
                obj.censusActivePolls(pIdx).totalVoters = obj.censusActivePolls(pIdx).totalVoters + 1;
                if msg.subtype == WSN_Config.CENSUS_POLL_YES
                    obj.censusActivePolls(pIdx).yesCount = obj.censusActivePolls(pIdx).yesCount + 1;
                end
                return;
            end
        end

        function handleShutdownMessage(obj, msg, t)
            [~, flags] = msg.getDownPayload();
            switch msg.subtype
                case WSN_Config.SHUTDOWN_SOFT_RESET
                    obj.neighborTrust = struct('id',{}, 'score',{});
                    obj.censusActivePolls = struct('pollUID',{}, 'suspectID',{}, 'startTick',{}, 'yesCount',{}, 'totalVoters',{}, 'voterIDs',{});
                    obj.addLog(sprintf('t=%d [SHUTDOWN] SOFT_RESET - trust/poll state cleared', t));
                case WSN_Config.SHUTDOWN_HARD_RESET
                    obj.parent = [];
                    obj.isOrphaned = true;
                    obj.orphanCheckCount = 0;
                    obj.neighborTrust = struct('id',{}, 'score',{});
                    obj.addLog(sprintf('t=%d [SHUTDOWN] HARD_RESET - forced re-discovery', t));
                case WSN_Config.SHUTDOWN_BLACKLIST
                    obj.isBlacklisted = true;
                    obj.addLog(sprintf('t=%d [SHUTDOWN] BLACKLIST - node permanently silenced', t));
            end
        end

        function handleHelloReception(obj, msg, t, rssi)
            % Populate neighbor table from Hello message
            sender = msg.src;
            idx = find([obj.neighborTable.id] == sender, 1);
            
            % Extract tier, battery, neighborCount from Hello payload
            if msg.payloadLen >= 2
                [tier, battery, neighborCount] = msg.getHelloPayload();
            else
                tier = 0; battery = 0; neighborCount = 0;
            end
            
            % Extract verified status from message flag
            senderVerified = msg.isVerified();
            
            % Ensure isVerified field exists in neighbor table
            if ~isempty(obj.neighborTable) && ~isfield(obj.neighborTable, 'isVerified')
                [obj.neighborTable.isVerified] = deal(false);
            end
            
            if isempty(idx)
                obj.neighborTable(end+1) = struct( ...
                    'id', sender, 'lastSeen', t, 'rssi', rssi, ...
                    'TrustScore', 50, 'commRange', 0, 'status', 0, ...
                    'tier', tier, 'battery', battery, 'neighborCount', neighborCount, ...
                    'isVerified', senderVerified);
                % Local log only for NEW neighbors
                tierStr = 'UNK';
                if tier == 2, tierStr = 'CH';
                elseif tier == 3, tierStr = 'GWN';
                end
                obj.addLog(sprintf('t=%d [HELLO_RX] NEW %s tier=%d(%s) verified=%d rssi=%.1f', ...
                    t, dec2hex(uint16(sender),4), tier, tierStr, senderVerified, rssi));
            else
                % Silent update - no log for updates
                obj.neighborTable(idx).lastSeen = t;
                obj.neighborTable(idx).rssi = rssi;
                obj.neighborTable(idx).tier = tier;
                obj.neighborTable(idx).battery = battery;
                obj.neighborTable(idx).neighborCount = neighborCount;
                obj.neighborTable(idx).isVerified = senderVerified;
            end
        end
    end
end