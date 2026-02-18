classdef WSN_Physics
    methods (Static)

        function [physAdj, stblAdj, distMat] = updateConnectivity(nodes)

            N = numel(nodes);
            distMat = zeros(N);
            physAdj = false(N);
            stblAdj = false(N);

            % ---------------- CONFIG ----------------
            plExp_Std  = WSN_Config.PathLossExp;             % e.g. 2.4
            plExp_Bkbn = WSN_Config.PathLossExp_Backbone;    % e.g. 1.8
            sensitivity = WSN_Config.Sensitivity;            % decode threshold
            rssiFloor   = 0.1;                               % HARD realism floor

            % ---------------- PRECOMPUTE RANGES ----------------
            % Deterministic decode horizon from RSSI model
            ranges = zeros(N,1);

            for i = 1:N
                if nodes(i).tier == 3 && isprop(nodes(i),'controlPower')
                    txP = max(nodes(i).txPower, nodes(i).controlPower);
                    pl  = plExp_Bkbn;
                else
                    txP = nodes(i).txPower;
                    if txP == 0
                        txP = WSN_Config.NormalPower;
                    end
                    pl = plExp_Std;
                end

                % Inverted RSSI equation: rx >= sensitivity
                ranges(i) = ((txP * 100) / sensitivity)^(1/pl);
            end

            % ---------------- LINK EVALUATION ----------------
            for i = 1:N
                for j = 1:N
                    if i == j, continue; end

                    d = norm(nodes(i).pos - nodes(j).pos);
                    distMat(i,j) = d;

                    % -------- HARD RANGE CUTOFF (sender-based) --------
                    % TX still occurs; delivery blocked
                    if d > ranges(i)
                        continue;
                    end

                    % -------- LINK PHYSICS --------
                    if nodes(i).tier == 3 && nodes(j).tier == 3
                        if isprop(nodes(i),'controlPower')
                            txP = nodes(i).controlPower;
                        else
                            txP = nodes(i).txPower;
                        end
                        pl = plExp_Bkbn;
                    else
                        txP = nodes(i).txPower;
                        if txP == 0
                            txP = WSN_Config.NormalPower;
                        end
                        pl = plExp_Std;
                    end

                    % Mean received power (no fading)
                    rxMean = txP * (1 / (max(0.1,d)^pl)) * 100;

                    % -------- RECEIVER SENSITIVITY (scales with receiver power) --------
                    % Higher RX power (amplifier) = better sensitivity
                    rxSensitivity = sensitivity;
                    if nodes(j).tier == 3 && isprop(nodes(j), 'controlPower')
                        % GWN receiver: improve sensitivity proportionally to controlPower
                        rxPowerRatio = nodes(j).controlPower / WSN_Config.TxPower_GWN_Control;
                        rxSensitivity = sensitivity / rxPowerRatio;  % Lower threshold = better sensitivity
                    end

                    % -------- STABLE LINK (NO FADING) --------
                    rxStable = rxMean * 0.8;
                    if rxStable >= rxSensitivity && rxStable >= rssiFloor
                        stblAdj(i,j) = true;
                    end

                    % -------- PHYSICAL LINK (WITH FADING) --------
                    rxPhys = rxMean * exprnd(WSN_Config.RayleighScale);

                    if rxPhys < rssiFloor
                        continue;   % not detectable at all
                    end

                    if rxPhys >= rxSensitivity
                        physAdj(i,j) = true;
                    end
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
            % Header: ID (5 chars with star space), D (4 chars), Tr, Bat, Nb, Age
            lines(end+1) = sprintf(' ID  | D   |Tr|Bat|Nb|Age');
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
                tHex = targetNode.hexID(end-3:end);  % Last 4 chars of hex ID
                
                % Check if neighbor is verified (star marking)
                isVerifiedNeighbor = false;
                if isfield(nbrs, 'isVerified') && ~isempty(nbrs(k).isVerified)
                    isVerifiedNeighbor = nbrs(k).isVerified;
                end
                
                % Format ID with star or space for alignment
                if isVerifiedNeighbor
                    idStr = sprintf('%s*', tHex);
                else
                    idStr = sprintf('%s ', tHex);
                end
                
                % Extract tier, battery, neighborCount from neighbor table
                tierVal = nbrs(k).tier;
                batVal = nbrs(k).battery;
                nbrCountVal = nbrs(k).neighborCount;

                % Format: ID(5) | D(4.1) | Tr(1) | Bat(2) | Nb(2) | Age(3)
                lines(end+1) = sprintf('%s|%4.1f| %d|%2d|%2d|%3ds', ...
                    idStr, estDist, tierVal, batVal, nbrCountVal, age);
            end

            str = char(join(lines, newline));
        end
    end
end