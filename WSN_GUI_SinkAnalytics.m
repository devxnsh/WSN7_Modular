classdef WSN_GUI_SinkAnalytics < handle
    properties
        axHealth, axThru, axEnergy, axDrop
        sinkTable
        timeHistory, healthHistory, throughputHistory, energyHistory, dropHistory
    end
    
    methods
        function obj = WSN_GUI_SinkAnalytics(parentTab)
            % Graphs
            obj.axHealth = axes('Parent',parentTab, 'Position',[0.05 0.65 0.4 0.3]); title(obj.axHealth, 'Network Health'); grid(obj.axHealth,'on');
            obj.axThru = axes('Parent',parentTab, 'Position',[0.55 0.65 0.4 0.3]); title(obj.axThru, 'Throughput'); grid(obj.axThru,'on');
            obj.axEnergy = axes('Parent',parentTab, 'Position',[0.05 0.3 0.4 0.3]); title(obj.axEnergy, 'Energy'); grid(obj.axEnergy,'on');
            obj.axDrop = axes('Parent',parentTab, 'Position',[0.55 0.3 0.4 0.3]); title(obj.axDrop, 'Drops'); grid(obj.axDrop,'on');
            
            % Registry Table
            uicontrol('Parent',parentTab, 'Style', 'text', 'String', ' SINK ROUTING REGISTRY', ...
                'Units', 'normalized', 'Position', [0.05 0.25 0.9 0.03], ...
                'BackgroundColor', [0.2 0.2 0.2], 'ForegroundColor', 'w', 'FontSize', 10, 'FontWeight', 'bold');
                
            obj.sinkTable = uitable('Parent',parentTab, 'Units', 'normalized', ...
                'Position', [0.05 0.02 0.9 0.22], ...
                'ColumnName', {'Node ID', 'Parent', 'Full Route', 'Local Key'}, ...
                'ColumnWidth', {80, 80, 400, 100}, 'RowName', []);
                
            obj.timeHistory=[]; obj.healthHistory=[]; obj.throughputHistory=[]; obj.energyHistory=[]; obj.dropHistory=[];
        end
        
        function updateRegistry(obj, nodes)
            sinkNode = [];
            for i=1:numel(nodes), if isa(nodes(i), 'WSN_Sink'), sinkNode=nodes(i); break; end; end
            
            if ~isempty(sinkNode) && isprop(sinkNode, 'nodeRegistry') && ~isempty(sinkNode.nodeRegistry)
                reg = sinkNode.nodeRegistry;
                sData = cell(numel(reg), 4);
                for k=1:numel(reg)
                    e = reg(k);
                    sData(k,:) = {e.hexID, e.parent, e.route, e.localKey};
                end
                set(obj.sinkTable, 'Data', sData);
            end
        end
        
        function updateGraphs(obj, nodes, t)
            % Basic Analytics (Placeholder logic)
            numActive = sum([nodes.isAwake]);
            healthPct = (numActive / numel(nodes)) * 100;
            avgBattery = mean([nodes.battery]);
            
            obj.timeHistory(end+1) = t;
            obj.healthHistory(end+1) = healthPct;
            obj.energyHistory(end+1) = avgBattery;
            obj.throughputHistory(end+1) = 0; 
            obj.dropHistory(end+1) = 0;
            
            if length(obj.timeHistory) > 100
                obj.timeHistory = obj.timeHistory(2:end);
                obj.healthHistory = obj.healthHistory(2:end);
                obj.energyHistory = obj.energyHistory(2:end);
                obj.throughputHistory = obj.throughputHistory(2:end);
                obj.dropHistory = obj.dropHistory(2:end);
            end
            
            plot(obj.axHealth, obj.timeHistory, obj.healthHistory, 'g-'); ylim(obj.axHealth,[0 100]);
            plot(obj.axEnergy, obj.timeHistory, obj.energyHistory, 'c-'); ylim(obj.axEnergy,[0 100]);
            plot(obj.axThru, obj.timeHistory, obj.throughputHistory, 'b-'); 
            plot(obj.axDrop, obj.timeHistory, obj.dropHistory, 'r-'); 
        end
    end
end