classdef WSN_ClusterHead < WSN_Node
    methods
        function obj = WSN_ClusterHead(id, pos)
            if nargin == 0, id=0; pos=[0 0]; end
            obj@WSN_Node(id, pos, WSN_Config.TIER_CH);
            obj.typeStr = 'CH';
            obj.txPower = WSN_Config.TxPower_CH;
        end
        
        function updatePhysics(obj, ~)
            if obj.battery <= 0, obj.isAwake = false; return; end
            obj.isAwake = true; 
        end
        
            function msgs = step(obj, ~, ~, ~)
            msgs = [];
            % Cluster Heads don't originate network traffic in this simulation
            % They aggregate sensor data and relay to gateways
        end
        
        function response = receive(obj, ~, ~, ~)
            response = [];
            % Cluster Heads don't process messages in this simulation
            % They would aggregate and relay sensor data in full implementation
        end
    end
end