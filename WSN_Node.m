classdef WSN_Node < handle & matlab.mixin.Heterogeneous
    properties
        id, pos, tier, typeStr, hexID = '0000'
        battery = 100.0
        isAwake = true
        offset = 0
        txPower = 2.0

        neighborTable = []
        parent = []
        children = []

        bufferUsage = 0
        log = {}

        % --- PROTOCOL ---
        multicastGroups = []   % e.g. [hex2dec('FF00')]
    end

    methods
        function obj = WSN_Node(id, pos, tier)
            if nargin == 0, return; end

            obj.id = id;
            obj.pos = pos;
            obj.tier = tier;
            obj.hexID = '0000';

            switch tier
                case 0, obj.typeStr = 'SINK';
                case 1, obj.typeStr = 'GWN';
                case 2, obj.typeStr = 'CH';
                case 3, obj.typeStr = 'SENSOR';
            end

            obj.neighborTable = struct( ...
                'id',{},'lastSeen',{},'rssi',{}, ...
                'trust',{},'commRange',{},'status',{});
        end
        function logTx(obj, msg, t)
            txt = sprintf('t=%d [TX] type=%d sub=%d → %s',t, msg.type, msg.subtype, obj.fmtID(msg.dst));
            obj.addLog( ...
                sprintf('t=%d [TX] %s → %s', ...
                    t, msg.getTypeStr(), obj.fmtID(msg.dst)), ...
                msg, ...
                t);

        end
        function h = hex(obj, id)
            h = dec2hex(uint16(id),4);
        end

        % --------------------------------------------------
        % HELPER
        % --------------------------------------------------
        function h = netHex(obj, v)
            if isempty(v), h = '----'; return; end
            h = dec2hex(uint16(v),4);
        end
        function s = fmtID(obj, v)
            if isempty(v)
                s = '<BCAST>';
            elseif v == 0
                s = '<BCAST>';
            elseif v == hex2dec('FFFF')
                s = 'FFFF';
            else
                s = dec2hex(uint16(v),4);
            end
        end


        
        % --------------------------------------------------
        % PHYSICS (unchanged)
        % --------------------------------------------------
        function updatePhysics(obj, t)
            if obj.battery > 0
                obj.battery = max(0, obj.battery - 0.0001);
            else
                obj.isAwake = false;
            end
        end

        function msgs = step(obj, t, physAdj)
            msgs = [];
        end

        % --------------------------------------------------
        % UNIVERSAL RECEIVE (PROTOCOL GATEKEEPER)
        % --------------------------------------------------
        function response = receive(obj, msg, t, rssi)
            if ~msg.checksumOK
                obj.addLog(sprintf( ...
                    't=%d [CHK_DROP] From %s', ...
                    t, obj.fmtID(msg.src)));
                return;
            end
            response = [];

            if ~obj.isAwake || obj.battery <= 0
                return;
            end

            % RX energy
            obj.battery = max(0, obj.battery - 0.01);

            % TTL check (future)
            if isprop(msg,'ttl') && msg.ttl <= 0
                return;
            end

            % --- DESTINATION FILTERING ---
            myID = hex2dec(obj.hexID);
            dst = msg.dst;

            isBroadcast = isempty(dst) || dst == 0 || dst == hex2dec('FFFF');
            isUnicast   = ~isempty(dst) && dst == myID;
            isMulticast = ~isempty(dst) && ismember(dst, obj.multicastGroups);

            if ~(isBroadcast || isUnicast || isMulticast)
                return;
            end

            % ENC_HB is NEVER forwarded, tier logic will handle
            % Forwarding decisions belong to subclasses

            % Delegate to tier-specific receive
            response = obj.receiveImpl(msg, t, rssi);
        end

        % --------------------------------------------------
        % TIER OVERRIDE POINT
        % --------------------------------------------------
        function response = receiveImpl(obj, msg, t, rssi)
            %#ok<INUSD>
            response = [];
        end

        % --------------------------------------------------
        % LOGGING
        % --------------------------------------------------
        function addLog(obj, txt, msg, t)
            % ---- LOCAL LOG ----
            if isempty(obj.log)
                obj.log = {txt};
            else
                obj.log{end+1} = txt;
            end

            % ---- GLOBAL EVENT ----
            if nargin >= 4 && ~isempty(msg)
                WSN_GUI_GlobalEventBus.emit(t, msg);
            end
        end

    end
    methods (Sealed)
        function tf = isequal(obj1, obj2)
            tf = isequal@handle(obj1, obj2);
        end
    end
end
