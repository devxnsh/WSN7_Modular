%   % Suppress unused variable warnings - defensive initializations
classdef WSN_GUI_ControlDeck < handle
    properties
        pnl
        ddNodes, inspectSummary
        logBoxBackbone   % LoRa Backbone radio log (yellow)
        logBoxAccess     % HC12 Access radio log (green)
        txtTx, txtTTL
        sldAttackIntensity, txtAttackIntensityVal
        txtAttackStartTime  % Start time input for delayed attacks
        btnFlood, menuAtk, menuExport
        lastSelectedNode = -1
        txtPosX, txtPosY
        globalEventFeed  % Reference to global event feed for CSV export
        nodesRef         % Reference to nodes array for CSV export
        currentTick = 0  % Track simulation tick for pending/active status
    end
    
    methods
        function updateAttackIntensity(obj)
            v = round(get(obj.sldAttackIntensity, 'Value'));
            set(obj.sldAttackIntensity, 'Value', v);   % snap to integer
            set(obj.txtAttackIntensityVal, 'String', num2str(v));
        end
        
        function onNodeSelectionChanged(obj)
            % Update attack dropdown to reflect selected node's malicious status
            nodeIdx = get(obj.ddNodes, 'Value');
            obj.updateAttackDropdownState(nodeIdx);
        end
        
        function updateAttackDropdownState(obj, nodeIdx)
            % Update attack dropdown appearance based on node's malicious status
            % Orange = pending (before start time), Red = active, White = normal
            %
            % NOTE: We suppress the menuAtk callback while doing programmatic
            % Value updates so that handleAttackSelection() is not triggered
            % before the intensity slider has been synced – which was the root
            % cause of intensity values being silently overwritten by the
            % slider's stale default.
            savedCb = get(obj.menuAtk, 'Callback');
            set(obj.menuAtk, 'Callback', []);  % suppress callback during sync

            if WSN_Attack.isMaliciousNode(nodeIdx)
                % Node is malicious - get status
                attackType = WSN_Attack.getAttackType(nodeIdx);
                guiIdx = WSN_Attack.attackTypeToGuiIndex(attackType);
                startTime = WSN_Attack.getStartTime(nodeIdx);

                % --- sync intensity first so the slider is correct BEFORE
                %     the dropdown Value is restored and callbacks re-enabled ---
                intensity = WSN_Attack.getIntensity(nodeIdx);
                set(obj.sldAttackIntensity, 'Value', intensity);
                set(obj.txtAttackIntensityVal, 'String', num2str(intensity));

                set(obj.menuAtk, 'Value', guiIdx);

                % Check if attack is pending (not yet active)
                if startTime > 0 && obj.currentTick < startTime
                    % PENDING - orange background
                    set(obj.menuAtk, 'BackgroundColor', [1.0 0.85 0.4]);  % Orange tint
                    set(obj.menuAtk, 'TooltipString', sprintf('PENDING: Activates at t=%d', startTime));
                else
                    % ACTIVE - red background
                    set(obj.menuAtk, 'BackgroundColor', [1.0 0.6 0.6]);  % Red tint
                    set(obj.menuAtk, 'TooltipString', 'ACTIVE');
                end

                % Update start time field if present
                if ~isempty(obj.txtAttackStartTime)
                    set(obj.txtAttackStartTime, 'String', num2str(startTime));
                end
            else
                % Node is normal - reset to white background, Normal selection
                set(obj.menuAtk, 'Value', 1);  % "Normal"
                set(obj.menuAtk, 'BackgroundColor', [1.0 1.0 1.0]);  % White
                set(obj.menuAtk, 'TooltipString', '');

                % Clear start time field
                if ~isempty(obj.txtAttackStartTime)
                    set(obj.txtAttackStartTime, 'String', '0');
                end
            end

            set(obj.menuAtk, 'Callback', savedCb);  % restore callback
        end
        
        function handleAttackSelection(obj, nodes)
            % Get selected node index
            nodeIdx = get(obj.ddNodes, 'Value');
            
            % Get attack type from dropdown (1=Normal, 2=HelloFlood, etc.)
            guiIdx = get(obj.menuAtk, 'Value');
            
            % Convert GUI index to attack type constant
            attackType = WSN_Attack.guiIndexToAttackType(guiIdx);
            
            % Get intensity from slider
            intensity = round(get(obj.sldAttackIntensity, 'Value'));
            
            % Apply attack (Sink protection handled inside setMalicious)
            success = WSN_Attack.setMalicious(nodeIdx, attackType, intensity, nodes);
            
            % Visual feedback - reset dropdown if attack was blocked (Sink)
            if ~success && attackType ~= 0
                set(obj.menuAtk, 'Value', 1);  % Reset to 'Normal'
            end
        end

        function obj = WSN_GUI_ControlDeck(parentTab, nodes)
            % 1. CONTROL DECK PANEL (Retaining original width/position)
            % Position: Bottom-Left, spanning 58% width
            obj.pnl = uipanel('Parent', parentTab, 'Title', ' CONTROL DECK ', ...
                'Units', 'normalized', 'Position', [0.02 0.02 0.58 0.38], ...
                'FontSize', 10, 'FontWeight', 'bold', 'BackgroundColor', [0.94 0.94 0.94]);
            
            % --- COLUMN 1: INSPECTOR (Left 33%) ---
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'TARGET:', ...
                'Units', 'normalized', 'Position', [0.02 0.90 0.08 0.08], ...
                'HorizontalAlignment', 'left', 'BackgroundColor', [0.94 0.94 0.94], 'FontWeight', 'bold');
            
            nodeNames = cell(1, numel(nodes));
            for i = 1:numel(nodes)
                if isprop(nodes(i), 'hexID'), id = nodes(i).hexID; else, id = sprintf('N%d', i); end
                nodeNames{i} = id;
            end
            
            obj.ddNodes = uicontrol('Parent', obj.pnl, 'Style', 'popupmenu', ...
                'String', nodeNames, 'Units', 'normalized', 'Position', [0.10 0.91 0.10 0.08], ...
                'Callback', @(s,e) obj.onNodeSelectionChanged());
            
            obj.inspectSummary = uicontrol('Parent', obj.pnl, 'Style', 'edit', ...
                'Units', 'normalized', 'Position', [0.02 0.05 0.26 0.83], ...
                'HorizontalAlignment', 'left', 'Max', 2, 'Enable', 'inactive', ...
                'FontName', 'Consolas', 'BackgroundColor', 'w', 'FontSize', 7);

            % --- COLUMNS 2 & 3: DUAL RADIO LOGS (Side by Side - wider) ---
            % Left: Backbone (LoRa) - Pale yellow
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'BACKBONE', ...
                'Units', 'normalized', 'Position', [0.29 0.90 0.18 0.08], ...
                'BackgroundColor', [0.94 0.94 0.94], 'FontWeight', 'bold');
                
            obj.logBoxBackbone = uicontrol('Parent', obj.pnl, 'Style', 'listbox', ...
                'Units', 'normalized', 'Position', [0.29 0.05 0.18 0.83], ...
                'FontName', 'Consolas', 'FontSize', 7, 'BackgroundColor', [1.0 1.0 0.92]);
            
            % Right: Access (HC12) - Pale green
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'ACCESS', ...
                'Units', 'normalized', 'Position', [0.48 0.90 0.18 0.08], ...
                'BackgroundColor', [0.94 0.94 0.94], 'FontWeight', 'bold');
                
            obj.logBoxAccess = uicontrol('Parent', obj.pnl, 'Style', 'listbox', ...
                'Units', 'normalized', 'Position', [0.48 0.05 0.18 0.83], ...
                'FontName', 'Consolas', 'FontSize', 7, 'BackgroundColor', [0.92 1.0 0.92]);

            % --- COLUMN 4: COMMANDS (Right - narrower) ---
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'COMMANDS', ...
                'Units', 'normalized', 'Position', [0.68 0.90 0.30 0.08], ...
                'BackgroundColor', [0.94 0.94 0.94], 'FontWeight', 'bold');

            %% ---------------- ROW 1 ----------------
            % X
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'X:', ...
                'Units', 'normalized', 'Position', [0.68 0.80 0.04 0.07], ...
                'HorizontalAlignment', 'right', 'BackgroundColor', [0.94 0.94 0.94]);

            obj.txtPosX = uicontrol('Parent', obj.pnl, 'Style', 'edit', ...
                'Units', 'normalized', 'Position', [0.72 0.80 0.07 0.07], ...
                'Callback', @(s,e)obj.updatePosition(nodes));

            % Y
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'Y:', ...
                'Units', 'normalized', 'Position', [0.80 0.80 0.04 0.07], ...
                'HorizontalAlignment', 'right', 'BackgroundColor', [0.94 0.94 0.94]);

            obj.txtPosY = uicontrol('Parent', obj.pnl, 'Style', 'edit', ...
                'Units', 'normalized', 'Position', [0.84 0.80 0.07 0.07], ...
                'Callback', @(s,e)obj.updatePosition(nodes));

            % Tx Power
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'TxPwr:', ...
                'Units', 'normalized', 'Position', [0.68 0.71 0.08 0.07], ...
                'HorizontalAlignment', 'right', 'BackgroundColor', [0.94 0.94 0.94]);

            obj.txtTx = uicontrol('Parent', obj.pnl, 'Style', 'edit', ...
                'Units', 'normalized', 'Position', [0.77 0.71 0.14 0.07], ...
                'Callback', @(s,e)obj.updateScale(nodes));

            %% ---------------- ROW 2 ----------------
            % TTL
            uicontrol('Parent', obj.pnl, 'Style', 'text', 'String', 'TTL:', ...
                'Units', 'normalized', 'Position', [0.68 0.62 0.08 0.07], ...
                'HorizontalAlignment', 'right', 'BackgroundColor', [0.94 0.94 0.94]);

            obj.txtTTL = uicontrol('Parent', obj.pnl, 'Style', 'edit', 'String', '5', ...
                'Units', 'normalized', 'Position', [0.77 0.62 0.14 0.07]);

            % Trigger Flood
            obj.btnFlood = uicontrol('Parent', obj.pnl, 'Style', 'pushbutton', ...
                'String', 'TRIGGER FLOOD', ...
                'Units', 'normalized', 'Position', [0.68 0.53 0.23 0.08], ...
                'BackgroundColor', [0.85 0.85 0.85], 'FontWeight', 'bold');

            %% ---------------- ROW 3 ----------------
            % --- ATTACK INTENSITY SLIDER ---
            uicontrol('Parent', obj.pnl, 'Style', 'text', ...
                'String', 'INTENSITY', ...
                'Units', 'normalized', ...
                'Position', [0.68 0.44 0.12 0.07], ...
                'BackgroundColor', [0.94 0.94 0.94], ...
                'HorizontalAlignment', 'center',...
                'FontWeight', 'bold');

            
            obj.sldAttackIntensity = uicontrol('Parent', obj.pnl, ...
                'Style', 'slider', ...
                'Min', 1, 'Max', 10, 'Value', 5, ...
                'SliderStep', [1/9 1/9], ...
                'Units', 'normalized', ...
                'Position', [0.68 0.44 0.19 0.06], ...
                'BackgroundColor', [1 0.6 0.6], ...
                'Callback', @(s,e)obj.updateAttackIntensity());

            obj.txtAttackIntensityVal = uicontrol('Parent', obj.pnl, ...
                'Style', 'text', ...
                'String', '5', ...
                'Units', 'normalized', ...
                'Position', [0.88 0.44 0.04 0.06], ...
                'BackgroundColor', [0.94 0.94 0.94], ...
                'FontWeight', 'bold');

            %% ---------------- ROW 4 ----------------
            % Attack Mode Dropdown
            uicontrol('Parent', obj.pnl, ...
                'Style', 'text', ...
                'String', 'ATTACK MODE', ...
                'Units', 'normalized', ...
                'Position', [0.68 0.34 0.23 0.07], ...
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
                'Units', 'normalized', 'Position', [0.68 0.27 0.23 0.07], ...
                'Callback', @(s,e)obj.handleAttackSelection(nodes));

            %% ---------------- ROW 5 ----------------
            % Attack Start Time Input
            uicontrol('Parent', obj.pnl, 'Style', 'text', ...
                'String', 'START @t=', ...
                'Units', 'normalized', ...
                'Position', [0.68 0.20 0.10 0.06], ...
                'BackgroundColor', [0.94 0.94 0.94], ...
                'HorizontalAlignment', 'right', ...
                'FontWeight', 'bold', ...
                'FontSize', 8);
            
            obj.txtAttackStartTime = uicontrol('Parent', obj.pnl, 'Style', 'edit', ...
                'String', '0', ...
                'Units', 'normalized', 'Position', [0.79 0.20 0.12 0.06], ...
                'TooltipString', 'Activation tick (0=immediate)', ...
                'Callback', @(s,e)obj.handleStartTimeChange(nodes));

            %% ---------------- ROW 6 ----------------
            % Export CSV Dropdown
            uicontrol('Parent', obj.pnl, 'Style', 'text', ...
                'String', 'EXPORT:', ...
                'Units', 'normalized', ...
                'Position', [0.68 0.10 0.08 0.07], ...
                'BackgroundColor', [0.94 0.94 0.94], ...
                'HorizontalAlignment', 'right', ...
                'FontWeight', 'bold');
            
            obj.menuExport = uicontrol('Parent', obj.pnl, 'Style', 'popupmenu', ...
                'String', { ...
                    'Select Export...', ...
                    'Global Event Log', ...
                    'Selected Node Log', ...
                    'Complete Logs (All)', ...
                    'Sink Node Log Only'}, ...
                'Units', 'normalized', 'Position', [0.77 0.10 0.18 0.07], ...
                'BackgroundColor', [0.7 0.9 0.7], ...
                'FontWeight', 'bold', ...
                'Callback', @(s,e) obj.handleExport());
            
            % Store reference to nodes for export
            obj.nodesRef = nodes;
        end
        
        function handleStartTimeChange(obj, nodes) %
            % Update attack start time for selected node
            % nodes argument kept for callback signature consistency
            nodeIdx = get(obj.ddNodes, 'Value');
            startTime = str2double(get(obj.txtAttackStartTime, 'String'));
            
            if isnan(startTime) || startTime < 0
                startTime = 0;
                set(obj.txtAttackStartTime, 'String', '0');
            end
            
            % Only update if node is configured as malicious
            if WSN_Attack.isMaliciousNode(nodeIdx)
                WSN_Attack.setStartTime(nodeIdx, startTime);
                obj.updateAttackDropdownState(nodeIdx);
            end
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
            
            % Track current simulation tick for pending/active attack status
            obj.currentTick = t;
            
            % Safety check for topology resizing
            if idx > numel(nodes), idx = 1; set(obj.ddNodes, 'Value', 1); end
            
            n = nodes(idx);
            
            if obj.lastSelectedNode ~= idx
                if isprop(n, 'txPower')
                    set(obj.txtTx, 'String', sprintf('%.1f', n.txPower));
                end

                set(obj.txtPosX, 'String', sprintf('%.2f', n.pos(1)));
                set(obj.txtPosY, 'String', sprintf('%.2f', n.pos(2)));

                % Update attack dropdown state when node selection changes
                obj.updateAttackDropdownState(idx);
                
                obj.lastSelectedNode = idx;
            else
                % Refresh attack status periodically (for pending->active transition)
                if mod(t, 10) == 0
                    obj.updateAttackDropdownState(idx);
                end
            end

            % --- ROBUST PROPERTY ACCESS (Crash Prevention) ---
            % ID
            if isprop(n, 'hexID'), idStr = n.hexID; else, idStr = sprintf('%d', n.id); end
            
            % State
            stStr='UNK'; 
            if isprop(n,'state')
                switch n.state, case 0,stStr='BOOT'; case 1,stStr='DISC'; case 2,stStr='SHAKE'; case 3,stStr='SECURE'; case 4,stStr='DORMANT'; case 5,stStr='TOKEN'; end
            end
            
            % Parent (Handle numeric, hex string, or missing)
            parStr = '-'; 
            if isprop(n, 'parent') && ~isempty(n.parent)
                val = n.parent;
                if isnumeric(val)
                    hexStr = dec2hex(val); 
                    if isa(n, 'WSN_ClusterHead')
                        parStr = sprintf('[%s]', hexStr);
                    else
                        parStr = hexStr;
                    end
                elseif ischar(val) || isstring(val)
                    parStr = val; 
                end
            end
            
            % Battery
            if isprop(n, 'battery'), bat = n.battery; else, bat = 0; end
            
            % Tier - TIER_SENSOR=1, TIER_CH=2, TIER_GWN=3
            tierStr = 'UNK';
            if isprop(n, 'tier')
                switch n.tier
                    case 1, tierStr = 'SENSOR';
                    case 2, tierStr = 'CH';
                    case 3
                        if isa(n, 'WSN_Sink'), tierStr = 'SINK'; else, tierStr = 'GWN'; end
                end
            end
            
            % Control Power & Buffer
            cp='-'; if isprop(n,'controlPower'), cp=sprintf('%.1f',n.controlPower); end
            buf=0; if isprop(n,'bufferUsage'), buf=n.bufferUsage; end
            
            % Child display: GWN children + [CH children]
            childStr = '';
            if isprop(n,'children') && ~isempty(n.children)
                gwnList = arrayfun(@(c) dec2hex(uint16(c),4), n.children, 'UniformOutput', false);
                childStr = strjoin(gwnList, ', ');
            end
            if isprop(n,'chChildren') && ~isempty(n.chChildren)
                chList = arrayfun(@(c) sprintf('[%s]', dec2hex(uint16(c),4)), n.chChildren, 'UniformOutput', false);
                if ~isempty(childStr)
                    childStr = [childStr, ', ', strjoin(chList, ', ')];
                else
                    childStr = strjoin(chList, ', ');
                end
            end
            if isempty(childStr), childStr = 'None'; end
            
            % Total child count
            childCnt = 0;
            if isprop(n,'children'), childCnt = childCnt + numel(n.children); end
            if isprop(n,'chChildren'), childCnt = childCnt + numel(n.chChildren); end
            
            % Neighbors
            if isprop(n, 'neighborTable'), nbrStr = WSN_Physics.getFormattedNeighborString(n, nodes, t); else, nbrStr = 'No Data'; end
            
            % --- PHASE QUEUES (GWN only) ---
            NL = char(10);  % Actual newline character
            bufferStr = '';
            if isprop(n, 'Q_fwd') && isprop(n, 'Q_local')
                fwdCnt = numel(n.Q_fwd);
                localCnt = numel(n.Q_local);
                if fwdCnt > 0 || localCnt > 0
                    bufferStr = [NL '--- QUEUES ---' NL];
                    bufferStr = [bufferStr sprintf('Q_fwd: %d/%d, Q_local: %d/%d', fwdCnt, WSN_Config.QUEUE_FWD_MAX, localCnt, WSN_Config.QUEUE_LOCAL_MAX) NL];
                    for bi = 1:min(3, fwdCnt)
                        buffered = n.Q_fwd{bi};
                        bufferStr = [bufferStr sprintf(' fwd: Type%d.%d @t=%d', buffered.msg.type, buffered.msg.subtype, buffered.enqueuedAt) NL];
                    end
                    for bi = 1:min(3, localCnt)
                        buffered = n.Q_local{bi};
                        bufferStr = [bufferStr sprintf(' loc: Type%d.%d @t=%d', buffered.msg.type, buffered.msg.subtype, buffered.enqueuedAt) NL];
                    end
                else
                    bufferStr = [NL '--- QUEUES (empty) ---' NL];
                end
            end
            
            % --- PHASE STATE (GWN only) ---
            phaseStr = '';
            if isprop(n, 'currentPhase') && isprop(n, 'phaseInherited')
                phaseNames = {'RX', 'TX', 'IDLE'};
                phaseName = 'IDLE';
                if n.currentPhase >= 0 && n.currentPhase < numel(phaseNames)
                    phaseName = phaseNames{n.currentPhase + 1};
                end
                inheritStr = 'No';
                if n.phaseInherited, inheritStr = 'Yes'; end
                phaseStr = [NL '=== PHASE: ' phaseName ' ===' NL ...
                    'Offset: ' num2str(n.phaseOffset) ' | Inherited: ' inheritStr NL];
            end
            
            % --- UPDATE SUMMARY ---
            info = sprintf('ID: %s | Type: %s\nState: %s | Parent: %s\nBat: %.1f%% | Children: %s\nTxPwr: %.1f | CtrlPwr: %s%s%s\n%s', ...
                idStr, tierStr, stStr, parStr, bat, childStr, n.txPower, cp, phaseStr, bufferStr, nbrStr);
            set(obj.inspectSummary, 'String', info);
            
            % --- UPDATE DUAL RADIO LOGS ---
            % Backbone Log (GWN/Sink only - Sensors/CHs don't have backbone radio)
            if isprop(n, 'logBackbone') && ~isempty(n.logBackbone)
                set(obj.logBoxBackbone, 'String', n.logBackbone);
                count = length(n.logBackbone);
                if count > 0, set(obj.logBoxBackbone, 'Value', count); end
            elseif n.tier == 3  % GWN/Sink with empty log
                set(obj.logBoxBackbone, 'String', {'(No Backbone Events)'});
                set(obj.logBoxBackbone, 'Value', 1);
            else  % Sensors (tier 1) and CHs (tier 2) - no backbone radio
                set(obj.logBoxBackbone, 'String', {'(No Backbone Radio)'});
                set(obj.logBoxBackbone, 'Value', 1);
            end
            
            % Access Log (All nodes have access radio)
            if isprop(n, 'logAccess') && ~isempty(n.logAccess)
                set(obj.logBoxAccess, 'String', n.logAccess);
                count = length(n.logAccess);
                if count > 0, set(obj.logBoxAccess, 'Value', count); end
            elseif isprop(n, 'log') && ~isempty(n.log)
                % Fallback to unified log for non-GWN nodes
                set(obj.logBoxAccess, 'String', n.log);
                count = length(n.log);
                if count > 0, set(obj.logBoxAccess, 'Value', count); end
            else
                set(obj.logBoxAccess, 'String', {'(No Access Events)'});
                set(obj.logBoxAccess, 'Value', 1);
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
        
        function setGlobalEventFeed(obj, feedRef)
            % Set reference to global event feed for CSV export
            obj.globalEventFeed = feedRef;
        end
        
        function handleExport(obj)
            % Handle export dropdown selection
            selection = get(obj.menuExport, 'Value');
            
            % Reset dropdown to first option after selection
            if selection == 1
                return;  % "Select Export..." - do nothing
            end
            
            switch selection
                case 2  % Global Event Log
                    obj.exportGlobalLog();
                case 3  % Selected Node Log
                    obj.exportSelectedNodeLog();
                case 4  % Complete Logs (All)
                    obj.exportCompleteLogs();
                case 5  % Sink Node Log Only
                    obj.exportSinkLog();
            end
            
            % Reset dropdown
            set(obj.menuExport, 'Value', 1);
        end
        
        function exportGlobalLog(obj)
            % Export Global Event Feed to CSV
            if isempty(obj.globalEventFeed) || ~isvalid(obj.globalEventFeed) || ...
               isempty(obj.globalEventFeed.logTable)
                msgbox('Global Event Feed not available', 'Export Error', 'warn');
                return;
            end
            
            data = get(obj.globalEventFeed.logTable, 'Data');
            if isempty(data)
                msgbox('No global events to export', 'Export Info', 'warn');
                return;
            end
            
            % Generate filename with timestamp
            timestamp = datestr(now, 'yyyymmdd_HHMMSS');
            defaultName = sprintf('WSN_GlobalLog_%s.csv', timestamp);
            [filename, pathname] = uiputfile('*.csv', 'Export Global Log', defaultName);
            
            if isequal(filename, 0)
                return;  % User cancelled
            end
            
            filepath = fullfile(pathname, filename);
            
            try
                fid = fopen(filepath, 'w');
                
                % Write header
                fprintf(fid, 'Timestamp,Frame,Inference,Type,Subtype,Source,Destination,PayloadLen,Encrypted,Verified,ChecksumOK,Payload,Direction,LogScope\n');
                
                % Write data rows (data is in reverse chronological order)
                for i = size(data, 1):-1:1
                    row = data(i, :);
                    t = row{1};
                    frame = strrep(char(row{2}), ',', ';');  % Escape commas
                    inference = strrep(char(row{3}), ',', ';');
                    msgType = row{4};
                    subtype = row{5};
                    src = char(row{6});
                    dst = char(row{7});
                    payloadLen = row{8};
                    encrypted = row{9};
                    verified = row{10};
                    checksumOK = row{11};
                    payload = strrep(char(row{12}), ',', ';');
                    
                    % Skip Hello and Heartbeat messages from complete export
                    if msgType == WSN_Config.MSG_TYPE_HELLO || msgType == WSN_Config.MSG_TYPE_HB
                        continue;
                    end

                    % Determine direction from frame
                    direction = 'TX';  % Global feed is TX-centric

                    fprintf(fid, '%d,"%s","%s",%d,%d,%s,%s,%d,%d,%d,%d,"%s",%s,GLOBAL\n', ...
                        t, frame, inference, msgType, subtype, src, dst, ...
                        payloadLen, encrypted, verified, checksumOK, payload, direction);
                end
                
                fclose(fid);
                msgbox(sprintf('Global log exported to:\n%s', filepath), 'Export Complete');
                
            catch ME
                if exist('fid', 'var') && fid > 0
                    fclose(fid);
                end
                msgbox(sprintf('Export failed: %s', ME.message), 'Export Error', 'error');
            end
        end
        
        function exportSelectedNodeLog(obj)
            % Export selected node's local logs to CSV
            nodes = obj.nodesRef;
            if isempty(nodes)
                msgbox('No nodes available', 'Export Error', 'warn');
                return;
            end
            
            idx = get(obj.ddNodes, 'Value');
            if idx < 1 || idx > numel(nodes)
                msgbox('Invalid node selection', 'Export Error', 'warn');
                return;
            end
            
            n = nodes(idx);
            nodeID = n.hexID;
            
            % Generate filename with timestamp
            timestamp = datestr(now, 'yyyymmdd_HHMMSS');
            defaultName = sprintf('WSN_Node_%s_%s.csv', nodeID, timestamp);
            [filename, pathname] = uiputfile('*.csv', 'Export Node Log', defaultName);
            
            if isequal(filename, 0)
                return;  % User cancelled
            end
            
            filepath = fullfile(pathname, filename);
            
            try
                fid = fopen(filepath, 'w');
                
                % Write header with node info
                fprintf(fid, '# Node Export: %s\n', nodeID);
                fprintf(fid, '# Tier: %d, Type: %s\n', n.tier, n.typeStr);
                if isprop(n, 'parent') && ~isempty(n.parent)
                    fprintf(fid, '# Parent: %s\n', dec2hex(uint16(n.parent), 4));
                end
                fprintf(fid, '# Battery: %.1f%%\n', n.battery);
                fprintf(fid, '#\n');
                
                % Write CSV header
                fprintf(fid, 'Timestamp,RadioType,Direction,EventType,MessageType,Subtype,Source,Destination,Status,Battery,BufferState,Parent,Children,TokenStatus,Details,LogScope\n');
                
                entryCount = 0;
                
                % Export Backbone log (GWN only)
                if isprop(n, 'logBackbone') && ~isempty(n.logBackbone)
                    for i = 1:numel(n.logBackbone)
                        entry = n.logBackbone{i};
                        parsed = obj.parseLogEntry(entry, 'BACKBONE', n);
                        fprintf(fid, '%s\n', parsed);
                        entryCount = entryCount + 1;
                    end
                end
                
                % Export Access log (GWN only)
                if isprop(n, 'logAccess') && ~isempty(n.logAccess)
                    for i = 1:numel(n.logAccess)
                        entry = n.logAccess{i};
                        parsed = obj.parseLogEntry(entry, 'ACCESS', n);
                        fprintf(fid, '%s\n', parsed);
                        entryCount = entryCount + 1;
                    end
                end
                
                % Export unified log (all nodes)
                if isprop(n, 'log') && ~isempty(n.log)
                    for i = 1:numel(n.log)
                        entry = n.log{i};
                        % Skip entries already in radio-specific logs
                        if ~startsWith(entry, '[BB]') && ~startsWith(entry, '[AC]')
                            parsed = obj.parseLogEntry(entry, 'UNIFIED', n);
                            fprintf(fid, '%s\n', parsed);
                            entryCount = entryCount + 1;
                        end
                    end
                end
                
                fclose(fid);
                msgbox(sprintf('Node %s log exported to:\n%s\n(%d entries)', nodeID, filepath, entryCount), 'Export Complete');
                
            catch ME
                if exist('fid', 'var') && fid > 0
                    fclose(fid);
                end
                msgbox(sprintf('Export failed: %s', ME.message), 'Export Error', 'error');
            end
        end
        
        function exportCompleteLogs(obj)
            % Export ALL logs: Global + all node local logs
            nodes = obj.nodesRef;
            
            % Generate filename with timestamp
            timestamp = datestr(now, 'yyyymmdd_HHMMSS');
            defaultName = sprintf('WSN_CompleteLogs_%s.csv', timestamp);
            [filename, pathname] = uiputfile('*.csv', 'Export Complete Logs', defaultName);
            
            if isequal(filename, 0)
                return;  % User cancelled
            end
            
            filepath = fullfile(pathname, filename);
            
            try
                fid = fopen(filepath, 'w');
                
                % Write master header
                fprintf(fid, '# WSN Complete Log Export\n');
                fprintf(fid, '# Generated: %s\n', datestr(now));
                fprintf(fid, '# Total Nodes: %d\n', numel(nodes));
                fprintf(fid, '#\n');
                
                % Write CSV header
                fprintf(fid, 'Timestamp,NodeID,NodeType,RadioType,Direction,EventType,MessageType,Subtype,Source,Destination,Status,Battery,BufferState,Parent,Children,TokenStatus,Details,LogScope\n');
                
                totalEntries = 0;
                
                % ========== GLOBAL LOG SECTION ==========
                if ~isempty(obj.globalEventFeed) && isvalid(obj.globalEventFeed) && ...
                   ~isempty(obj.globalEventFeed.logTable)
                    
                    data = get(obj.globalEventFeed.logTable, 'Data');
                    if ~isempty(data)
                        for i = size(data, 1):-1:1
                            row = data(i, :);
                            t = row{1};
                            frame = strrep(char(row{2}), ',', ';');
                            inference = strrep(char(row{3}), ',', ';');
                            msgType = row{4};
                            subtype = row{5};
                            src = char(row{6});
                            dst = char(row{7});
                            
                            % Skip Hello/Heartbeat from global export
                            if msgType == WSN_Config.MSG_TYPE_HELLO || msgType == WSN_Config.MSG_TYPE_HB
                                continue;
                            end
                            
                            fprintf(fid, '%d,GLOBAL,NETWORK,GLOBAL,TX,%s,%d,%d,%s,%s,UNK,100.0,0/0,,,%s,"%s",GLOBAL\n', ...
                                t, inference, msgType, subtype, src, dst, 'None', frame);
                            totalEntries = totalEntries + 1;
                        end
                    end
                end
                
                % ========== PER-NODE LOCAL LOGS ==========
                for nIdx = 1:numel(nodes)
                    n = nodes(nIdx);
                    nodeID = n.hexID;
                    nodeType = n.typeStr;
                    
                    % Backbone log (GWN/Sink only)
                    if isprop(n, 'logBackbone') && ~isempty(n.logBackbone)
                        for i = 1:numel(n.logBackbone)
                            entry = n.logBackbone{i};
                            % Skip Hello/Heartbeat entries
                            typeMatch = regexp(entry, '(\d+)\.(\d+)', 'tokens');
                            if ~isempty(typeMatch)
                                msgType = str2double(typeMatch{1}{1});
                                if msgType == WSN_Config.MSG_TYPE_HELLO || msgType == WSN_Config.MSG_TYPE_HB
                                    continue;
                                end
                            end
                            parsed = obj.parseLogEntry(entry, 'BACKBONE', n);
                            % Insert nodeID and nodeType after timestamp
                            parts = strsplit(parsed, ',', 'CollapseDelimiters', false);
                            timestamp = parts{1};
                            rest = strjoin(parts(2:end), ',');
                            fullLine = sprintf('%s,%s,%s,%s', timestamp, nodeID, nodeType, rest);
                            fprintf(fid, '%s\n', fullLine);
                            totalEntries = totalEntries + 1;
                        end
                    end
                    
                    % Access log (GWN/Sink only)
                    if isprop(n, 'logAccess') && ~isempty(n.logAccess)
                        for i = 1:numel(n.logAccess)
                            entry = n.logAccess{i};
                            % Skip Hello/Heartbeat entries
                            typeMatch = regexp(entry, '(\d+)\.(\d+)', 'tokens');
                            if ~isempty(typeMatch)
                                msgType = str2double(typeMatch{1}{1});
                                if msgType == WSN_Config.MSG_TYPE_HELLO || msgType == WSN_Config.MSG_TYPE_HB
                                    continue;
                                end
                            end
                            parsed = obj.parseLogEntry(entry, 'ACCESS', n);
                            parts = strsplit(parsed, ',', 'CollapseDelimiters', false);
                            timestamp = parts{1};
                            rest = strjoin(parts(2:end), ',');
                            fullLine = sprintf('%s,%s,%s,%s', timestamp, nodeID, nodeType, rest);
                            fprintf(fid, '%s\n', fullLine);
                            totalEntries = totalEntries + 1;
                        end
                    end
                    
                    % Unified log (CH/Sensor and fallback)
                    if isprop(n, 'log') && ~isempty(n.log)
                        for i = 1:numel(n.log)
                            entry = n.log{i};
                            % Skip entries that duplicate radio-specific logs
                            if ~startsWith(entry, '[BB]') && ~startsWith(entry, '[AC]')
                                % Skip Hello/Heartbeat entries
                                typeMatch = regexp(entry, '(\d+)\.(\d+)', 'tokens');
                                if ~isempty(typeMatch)
                                    msgType = str2double(typeMatch{1}{1});
                                    if msgType == WSN_Config.MSG_TYPE_HELLO || msgType == WSN_Config.MSG_TYPE_HB
                                        continue;
                                    end
                                end
                                parsed = obj.parseLogEntry(entry, 'UNIFIED', n);
                                parts = strsplit(parsed, ',', 'CollapseDelimiters', false);
                                timestamp = parts{1};
                                rest = strjoin(parts(2:end), ',');
                                fullLine = sprintf('%s,%s,%s,%s', timestamp, nodeID, nodeType, rest);
                                fprintf(fid, '%s\n', fullLine);
                                totalEntries = totalEntries + 1;
                            end
                        end
                    end
                end
                
                fclose(fid);
                msgbox(sprintf('Complete logs exported to:\n%s\n(%d total entries)', filepath, totalEntries), 'Export Complete');
                
            catch ME
                if exist('fid', 'var') && fid > 0
                    fclose(fid);
                end
                msgbox(sprintf('Export failed: %s', ME.message), 'Export Error', 'error');
            end
        end
        
        function exportSinkLog(obj)
            % Export only the Sink node's logs to CSV
            nodes = obj.nodesRef;
            if isempty(nodes)
                msgbox('No nodes available', 'Export Error', 'warn');
                return;
            end

            % Find the Sink node (typeStr == 'SINK')
            sinkIdx = find(arrayfun(@(n) isprop(n, 'typeStr') && strcmpi(n.typeStr, 'SINK'), nodes), 1);
            if isempty(sinkIdx)
                msgbox('No Sink node found', 'Export Error', 'warn');
                return;
            end
            n = nodes(sinkIdx);
            nodeID = n.hexID;

            % Generate filename with timestamp
            timestamp = datestr(now, 'yyyymmdd_HHMMSS');
            defaultName = sprintf('WSN_SinkNode_%s.csv', timestamp);
            [filename, pathname] = uiputfile('*.csv', 'Export Sink Node Log', defaultName);

            if isequal(filename, 0)
                return;  % User cancelled
            end

            filepath = fullfile(pathname, filename);

            try
                fid = fopen(filepath, 'w');

                % Write header with node info
                fprintf(fid, '# Sink Node Export: %s\n', nodeID);
                fprintf(fid, '# Tier: %d, Type: %s\n', n.tier, n.typeStr);
                if isprop(n, 'parent') && ~isempty(n.parent)
                    fprintf(fid, '# Parent: %s\n', dec2hex(uint16(n.parent), 4));
                end
                fprintf(fid, '# Battery: %.1f%%\n', n.battery);
                fprintf(fid, '#\n');

                % Write CSV header
                fprintf(fid, 'Timestamp,RadioType,Direction,EventType,MessageType,Subtype,Source,Destination,Details,LogScope\n');

                entryCount = 0;

                % Export Backbone log
                if isprop(n, 'logBackbone') && ~isempty(n.logBackbone)
                    for i = 1:numel(n.logBackbone)
                        entry = n.logBackbone{i};
                        parsed = obj.parseLogEntry(entry, 'BACKBONE');
                        if contains(parsed, ',RX,')
                            fprintf(fid, '%s\n', parsed);
                            entryCount = entryCount + 1;
                        end
                    end
                end

                % Export Access log
                if isprop(n, 'logAccess') && ~isempty(n.logAccess)
                    for i = 1:numel(n.logAccess)
                        entry = n.logAccess{i};
                        parsed = obj.parseLogEntry(entry, 'ACCESS');
                        if contains(parsed, ',RX,')
                            fprintf(fid, '%s\n', parsed);
                            entryCount = entryCount + 1;
                        end
                    end
                end

                % Export unified log
                if isprop(n, 'log') && ~isempty(n.log)
                    for i = 1:numel(n.log)
                        entry = n.log{i};
                        % Skip entries already in radio-specific logs
                        if ~startsWith(entry, '[BB]') && ~startsWith(entry, '[AC]')
                            parsed = obj.parseLogEntry(entry, 'UNIFIED');
                            if contains(parsed, ',RX,')
                                fprintf(fid, '%s\n', parsed);
                                entryCount = entryCount + 1;
                            end
                        end
                    end
                end

                fclose(fid);
                msgbox(sprintf('Sink node log exported to:\n%s\n(%d entries)', filepath, entryCount), 'Export Complete');

            catch ME
                if exist('fid', 'var') && fid > 0
                    fclose(fid);
                end
                msgbox(sprintf('Export failed: %s', ME.message), 'Export Error', 'error');
            end
        end
        
        function csvLine = parseLogEntry(obj, entry, radioType, n) %
            % Parse a log entry string into CSV format
            % If n is provided, include node state fields
            % obj is retained for method consistency
            
            entry = char(entry);
            
            % Default values
            timestamp = 0;
            direction = 'N/A';
            eventType = 'INFO';
            msgType = -1;
            subtype = -1;
            src = '';
            dst = '';
            details = strrep(entry, ',', ';');  % Escape commas
            
            % Extract timestamp: t=XXX
            tMatch = regexp(entry, 't=(\d+)', 'tokens');
            if ~isempty(tMatch)
                timestamp = str2double(tMatch{1}{1});
            end
            
            % Determine direction
            if contains(entry, '[TX]') || contains(entry, '_TX]')
                direction = 'TX';
            elseif contains(entry, '[RX]') || contains(entry, '_RX]')
                direction = 'RX';
            elseif contains(entry, '[RELAY')
                direction = 'RELAY';
            elseif contains(entry, '[BUF]')
                direction = 'BUFFER';
            elseif contains(entry, '[FWD]')
                direction = 'FWD';
            end
            
            % Determine event type
            eventTypes = {'TX', 'RX', 'STATE', 'HANDSHAKE', 'TOKEN', 'BUF', 'RELAY', ...
                         'HELLO', 'CHILD', 'PARENT', 'REJECT', 'TIMEOUT', 'ERROR', ...
                         'VERIFY', 'SENSOR', 'CH_REQ', 'CH_ACK', 'KEY_ACK', 'DROP', ...
                         'ORPHAN', 'PHY', 'PURGE', 'CRITICAL', 'SECURITY', 'FWD'};
            for i = 1:numel(eventTypes)
                if contains(entry, ['[' eventTypes{i}])
                    eventType = eventTypes{i};
                    break;
                end
            end
            
            % Extract message type and subtype if present (e.g., "Type7.5" or "5.2")
            typeMatch = regexp(entry, '(\d+)\.(\d+)', 'tokens');
            if ~isempty(typeMatch)
                msgType = str2double(typeMatch{1}{1});
                subtype = str2double(typeMatch{1}{2});
            end
            
            % Extract source and destination if present (e.g., "-> 0A2B" or "<- 0A2B")
            dstMatch = regexp(entry, '-> ([0-9A-Fa-f]{4})', 'tokens');
            if ~isempty(dstMatch)
                dst = upper(dstMatch{1}{1});
            end
            srcMatch = regexp(entry, '<- ([0-9A-Fa-f]{4})', 'tokens');
            if ~isempty(srcMatch)
                src = upper(srcMatch{1}{1});
            end
            
            if nargin < 4 || isempty(n)
                % No node info
                csvLine = sprintf('%d,%s,%s,%s,%d,%d,%s,%s,"%s",LOCAL', ...
                    timestamp, radioType, direction, eventType, msgType, subtype, src, dst, details);
            else
                % Include node state fields
                status = 'UNK';
                if isprop(n, 'state')
                    states = {'BOOT', 'DISC', 'SHAKE', 'SECURE', 'DORMANT', 'TOKEN'};
                    if n.state >= 0 && n.state < numel(states)
                        status = states{n.state + 1};
                    end
                end
                
                battery = sprintf('%.1f', n.battery);
                
                bufferState = '0';
                if isprop(n, 'Q_fwd') && isprop(n, 'Q_local')
                    bufferState = sprintf('%d+%d', numel(n.Q_fwd), numel(n.Q_local));
                end
                
                parent = '';
                if isprop(n, 'parent') && ~isempty(n.parent)
                    parent = dec2hex(uint16(n.parent), 4);
                end
                
                children = '';
                if isprop(n, 'children') && ~isempty(n.children)
                    children = strjoin(arrayfun(@(c) dec2hex(uint16(c), 4), n.children, 'UniformOutput', false), ';');
                end
                if isprop(n, 'chChildren') && ~isempty(n.chChildren)
                    chStr = strjoin(arrayfun(@(c) sprintf('[%s]', dec2hex(uint16(c), 4)), n.chChildren, 'UniformOutput', false), ';');
                    if ~isempty(children)
                        children = [children ';' chStr];
                    else
                        children = chStr;
                    end
                end
                
                phaseStatus = 'N/A';
                if isprop(n, 'currentPhase') && isprop(n, 'phaseInherited') && n.phaseInherited
                    phaseNames = {'RX', 'TX', 'IDLE'};
                    if n.currentPhase >= 0 && n.currentPhase < numel(phaseNames)
                        phaseStatus = phaseNames{n.currentPhase + 1};
                    end
                end
                
                csvLine = sprintf('%d,%s,%s,%s,%d,%d,%s,%s,%s,%s,%s,%s,%s,%s,"%s",LOCAL', ...
                    timestamp, radioType, direction, eventType, msgType, subtype, src, dst, ...
                    status, battery, bufferState, parent, children, phaseStatus, details);
            end
        end
    end
end