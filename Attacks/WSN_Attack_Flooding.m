classdef WSN_Attack_Flooding
    % =========================================================
    % Flooding ATTACK MODULE
    % =========================================================
    % Extracted verbatim from WSN_Attack.m (the Flooding ATTACK LOGIC
    % section). Stateless - all state lives in WSN_Attack's persistent
    % pDataStore, accessed via WSN_Attack.getData()/setData()/
    % recordGroundTruth() exactly as before the split. WSN_Attack.m keeps
    % thin one-line wrappers so every existing call site is unaffected.
    % =========================================================
    methods (Static)
        % =========================================================
        % FLOODING ATTACK LOGIC
        % Intensity 1 = Massive constant flood (obvious)
        % Intensity 10 = Occasional small bursts (stealthy)
        % REALISTIC: Spreads packets over ticks, models self-interference/collision
        % =========================================================
        function [count, collisionLoss] = getFloodingBurstCount(nodeIdx, t)
            data = WSN_Attack.getData();
            count = 0;
            collisionLoss = 0;
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_FLOODING
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Check if we have remaining packets from a previous burst
            if data.floodingBurstRemaining(nodeIdx) > 0
                % Continue spreading previous burst over this tick
                maxPerTick = 15;  % Realistic per-tick limit
                count = min(data.floodingBurstRemaining(nodeIdx), maxPerTick);
                data.floodingBurstRemaining(nodeIdx) = data.floodingBurstRemaining(nodeIdx) - count;
            else
                % Decide whether to start a new burst
                newBurstSize = 0;
                
                % Intensity 1-3: Massive constant flooding (50-100 packets total)
                % Intensity 4-6: Moderate periodic flooding (20-40 packets)
                % Intensity 7-10: Occasional small bursts (5-15 packets, rare)
                if intensity <= 3
                    newBurstSize = 100 - (intensity - 1) * 15;  % 100 -> 70
                elseif intensity <= 6
                    % Periodic flooding
                    period = 3 + intensity;  % period 7-9
                    if mod(t, period) == 0
                        newBurstSize = 40 - (intensity - 4) * 7;  % 40 -> 26
                    end
                else
                    % Stealthy: rare small bursts
                    if rand() < (0.25 - (intensity - 7) * 0.05)  % 25% -> 10% chance
                        newBurstSize = 15 - (intensity - 7) * 3;  % 15 -> 6
                        newBurstSize = max(3, newBurstSize);
                    end
                end
                
                if newBurstSize > 0
                    % Start new burst - spread over multiple ticks
                    maxPerTick = 15;
                    count = min(newBurstSize, maxPerTick);
                    data.floodingBurstRemaining(nodeIdx) = newBurstSize - count;
                    data.floodingLastBurstTick(nodeIdx) = t;
                end
            end
            
            % Model self-interference: too many packets cause collisions
            if count > 0
                % Collision probability increases with packet count
                collisionProb = min(0.5, count * 0.03);  % Up to 50% loss at 15+ packets
                collisionLoss = floor(count * collisionProb);
                actualSent = count - collisionLoss;
                
                % Track energy cost per packet (realistic drain)
                energyCostPerPacket = 0.02;  % 2% of base per packet
                data.energyDrained(nodeIdx) = data.energyDrained(nodeIdx) + count * energyCostPerPacket;
                
                data.packetsFlooded(nodeIdx) = data.packetsFlooded(nodeIdx) + actualSent;
                data.floodingCollisionCount(nodeIdx) = data.floodingCollisionCount(nodeIdx) + collisionLoss;
                WSN_Attack.setData(data);
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_FLOODING, ...
                    sprintf('FLOOD_%d_COLL_%d', actualSent, collisionLoss));
            else
                WSN_Attack.setData(data);
            end
        end
        
        function [countAccess, countBackbone, collisionLoss] = getFloodingBurstCountGWN(nodeIdx, t)
            % GWN-specific: which radio(s) to flood
            % Intensity 1 = Flood BOTH radios massively (obvious)
            % Intensity 10 = Flood only ONE radio occasionally (stealthy)
            % REALISTIC: Per-radio limits, collision modeling, energy tracking
            countAccess = 0;
            countBackbone = 0;
            collisionLoss = 0;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_FLOODING
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            maxPerRadioPerTick = 10;  % Realistic per-radio limit
            
            % Determine target counts based on intensity
            targetAccess = 0;
            targetBackbone = 0;
            
            if intensity <= 3
                % Flood BOTH radios constantly with high volume
                baseCount = 80 - (intensity - 1) * 10;  % 80 -> 60
                targetAccess = baseCount;
                targetBackbone = baseCount;
            elseif intensity <= 6
                % Moderate: flood both but less frequently
                period = intensity + 3;
                if mod(t, period) == 0
                    baseCount = 35 - (intensity - 4) * 5;  % 35 -> 25
                    targetAccess = baseCount;
                    targetBackbone = baseCount;
                end
            else
                % Stealthy: flood only ONE radio, rarely
                if rand() < (0.2 - (intensity - 7) * 0.04)  % 20% -> 8%
                    smallCount = 12 - (intensity - 7) * 2;  % 12 -> 6
                    smallCount = max(3, smallCount);
                    if rand() < 0.5
                        targetAccess = smallCount;
                    else
                        targetBackbone = smallCount;
                    end
                end
            end
            
            % Spread over ticks (don't send more than max per tick)
            countAccess = min(targetAccess, maxPerRadioPerTick);
            countBackbone = min(targetBackbone, maxPerRadioPerTick);
            
            % Model collision losses per radio
            if countAccess > 0
                collisionProbAccess = min(0.4, countAccess * 0.04);
                lossAccess = floor(countAccess * collisionProbAccess);
                countAccess = countAccess - lossAccess;
                collisionLoss = collisionLoss + lossAccess;
            end
            if countBackbone > 0
                collisionProbBackbone = min(0.4, countBackbone * 0.04);
                lossBackbone = floor(countBackbone * collisionProbBackbone);
                countBackbone = countBackbone - lossBackbone;
                collisionLoss = collisionLoss + lossBackbone;
            end
            
            total = countAccess + countBackbone;
            if total > 0
                % Track energy cost
                energyCostPerPacket = 0.025;  % GWN uses more power
                data.energyDrained(nodeIdx) = data.energyDrained(nodeIdx) + (total + collisionLoss) * energyCostPerPacket;
                
                data.packetsFlooded(nodeIdx) = data.packetsFlooded(nodeIdx) + total;
                data.floodingCollisionCount(nodeIdx) = data.floodingCollisionCount(nodeIdx) + collisionLoss;
                WSN_Attack.setData(data);
                if countAccess > 0 && countBackbone > 0
                    radioStr = 'BOTH';
                elseif countAccess > 0
                    radioStr = 'ACCESS';
                else
                    radioStr = 'BACKBONE';
                end
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_FLOODING, ...
                    sprintf('FLOOD_%s_%d_COLL_%d', radioStr, total, collisionLoss));
            end
        end
        
        function txPower = getFloodingTxPower(nodeIdx)
            data = WSN_Attack.getData();
            txPower = WSN_Config.TxPower_CH;
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_FLOODING
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            % Intensity 1: High power (5x), Intensity 10: Normal power (1.2x)
            multiplier = 5 - (intensity - 1) * 0.4;  % 5x -> 1.4x
            multiplier = max(1.2, multiplier);
            txPower = WSN_Config.TxPower_CH * multiplier;
        end
        
    end
end

