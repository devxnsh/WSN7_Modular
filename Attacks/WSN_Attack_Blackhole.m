classdef WSN_Attack_Blackhole
    % =========================================================
    % BLACKHOLE ATTACK MODULE
    % =========================================================
    % Extracted verbatim from WSN_Attack.m (the BLACKHOLE ATTACK LOGIC
    % section). Stateless itself - all state lives in WSN_Attack's
    % persistent pDataStore, accessed via WSN_Attack.getData()/setData()/
    % recordGroundTruth() exactly as before the split. WSN_Attack.m keeps
    % thin one-line wrappers (shouldDropBlackhole/shouldDropBlackholeGWN)
    % so every existing call site across SN/CH/GWN is unaffected.
    % =========================================================
    methods (Static)
        % BLACKHOLE ATTACK LOGIC
        % Intensity 1 = Always drop (obvious), Intensity 10 = Rare drops (stealthy)
        % REALISTIC: Tracks drop history, uses smart selection, maintains cover
        function drop = shouldDropBlackhole(nodeIdx, t)
            data = WSN_Attack.getData();
            drop = false;

            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_BLACKHOLE
                return;
            end

            intensity = data.intensity(nodeIdx);

            % Track promised vs actual to maintain realistic behavior
            data.promisedForwards(nodeIdx) = data.promisedForwards(nodeIdx) + 1;

            % Initialize drop window if needed
            if isempty(data.dropWindow{nodeIdx})
                data.dropWindow{nodeIdx} = [];
            end

            % Compute recent drop ratio from history (for adaptive behavior)
            windowSize = 20;
            history = data.dropWindow{nodeIdx};
            recentDropRatio = 0;
            if ~isempty(history)
                recentHistory = history(max(1, end-windowSize+1):end);
                recentDropRatio = sum(recentHistory) / numel(recentHistory);
            end

            % Intensity 1-3: Always drop (easily detectable)
            % Intensity 4-6: Periodic drops with adaptive timing
            % Intensity 7-10: Smart drops - maintain low but consistent drop ratio
            if intensity <= 3
                drop = true;  % 100% drop rate - obvious
            elseif intensity <= 6
                % Periodic: drop less frequently, but adapt if too obvious
                basePeriod = 2 + intensity;  % period 6-8
                if recentDropRatio > 0.6  % Too obvious, back off
                    basePeriod = basePeriod + 2;
                end
                drop = mod(t, basePeriod) == 0;
            else
                % Stealthy: maintain low drop ratio, looks like normal packet loss
                targetDropRatio = 0.3 - (intensity - 7) * 0.07;  % 30% -> 9%
                if recentDropRatio < targetDropRatio * 0.8
                    % Below target - can drop
                    drop = rand() < (targetDropRatio * 1.2);
                elseif recentDropRatio > targetDropRatio * 1.3
                    % Above target - don't drop
                    drop = false;
                else
                    % Near target - random with target probability
                    drop = rand() < targetDropRatio;
                end
            end

            % Update tracking
            data.dropWindow{nodeIdx} = [data.dropWindow{nodeIdx}, double(drop)];
            if numel(data.dropWindow{nodeIdx}) > 50
                data.dropWindow{nodeIdx} = data.dropWindow{nodeIdx}(end-49:end);
            end

            if drop
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
            else
                data.actualForwards(nodeIdx) = data.actualForwards(nodeIdx) + 1;
            end
            WSN_Attack.setData(data);

            if drop
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_BLACKHOLE, 'DROP');
            end
        end

        function [dropAccess, dropBackbone] = shouldDropBlackholeGWN(nodeIdx, t)
            % GWN-specific: which radio(s) to block
            % Intensity 1 = Block BOTH radios (obvious)
            % Intensity 10 = Block only ONE radio intermittently (stealthy)
            dropAccess = false;
            dropBackbone = false;

            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_BLACKHOLE
                return;
            end

            intensity = data.intensity(nodeIdx);

            if intensity <= 3
                % Block BOTH radios constantly
                dropAccess = true;
                dropBackbone = true;
            elseif intensity <= 6
                % Block both but periodically
                period = intensity + 2;
                if mod(t, period) < 2
                    dropAccess = true;
                    dropBackbone = true;
                end
            else
                % Stealthy: block only ONE radio, randomly
                if rand() < (0.4 - (intensity - 7) * 0.08)
                    if rand() < 0.5
                        dropAccess = true;
                    else
                        dropBackbone = true;
                    end
                end
            end

            if dropAccess || dropBackbone
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
                WSN_Attack.setData(data);
                if dropAccess && dropBackbone
                    radioStr = 'BOTH';
                elseif dropAccess
                    radioStr = 'ACCESS';
                else
                    radioStr = 'BACKBONE';
                end
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_BLACKHOLE, ['DROP_' radioStr]);
            end
        end
    end
end
