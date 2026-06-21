classdef WSN_Attack_Grayhole
    % =========================================================
    % GRAYHOLE ATTACK MODULE
    % =========================================================
    % Extracted verbatim from WSN_Attack.m (the GRAYHOLE ATTACK LOGIC
    % section). Stateless - all state lives in WSN_Attack's persistent
    % pDataStore, accessed via WSN_Attack.getData()/setData()/
    % recordGroundTruth() exactly as before the split. WSN_Attack.m keeps
    % thin one-line wrappers so every existing call site is unaffected.
    % =========================================================
    methods (Static)
        % =========================================================
        % GRAYHOLE ATTACK LOGIC (Selective Forwarding)
        % Intensity 1 = High drop rate (obvious), Intensity 10 = Low drop rate (stealthy)
        % REALISTIC: Tracks history, varies pattern to avoid detection
        % =========================================================
        function drop = shouldDropGrayhole(nodeIdx, t)
            data = WSN_Attack.getData();
            drop = false;
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_GRAYHOLE
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Initialize drop window if needed
            if isempty(data.dropWindow{nodeIdx})
                data.dropWindow{nodeIdx} = [];
            end
            
            % Compute recent drop ratio from history
            windowSize = 30;
            history = data.dropWindow{nodeIdx};
            recentDropRatio = 0;
            if ~isempty(history)
                recentHistory = history(max(1, end-windowSize+1):end);
                recentDropRatio = sum(recentHistory) / numel(recentHistory);
            end
            
            % Determine target drop rate based on intensity
            % Intensity 1-3: High drop rate 70-80% (obvious)
            % Intensity 4-6: Medium drop rate 40-50% (moderate)
            % Intensity 7-10: Low drop rate 10-25% (stealthy, looks like packet loss)
            if intensity <= 3
                targetDropRate = 0.8 - (intensity - 1) * 0.05;  % 0.8 -> 0.7
            elseif intensity <= 6
                targetDropRate = 0.55 - (intensity - 4) * 0.05;  % 0.55 -> 0.4
            else
                targetDropRate = 0.25 - (intensity - 7) * 0.05;  % 0.25 -> 0.1
            end
            
            % Adaptive dropping: vary rate around target to create natural pattern
            variance = 0.1;  % Allow 10% variance
            if recentDropRatio < targetDropRate - variance
                % Below target - increase drop rate
                drop = rand() < (targetDropRate + variance);
            elseif recentDropRatio > targetDropRate + variance
                % Above target - decrease drop rate
                drop = rand() < (targetDropRate - variance);
            else
                % At target - use base rate with small random adjustment
                drop = rand() < (targetDropRate + (rand() - 0.5) * variance);
            end
            
            % Track decision
            data.dropWindow{nodeIdx} = [data.dropWindow{nodeIdx}, double(drop)];
            if numel(data.dropWindow{nodeIdx}) > 50
                data.dropWindow{nodeIdx} = data.dropWindow{nodeIdx}(end-49:end);
            end
            
            if drop
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_GRAYHOLE, 'DROP');
            else
                data.actualForwards(nodeIdx) = data.actualForwards(nodeIdx) + 1;
            end
            data.promisedForwards(nodeIdx) = data.promisedForwards(nodeIdx) + 1;
            WSN_Attack.setData(data);
        end
        
        function [dropAccess, dropBackbone] = shouldDropGrayholeGWN(nodeIdx, t) %
            % GWN-specific selective forwarding
            % t argument reserved for future time-based pattern variation
            dropAccess = false;
            dropBackbone = false;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_GRAYHOLE
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            if intensity <= 3
                % Drop on both radios with high rate
                dropRate = 0.75 - (intensity - 1) * 0.05;
                dropAccess = rand() < dropRate;
                dropBackbone = rand() < dropRate;
            elseif intensity <= 6
                % Medium rate, sometimes only one radio
                dropRate = 0.45 - (intensity - 4) * 0.05;
                if rand() < 0.7  % 70% chance to affect both
                    dropAccess = rand() < dropRate;
                    dropBackbone = rand() < dropRate;
                else  % 30% chance single radio
                    if rand() < 0.5
                        dropAccess = rand() < dropRate;
                    else
                        dropBackbone = rand() < dropRate;
                    end
                end
            else
                % Stealthy: low rate, usually single radio
                dropRate = 0.2 - (intensity - 7) * 0.03;
                if rand() < 0.3  % Rarely affect both
                    dropAccess = rand() < dropRate;
                    dropBackbone = rand() < dropRate;
                else
                    if rand() < 0.5
                        dropAccess = rand() < dropRate;
                    else
                        dropBackbone = rand() < dropRate;
                    end
                end
            end
            
            if dropAccess || dropBackbone
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
                WSN_Attack.setData(data);
            end
        end
        
    end
end

