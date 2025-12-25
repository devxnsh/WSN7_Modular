classdef WSN_Sensor < WSN_Node
    methods
        function obj = WSN_Sensor(id, pos)
            if nargin == 0, id=0; pos=[0 0]; end
            obj@WSN_Node(id, pos, WSN_Config.TIER_SENSOR);
            obj.typeStr = 'SENSOR';
            obj.txPower = WSN_Config.TxPower_Sensor;
        end
        
        function updatePhysics(obj, t)
            if obj.battery <= 0, obj.isAwake = false; return; end
            if mod(t + obj.offset, 20) < 4, obj.isAwake = true; else, obj.isAwake = false; end
        end
        
            function msgs = step(obj, ~, ~, ~)
            msgs = [];
            % Sensors don't originate network traffic in this simulation
            % They would send sensor readings if routed through cluster heads/gateways
        end
        
        function response = receive(obj, ~, ~, ~)
            response = [];
            % Sensors don't process messages in this simulation
            % They are passive data sources
        end
    end
end