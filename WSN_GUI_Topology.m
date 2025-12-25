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
                pwr = n.txPower; if pwr < 0.1, pwr = 1.0; end
                rng = ((pwr*100)/0.15)^(1/2.4);
                set(obj.rangeCirc, 'Position', [n.pos(1)-rng, n.pos(2)-rng, 2*rng, 2*rng], ...
                    'Curvature', [1 1], 'EdgeColor', 'r', 'LineStyle', '--', 'LineWidth', 1, 'Visible', 'on');
            end
            if n.tier == 3 && n.state < 1
                if isprop(n, 'controlPower')
                    cp = n.controlPower;
                    rngC = ((cp*100)/0.15)^(1/2.4);
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
                if ~isempty(n.parent)
                    pIdx = id2idx(n.parent);
                    if ~isempty(pIdx)
                        plot(obj.ax, ...
                            [n.pos(1) nodes(pIdx).pos(1)], ...
                            [n.pos(2) nodes(pIdx).pos(2)], ...
                            'Color', [0 0.8 0], 'LineWidth', 2);
                    end
                end

            end
            
            for k = 1:numel(nodes)
                n = nodes(k); 
                faceCol='none'; edgeCol=[0 0.7 0]; lw=1.5; sz=40; 
                if n.tier==3, faceCol=[0 1 0]; edgeCol='k'; if isa(n,'WSN_Sink'), edgeCol='b'; lw=2; end; end
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

                % ---------- COLOR SANITIZATION ----------
                % NEVER allow default black
                col = vl.color;

                if isempty(col) || isequal(col, 'k') || isequal(col, [0 0 0])
                    % Default fallback = HEARTBEAT
                    col = [1 0.4 0.7];   % pink
                    lw  = 0.5;
                    ls  = '-';
                else
                    lw = 1;
                    ls = '-';
                end

                % Respect explicit width/style if present
                if isfield(vl, 'width') && ~isempty(vl.width)
                    lw = vl.width;
                end
                if isfield(vl, 'style') && ~isempty(vl.style)
                    ls = vl.style;
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