classdef WSN_GUI_Topology < handle
    properties
        ax, hullLine, rangeCirc, controlCirc
    end
    
    methods
        function obj = WSN_GUI_Topology(parentTab, fieldSize)
            obj.ax = axes('Parent', parentTab, 'Units', 'normalized', ...
                'Position', [0.02 0.42 0.58 0.55], 'Box', 'on', 'Color', 'w', 'XGrid', 'on', 'YGrid', 'on');
            hold(obj.ax,'on'); axis(obj.ax,[0 fieldSize(1) 0 fieldSize(2)]);
            title(obj.ax, 'Topology: Green=Secure Tree, Pink=Negotiating', 'FontSize', 10);
            obj.hullLine = plot(obj.ax, NaN, NaN, 'b-', 'LineWidth', 0.5); 
            obj.rangeCirc = rectangle(obj.ax, 'Position', [0,0,0,0], 'Visible', 'off');
            obj.controlCirc = rectangle(obj.ax, 'Position', [0,0,0,0], 'Visible', 'off');
        end
        
        function updateCircles(obj, n)
            if isempty(n), return; end
            if isvalid(obj.rangeCirc)
                % Standard node: use txPower and standard pathLossExp
                pwr = n.txPower; 
                if pwr < 0.1, pwr = 1.0; end
                plExp = WSN_Config.PathLossExp;  % 2.4
                rng = ((pwr*100)/WSN_Config.Sensitivity)^(1/plExp);
                set(obj.rangeCirc, 'Position', [n.pos(1)-rng, n.pos(2)-rng, 2*rng, 2*rng], ...
                    'Curvature', [1 1], 'EdgeColor', 'r', 'LineStyle', '--', 'LineWidth', 1, 'Visible', 'on');
            end
            % Control circle: GWN backbone range (always visible)
            if n.tier == 3
                if isprop(n, 'controlPower')
                    cp = n.controlPower;
                    % GWN-to-GWN uses backbone pathLossExp (1.5)
                    plExp = WSN_Config.PathLossExp_Backbone;  % 1.5
                    rngC = ((cp*100)/WSN_Config.Sensitivity)^(1/plExp);
                    set(obj.controlCirc, 'Position', [n.pos(1)-rngC, n.pos(2)-rngC, 2*rngC, 2*rngC], ...
                        'Curvature', [1 1], 'EdgeColor', 'm', 'LineStyle', '-', 'LineWidth', 0.5, 'Visible', 'on');
                end
            else
                set(obj.controlCirc, 'Visible', 'off');
            end
        end
        
        function update(obj, nodes, physAdj, selectedID)
            id2idx = @(hid) find(arrayfun(@(x) hex2dec(x.hexID) == hid, nodes), 1);
            cla(obj.ax); hold(obj.ax,'on');
            hull = WSN_TopologyGenerator.getGWNHull(nodes);
            if ~isempty(hull), plot(obj.ax, hull(:,1), hull(:,2), 'b-', 'LineWidth', 0.5, 'Color', [0 0 1 0.2]); end
            
            obj.rangeCirc = rectangle(obj.ax, 'Position', [0,0,0,0], 'Visible', 'off');
            obj.controlCirc = rectangle(obj.ax, 'Position', [0,0,0,0], 'Visible', 'off');
            
            % Count nodes in TX phase for title
            txCount = 0;
            rxCount = 0;
            for k = 1:numel(nodes)
                if isprop(nodes(k), 'currentPhase')
                    if nodes(k).currentPhase == WSN_Config.PHASE_TX
                        txCount = txCount + 1;
                    elseif nodes(k).currentPhase == WSN_Config.PHASE_RX
                        rxCount = rxCount + 1;
                    end
                end
            end
            if txCount > 0 || rxCount > 0
                title(obj.ax, sprintf('Topology: Green=Secure, Gold=TX(%d), Cyan=RX(%d)', txCount, rxCount), 'FontSize', 10);
            else
                title(obj.ax, 'Topology: Green=Secure Tree, Pink=Negotiating', 'FontSize', 10);
            end

            for k = 1:numel(nodes)
                n = nodes(k);
                
                % --- PINK LINE LOGIC ---
                showPink = false;
                if n.tier == 3
                    if n.state <= 1 % BOOT/DISC
                        showPink = true;
                    elseif n.isVerified && isprop(n, 'neighborTable') && ~isempty(n.neighborTable)
                        if any([n.neighborTable.status] == 1), showPink = true; end
                    end
                end
                
                if showPink
                    nbrs = n.neighborTable;
                    for nIdx = 1:numel(nbrs)
                        if n.state <= 1 || nbrs(nIdx).status == 1
                            nid = nbrs(nIdx).id;
                            if nid <= numel(nodes) && nodes(nid).tier == 3 && k < nid
                                plot(obj.ax, [n.pos(1) nodes(nid).pos(1)], [n.pos(2) nodes(nid).pos(2)], 'Color', 'm', 'LineWidth', 1.0);
                            end
                        end
                    end
                end
                
                % --- GREEN LINE LOGIC (Secure Tree) ---
                % Skip sensors (tier 1) - they only show blue TX lines
                if ~isempty(n.parent) && n.tier ~= 1
                    pIdx = id2idx(n.parent);
                    if ~isempty(pIdx)
                        % Determine link color based on node types
                        parentNode = nodes(pIdx);
                        if n.tier == 2 && parentNode.tier == 3
                            % CH (tier 2) -> GWN (tier 3): Light Green (visible)
                            linkColor = [0.5 0.9 0.5];
                            linkWidth = 1.8;
                        elseif n.tier == 2 && parentNode.tier == 2
                            % CH (tier 2) -> CH (tier 2): Green-Yellow (visible)
                            linkColor = [0.6 0.85 0.3];
                            linkWidth = 1.5;
                        else
                            % GWN-GWN or GWN-Sink: Standard bright green
                            linkColor = [0 0.8 0];
                            linkWidth = 2;
                        end
                        plot(obj.ax, ...
                            [n.pos(1) nodes(pIdx).pos(1)], ...
                            [n.pos(2) nodes(pIdx).pos(2)], ...
                            'Color', linkColor, 'LineWidth', linkWidth);
                    end
                end

            end
            
            for k = 1:numel(nodes)
                n = nodes(k); 
                faceCol='none'; edgeCol=[0 0.7 0]; lw=1.5; sz=40; 
                
                % Check for phase state first (override other colors for GWNs)
                if isprop(n, 'currentPhase') && isprop(n, 'phaseInherited') && n.phaseInherited
                    if n.currentPhase == WSN_Config.PHASE_TX
                        faceCol = [1 0.84 0];    % Gold for TX phase
                        edgeCol = [1 0.5 0];     % Orange edge
                        lw = 3.0;
                        sz = 55;                 % Slightly larger
                    elseif n.currentPhase == WSN_Config.PHASE_RX
                        faceCol = [0 0.9 0.9];   % Cyan for RX phase
                        edgeCol = [0 0.6 0.6];   % Teal edge
                        lw = 2.5;
                        sz = 50;
                    else
                        % PHASE_IDLE or default
                        faceCol = [0 1 0];       % Green for IDLE/Secure
                        edgeCol = 'k';
                    end
                    if isa(n,'WSN_Sink'), edgeCol='b'; lw=2; end
                elseif n.tier==3
                    faceCol=[0 1 0]; edgeCol='k'; 
                    if isa(n,'WSN_Sink'), edgeCol='b'; lw=2; end
                end
                if n.tier==2, faceCol=[0.6 0 0.8]; edgeCol='k'; end
                if k == selectedID, edgeCol = 'm'; lw = 2.5; end
                scatter(obj.ax, n.pos(1), n.pos(2), sz, 'MarkerFaceColor', faceCol, 'MarkerEdgeColor', edgeCol, 'LineWidth', lw);
                text(obj.ax, n.pos(1)+1.5, n.pos(2)+1.5, n.hexID, 'FontSize',8, 'FontWeight','bold');
            end
            
            if selectedID > 0 && selectedID <= numel(nodes)
                obj.updateCircles(nodes(selectedID));
            end
        end
        
        function drawPackets(obj, visualLines, t)
            for k = 1:numel(visualLines)
                vl = visualLines(k);
                if vl.expiry < t, continue; end

                % ---------- COLOR & STYLE BY MESSAGE TYPE ----------
                col = vl.color;
                lw = 1;
                ls = '-';

                if isempty(col) || isequal(col, 'k') || isequal(col, [0 0 0])
                    % Default fallback = HEARTBEAT (pink, thin)
                    col = [1 0.4 0.7];
                    lw  = 0.5;
                    ls  = '-';
                elseif isequal(col, [0.3 0.5 1.0])
                    % Type 1 Sensor: thin blue solid
                    lw = 0.5;
                    ls = '-';
                elseif isequal(col, [0.6 0.2 0.8])
                    % 5.2 SENSOR_AGG: violet dashed
                    lw = 1.0;
                    ls = '--';
                elseif isequal(col, [1.0 0.7 0.2])
                    % 5.3 AGG_ACK: amber dashed
                    lw = 0.8;
                    ls = '--';
                end

                plot(obj.ax, ...
                    [vl.srcPos(1) vl.dstPos(1)], ...
                    [vl.srcPos(2) vl.dstPos(2)], ...
                    'Color', col, ...
                    'LineWidth', lw, ...
                    'LineStyle', ls);
            end
        end

    end
end