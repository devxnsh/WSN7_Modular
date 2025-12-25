classdef WSN_Gateway < WSN_Node
    % =========================================================
    % WSN GATEWAY — FACADE / STATE OWNER
    % Delegates FSM to Behavior, protocol to Messaging
    % =========================================================

    properties
        % -------- ORIGINAL PROPERTIES (UNCHANGED) --------
        controlPower = 6.0
        state = 0

        hasKey = false
        encryptionKey = ''
        isVerified = false
        localKeyHex

        targetParent = []
        lastParent = -1

        crazyTimer = 0
        lastNbrCount = 0

        candidatePtr = 1
        minProspectiveChildren = 1

        handshakePartner = []

        % Neighbor states
        ST_NONE   = 0
        ST_PROSP  = 1
        ST_CHILD  = 2
        ST_PARENT = 3
        ST_REJECT = 4

        % -------- NEW INTERNAL DELEGATES --------
        behavior    % WSN_Gateway_Behavior
        messaging   % WSN_Gateway_Messaging
    end

    % =========================================================
    % CONSTRUCTOR
    % =========================================================
    methods

        function obj = WSN_Gateway(id, pos)
            if nargin == 0
                id = 0; pos = [0 0];
            end

            obj@WSN_Node(id, pos, WSN_Config.TIER_GWN);

            obj.typeStr      = 'GWN';
            obj.txPower      = WSN_Config.TxPower_GWN;
            obj.controlPower = WSN_Config.TxPower_GWN_Control;
            obj.state        = WSN_Config.STATE_BOOT;

            obj.multicastGroups = [];

            obj.neighborTable = struct( ...
                'id',{}, ...
                'lastSeen',{}, ...
                'rssi',{}, ...
                'trust',{}, ...
                'commRange',{}, ...
                'status',{} );

            % -------- CREATE DELEGATES --------
            obj.behavior  = WSN_Gateway_Behavior(obj);
            obj.messaging = WSN_Gateway_Messaging(obj);
        end
    end

    % =========================================================
    % PHYSICS UPDATE (UNCHANGED SEMANTICS)
    % =========================================================
    methods
        function updatePhysics(obj, t)
            if obj.battery <= 0
                obj.isAwake = false;
                return;
            end

            obj.isAwake = true;
            obj.battery = max(0, obj.battery - 0.001);

            if obj.crazyTimer > 0
                obj.crazyTimer = obj.crazyTimer - 1;
            end

            % Neighbor-count change detection stays HERE
            if numel(obj.neighborTable) ~= obj.lastNbrCount
                obj.lastNbrCount = numel(obj.neighborTable);
                obj.crazyTimer   = WSN_Config.CrazyDuration_Neighbor;

                if ~isempty(obj.neighborTable)
                    [~, idx] = sort([obj.neighborTable.rssi], 'descend');
                    obj.neighborTable = obj.neighborTable(idx);
                    obj.candidatePtr = 1;
                end

                obj.addLog(sprintf( ...
                    't=%d [PHY] Neighbor count=%d', ...
                    t, obj.lastNbrCount));
            end
        end
    end

    % =========================================================
    % STEP — FACADE
    % =========================================================
    methods
        function msgs = step(obj, t, physAdj, allNodes)
            %#ok<INUSD>
            msgs = WSN_Message.empty;

            % ---- BEHAVIOR DECIDES WHAT TO DO ----
            actions = obj.behavior.step(t);

            % ---- MESSAGING MATERIALIZES PACKETS ----
            msgs = obj.messaging.emit(actions, t);
        end
    end

    % =========================================================
    % RECEIVE — FACADE
    % =========================================================
    methods
        function response = receive(obj, msg, t, rssi)
            response = [];

            % RX energy cost (UNCHANGED)
            obj.battery = max(0, obj.battery - WSN_Config.RxCost);

            % ---- PROTOCOL HANDLING ----
            actions = obj.messaging.handleReceive(msg, t, rssi);

            % ---- FSM / STATE UPDATES ----
            obj.behavior.apply(actions, t);

            % ---- RESPONSES ----
            response = obj.messaging.emit(actions, t);
        end
        function localKeyHex = deriveLocalKey(obj)
            gk = uint8(hex2dec(reshape(obj.encryptionKey,2,[])'));
            idBytes = typecast(uint16(hex2dec(obj.hexID)),'uint8');
            pBytes  = typecast(uint16(obj.parent),'uint8');
            seed = [gk; idBytes(:); pBytes(:)];
            lk = gk(1:8);
            for i = 1:numel(seed)
                lk(mod(i-1,8)+1) = bitxor(lk(mod(i-1,8)+1), seed(i));
            end
            localKeyHex = upper(reshape(dec2hex(lk,2).',1,[]));
        end
    end


end
