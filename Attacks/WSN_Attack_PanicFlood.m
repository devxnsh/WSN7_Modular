classdef WSN_Attack_PanicFlood
    % =========================================================
    % PanicFlood ATTACK MODULE
    % =========================================================
    % Extracted verbatim from WSN_Attack.m (the PanicFlood ATTACK LOGIC
    % section). Stateless - all state lives in WSN_Attack's persistent
    % pDataStore, accessed via WSN_Attack.getData()/setData()/
    % recordGroundTruth() exactly as before the split. WSN_Attack.m keeps
    % thin one-line wrappers so every existing call site is unaffected.
    % =========================================================
    methods (Static)
        % =========================================================
        % PANIC FLOOD ATTACK LOGIC
        % Intensity 1 = Constant panic floods (obvious false alarms)
        % Intensity 10 = Rare panic signals (hard to distinguish from real)
        % REALISTIC: Cooldown between panics, varied severity, rate limiting
        % =========================================================
        function [shouldFlood, panicSubtype] = shouldPanicFlood(nodeIdx, t)
            data = WSN_Attack.getData();
            shouldFlood = false;
            panicSubtype = 0;  % Default: generic alarm
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_PANIC_FLOOD
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Check cooldown - realistic systems would notice repeated panics from same source
            lastPanicTick = data.panicLastTick(nodeIdx);
            % Minimum ticks between panics (more at high intensity to stay hidden)
            minCooldown = max(1, intensity - 2);  % 1 tick at intensity 1, 8 ticks at intensity 10
            if (t - lastPanicTick) < minCooldown && lastPanicTick > 0
                return;  % Still in cooldown
            end
            
            % Intensity determines base probability of panic this tick
            % Intensity 1-3: Very frequent panics (obvious spam)
            % Intensity 4-6: Periodic panics (every few ticks)
            % Intensity 7-10: Rare panics (occasional, looks like real emergency)
            if intensity <= 3
                shouldFlood = true;  % Every tick after cooldown - obvious spam
            elseif intensity <= 6
                period = 2 + intensity;  % period 6-8
                shouldFlood = mod(t, period) == 0;
            else
                % Rare: 15% -> 5% chance per eligible tick
                shouldFlood = rand() < (0.15 - (intensity - 7) * 0.03);
            end
            
            if shouldFlood
                % Vary panic type based on intensity
                % Low intensity: always uses same type (suspicious pattern)
                % High intensity: varies type (more realistic)
                if intensity <= 3
                    panicSubtype = 1;  % Always intrusion (pattern detectable)
                elseif intensity <= 6
                    panicSubtype = randi([1, 2]);  % Intrusion or fire
                else
                    panicSubtype = randi([1, 4]);  % Any type (intrusion, fire, medical, environmental)
                end
                
                % Update tracking
                data.panicLastTick(nodeIdx) = t;
                data.panicCooldown(nodeIdx) = minCooldown;
                WSN_Attack.setData(data);
                
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_PANIC_FLOOD, ...
                    sprintf('PANIC_TYPE%d', panicSubtype));
            end
        end
        
        function msg = createFakePanicBeacon(nodeIdx, hexID, t, panicSubtype) %
            % REALISTIC: Create panic with specified or varied subtype
            % nodeIdx reserved for future ground truth logging per node
            if nargin < 4
                panicSubtype = 1;  % Default: intrusion
            end
            
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_PANIC;
            
            % Map subtype to config constant
            switch panicSubtype
                case 1
                    msg.subtype = WSN_Config.PANIC_SUB_INTRUSION;
                case 2
                    if isprop(WSN_Config, 'PANIC_SUB_FIRE')
                        msg.subtype = WSN_Config.PANIC_SUB_FIRE;
                    else
                        msg.subtype = 2;
                    end
                case 3
                    if isprop(WSN_Config, 'PANIC_SUB_MEDICAL')
                        msg.subtype = WSN_Config.PANIC_SUB_MEDICAL;
                    else
                        msg.subtype = 3;
                    end
                otherwise
                    msg.subtype = panicSubtype;
            end
            
            msg.src = hex2dec(hexID);
            msg.dst = 0;  % Broadcast
            msg.ttl = WSN_Config.PANIC_DEFAULT_TTL;
            msg.seq = mod(t, 256);
            msg.prio = 3;  % High priority
            
            % Create plausible payload based on panic type
            sensorValue = randi([80, 100]);  % High reading to seem urgent
            confidence = randi([85, 99]);    % High confidence
            payload = [uint8(panicSubtype), uint8(sensorValue), uint8(confidence)];
            msg.payload = payload;
            msg.payloadLen = numel(payload);
            msg.addChecksum();
            msg.color = WSN_Attack.COLOR_PANIC_FLOOD;
        end
        
    end
end

