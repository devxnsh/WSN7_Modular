classdef WSN_Gateway_Messaging < handle
    % =========================================================
    % WSN GATEWAY MESSAGING — RX/TX + PROTOCOL SEMANTICS
    % Owns WHAT packets mean, never WHEN to act
    % =========================================================

    properties
        gw   % handle to owning WSN_Gateway
    end

    % =========================================================
    % CONSTRUCTOR
    % =========================================================
    methods
        function obj = WSN_Gateway_Messaging(gateway)
            obj.gw = gateway;
        end
    end

    % =========================================================
    % EMIT ACTIONS → PACKETS
    % =========================================================
    methods
        function msgs = emit(obj, actions, t)
            %#ok<INUSD>
            msgs = WSN_Message.empty;
            gw = obj.gw;

            if isempty(actions), return; end

            for k = 1:numel(actions)
                a = actions{k};
                if ~isfield(a,'type')
                    continue;
                end
                switch a.type
                    case 'RESP'
                        msgs(end+1) = a.msg; %#ok<AGROW>

                    case 'HB'
                        m = obj.sendHeartbeat(t, a.hb);
                        if ~isempty(m)
                            msgs(end+1) = m; %#ok<AGROW>
                            gw.logTx(m,t);
                        end

                    case 'SEND'
                        switch a.cmd
                            case 'PARENT_INIT'
                                m = WSN_Message(7, hex2dec(gw.hexID), a.dst, []);
                                m.subtype = 0;
                                m.flag = bitset(uint8(0),2,1); % VERIFIED
                                m.addChecksum();
                                msgs(end+1) = m;
                                gw.logTx(m,t);
                        end
                end
            end
        end
    end

    % =========================================================
    % HANDLE RECEIVE → ACTIONS
    % =========================================================
    methods
        function actions = handleReceive(obj, msg, t, rssi)
            actions = {};
            gw = obj.gw;

            % ---- LOG RX (non-heartbeat) ----
            if msg.type ~= 9
                gw.addLog(sprintf( ...
                    't=%d [RX] %s ← %s', ...
                    t, msg.getTypeStr(), gw.fmtID(msg.src)), ...
                    msg, ...
                    t);
            end

            % ---- CHECKSUM ----
            if ~msg.verifyChecksum()
                gw.addLog(sprintf('t=%d [CHK_DROP] %s', ...
                    t, dec2hex(uint16(msg.src),4)));
                return;
            end

            sender = msg.src;
            idx = find([gw.neighborTable.id]==sender,1);

            % ================= HEARTBEAT =================
            if msg.type == 9
                trust = [10 30 60 100];

                if isempty(idx)
                    gw.neighborTable(end+1) = struct( ...
                        'id', sender, ...
                        'lastSeen', t, ...
                        'rssi', rssi, ...
                        'trust', trust(min(end,msg.subtype+1)), ...
                        'commRange', 0, ...
                        'status', gw.ST_NONE );
                else
                    gw.neighborTable(idx).lastSeen = t;
                    gw.neighborTable(idx).rssi = rssi;
                end
                return;
            end

            % ================= CMD ONLY =================
            if msg.type ~= 7 || msg.dst ~= hex2dec(gw.hexID)
                return;
            end

            switch msg.subtype

                % ----------- PARENT_INIT -----------
                case 0
                    if bitget(msg.flag,2) == 0
                        return;
                    end

                    if ~isempty(gw.parent) || ...
                            (~isempty(gw.handshakePartner) && gw.handshakePartner ~= sender)

                        r = WSN_Message(7,hex2dec(gw.hexID),sender,[]);
                        r.subtype = 3;
                        r.addChecksum();
                        actions{end+1} = struct('type','RESP','msg',r);
                        gw.logTx(r,t);
                        return;
                    end

                    % mutual-init deadlock
                    if ~isempty(gw.handshakePartner) && gw.handshakePartner == sender
                        r = WSN_Message(7,hex2dec(gw.hexID),sender,[]);
                        r.subtype = 3;
                        r.addChecksum();
                        actions{end+1} = struct('type','RESP','msg',r);
                        gw.logTx(r,t);

                        actions{end+1} = struct('effect','REJECT_NEIGHBOR','value',sender);
                        actions{end+1} = struct('effect','RESET_PROSPECTS');
                        actions{end+1} = struct('effect','CLEAR_HANDSHAKE');
                        actions{end+1} = struct('effect','STATE','value',WSN_Config.STATE_SECURE);
                        return;
                    end

                    gw.handshakePartner = sender;
                    actions{end+1} = struct('effect','STATE','value',WSN_Config.STATE_HANDSHAKE);

                    r = WSN_Message(7,hex2dec(gw.hexID),sender,[]);
                    r.subtype = 1;
                    r.addChecksum();
                    actions{end+1} = struct('type','RESP','msg',r);
                    gw.logTx(r,t);

                    % ----------- REQ_JOIN -----------
                case 1
                    actions{end+1} = struct('effect','CLEAR_HANDSHAKE');

                    r = WSN_Message(7,hex2dec(gw.hexID),sender,[]);
                    r.subtype = 2;
                    r.addChecksum();
                    actions{end+1} = struct('type','RESP','msg',r);
                    gw.logTx(r,t);

                    actions{end+1} = struct('effect','MARK_CHILD','value',sender);

                    if ~isempty(idx)
                        gw.neighborTable(idx).status = gw.ST_CHILD;
                    end

                    gk = WSN_Message(7,hex2dec(gw.hexID),sender,[]);
                    gk.subtype = 4;
                    gk.flag = bitset(uint8(0),1,1);
                    gk.setGlobalKeyPayload();
                    actions{end+1} = struct('type','RESP','msg',gk);
                    gw.logTx(gk,t);

                    % ----------- ACK_JOIN -----------
                case 2
                    actions{end+1} = struct('effect','CLEAR_HANDSHAKE');
                    if isempty(gw.parent)
                        actions{end+1} = struct('effect','SET_PARENT','value',sender);
                    end

                    % ----------- PARENT_REJECT -----------
                case 3
                    actions{end+1} = struct('effect','REJECT_NEIGHBOR','value',sender);
                    actions{end+1} = struct('effect','RESET_PROSPECTS');
                    actions{end+1} = struct('effect','CLEAR_HANDSHAKE');
                    actions{end+1} = struct('effect','STATE','value',WSN_Config.STATE_SECURE);

                    % ----------- GLOBAL_KEY -----------
                case 4
                    gw.encryptionKey = msg.getGlobalKeyPayload();
                    gw.localKeyHex   = gw.deriveLocalKey();
                    gw.hasKey = true;
                    gw.isVerified = true;

                    if isempty(gw.parent)
                        gw.parent = sender;
                    end

                    if ~isa(gw,'WSN_Sink')
                        h = WSN_Message(7,hex2dec(gw.hexID),gw.parent,[]);
                        h.subtype = 5;
                        h.flag = bitset(uint8(0),1,1);
                        h.setEncHelloPayload( ...
                            hex2dec(gw.hexID), ...
                            gw.parent, ...
                            gw.localKeyHex, ...
                            0,0);
                        h.addChecksum();
                        actions{end+1} = struct('type','RESP','msg',h);
                        gw.logTx(h,t);
                    end

                    actions{end+1} = struct('effect','RESET_PROSPECTS');

                    % ----------- ENC_HELLO -----------
                case 5
                    if isempty(gw.parent) || isa(gw,'WSN_Sink')
                        return;
                    end

                    fwd = WSN_Message(7,hex2dec(gw.hexID),gw.parent,[]);
                    fwd.subtype = 5;
                    fwd.flag = msg.flag;
                    fwd.payload = msg.payload;
                    fwd.payloadLen = msg.payloadLen;
                    fwd.addChecksum();
                    actions{end+1} = struct('type','RESP','msg',fwd);
                    gw.logTx(fwd,t);
            end
        end
    end

    % =========================================================
    % HEARTBEAT TX (UNCHANGED)
    % =========================================================
    methods
        function msg = sendHeartbeat(obj, t, hbType)
            msg = [];
            gw = obj.gw;

            gw.battery = max(0, gw.battery - 0.05);

            if gw.isVerified
                hbType = 'ENC_HB';
            end

            switch hbType
                case 'HB_BOOT'
                    st = 0; dst = 0; enc = false; ver = false;
                case 'HB_DISC'
                    st = 1; dst = 0; enc = false; ver = false;
                case 'ENC_HB'
                    st = 3; dst = hex2dec('FF00'); enc = true; ver = true;
                otherwise
                    return;
            end

            batNib = min(15, floor(gw.battery/7));
            nbrNib = min(15, numel(gw.neighborTable));
            payloadHex = dec2hex(bitshift(batNib,4)+nbrNib,2);

            msg = WSN_Message(9, hex2dec(gw.hexID), dst, payloadHex);
            msg.subtype = st;
            msg.flag = uint8(0);
            msg.flag = bitset(msg.flag,1,enc);
            msg.flag = bitset(msg.flag,2,ver);
            msg.addChecksum();
        end
    end
end
