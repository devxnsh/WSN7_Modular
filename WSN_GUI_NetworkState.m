classdef WSN_GUI_NetworkState < handle
    properties
        headerText
        netTable
    end

    methods
        function obj = WSN_GUI_NetworkState(parentTab)

            obj.headerText = uicontrol('Parent',parentTab, ...
                'Style','text', ...
                'Units','normalized', ...
                'Position',[0.62 0.37 0.36 0.035], ...
                'String','NETWORK STATE @ T = 0', ...
                'FontWeight','bold', ...
                'FontName','Consolas', ...
                'ForegroundColor', [1 1 1],...
                'FontSize',9, ...
                'HorizontalAlignment','center', ...
                'BackgroundColor',[0.2 0.2 0.2]);

            obj.netTable = uitable('Parent',parentTab, 'Units','normalized', ...
                'Position',[0.62 0.02 0.36 0.34], ...
                'ColumnName', {'ID','Role','Bat%','Parent','Children','Nbrs'}, ...
                'ColumnWidth',{40,40,35,45,150,190}, ...
                'RowName',[]);
        end

        function update(obj, nodes, t)
            if nargin < 3
                t = 0;
            end

            % -------- UPDATE HEADER --------
            if isvalid(obj.headerText)
                set(obj.headerText, ...
                    'String', sprintf('NETWORK STATE @ T = %d', t));
            end

            % -------- TABLE DATA --------
            id2idx = @(id) find(arrayfun(@(x) hex2dec(x.hexID) == id, nodes), 1);
            data = cell(numel(nodes), 6);

            for i = 1:numel(nodes)
                n = nodes(i);

                % ID / ROLE / BATTERY
                hID  = n.hexID;
                tStr = n.typeStr;
                bat  = sprintf('%.0f', n.battery);

                % -------- PARENT --------
                pStr = '-';
                if isprop(n,'parent') && ~isempty(n.parent)
                    pIdx = id2idx(n.parent);
                    if ~isempty(pIdx)
                        hexStr = nodes(pIdx).hexID;
                        parentIsCH = isa(nodes(pIdx), 'WSN_ClusterHead');
                        if isa(n, 'WSN_ClusterHead') && ~parentIsCH
                            pStr = sprintf('[%s]', hexStr);  % CH with GWN parent
                        else
                            pStr = hexStr;  % Sensor or CH with CH parent
                        end
                    end
                end

                % -------- CHILDREN --------
                cStr = '-';
                childParts = {};
                
                % GWN children
                if isprop(n,'children') && ~isempty(n.children)
                    hx = {};
                    childIds = n.children(:)';  % Ensure row vector for iteration
                    for cid = childIds
                        cIdx = id2idx(cid);
                        if ~isempty(cIdx)
                            hx{end+1} = nodes(cIdx).hexID; %
                        end
                    end
                    if ~isempty(hx)
                        childParts{end+1} = strjoin(hx, ', '); %
                    end
                end
                
                % CH children (with brackets)
                if isprop(n,'chChildren') && ~isempty(n.chChildren)
                    hx = {};
                    chIds = n.chChildren(:)';  % Ensure row vector for iteration
                    for cid = chIds
                        cIdx = id2idx(cid);
                        if ~isempty(cIdx)
                            hx{end+1} = sprintf('[%s]', nodes(cIdx).hexID); %
                        end
                    end
                    if ~isempty(hx)
                        childParts{end+1} = strjoin(hx, ', '); %
                    end
                end
                
                % Grandchild CHs: chChildren of this node's GWN children
                if isprop(n,'children') && ~isempty(n.children)
                    hx = {};
                    childIds2 = n.children(:)';  % Ensure row vector
                    for childGwnId = childIds2
                        childIdx = id2idx(childGwnId);
                        if ~isempty(childIdx)
                            childNode = nodes(childIdx);
                            if isprop(childNode,'chChildren') && ~isempty(childNode.chChildren)
                                gcIds = childNode.chChildren(:)';  % Ensure row vector
                                for gcid = gcIds
                                    gcIdx = id2idx(gcid);
                                    if ~isempty(gcIdx)
                                        hx{end+1} = sprintf('[[%s]]', nodes(gcIdx).hexID); %
                                    end
                                end
                            end
                        end
                    end
                    if ~isempty(hx)
                        childParts{end+1} = strjoin(hx, ', '); %
                    end
                end
                
                if ~isempty(childParts)
                    cStr = strjoin(childParts, ', ');
                end

                % -------- NEIGHBORS --------
                nbrStr = '-';
                if isprop(n,'neighborTable') && ~isempty(n.neighborTable)
                    hx = {};
                    for nid = [n.neighborTable.id]
                        nIdx = id2idx(nid);
                        if ~isempty(nIdx)
                            hx{end+1} = nodes(nIdx).hexID; %
                        end
                    end
                    if ~isempty(hx)
                        nbrStr = strjoin(hx, ', ');
                    end
                end

                data(i,:) = {hID, tStr, bat, pStr, cStr, nbrStr};
            end

            % Preserve scroll position
            try
                jScroll = findjobj(obj.netTable);
                jTable = jScroll.getViewport.getView;
                scrollPos = jScroll.getVerticalScrollBar.getValue;
                set(obj.netTable, 'Data', data);
                drawnow;
                jScroll.getVerticalScrollBar.setValue(scrollPos);
            catch
                set(obj.netTable, 'Data', data);
            end
        end

    end
end
