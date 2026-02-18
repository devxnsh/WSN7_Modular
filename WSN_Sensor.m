classdef WSN_Sensor < WSN_Node
    properties
        % --- SENSOR DATA TRANSMISSION ---
        sensorPeriod = 0           % Fixed random period 3-7 TFs (set once)
        nextSensorTX = 0           % Next scheduled sensor TX time
        sensorValue = 0            % Current sensor reading (random 0-100)
        prevSensorValue = 50       % Previous sensor value for priority calculation
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
            if obj.battery <= 0, obj.isAwake = false; return; end
            
            % Sensors SLEEP when not transmitting (very low discharge)
            % Wake cycle only during TX window
            if mod(t + obj.offset, 20) < 4
                obj.isAwake = true;
                % Awake: normal idle cost (but minimal since wake window is short)
                obj.battery = max(0, obj.battery - WSN_Config.IdleCost);
            else
                obj.isAwake = false;
                % Sleep: very low discharge (v.v. low power mode)
                obj.battery = max(0, obj.battery - WSN_Config.SleepCost);
            end
        end
        
        function msgs = step(obj, t, ~, ~)
            msgs = [];
            
            % --- PHASE 2: HELLO BURST ---
            if t >= 0 && t == obj.nextHelloBurst
                helloMsg = obj.createHelloMessage(t);
                msgs = [msgs, helloMsg];
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
                        % Generate new sensor reading
                        newValue = randi([0, 100]);
                        
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
                        
                        obj.addLog(sprintf('t=%d [SENSOR_TX] val=%d bat=%d%% pri=%d -> %s', ...
                            t, obj.sensorValue, uint8(obj.battery), priority, dec2hex(uint16(target), 4)));
                    end
                    
                    % Schedule next TX with jitter
                    jitter = randi([WSN_Config.SENSOR_JITTER_MIN, WSN_Config.SENSOR_JITTER_MAX]);
                    obj.nextSensorTX = t + obj.sensorPeriod + jitter;
                end
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
            
            % Destination filtering for broadcast/multicast
            myID = hex2dec(obj.hexID);
            dst = msg.dst;
            isBroadcast = isempty(dst) || dst == 0 || dst == hex2dec('FFFF');
            
            if ~isBroadcast
                % Only process broadcasts (Hello messages are always broadcast)
                return;
            end
            
            % --- PHASE 2: HELLO MESSAGE (Type 0) ---
            if msg.type == 0 && msg.verifyChecksum()
                obj.handleHelloReception(msg, t, rssi);
            end
            
            % Sensors don't process other messages in this simulation
            % They are passive data sources
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
                    'trust', 20, 'commRange', 0, 'status', 0, ...
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