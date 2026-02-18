classdef WSN_GUI_SinkAnalytics < handle
    properties
        % Graphs
        axHealth, axThru
        axSensorBattery, axSensorValue
        
        % Tables
        sinkTable, sensorTable
        
        % Controls
        sensorDropdown
        selectedSensorID = []
        
        % Data history
        timeHistory, healthHistory, throughputHistory
        cachedSensorRegistry = []
    end
    
    methods
        function obj = WSN_GUI_SinkAnalytics(parentTab)
            % =========================================================
            % HEADER PANEL
            % =========================================================
            uicontrol('Parent', parentTab, 'Style', 'text', ...
                'String', '  SINK ANALYTICS DASHBOARD', ...
                'Units', 'normalized', 'Position', [0.02 0.95 0.96 0.04], ...
                'BackgroundColor', [0.1 0.3 0.5], 'ForegroundColor', 'w', ...
                'FontSize', 12, 'FontWeight', 'bold', 'HorizontalAlignment', 'left');
            
            % =========================================================
            % TOP ROW: NETWORK OVERVIEW GRAPHS
            % =========================================================
            % Network Health Graph (axes first, then label outside)
            obj.axHealth = axes('Parent', parentTab, 'Position', [0.04 0.72 0.44 0.15], ...
                'Color', [0.95 0.95 0.95], 'XColor', 'k', 'YColor', 'k', 'GridColor', [0.7 0.7 0.7]);
            grid(obj.axHealth, 'on'); hold(obj.axHealth, 'on');
            ylabel(obj.axHealth, '%', 'Color', 'k');
            title(obj.axHealth, 'Network Health', 'Color', [0.1 0.4 0.1], 'FontSize', 10, 'FontWeight', 'bold');
            
            % Sensors Tracked Graph
            obj.axThru = axes('Parent', parentTab, 'Position', [0.54 0.72 0.44 0.15], ...
                'Color', [0.95 0.95 0.95], 'XColor', 'k', 'YColor', 'k', 'GridColor', [0.7 0.7 0.7]);
            grid(obj.axThru, 'on'); hold(obj.axThru, 'on');
            ylabel(obj.axThru, 'Count', 'Color', 'k');
            title(obj.axThru, 'Sensors Tracked', 'Color', [0.1 0.2 0.5], 'FontSize', 10, 'FontWeight', 'bold');
            
            % =========================================================
            % MIDDLE ROW: SENSOR SELECTION + TIMESERIES
            % =========================================================
            % Sensor Selection Panel
            uicontrol('Parent', parentTab, 'Style', 'text', ...
                'String', ' SENSOR TIMESERIES', ...
                'Units', 'normalized', 'Position', [0.02 0.66 0.96 0.025], ...
                'BackgroundColor', [0.2 0.2 0.3], 'ForegroundColor', [1 0.9 0.5], ...
                'FontSize', 10, 'FontWeight', 'bold', 'HorizontalAlignment', 'left');
            
            % Dropdown label + control
            uicontrol('Parent', parentTab, 'Style', 'text', 'String', 'Sensor:', ...
                'Units', 'normalized', 'Position', [0.02 0.62 0.06 0.03], ...
                'FontSize', 9, 'FontWeight', 'bold', 'HorizontalAlignment', 'right');
            
            obj.sensorDropdown = uicontrol('Parent', parentTab, 'Style', 'popupmenu', ...
                'Units', 'normalized', 'Position', [0.09 0.62 0.12 0.03], ...
                'String', {'-- None --'}, 'FontSize', 9, ...
                'Callback', @(src,~) obj.onSensorSelect(src));
            
            % Battery Graph
            obj.axSensorBattery = axes('Parent', parentTab, 'Position', [0.04 0.42 0.44 0.18], ...
                'Color', [0.95 0.95 0.95], 'XColor', 'k', 'YColor', 'k', 'GridColor', [0.7 0.7 0.7]);
            title(obj.axSensorBattery, 'Battery %', 'Color', [0 0.5 0.5], 'FontSize', 10);
            grid(obj.axSensorBattery, 'on'); hold(obj.axSensorBattery, 'on');
            ylabel(obj.axSensorBattery, '%', 'Color', 'k');
            xlabel(obj.axSensorBattery, 'Time (TF)', 'Color', 'k');
            
            % Value Graph
            obj.axSensorValue = axes('Parent', parentTab, 'Position', [0.54 0.42 0.44 0.18], ...
                'Color', [0.95 0.95 0.95], 'XColor', 'k', 'YColor', 'k', 'GridColor', [0.7 0.7 0.7]);
            title(obj.axSensorValue, 'Sensor Value', 'Color', [0.6 0.2 0.6], 'FontSize', 10);
            grid(obj.axSensorValue, 'on'); hold(obj.axSensorValue, 'on');
            ylabel(obj.axSensorValue, 'Value', 'Color', 'k');
            xlabel(obj.axSensorValue, 'Time (TF)', 'Color', 'k');
            
            % =========================================================
            % BOTTOM SECTION: TABLES
            % =========================================================
            % Sensor Registry Table Header
            uicontrol('Parent', parentTab, 'Style', 'text', ...
                'String', ' SENSOR REGISTRY', ...
                'Units', 'normalized', 'Position', [0.02 0.36 0.96 0.025], ...
                'BackgroundColor', [0.3 0.2 0.4], 'ForegroundColor', 'w', ...
                'FontSize', 10, 'FontWeight', 'bold', 'HorizontalAlignment', 'left');
            
            obj.sensorTable = uitable('Parent', parentTab, 'Units', 'normalized', ...
                'Position', [0.02 0.22 0.96 0.14], ...
                'ColumnName', {'Sensor', 'Parent', 'Route History', 'Time', 'Value', 'Bat%'}, ...
                'ColumnWidth', {70, 70, 280, 60, 60, 50}, ...
                'RowName', [], 'FontSize', 9);
            
            % Sink Routing Registry Table Header
            uicontrol('Parent', parentTab, 'Style', 'text', ...
                'String', ' GWN/CH ROUTING REGISTRY', ...
                'Units', 'normalized', 'Position', [0.02 0.17 0.96 0.025], ...
                'BackgroundColor', [0.2 0.3 0.3], 'ForegroundColor', 'w', ...
                'FontSize', 10, 'FontWeight', 'bold', 'HorizontalAlignment', 'left');
            
            obj.sinkTable = uitable('Parent', parentTab, 'Units', 'normalized', ...
                'Position', [0.02 0.02 0.96 0.15], ...
                'ColumnName', {'Node', 'Parent', 'Full Route to Sink', 'Local Key'}, ...
                'ColumnWidth', {70, 70, 380, 100}, ...
                'RowName', [], 'FontSize', 9);
            
            % Initialize history
            obj.timeHistory = []; 
            obj.healthHistory = []; 
            obj.throughputHistory = [];
        end
        
        function onSensorSelect(obj, src)
            idx = get(src, 'Value');
            items = get(src, 'String');
            if idx <= 1 || isempty(obj.cachedSensorRegistry)
                obj.selectedSensorID = [];
                return;
            end
            selected = items{idx};
            obj.selectedSensorID = hex2dec(selected);
        end
        
        function updateRegistry(obj, nodes)
            sinkNode = [];
            for i = 1:numel(nodes)
                if isa(nodes(i), 'WSN_Sink')
                    sinkNode = nodes(i);
                    break;
                end
            end
            
            if isempty(sinkNode), return; end
            
            % === Update GWN/CH Registry ===
            if isprop(sinkNode, 'nodeRegistry') && ~isempty(sinkNode.nodeRegistry)
                reg = sinkNode.nodeRegistry;
                hexIDs = {reg.hexID};
                numIDs = hex2dec(hexIDs);
                [~, sortIdx] = sort(numIDs, 'descend');
                reg = reg(sortIdx);
                
                sData = cell(numel(reg), 4);
                for k = 1:numel(reg)
                    e = reg(k);
                    sData(k,:) = {e.hexID, e.parent, e.route, e.localKey};
                end
                set(obj.sinkTable, 'Data', sData);
            end
            
            % === Update Sensor Registry ===
            if isprop(sinkNode, 'sensorRegistry') && ~isempty(sinkNode.sensorRegistry)
                sreg = sinkNode.sensorRegistry;
                obj.cachedSensorRegistry = sreg;
                
                % Update dropdown
                sensorIDs = {'-- None --'};
                for k = 1:numel(sreg)
                    sensorIDs{end+1} = sreg(k).hexID; %#ok<AGROW>
                end
                currentVal = get(obj.sensorDropdown, 'Value');
                set(obj.sensorDropdown, 'String', sensorIDs);
                if currentVal <= numel(sensorIDs)
                    set(obj.sensorDropdown, 'Value', currentVal);
                end
                
                % Build table data
                sensorData = cell(numel(sreg), 6);
                for k = 1:numel(sreg)
                    s = sreg(k);
                    if ~isempty(s.timeseries)
                        latest = s.timeseries(end);
                        routeHist = '-';
                        if isfield(s, 'routeHistory') && ~isempty(s.routeHistory)
                            routeHist = strjoin(s.routeHistory, ' > ');
                        else
                            routeHist = dec2hex(uint16(s.parentCH), 4);
                        end
                        sensorData(k,:) = {s.hexID, dec2hex(uint16(s.parentCH), 4), ...
                                          routeHist, latest.time, latest.value, latest.battery};
                    else
                        sensorData(k,:) = {s.hexID, dec2hex(uint16(s.parentCH), 4), '-', '-', '-', '-'};
                    end
                end
                set(obj.sensorTable, 'Data', sensorData);
            end
        end
        
        function updateGraphs(obj, nodes, t)
            sinkNode = [];
            for i = 1:numel(nodes)
                if isa(nodes(i), 'WSN_Sink')
                    sinkNode = nodes(i);
                    break;
                end
            end
            
            % === Network Health ===
            numActive = sum([nodes.isAwake]);
            healthPct = (numActive / numel(nodes)) * 100;
            
            obj.timeHistory(end+1) = t;
            obj.healthHistory(end+1) = healthPct;
            
            % === Throughput ===
            throughput = 0;
            if ~isempty(sinkNode) && isprop(sinkNode, 'sensorRegistry')
                throughput = numel(sinkNode.sensorRegistry);
            end
            obj.throughputHistory(end+1) = throughput;
            
            % Limit history
            maxHistory = 200;
            if length(obj.timeHistory) > maxHistory
                obj.timeHistory = obj.timeHistory(end-maxHistory+1:end);
                obj.healthHistory = obj.healthHistory(end-maxHistory+1:end);
                obj.throughputHistory = obj.throughputHistory(end-maxHistory+1:end);
            end
            
            % === Plot Health ===
            cla(obj.axHealth);
            area(obj.axHealth, obj.timeHistory, obj.healthHistory, ...
                'FaceColor', [0.2 0.6 0.3], 'EdgeColor', [0.1 0.4 0.1], 'FaceAlpha', 0.6);
            ylim(obj.axHealth, [0 100]);
            title(obj.axHealth, sprintf('Network Health: %.0f%% (%d/%d awake)', ...
                healthPct, numActive, numel(nodes)), 'Color', [0.1 0.4 0.1], 'FontSize', 10, 'FontWeight', 'bold');
            
            % === Plot Throughput ===
            cla(obj.axThru);
            stem(obj.axThru, obj.timeHistory, obj.throughputHistory, ...
                'Color', [0.2 0.4 0.8], 'MarkerFaceColor', [0.3 0.5 0.9], 'MarkerSize', 3);
            title(obj.axThru, sprintf('Sensors Tracked: %d', throughput), ...
                'Color', [0.1 0.2 0.5], 'FontSize', 10, 'FontWeight', 'bold');
            
            % === Plot Selected Sensor ===
            if ~isempty(obj.selectedSensorID) && ~isempty(sinkNode) && ...
               isprop(sinkNode, 'sensorRegistry') && ~isempty(sinkNode.sensorRegistry)
                obj.plotSelectedSensor(sinkNode.sensorRegistry);
            else
                cla(obj.axSensorBattery);
                cla(obj.axSensorValue);
                title(obj.axSensorBattery, 'Select a sensor from dropdown', 'Color', [0.4 0.4 0.4]);
                title(obj.axSensorValue, 'Select a sensor from dropdown', 'Color', [0.4 0.4 0.4]);
            end
        end
        
        function plotSelectedSensor(obj, sensorRegistry)
            cla(obj.axSensorBattery);
            cla(obj.axSensorValue);
            
            idx = find([sensorRegistry.id] == obj.selectedSensorID, 1);
            if isempty(idx)
                title(obj.axSensorBattery, 'Sensor not found', 'Color', [0.6 0.2 0.2]);
                title(obj.axSensorValue, 'Sensor not found', 'Color', [0.6 0.2 0.2]);
                return;
            end
            
            s = sensorRegistry(idx);
            if isempty(s.timeseries)
                title(obj.axSensorBattery, sprintf('%s: No data yet', s.hexID), 'Color', [0.5 0.4 0.2]);
                title(obj.axSensorValue, sprintf('%s: No data yet', s.hexID), 'Color', [0.5 0.4 0.2]);
                return;
            end
            
            times = [s.timeseries.time];
            batteries = [s.timeseries.battery];
            values = [s.timeseries.value];
            
            % Battery plot with gradient fill
            area(obj.axSensorBattery, times, batteries, ...
                'FaceColor', [0.2 0.6 0.6], 'EdgeColor', [0.1 0.4 0.4], 'FaceAlpha', 0.5);
            ylim(obj.axSensorBattery, [0 100]);
            title(obj.axSensorBattery, sprintf('%s Battery: %.0f%%', s.hexID, batteries(end)), ...
                'Color', 'k', 'FontSize', 10);
            
            % Value plot with line + markers
            plot(obj.axSensorValue, times, values, '-o', ...
                'Color', [0.6 0.2 0.6], 'MarkerFaceColor', [0.8 0.4 0.8], 'MarkerSize', 4, 'LineWidth', 1.5);
            title(obj.axSensorValue, sprintf('%s Value: %d', s.hexID, values(end)), ...
                'Color', 'k', 'FontSize', 10);
        end
    end
end