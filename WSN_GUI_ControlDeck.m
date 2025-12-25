classdef WSN_GUI_ControlDeck < handle
    properties
        pnl
        ddNodes, inspectSummary, logBox
        txtTx, txtTTL
        sldAttackIntensity, txtAttackIntensityVal
        btnFlood, menuAtk, btnExp
        lastSelectedNode = -1
        txtPosX, txtPosY
    end
    
    methods
        function updateAttackIntensity(obj)
            v = round(get(obj.sldAttackIntensity, 'Value'));
            set(obj.sldAttackIntensity, 'Value', v);   % snap to integer
            set(obj.txtAttackIntensityVal, 'String', num2str(v));
        end

        function obj = WSN_GUI_ControlDeck(parentTab, nodes)
            % 1. CONTROL DECK PANEL (Retaining original width/position)
            % Position: Bottom-Left, spanning 58% width
            obj.pnl = uipanel('Parent', parentTab, 'Title', ' CONTROL DECK ', ...
                'Units', 'normalized', 'Position', [0.02 0.02 0.58 0.38], ...
                'FontSize', 10, 'FontWeight', 'bold', 'BackgroundColor', [0.94 0.94 0.94]);
            
            % --- COLUMN 1: INSPECTOR (Left 33%) ---
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'TARGET:', ...
                'Units', 'normalized', 'Position', [0.02 0.90 0.15 0.08], ...
                'HorizontalAlignment', 'left', 'BackgroundColor', [0.94 0.94 0.94], 'FontWeight', 'bold');
            
            nodeNames = cell(1, numel(nodes));
            for i = 1:numel(nodes)
                if isprop(nodes(i), 'hexID'), id = nodes(i).hexID; else, id = sprintf('N%d', i); end
                nodeNames{i} = id;
            end
            
            obj.ddNodes = uicontrol('Parent', obj.pnl, 'Style', 'popupmenu', ...
                'String', nodeNames, 'Units', 'normalized', 'Position', [0.18 0.91 0.14 0.08]);
            
            obj.inspectSummary = uicontrol('Parent', obj.pnl, 'Style', 'edit', ...
                'Units', 'normalized', 'Position', [0.02 0.05 0.30 0.83], ...
                'HorizontalAlignment', 'left', 'Max', 2, 'Enable', 'inactive', ...
                'FontName', 'Consolas', 'BackgroundColor', 'w', 'FontSize', 9);

            % --- COLUMN 2: LOCAL LOG (Middle 33%) ---
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'LOCAL LOG', ...
                'Units', 'normalized', 'Position', [0.34 0.90 0.30 0.08], ...
                'BackgroundColor', [0.94 0.94 0.94], 'FontWeight', 'bold');
                
            obj.logBox = uicontrol('Parent', obj.pnl, 'Style', 'listbox', ...
                'Units', 'normalized', 'Position', [0.34 0.05 0.30 0.83], ...
                'FontName', 'Consolas', 'FontSize', 8, 'BackgroundColor', 'w');

            % --- COLUMN 3: COMMANDS (Right 33%) ---
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'COMMANDS', ...
                'Units', 'normalized', 'Position', [0.66 0.90 0.32 0.08], ...
                'BackgroundColor', [0.94 0.94 0.94], 'FontWeight', 'bold');

            %% ---------------- ROW 1 ----------------
            % X
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'X:', ...
                'Units', 'normalized', 'Position', [0.66 0.80 0.05 0.06], ...
                'HorizontalAlignment', 'right', 'BackgroundColor', [0.94 0.94 0.94]);

            obj.txtPosX = uicontrol('Parent', obj.pnl, 'Style', 'edit', ...
                'Units', 'normalized', 'Position', [0.71 0.80 0.08 0.06], ...
                'Callback', @(s,e)obj.updatePosition(nodes));

            % Y
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'Y:', ...
                'Units', 'normalized', 'Position', [0.80 0.80 0.05 0.06], ...
                'HorizontalAlignment', 'right', 'BackgroundColor', [0.94 0.94 0.94]);

            obj.txtPosY = uicontrol('Parent', obj.pnl, 'Style', 'edit', ...
                'Units', 'normalized', 'Position', [0.85 0.80 0.08 0.06], ...
                'Callback', @(s,e)obj.updatePosition(nodes));

            % Tx Power
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'TxPwr:', ...
                'Units', 'normalized', 'Position', [0.66 0.72 0.10 0.06], ...
                'HorizontalAlignment', 'right', 'BackgroundColor', [0.94 0.94 0.94]);

            obj.txtTx = uicontrol('Parent', obj.pnl, 'Style', 'edit', ...
                'Units', 'normalized', 'Position', [0.77 0.72 0.16 0.06], ...
                'Callback', @(s,e)obj.updateScale(nodes));

            %% ---------------- ROW 2 ----------------
            % TTL
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'TTL:', ...
                'Units', 'normalized', 'Position', [0.66 0.64 0.10 0.06], ...
                'HorizontalAlignment', 'right', 'BackgroundColor', [0.94 0.94 0.94]);

            obj.txtTTL = uicontrol('Parent', obj.pnl, 'Style', 'edit', 'String', '5', ...
                'Units', 'normalized', 'Position', [0.77 0.64 0.16 0.06]);

            % Trigger Flood
            obj.btnFlood = uicontrol('Parent', obj.pnl, 'Style', 'pushbutton', ...
                'String', 'TRIGGER FLOOD', ...
                'Units', 'normalized', 'Position', [0.66 0.56 0.27 0.07], ...
                'BackgroundColor', [0.85 0.85 0.85], 'FontWeight', 'bold');

            %% ---------------- ROW 3 ----------------
            % --- ATTACK INTENSITY SLIDER ---
            uicontrol('Parent', obj.pnl, 'Style', 'text', ...
                'String', 'INTENSITY', ...
                'Units', 'normalized', ...
                'Position', [0.66 0.46 0.14 0.06], ...
                'BackgroundColor', [0.94 0.94 0.94], ...
                'HorizontalAlignment', 'center',...
                'FontWeight', 'bold');

            
            obj.sldAttackIntensity = uicontrol('Parent', obj.pnl, ...
                'Style', 'slider', ...
                'Min', 1, 'Max', 10, 'Value', 5, ...
                'SliderStep', [1/9 1/9], ...
                'Units', 'normalized', ...
                'Position', [0.66 0.47 0.27 0.05], ...   % same width as dropdown
                'BackgroundColor', [1 0.6 0.6], ...     % soft red
                'Callback', @(s,e)obj.updateAttackIntensity());

            obj.txtAttackIntensityVal = uicontrol('Parent', obj.pnl, ...
                'Style', 'text', ...
                'String', '5', ...
                'Units', 'normalized', ...
                'Position', [0.94 0.47 0.04 0.05], ...
                'BackgroundColor', [0.94 0.94 0.94], ...
                'FontWeight', 'bold');

            %% ---------------- ROW 4 ----------------
            % Attack Mode Dropdown
            uicontrol('Parent', obj.pnl, ...
                'Style', 'text', ...
                'String', 'ATTACK MODE', ...
                'Units', 'normalized', ...
                'Position', [0.66 0.36 0.27 0.05], ...
                'BackgroundColor', [0.94 0.94 0.94], ...
                'HorizontalAlignment', 'center', ...
                'FontWeight', 'bold', ...
                'FontSize', 9);

            obj.menuAtk = uicontrol('Parent', obj.pnl, 'Style', 'popupmenu', ...
                'String', { ...
                    'Normal',...
                    'Hello Flood', ...
                    'Panic Flood', ...
                    'Sybil', ...
                    'Black Hole', ...
                    'Wormhole', ...
                    'Selective Forwarding', ...
                    'Denial of Sleep (Vampire)'}, ...
                'Units', 'normalized', 'Position', [0.66 0.31 0.27 0.05]);

            %% ---------------- ROW 5 ----------------
            % Export CSV
            obj.btnExp = uicontrol('Parent', obj.pnl, 'Style', 'pushbutton', ...
                'String', 'EXPORT CSV', ...
                'Units', 'normalized', 'Position', [0.66 0.18 0.27 0.08], ...
                'BackgroundColor', [0.7 0.9 0.7], 'FontWeight', 'bold');
        end
        
        function updateScale(obj, nodes)
            idx = get(obj.ddNodes, 'Value'); 
            newPwr = str2double(get(obj.txtTx, 'String'));
            if ~isnan(newPwr)
                if idx <= numel(nodes)
                    nodes(idx).txPower = newPwr;
                    if isprop(nodes(idx), 'controlPower'), nodes(idx).controlPower = newPwr; end
                end
            end
        end
        
        function update(obj, nodes, t)
            idx = get(obj.ddNodes, 'Value'); if isempty(idx), return; end
            
            % Safety check for topology resizing
            if idx > numel(nodes), idx = 1; set(obj.ddNodes, 'Value', 1); end
            
            n = nodes(idx);
            
            if obj.lastSelectedNode ~= idx
                if isprop(n, 'txPower')
                    set(obj.txtTx, 'String', sprintf('%.1f', n.txPower));
                end

                set(obj.txtPosX, 'String', sprintf('%.2f', n.pos(1)));
                set(obj.txtPosY, 'String', sprintf('%.2f', n.pos(2)));

                obj.lastSelectedNode = idx;
            end

            % --- ROBUST PROPERTY ACCESS (Crash Prevention) ---
            % ID
            if isprop(n, 'hexID'), idStr = n.hexID; else, idStr = sprintf('%d', n.id); end
            
            % State
            stStr='UNK'; 
            if isprop(n,'state')
                switch n.state, case 0,stStr='BOOT'; case 1,stStr='DISC'; case 2,stStr='SHAKE'; case 3,stStr='SECURE'; case 4,stStr='DORMANT'; end
            end
            
            % Parent (Handle numeric, hex string, or missing)
            parStr = '-'; 
            if isprop(n, 'parent') && ~isempty(n.parent)
                val = n.parent;
                if isnumeric(val)
                    parStr = dec2hex(val); 
                elseif ischar(val) || isstring(val)
                    parStr = val; 
                end
            end
            
            % Battery
            if isprop(n, 'battery'), bat = n.battery; else, bat = 0; end
            
            % Control Power & Buffer
            cp='-'; if isprop(n,'controlPower'), cp=sprintf('%.1f',n.controlPower); end
            buf=0; if isprop(n,'bufferUsage'), buf=n.bufferUsage; end
            
            % Neighbors
            if isprop(n, 'neighborTable'), nbrStr = WSN_Physics.getFormattedNeighborString(n, nodes, t); else, nbrStr = 'No Data'; end
            
            % --- UPDATE SUMMARY ---
            info = sprintf('ID: %s\nState: %s\nPar: %s\nBat: %.1f%%\nBuf: %d/20\nCtrlPwr: %s\n\n%s', ...
                idStr, stStr, parStr, bat, buf, cp, nbrStr);
            set(obj.inspectSummary, 'String', info);
            
            % --- UPDATE LOG ---
            if isprop(n, 'log') && ~isempty(n.log)
                set(obj.logBox, 'String', n.log); 
                count = length(n.log);
                if count > 0, set(obj.logBox, 'Value', count); end
            else
                set(obj.logBox, 'String', {'(No Events)'}); 
                set(obj.logBox, 'Value', 1);
            end
        end
        function updatePosition(obj, nodes)
            idx = get(obj.ddNodes, 'Value');
            if idx < 1 || idx > numel(nodes), return; end

            x = str2double(get(obj.txtPosX, 'String'));
            y = str2double(get(obj.txtPosY, 'String'));

            if isnan(x) || isnan(y), return; end

            nodes(idx).pos = [x y];
        end
    end
end