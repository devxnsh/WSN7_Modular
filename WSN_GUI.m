classdef WSN_GUI < handle
    properties
        fig, tabGroup, tabTopo, tabSink
        topology, eventFeed, controlDeck, networkState, sinkAnalytics
    end
    
    methods
        function obj = WSN_GUI(nodes, fieldSize)
            obj.fig = figure('Name','WSN Inspector (Final)','Color',[0.94 0.94 0.94],...
                'Units', 'normalized', 'Position', [0.1 0.1 0.85 0.8], 'MenuBar', 'none', 'ToolBar', 'figure');
            
            obj.tabGroup = uitabgroup(obj.fig, 'Position', [0 0 1 1]);
            obj.tabTopo = uitab(obj.tabGroup, 'Title', 'Topology & Operations');
            obj.tabSink = uitab(obj.tabGroup, 'Title', 'Sink Analytics');
            
            obj.topology = WSN_GUI_Topology(obj.tabTopo, fieldSize);
            obj.eventFeed = WSN_GUI_GlobalEventFeed(obj.tabTopo);
            WSN_GUI_GlobalEventBus.bind(obj.eventFeed);


            obj.controlDeck = WSN_GUI_ControlDeck(obj.tabTopo, nodes);
            obj.networkState = WSN_GUI_NetworkState(obj.tabTopo);
            obj.sinkAnalytics = WSN_GUI_SinkAnalytics(obj.tabSink); 
            
            obj.updateInspector(nodes, 0); 
            obj.updateNetworkTable(nodes);
        end
        
        function updateNetwork(obj, nodes, physAdj, t)
            % GET SELECTION FROM CONTROL DECK
            selIdx = get(obj.controlDeck.ddNodes, 'Value');
            
            % PASS SELECTION TO TOPOLOGY
            obj.topology.update(nodes, physAdj, selIdx);
        end
        
        function drawPackets(obj, visualLines, t)
            obj.topology.drawPackets(visualLines, t);
        end
        
        function updateInspector(obj, nodes, t)
            obj.controlDeck.update(nodes, t);
            % Force topology to refresh circles if static
            % (Though updateNetwork handles the loop refresh)
        end
        
        function updateNetworkTable(obj, nodes, t)
            if nargin < 3
                t = 0;
            end

            obj.networkState.update(nodes, t);

            if isvalid(obj.sinkAnalytics)
                obj.sinkAnalytics.updateRegistry(nodes);
            end
        end
        function logVisual(obj, t, src, dst, type, payload)
            if ~isvalid(obj.eventFeed), return; end
            obj.eventFeed.addEntry(t, src, dst, type, payload);
        end

        
        function updateSinkAnalytics(obj, nodes, t)
            if isvalid(obj.sinkAnalytics), obj.sinkAnalytics.updateGraphs(nodes, t); end
        end
    end
end