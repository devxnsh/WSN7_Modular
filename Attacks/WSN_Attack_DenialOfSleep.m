classdef WSN_Attack_DenialOfSleep
    % =========================================================
    % DenialOfSleep ATTACK MODULE
    % =========================================================
    % Extracted verbatim from WSN_Attack.m (the DenialOfSleep ATTACK LOGIC
    % section). Stateless - all state lives in WSN_Attack's persistent
    % pDataStore, accessed via WSN_Attack.getData()/setData()/
    % recordGroundTruth() exactly as before the split. WSN_Attack.m keeps
    % thin one-line wrappers so every existing call site is unaffected.
    % =========================================================
    methods (Static)
        % =========================================================
        % DENIAL OF SLEEP ATTACK LOGIC (Vampire)
        % Intensity 1 = Constantly wake ALL neighbors (obvious)
        % Intensity 10 = Occasionally wake few neighbors (stealthy)
        % REALISTIC: Cooldown between attacks, requires wake packets, energy tracking
        % =========================================================
        function [targets, wakeMsgs] = getDenialOfSleepTargets(nodeIdx, neighborTable, t)
            data = WSN_Attack.getData();
            targets = [];
            wakeMsgs = {};  % Array of actual wake messages to send
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_DENIAL_SLEEP
                return;
            end
            
            if isempty(neighborTable)
                return;
            end
            
            sensorNeighbors = neighborTable([neighborTable.tier] == 1);
            if isempty(sensorNeighbors)
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Check cooldown - can't spam wake packets instantly
            lastWakeTick = data.denialLastWakeTick(nodeIdx);
            minCooldown = max(1, 4 - floor(intensity / 3));  % 1-4 ticks based on intensity
            if (t - lastWakeTick) < minCooldown
                return;  % Still in cooldown
            end
            
            shouldAttack = false;
            
            % Intensity 1-3: Constantly target ALL sensors (obvious drain)
            % Intensity 4-6: Periodically target most sensors
            % Intensity 7-10: Rarely target few sensors (looks like normal traffic)
            if intensity <= 3
                shouldAttack = true;
                targets = [sensorNeighbors.id];
            elseif intensity <= 6
                period = intensity;  % period 4-6
                if mod(t, period) == 0
                    shouldAttack = true;
                    % Target 60-80% of sensors
                    numTargets = max(1, round(numel(sensorNeighbors) * (0.8 - (intensity - 4) * 0.1)));
                    idx = randperm(numel(sensorNeighbors), min(numTargets, numel(sensorNeighbors)));
                    targets = [sensorNeighbors(idx).id];
                end
            else
                % Stealthy: rare, few targets
                if rand() < (0.3 - (intensity - 7) * 0.06)  % 30% -> 12%
                    shouldAttack = true;
                    numTargets = randi([1, max(1, floor(numel(sensorNeighbors) * 0.3))]);
                    idx = randperm(numel(sensorNeighbors), min(numTargets, numel(sensorNeighbors)));
                    targets = [sensorNeighbors(idx).id];
                end
            end
            
            if shouldAttack && ~isempty(targets)
                % Generate actual wake messages for each target
                attackerID = nodeIdx;  % Would be actual node ID in real implementation
                for i = 1:numel(targets)
                    wakeMsg = WSN_Attack.createWakePacket(attackerID, targets(i), t);
                    wakeMsgs{end+1} = wakeMsg;
                end
                
                % Track energy cost (attacker spends energy too)
                energyPerWake = 0.05;  % Energy cost per wake packet
                data.energyDrained(nodeIdx) = data.energyDrained(nodeIdx) + numel(targets) * energyPerWake;
                data.denialLastWakeTick(nodeIdx) = t;
                data.denialWakeCount(nodeIdx) = data.denialWakeCount(nodeIdx) + numel(targets);
                WSN_Attack.setData(data);
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_DENIAL_SLEEP, ...
                    sprintf('VAMPIRE_%d_TARGETS', numel(targets)));
            end
        end
        
        function msg = createWakePacket(srcID, dstID, t)
            % Create realistic wake packet (requires actual transmission)
            msg = WSN_Message();
            msg.type = 255;  % Spurious/wake type
            msg.subtype = 1;  % Wake subtype
            msg.src = srcID;
            msg.dst = dstID;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            % Minimal payload but requires radio transmission
            msg.payload = uint8([mod(t, 256), randi([0, 255])]);
            msg.payloadLen = 2;
            msg.addChecksum();
            msg.color = WSN_Attack.COLOR_DENIAL_SLEEP;
        end
        
        function msg = createSpuriousPacket(srcID, dstID, t)
            msg = WSN_Message();
            msg.type = 255;
            msg.subtype = 0;
            msg.src = srcID;
            msg.dst = dstID;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            msg.payload = uint8(randi([0, 255], 1, 8));
            msg.payloadLen = 8;
            msg.addChecksum();
            msg.color = WSN_Attack.COLOR_DENIAL_SLEEP;
        end
        
    end
end

