classdef WSN_Sink < WSN_Gateway
    % =========================================================
    % WSN SINK — TERMINAL, CHECKSUM-SAFE, FSM-CORRECT
    % =========================================================

    properties
        bootComplete    logical = false
        recruitmentDone logical = false

        grayList
        nodeRegistry
    end

    % =========================================================
    % CONSTRUCTOR
    % =========================================================
    methods
        function obj = WSN_Sink(id, pos)
            obj@WSN_Gateway(id, pos);

            obj.typeStr = 'SINK';

            obj.parent   = [];
            obj.children = [];

            % Sink does NOT auto-expand children like GWN
            obj.minProspectiveChildren = 0;

            obj.grayList     = struct('id',{},'dumpCount',{},'proxy',{});
            obj.nodeRegistry = struct('hexID',{},'parent',{},'route',{},'localKey',{});
        end
    end

    % =========================================================
    % STEP
    % =========================================================
    methods
        function msgs = step(obj, t, physAdj, allNodes)
            msgs = WSN_Message.empty;

            % ---------------- BOOT PHASE ----------------
            % EXACTLY like Gateway
            if t < WSN_Config.BootSteps
                msgs = step@WSN_Gateway(obj, t, physAdj, allNodes);

                if mod(t, WSN_Config.HelloInterval) == mod(obj.offset, WSN_Config.HelloInterval)
                    msgs = [msgs, obj.sendHeartbeat(t,'HB_BOOT')];
                end
                return;
            end

            % ---------------- BOOT COMPLETE ----------------
            if ~obj.bootComplete
                obj.bootComplete = true;

                obj.state         = WSN_Config.STATE_SECURE;
                obj.isVerified    = true;
                obj.hasKey        = true;
                obj.encryptionKey = WSN_Message.GLOBAL_AES_KEY_HEX;
                obj.multicastGroups = hex2dec('FF00');

                obj.addLog(sprintf('t=%d [SINK] Boot complete', t));
            end


            % ---------------- ONE-TIME RECRUITMENT ----------------
            if ~obj.recruitmentDone && numel(obj.neighborTable) >= 2

                % Sort neighbors by RSSI descending
                [~, idx] = sort([obj.neighborTable.rssi], 'descend');
                nbrs = obj.neighborTable(idx);

                % Always take the top 2
                rssi2 = nbrs(2).rssi;
                thresh = 0.95 * rssi2;

                selected = [];

                for k = 1:numel(nbrs)
                    if k <= 2 || nbrs(k).rssi >= thresh
                        selected(end+1) = nbrs(k).id; %#ok<AGROW>
                    else
                        break;  % sorted list → safe to stop
                    end
                end

                % Send PARENT_INIT to selected nodes
                for nid = selected
                    m = WSN_Message(7, hex2dec(obj.hexID), nid, []);
                    m.subtype = 0;                          % PARENT_INIT
                    m.flag    = bitset(uint8(0),2,1);       % VERIFIED
                    m.addChecksum();

                    msgs = [msgs, m];

                    obj.addLog( ...
                        sprintf('t=%d [SINK_RECRUIT] INIT → %s', ...
                        t, dec2hex(uint16(nid),4)), ...
                        m, ...
                        t);
                end

                obj.recruitmentDone = true;
            end

            % ---------------- NORMAL OPERATION ----------------
            if mod(t,WSN_Config.HelloInterval)==mod(obj.offset,WSN_Config.HelloInterval)
            
                % Plain discovery heartbeat for unverified neighbors
                if ~obj.isVerified
                    hb = obj.sendHeartbeat(t,'HB_DISC');
                    if ~isempty(hb)
                        msgs = [msgs, hb];
                    end
                end
            
                % Encrypted multicast heartbeat for verified network
                if obj.isVerified
                    hb = obj.sendHeartbeat(t,'ENC_HB');
                    if ~isempty(hb)
                        msgs = [msgs, hb];
                    end
                end
            end
        end
    end

    % =========================================================
    % RECEIVE (TERMINAL)
    % =========================================================
    methods

        function response = receive(obj, msg, t, rssi)
            response = [];
            obj.battery = max(0, obj.battery - WSN_Config.RxCost);

            % ---- CHECKSUM ----
            if ~msg.verifyChecksum()
                obj.addLog(sprintf('t=%d [CHK_DROP] From %s', ...
                    t, dec2hex(uint16(msg.src),4)));
                return;
            end

            % ---- HEARTBEAT ----
            if msg.type == 9
                response = receive@WSN_Gateway(obj, msg, t, rssi);
                return;
            end

            % ---- CMD FRAME ----
            if msg.type ~= 7
                return;
            end
            % 1️⃣ IMMUNITY: Sink never accepts parents
            if msg.subtype == 0
                r = WSN_Message(7, hex2dec(obj.hexID), msg.src, []);
                r.subtype = 3; % PARENT_REJECT
                r.addChecksum();
                response = r;
            
                obj.addLog(sprintf( ...
                    't=%d [IMMUNITY] Reject INIT from %s', ...
                    t, dec2hex(uint16(msg.src),4)), ...
                    msg, ...
                    t);
                return;
            end

            % 2️⃣ TERMINATE ENC_HELLO AT SINK
            if msg.subtype == 5 && msg.dst == hex2dec(obj.hexID)

                s = msg.getEncHelloPayload();

                nodeHex   = dec2hex(s.srcID,4);
                parentHex = dec2hex(s.parentID,4);

                idx = find(strcmp({obj.nodeRegistry.hexID}, nodeHex), 1);

                if isempty(idx)
                    obj.nodeRegistry(end+1) = struct( ...
                        'hexID', nodeHex, ...
                        'parent', parentHex, ...
                        'route', '', ...
                        'localKey', s.localKeyHex);
                else
                    obj.nodeRegistry(idx).parent   = parentHex;
                    obj.nodeRegistry(idx).localKey = s.localKeyHex;
                end

                idx = find(strcmp({obj.nodeRegistry.hexID}, nodeHex), 1);
                obj.nodeRegistry(idx).route = obj.traceRoute(nodeHex);

                obj.addLog(sprintf( ...
                    't=%d [REGISTRY] %s route=%s', ...
                    t, nodeHex, obj.nodeRegistry(idx).route));
                return;
            end

            % 3️⃣ EVERYTHING ELSE → Gateway FSM
            response = receive@WSN_Gateway(obj, msg, t, rssi);
        end

    end

    % =========================================================
    % ROUTE TRACE
    % =========================================================
    methods
        function routeStr = traceRoute(obj, targetHex)
            path = {};
            curr = targetHex;
            hops = 0;

            while hops < 20
                path{end+1} = curr;
                idx = find(strcmp({obj.nodeRegistry.hexID}, curr), 1);
                if isempty(idx), break; end
                curr = obj.nodeRegistry(idx).parent;
                hops = hops + 1;
            end

            path{end+1} = obj.hexID;
            routeStr = strjoin(flip(path), ' -> ');
        end
    end
end
