classdef WSN_Physics
    methods (Static)
        function [physAdj, stblAdj, distMat] = updateConnectivity(nodes)
            N = numel(nodes);
            distMat = zeros(N);
            physAdj = false(N);
            stblAdj = false(N);
            
            plExp_Std = WSN_Config.PathLossExp;      % 2.4
            plExp_Bkbn = WSN_Config.PathLossExp_Backbone; % 1.8
            sensitivity = WSN_Config.Sensitivity;
            
            % Pre-calculate Max Possible Ranges (Optimistic)
            % We assume the best case (Backbone Exp) for GWNs to ensure we don't skip neighbors.
            ranges = zeros(N, 1);
            for i = 1:N
                pwr = nodes(i).txPower;
                if isprop(nodes(i), 'controlPower') && nodes(i).tier == 3
                    % GWNs might use higher control power
                    pwr = max(pwr, nodes(i).controlPower);
                    % Use Backbone exponent for range check (Longer range)
                    ranges(i) = ((pwr * 100) / sensitivity) ^ (1/plExp_Bkbn);
                else
                    if pwr == 0, pwr = WSN_Config.NormalPower; end
                    % Use Standard exponent for sensors
                    ranges(i) = ((pwr * 100) / sensitivity) ^ (1/plExp_Std);
                end
            end
            
            for i = 1:N
                for j = 1:N
                    if i == j, continue; end
                    
                    d = norm(nodes(i).pos - nodes(j).pos);
                    distMat(i,j) = d;
                    
                    % Optimization: Skip if physically impossible even in best conditions
                    if d > ranges(i), continue; end
                    
                    % --- LINK SPECIFIC PHYSICS ---
                    
                    % 1. Determine Power
                    srcPwr = nodes(i).txPower;
                    if nodes(i).tier == 3 && nodes(j).tier == 3
                        % GWN-to-GWN can use Control Power
                        if isprop(nodes(i), 'controlPower'), srcPwr = nodes(i).controlPower; end
                        % GWN-to-GWN uses Backbone Physics
                        currentPL = plExp_Bkbn; 
                    else
                        % Sensor links use Standard Physics
                        currentPL = plExp_Std;
                    end
                    
                    if srcPwr == 0, srcPwr = WSN_Config.NormalPower; end
                    
                    % 2. Calculate Received Power
                    % RSSI = (Tx * 100) / d^n
                    rxPwr = srcPwr * (1/(max(0.1,d)^currentPL)) * 100;
                    
                    % 3. Apply Fading
                    rxPhys = rxPwr * exprnd(WSN_Config.RayleighScale);
                    
                    % 4. Threshold Check
                    if rxPhys >= sensitivity
                        physAdj(i,j) = true; 
                    end
                    
                    % Stable check (ignoring fading)
                    rxStable = rxPwr * 0.8;
                    if rxStable >= sensitivity, stblAdj(i,j) = true; end
                end
            end
        end
        
        function nodes = updateBatteryAndSleep(nodes, t)
            % Update battery levels and dormancy based on power consumption
            % This is a placeholder for future power modeling
            for i = 1:numel(nodes)
                if nodes(i).battery > 0
                    % Drain based on activity (simplified model)
                    if nodes(i).isAwake
                        drainRate = 0.01; % Active drain per timestep
                    else
                        drainRate = 0.001; % Dormant drain per timestep
                    end
                    nodes(i).battery = max(0, nodes(i).battery - drainRate);
                    
                    % Enter dormant if critical
                    if nodes(i).battery < 5 && nodes(i).battery > 0
                        if isprop(nodes(i), 'state')
                            nodes(i).state = 4; % STATE_DORMANT
                        end
                    end
                end
            end
        end
        
        function targets = getHighPowerTargets(srcIdx, distMat)
            % Find nodes within high-power transmission range (for GWN broadcasts)
            % Returns indices of nodes at distance < 50 units
            targets = find(distMat(srcIdx, :) < 50 & distMat(srcIdx, :) > 0);
        end

        function str = getFormattedNeighborString(node, allNodes, t)

            nbrs = node.neighborTable;
            if isempty(nbrs)
                str = 'Scanning...';
                return;
            end

            % ID → index resolver
            id2idx = @(id) find(arrayfun(@(n) hex2dec(n.hexID) == id, allNodes), 1);

            [~, sortIdx] = sort([nbrs.rssi], 'descend');
            nbrs = nbrs(sortIdx);

            lines = strings(0);
            lines(end+1) = sprintf('%-6s | %-6s | %s', 'ID', 'RSSI-D', 'Age');
            lines(end+1) = repmat('-', 1, 28);

            for k = 1:numel(nbrs)

                nid = nbrs(k).id;
                idx = id2idx(nid);

                if isempty(idx)
                    continue; % unknown / stale node
                end

                targetNode = allNodes(idx);

                % ---------- ESTIMATION ----------
                if targetNode.tier == 3 && isprop(targetNode,'controlPower')
                    txP = targetNode.controlPower;
                else
                    txP = targetNode.txPower;
                end
                if txP <= 0
                    txP = WSN_Config.NormalPower;
                end

                rssiVal = nbrs(k).rssi;
                estDist = NaN;

                if ~isempty(rssiVal) && rssiVal > 0
                    if node.tier == 3 && targetNode.tier == 3
                        f = WSN_Config.Frequency_Backbone;
                        snrFactor = WSN_Config.BackboneSNRFactor;
                    else
                        f = WSN_Config.Frequency_Normal;
                        snrFactor = WSN_Config.NormalSNRFactor;
                    end

                    c = 3e8;
                    lambda = c / f;
                    num = txP * 100;
                    denom = max(rssiVal * snrFactor, 1e-6);
                    estDist = (lambda / (4*pi)) * sqrt(num / denom);
                    estDist = min(estDist, 200.0);
                else
                    estDist = norm(node.pos - targetNode.pos);
                end

                age = t - nbrs(k).lastSeen;
                tHex = targetNode.hexID;

                lines(end+1) = sprintf('%-6s | %4.1f  | %ds', tHex, estDist, age);
            end

            str = char(join(lines, newline));
        end
   end
end