classdef WSN_Attack_Wormhole
    % =========================================================
    % WORMHOLE ATTACK MODULE
    % =========================================================
    % Extracted verbatim from WSN_Attack.m: setWormholeEndpoints
    % (originally in the CONFIGURATION section, sandwiched between
    % clearMalicious and isMaliciousNode which stayed in WSN_Attack.m
    % core) plus the WORMHOLE ATTACK LOGIC section. Stateless - all
    % state lives in WSN_Attack's persistent pDataStore, accessed via
    % WSN_Attack.getData()/setData()/setMalicious() exactly as before
    % the split. WSN_Attack.m keeps thin one-line wrappers so every
    % existing call site is unaffected.
    % =========================================================
    methods (Static)
        function setWormholeEndpoints(nodeA, nodeB, intensity, nodes)
            data = WSN_Attack.getData();
            
            % Prevent Sink from being wormhole endpoint
            if nargin >= 4 && ~isempty(nodes)
                if isa(nodes(nodeA), 'WSN_Sink') || isa(nodes(nodeB), 'WSN_Sink')
                    return;
                end
            end
            
            if nargin < 3, intensity = 5; end
            
            data.wormholeEndpoints = [nodeA, nodeB];
            WSN_Attack.setData(data);
            
            WSN_Attack.setMalicious(nodeA, WSN_Attack.ATTACK_WORMHOLE, intensity, []);
            WSN_Attack.setMalicious(nodeB, WSN_Attack.ATTACK_WORMHOLE, intensity, []);
        end
        
        % =========================================================
        % WORMHOLE ATTACK LOGIC
        % Intensity 1 = Always tunnel (obvious shortcut)
        % Intensity 10 = Intermittent tunneling (harder to detect RTT anomalies)
        % REALISTIC: Bandwidth limiting, latency modeling, distance-based RSSI
        % =========================================================
        function [shouldRelay, otherEndpoint, latencyTicks] = shouldWormholeRelay(nodeIdx, t)
            data = WSN_Attack.getData();
            shouldRelay = false;
            otherEndpoint = [];
            latencyTicks = 0;
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_WORMHOLE
                return;
            end
            
            wormhole = data.wormholeEndpoints;
            if isempty(wormhole)
                return;
            end
            
            if wormhole(1) == nodeIdx
                otherEndpoint = wormhole(2);
            elseif wormhole(2) == nodeIdx
                otherEndpoint = wormhole(1);
            else
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Check bandwidth limit per tick
            bandwidthLimit = 5;  % Max packets through tunnel per tick
            if data.wormholeBandwidthUsed(nodeIdx) >= bandwidthLimit
                % Bandwidth exhausted this tick
                shouldRelay = false;
                return;
            end
            
            % Intensity 1-3: Always tunnel (100% - creates obvious RTT shortcuts)
            % Intensity 4-6: Frequently tunnel (60-80%)
            % Intensity 7-10: Intermittent tunnel (20-40% - harder to detect)
            if intensity <= 3
                shouldRelay = true;
            elseif intensity <= 6
                relayRate = 0.85 - (intensity - 4) * 0.08;  % 85% -> 69%
                shouldRelay = rand() < relayRate;
            else
                relayRate = 0.45 - (intensity - 7) * 0.07;  % 45% -> 24%
                shouldRelay = rand() < relayRate;
            end
            
            if shouldRelay
                % Model tunnel latency (realistic out-of-band transport)
                % Low intensity = fast (obvious), high intensity = variable (stealthier)
                if intensity <= 3
                    latencyTicks = 0;  % Instant - very suspicious
                elseif intensity <= 6
                    latencyTicks = randi([0, 1]);  % Small delay
                else
                    latencyTicks = randi([1, 3]);  % Variable delay, harder to detect
                end
                
                % Update bandwidth usage
                data.wormholeBandwidthUsed(nodeIdx) = data.wormholeBandwidthUsed(nodeIdx) + 1;
                WSN_Attack.setData(data);
                
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_WORMHOLE, ...
                    sprintf('TUNNEL_LAT%d', latencyTicks));
            end
        end
        
        function rssi = getWormholeRSSI(actualDistance, intensity)
            % REALISTIC: Calculate RSSI based on wormhole behavior
            % Low intensity: Perfect RSSI (suspicious)
            % High intensity: RSSI matches expected distance (stealthier)
            if nargin < 2
                intensity = 5;  % Default medium intensity
            end
            if nargin < 1
                actualDistance = 100;  % Default distance
            end
            
            if intensity <= 3
                % Obvious: Perfect signal regardless of distance
                rssi = 0.95;
            elseif intensity <= 6
                % Moderate: Slightly better than expected
                expectedRSSI = max(0.1, 1.0 - actualDistance / 500);
                rssi = min(1.0, expectedRSSI * 1.3);
            else
                % Stealthy: RSSI matches what would be expected for some plausible distance
                % Add some variance to simulate realistic conditions
                plausibleDistance = actualDistance * (0.3 + rand() * 0.4);  % 30-70% of actual
                rssi = max(0.1, 1.0 - plausibleDistance / 500);
                rssi = rssi + (rand() - 0.5) * 0.1;  % Add noise
                rssi = max(0.1, min(1.0, rssi));
            end
        end
        
        function resetWormholeBandwidth()
            % Call at start of each tick to reset bandwidth counter
            data = WSN_Attack.getData();
            if ~isempty(data)
                data.wormholeBandwidthUsed = zeros(size(data.wormholeBandwidthUsed));
                WSN_Attack.setData(data);
            end
        end
        
    end
end

