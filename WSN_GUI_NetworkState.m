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
                'ColumnWidth',{40,40,35,45,150,100}, ...
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
                        pStr = nodes(pIdx).hexID;
                    end
                end

                % -------- CHILDREN --------
                cStr = '-';
                if isprop(n,'children') && ~isempty(n.children)
                    hx = {};
                    for cid = n.children
                        cIdx = id2idx(cid);
                        if ~isempty(cIdx)
                            hx{end+1} = nodes(cIdx).hexID; %#ok<AGROW>
                        end
                    end
                    if ~isempty(hx)
                        cStr = strjoin(hx, ', ');
                    end
                end

                % -------- NEIGHBORS --------
                nbrStr = '-';
                if isprop(n,'neighborTable') && ~isempty(n.neighborTable)
                    hx = {};
                    for nid = [n.neighborTable.id]
                        nIdx = id2idx(nid);
                        if ~isempty(nIdx)
                            hx{end+1} = nodes(nIdx).hexID; %#ok<AGROW>
                        end
                    end
                    if ~isempty(hx)
                        nbrStr = strjoin(hx, ', ');
                    end
                end

                data(i,:) = {hID, tStr, bat, pStr, cStr, nbrStr};
            end

            set(obj.netTable, 'Data', data);
        end

    end
end
