%    % Suppress property shadowing suggestions - intentional local alias pattern
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
    % PHASE-BASED SCHEDULING HELPERS (Replaces Token Gating)
    % =========================================================
    methods
        function phase = computePhase(obj, t)
            % Compute current backbone radio phase from global key and time
            % Returns: PHASE_TX=1 or PHASE_RX=0
            % Formula: phase(t) = f(GLOBAL_AES_KEY, t) XOR phaseOffset
            gw = obj.gw;
            
            % Compute base phase from time (3 TF TX, 3 TF RX cycles)
            cycleLen = WSN_Config.PHASE_CYCLE_LENGTH;  % 6 TFs
            posInCycle = mod(t, cycleLen);
            
            % First half = TX (0,1,2), second half = RX (3,4,5)
            if posInCycle < WSN_Config.PHASE_TX_DURATION
                basePhase = WSN_Config.PHASE_TX;
            else
                basePhase = WSN_Config.PHASE_RX;
            end
            
            % XOR with inherited phase offset to get actual phase
            % This creates opposite phase in parent-child pairs
            phase = bitxor(basePhase, gw.phaseOffset);
        end
        
        function enqueueForward(obj, msg, t)
            % Add message to forwarding queue (child→parent relay)
            % Forwarding queue has strict priority over local queue
            gw = obj.gw;
            
            % Check queue limit (15 max)
            if numel(gw.Q_fwd) >= WSN_Config.QUEUE_FWD_MAX
                % Purge oldest 3 messages
                gw.Q_fwd(1:WSN_Config.QUEUE_PURGE_COUNT) = [];
                gw.addLogBackbone(sprintf('t=%d [Q_FWD] Purged %d oldest (overflow)', ...
                    t, WSN_Config.QUEUE_PURGE_COUNT), [], t);
            end
            
            % Add to queue
            gw.Q_fwd{end+1} = struct('msg', msg, 'enqueuedAt', t);
            gw.addLogBackbone(sprintf('t=%d [Q_FWD] Queued %s.%d (size=%d/%d)', ...
                t, msg.getTypeStr(), msg.subtype, numel(gw.Q_fwd), WSN_Config.QUEUE_FWD_MAX), msg, t);
        end
        
        function enqueueLocal(obj, msg, t)
            % Add message to local queue (own data: CH_HELLO, SENSOR_AGG)
            gw = obj.gw;
            
            % Check queue limit (15 max)
            if numel(gw.Q_local) >= WSN_Config.QUEUE_LOCAL_MAX
                % Purge oldest 3 messages
                gw.Q_local(1:WSN_Config.QUEUE_PURGE_COUNT) = [];
                gw.addLogBackbone(sprintf('t=%d [Q_LOCAL] Purged %d oldest (overflow)', ...
                    t, WSN_Config.QUEUE_PURGE_COUNT), [], t);
            end
            
            % Add to queue
            gw.Q_local{end+1} = struct('msg', msg, 'enqueuedAt', t);
            gw.addLogBackbone(sprintf('t=%d [Q_LOCAL] Queued %s.%d (size=%d/%d)', ...
                t, msg.getTypeStr(), msg.subtype, numel(gw.Q_local), WSN_Config.QUEUE_LOCAL_MAX), msg, t);
        end
        
        function msg = dequeueForTx(obj, t)
            % Dequeue one message for transmission (strict priority: Q_fwd first)
            % Called during TX phase
            gw = obj.gw;
            msg = [];
            
            % STRICT PRIORITY: Forwarding queue first
            if ~isempty(gw.Q_fwd)
                entry = gw.Q_fwd{1};
                gw.Q_fwd(1) = [];
                msg = entry.msg;
                gw.addLogBackbone(sprintf('t=%d [DEQUEUE] From Q_fwd (waited %d TFs)', ...
                    t, t - entry.enqueuedAt), msg, t);
                return;
            end
            
            % Local queue second
            if ~isempty(gw.Q_local)
                entry = gw.Q_local{1};
                gw.Q_local(1) = [];
                msg = entry.msg;
                gw.addLogBackbone(sprintf('t=%d [DEQUEUE] From Q_local (waited %d TFs)', ...
                    t, t - entry.enqueuedAt), msg, t);
                return;
            end
            
            % Both queues empty - IDLE
        end
        
        function isExempt = isControlMessage(~, msg)
            % Check if message is exempt from phase scheduling (control traffic)
            % Control messages can be sent anytime: CMD, HB
            isExempt = ismember(msg.type, [WSN_Config.MSG_TYPE_CMD, WSN_Config.MSG_TYPE_HB]);
        end
    end

    % =========================================================
    % EMIT ACTIONS → PACKETS
    % =========================================================
    methods
        function msgs = emit(obj, actions, t)
            msgs = WSN_Message.empty;
            gw = obj.gw;
            if isempty(actions), return; end
            for k = 1:numel(actions)
                a = actions{k};
                if ~isfield(a,'type'), continue; end
                switch a.type
                    case 'RESP'
                        msgs(end+1) = a.msg;
                    case 'HB'
                        m = obj.sendHeartbeat(t, a.hb);
                        if ~isempty(m)
                            msgs(end+1) = m;
                            % Log HB TX to backbone local log only (no global event feed)
                            gw.addLogBackbone(sprintf('t=%d [TX] HB.%d -> %s', ...
                                t, m.subtype, gw.fmtID(m.dst)), [], t);
                        end
                    case 'SEND'
                        m = obj.sendCommand(t, a.cmd, a.dst);
                        if ~isempty(m)
                            msgs(end+1) = m;
                            gw.logTxBackbone(m,t);
                        end
                end
            end
        end
        
        function m = sendCommand(obj, t, cmd, dst)
            m = [];
            gw = obj.gw;
            if ~strcmp(cmd, 'PARENT_INIT'), return; end
            m = WSN_Message(7, hex2dec(gw.hexID), dst, []);
            m.subtype = 0;
            m.flag = bitset(uint8(0),2,1); % VERIFIED
            m.addChecksum();
            gw.handshakePartner = dst;
            gw.radio.setLock(dst, WSN_Config.HandshakeTimeout);
        end
    end

    % =========================================================
    % HANDLE RECEIVE → ACTIONS
    % =========================================================
    methods
        function actions = handleReceive(obj, msg, t, rssi)
            actions = {};
            gw = obj.gw;
            
            % === ATTACK: BLACKHOLE/GRAYHOLE CHECK ===
            % Malicious GWN may drop messages instead of forwarding
            if WSN_Attack.isMaliciousNode(gw.id)
                attackType = WSN_Attack.getAttackType(gw.id);
                if attackType == WSN_Attack.ATTACK_BLACKHOLE
                    if WSN_Attack.shouldDropBlackhole(gw.id, t)
                        % Add ghost link to parent (dropped message)
                        if ~isempty(gw.parent)
                            WSN_Attack.addGhostLink(gw.id, gw.parent, t + 3, 'FWD');
                        end
                        % Log RX only - no forward/TX logged (stealth)
                        gw.addLog(sprintf('t=%d [RX] type=%d.%d <- %s (no action)', ...
                            t, msg.type, msg.subtype, gw.fmtID(msg.src)));
                        return;  % Drop message
                    end
                elseif attackType == WSN_Attack.ATTACK_GRAYHOLE
                    if WSN_Attack.shouldDropGrayhole(gw.id, t)
                        % Add ghost link to parent (dropped message)
                        if ~isempty(gw.parent)
                            WSN_Attack.addGhostLink(gw.id, gw.parent, t + 3, 'FWD');
                        end
                        % Log RX only - no forward/TX logged (stealth)
                        gw.addLog(sprintf('t=%d [RX] type=%d.%d <- %s (no action)', ...
                            t, msg.type, msg.subtype, gw.fmtID(msg.src)));
                        return;  % Drop message selectively
                    end
                end
            end
            
            % =========================================================
            % UNIVERSAL BACKBONE RELAY: Encrypted + From Child → Queue to Q_fwd
            % This handles ENC_HELLO, CH_HELLO (5.0/5.1), SENSOR_AGG (5.2), etc.
            % GWN acts as store-and-forward relay - phase-scheduled TX
            % =========================================================
            if msg.isEncrypted() && ismember(msg.src, gw.children) && ~isa(gw, 'WSN_Sink')
                if ~msg.verifyChecksum()
                    return;
                end

                % Log reception
                gw.addLogBackbone(sprintf('t=%d [RX_FWD] Encrypted %s.%d from Child %s -> Queue for Parent %s', ...
                    t, msg.getTypeStr(), msg.subtype, gw.fmtID(msg.src), gw.fmtID(gw.parent)), msg, t);

                % Queue for forwarding to parent (strict priority)
                if ~isempty(gw.parent) && gw.hasKey
                    fwd = obj.createRelayForward(msg, t);
                    if ~isempty(fwd)
                        obj.enqueueForward(fwd, t);
                    end
                end
                return;  % Relay queued - don't process further
            end
            
            % Skip RX logging for Hello packets (Type 0) - handled silently
            if msg.type == WSN_Config.MSG_TYPE_HELLO
                % Verify checksum first
                if ~msg.verifyChecksum()
                    return;
                end
                % Route directly to handler (no log)
                obj.handleHello(msg, t, rssi);
                return;
            end
            
            % Handle SENSOR DATA (Type 1) - Direct sensor->GWN on Access radio
            if msg.type == WSN_Config.MSG_TYPE_SENSOR
                if ~msg.verifyChecksum()
                    return;
                end
                gw.addLogAccess(sprintf('t=%d [RX] SENSOR <- %s', ...
                    t, gw.fmtID(msg.src)), msg, t);
                obj.handleSensorData(msg, t, rssi);
                return;
            end
            
            % Handle PANIC (Type 2) - Emergency messages with TTL rebroadcast
            if msg.type == WSN_Config.MSG_TYPE_PANIC
                if ~msg.verifyChecksum()
                    return;
                end
                gw.addLog(sprintf('t=%d [PANIC_RX] sev=%d from=%s TTL=%d', ...
                    t, msg.prio, gw.fmtID(msg.src), msg.ttl));
                actions = obj.handlePanicMessage(msg, t, rssi);
                return;
            end
            
            % Skip RX logging for Heartbeat packets (Type 9) - handled silently
            if msg.type == WSN_Config.MSG_TYPE_HB
                % Verify checksum first
                if ~msg.verifyChecksum()
                    return;
                end
                % Route directly to handler (no log)
                obj.handleHeartbeat(msg, t, rssi);
                return;
            end
            
            % Handle CH_CMD (Type 6) - CH-GWN handshake on Access radio
            if msg.type == WSN_Config.MSG_TYPE_CH_CMD
                if ~msg.verifyChecksum()
                    return;
                end
                % Log to Access log (CH communication)
                gw.addLogAccess(sprintf('t=%d [RX] CH_CMD.%d <- %s', ...
                    t, msg.subtype, gw.fmtID(msg.src)), msg, t);
                actions = obj.handleCHCMD(msg, t, rssi);
                return;
            end
            
            % Handle CH_HELLO (Type 5) - Forward to parent like ENC_HELLO
            if msg.type == WSN_Config.MSG_TYPE_CH_HELLO
                if ~msg.verifyChecksum()
                    return;
                end
                % Log to Backbone log (routing message)
                gw.addLogBackbone(sprintf('t=%d [RX] CH_HELLO <- %s', ...
                    t, gw.fmtID(msg.src)), msg, t);
                actions = obj.handle_CH_HELLO(msg, t);
                return;
            end
            
            % TOKEN (Type 8) - DEPRECATED: Phase scheduling replaces token-based flow control
            % GWNs ignore all TOKEN messages; Sink also ignores them now
            if msg.type == WSN_Config.MSG_TYPE_TOKEN
                gw.addLogBackbone(sprintf('t=%d [IGNORED] TOKEN.%d <- %s (phase scheduling active)', ...
                    t, msg.subtype, gw.fmtID(msg.src)), msg, t);
                return;
            end

            % ML-IDS CENSUS (Type 11) - daisy-chain trust polling (ML_IDS_PLAN.md Phase 4)
            if msg.type == WSN_Config.MSG_TYPE_CENSUS
                if ~msg.verifyChecksum(), return; end
                resp = gw.handleCensusMessage(msg, t);
                if ~isempty(resp)
                    actions{end+1} = struct('type', 'RESP', 'msg', resp);
                end
                return;
            end

            % ML-IDS SHUTDOWN (Type 12) - reset/blacklist enforcement (ML_IDS_PLAN.md Phase 4)
            if msg.type == WSN_Config.MSG_TYPE_SHUTDOWN
                if ~msg.verifyChecksum() || msg.dst ~= hex2dec(gw.hexID), return; end
                gw.handleShutdownMessage(msg, t);
                return;
            end

            % Log RX for CMD messages only
            tag = msg.getTypeStr();
            if msg.type == 7
                tag = sprintf('%s.%d', msg.getTypeStr(), msg.subtype);
            end
            % Use Backbone log for CMD (GWN-GWN communication over LoRa)
            gw.addLogBackbone(sprintf('t=%d [RX] %s <- %s RSSI=%.1f', ...
                t, tag, gw.fmtID(msg.src), rssi), msg, t);

            % Verify checksum
            if ~msg.verifyChecksum()
                gw.addLogBackbone(sprintf('t=%d [CHK_DROP] %s', ...
                t, dec2hex(uint16(msg.src),4)), [], t);
                return;
            end
            
            % CMD frames must be unicast to self
            if msg.type ~= 7 || msg.dst ~= hex2dec(gw.hexID)
                return;
            end
            
            % Lock handling based on subtype:
            % 7.0 (PARENT_INIT): CREATES lock (handled in handler)
            % 7.1, 7.2, 7.4: REFRESH lock
            % 7.3, 7.5: CLEAR lock (handled in handlers)
            if ~isempty(gw.handshakePartner) && msg.src == gw.handshakePartner && ...
                    (msg.subtype == 1 || msg.subtype == 2 || msg.subtype == 4)
                gw.radio.refreshLock(WSN_Config.HandshakeTimeout);
            end
            
            % Route to CMD handler by subtype
            switch msg.subtype
                case 0, actions = obj.handle_PARENT_INIT(msg, t);
                case 1, actions = obj.handle_REQ_JOIN(msg, t);
                case 2, actions = obj.handle_ACK_JOIN(msg, t);
                case 3, actions = obj.handle_PARENT_REJECT(msg, t);
                case 4, actions = obj.handle_GLOBAL_KEY(msg, t);
                case 5, actions = obj.handle_ENC_HELLO(msg, t);
                case 6, actions = obj.handle_DOWN(msg, t);
                case 7, actions = obj.handle_UP(msg, t);
            end
        end
        
        function handleHello(obj, msg, t, rssi)
            % Phase 2: Hello message (Type 0) handling
            % Updates neighbor table with topology info without recruitment
            gw = obj.gw;
            sender = msg.src;
            
            % Extract payload: tier, battery, neighborCount
            if msg.payloadLen >= 2
                [tier, battery, neighborCount] = msg.getHelloPayload();
            else
                tier = 0; battery = 0; neighborCount = 0;
            end
            
            % Extract verified status from message flag
            senderVerified = msg.isVerified();
            
            % Track previous count for change detection
            prevCount = numel(gw.neighborTable);
            
            % Ensure isVerified field exists in neighbor table
            if ~isempty(gw.neighborTable) && ~isfield(gw.neighborTable, 'isVerified')
                [gw.neighborTable.isVerified] = deal(false);
            end
            
            % Find or create neighbor entry
            idx = find([gw.neighborTable.id]==sender, 1);
            trust = [10 30 60 100];
            
            if isempty(idx)
                % New neighbor from Hello
                gw.neighborTable(end+1) = struct( ...
                    'id', sender, 'lastSeen', t, 'rssi', rssi, ...
                    'TrustScore', trust(min(end, min(3, tier)+1)), ...
                    'commRange', 0, 'status', gw.ST_NONE, ...
                    'tier', tier, 'battery', battery, 'neighborCount', neighborCount, ...
                    'isVerified', senderVerified);
            else
                % Update existing neighbor
                gw.neighborTable(idx).lastSeen = t;
                gw.neighborTable(idx).rssi = rssi;
                gw.neighborTable(idx).tier = tier;
                gw.neighborTable(idx).battery = battery;
                gw.neighborTable(idx).neighborCount = neighborCount;
                gw.neighborTable(idx).isVerified = senderVerified;
            end
            
            % Log only if neighbor count changed (to both logs - common node event)
            newCount = numel(gw.neighborTable);
            if newCount ~= prevCount
                gw.addLogBoth(sprintf('t=%d [PHY] Neighbour count: %d->%d', t, prevCount, newCount), [], t);
            end
        end
        
        function handleHeartbeat(obj, msg, t, rssi)
            gw = obj.gw;
            sender = msg.src;
            idx = find([gw.neighborTable.id]==sender, 1);
            trust = [10 30 60 100];
            
            % ENC_HB (subtype 3) implies verified sender
            senderVerified = (msg.subtype == 3);
            
            % Ensure isVerified field exists in neighbor table
            if ~isempty(gw.neighborTable) && ~isfield(gw.neighborTable, 'isVerified')
                [gw.neighborTable.isVerified] = deal(false);
            end
            
            if isempty(idx)
                gw.neighborTable(end+1) = struct( ...
                    'id', sender, 'lastSeen', t, 'rssi', rssi, ...
                    'TrustScore', trust(min(end, msg.subtype+1)), ...
                    'commRange', 0, 'status', gw.ST_NONE, ...
                    'tier', 3, 'battery', 0, 'neighborCount', 0, ...
                    'isVerified', senderVerified);
            else
                gw.neighborTable(idx).lastSeen = t;
                gw.neighborTable(idx).rssi = rssi;
                % Update verified status (ENC_HB confirms verification)
                if senderVerified
                    gw.neighborTable(idx).isVerified = true;
                end
            end
            % No logging for ENC_HB - just update neighbor table silently
        end
        
        function actions = handle_PARENT_INIT(obj, msg, t)
            actions = {};
            gw = obj.gw;
            sender = msg.src;
            
            % Only accept VERIFIED init
            if bitget(msg.flag, 2) == 0
                return;
            end
            
            % Sink: always reject
            if isa(gw, 'WSN_Sink')
                actions = obj.rejectParentInit(sender, t);
                return;
            end
            
            % ORPHAN GUARD: If PARENT_INIT from our current parent, we're orphaned
            % Parent forgot about us (dropped ENC_HELLO), clear state and accept re-recruitment
            if ~isempty(gw.parent) && sender == gw.parent
                gw.addLog(sprintf('t=%d [ORPHAN_DETECT] PARENT_INIT from parent %s - clearing state', ...
                    t, dec2hex(uint16(sender), 4)));
                gw.parent = [];
                gw.hasKey = false;
                gw.isVerified = false;
                gw.encryptionKey = '';
                % Fall through to accept the PARENT_INIT
            end
            
            % Already has parent or mid-handshake: reject
            if ~isempty(gw.parent) || ...
                    (~isempty(gw.handshakePartner) && gw.handshakePartner ~= sender)
                actions = obj.rejectParentInit(sender, t);
                return;
            end
            
            % Mutual init deadlock: reject and reset
            if ~isempty(gw.handshakePartner) && gw.handshakePartner == sender
                r = WSN_Message(7, hex2dec(gw.hexID), sender, []);
                r.subtype = 3;
                r.addChecksum();
                actions{end+1} = struct('type','RESP','msg',r);
                gw.logTxBackbone(r,t);
                actions{end+1} = struct('effect','REJECT_NEIGHBOR','value',sender);
                actions{end+1} = struct('effect','RESET_PROSPECTS');
                actions{end+1} = struct('effect','CLEAR_HANDSHAKE');
                actions{end+1} = struct('effect','STATE','value',WSN_Config.STATE_SECURE);
                return;
            end
            
            % Accept: enter handshake (sender wants to be our parent)
            actions{end+1} = struct('effect','STATE','value',WSN_Config.STATE_HANDSHAKE);
            actions{end+1} = struct('effect','SET_HANDSHAKE','value',sender);
            % DO NOT set parent here - wait for ACK_JOIN
            r = WSN_Message(7, hex2dec(gw.hexID), sender, []);
            r.subtype = 1;  % REQ_JOIN
            r.addChecksum();
            actions{end+1} = struct('type','RESP','msg',r);
            % Note: SET_HANDSHAKE effect creates lock, TX of REQ_JOIN refreshes it
            gw.logTxBackbone(r,t);
            gw.logTxBackbone(r,t);
        end
        
        function actions = rejectParentInit(obj, sender, t)
            actions = {};
            gw = obj.gw;
            
            r = WSN_Message(7, hex2dec(gw.hexID), sender, []);
            r.subtype = 3;  % PARENT_REJECT
            r.addChecksum();
            
            actions{end+1} = struct('type','RESP','msg',r);
            gw.logTxBackbone(r,t);
            actions{end+1} = struct('effect','CLEAR_HANDSHAKE');
            
            % Clear lock immediately on TX of PARENT_REJECT
            gw.radio.clearLock('REJECT');
            
            gw.addLog(sprintf('t=%d [REJ_PARENT] → %s', t, dec2hex(uint16(sender),4)));
        end
        
        function actions = handle_REQ_JOIN(obj, msg, t)
            actions = {};
            gw = obj.gw;
            sender = msg.src;
            idx = find([gw.neighborTable.id]==sender, 1);
            
            % Reset timer and respond
            actions{end+1} = struct('effect','RESET_TIMER');
            r = WSN_Message(7, hex2dec(gw.hexID), sender, []);
            r.subtype = 2;  % ACK_JOIN
            r.addChecksum();
            actions{end+1} = struct('type','RESP','msg',r);
            gw.logTxBackbone(r,t);
            % TX of 7.2 ACK_JOIN refreshes lock
            gw.radio.refreshLock(WSN_Config.HandshakeTimeout);
            
            % SECURE HANDSHAKE: Add to pendingChildren (not children yet)
            % Will be promoted to children only when ENC_HELLO is received
            if isempty(gw.pendingChildren) || ~any([gw.pendingChildren.id] == sender)
                gw.pendingChildren(end+1) = struct('id', sender, 'addedAt', t);
                gw.addLogBackbone(sprintf('t=%d [HANDSHAKE] %s added to pendingChildren (awaiting ENC_HELLO)', ...
                    t, gw.fmtID(sender)), r, t);
            end
            
            if ~isempty(idx)
                gw.neighborTable(idx).status = gw.ST_CHILD;
            end
            
            % Send global key with phase offset inheritance
            % Child gets opposite phase offset: NOT(parent.phaseOffset)
            childPhaseOffset = bitxor(gw.phaseOffset, 1);  % 0->1, 1->0
            gk = WSN_Message(7, hex2dec(gw.hexID), sender, []);
            gk.subtype = 4;  % GLOBAL_KEY
            gk.flag = bitset(uint8(0),1,1);
            gk.setGlobalKeyPayload(childPhaseOffset);
            actions{end+1} = struct('type','RESP','msg',gk);
            gw.logTxBackbone(gk,t);
            gw.addLogBackbone(sprintf('t=%d [PHASE] Sending phaseOffset=%d to child %s (self=%d)', ...
                t, childPhaseOffset, gw.fmtID(sender), gw.phaseOffset), [], t);
            % TX of 7.4 GLOBAL_KEY refreshes lock
            gw.radio.refreshLock(WSN_Config.HandshakeTimeout);
        end
        
        function actions = handle_ACK_JOIN(obj, msg, t)
            actions = {};
            gw = obj.gw;
            sender = msg.src;
            
            actions{end+1} = struct('effect','RESET_TIMER');
            if isempty(gw.parent)
                actions{end+1} = struct('effect','SET_PARENT','value',sender);
            end
        end
        
        function actions = handle_PARENT_REJECT(obj, msg, t)
            actions = {};
            gw = obj.gw;
            sender = msg.src;
            
            % ORPHAN GUARD: If sender was our parent, we're being disowned
            % This handles the case where parent timed out waiting for ENC_HELLO
            if ~isempty(gw.parent) && gw.parent == sender
                gw.addLog(sprintf('t=%d [ORPHAN_CLEARED] Parent %s disowned us', t, dec2hex(uint16(sender),4)));
                gw.parent = [];
                gw.isVerified = false;
                gw.hasKey = false;
                gw.encryptionKey = '';
                % Return to DISCOVERY since we lost our parent
                actions{end+1} = struct('effect','STATE','value',WSN_Config.STATE_DISCOVERY);
                actions{end+1} = struct('effect','CLEAR_HANDSHAKE');
                gw.radio.clearLock('ORPHAN');
                return;
            end
            
            % PURGE: If sender was a child, remove them
            if isprop(gw, 'children') && ~isempty(gw.children)
                gw.children(gw.children == sender) = [];
            end
            
            % Mark sender as rejected so we don't try them again
            actions{end+1} = struct('effect','REJECT_NEIGHBOR','value',sender);
            
            % If this sender was our current retry target, stop retrying them
            if gw.behavior.retryTarget == sender
                gw.behavior.retryTarget = [];
                gw.behavior.retryCount = 0;
            end
            
            % Clear handshake state to try next neighbor
            actions{end+1} = struct('effect','CLEAR_HANDSHAKE');
            
            % Clear lock immediately on RX of PARENT_REJECT
            gw.radio.clearLock('REJECT');
            
            % Return to SECURE so FSM can pick next neighbor on next step
            actions{end+1} = struct('effect','STATE','value',WSN_Config.STATE_SECURE);
            
            gw.addLog(sprintf('t=%d [RX] PARENT_REJECT from %s, trying next', t, dec2hex(uint16(sender),4)));
        end
        
        function actions = handle_GLOBAL_KEY(obj, msg, t)
            actions = {};
            gw = obj.gw;
            sender = msg.src;
            
            % GUARD: Drop if ACK_JOIN was never received (parent not set)
            % Otherwise node broadcasts ENC_HELLO to dst=0 which is invalid
            if isempty(gw.parent)
                gw.addLog(sprintf('t=%d [DROP] GLOBAL_KEY from %s - no ACK_JOIN received', t, dec2hex(uint16(sender),4)));
                return;
            end
            
            % Extract key and phase offset from GLOBAL_KEY message
            [keyHex, childPhaseOffset] = msg.getGlobalKeyPayload();
            gw.encryptionKey = keyHex;
            gw.localKeyHex = gw.deriveLocalKey();
            gw.hasKey = true;
            gw.isVerified = true;
            
            % PHASE INHERITANCE: Set phase offset from parent's GLOBAL_KEY
            gw.phaseOffset = childPhaseOffset;
            gw.phaseInherited = true;
            gw.addLogBackbone(sprintf('t=%d [PHASE] Inherited phaseOffset=%d from parent %s', ...
                t, childPhaseOffset, gw.fmtID(sender)), [], t);
            
            % Subscribe to verified GWN multicast group (FF00) for ENC_HB
            if ~ismember(hex2dec('FF00'), gw.multicastGroups)
                gw.multicastGroups(end+1) = hex2dec('FF00');
            end
            
            % Non-sink: send first ENC_HELLO and schedule retries
            if ~isa(gw, 'WSN_Sink')
                encHello = obj.createEncHello(t);
                if ~isempty(encHello)
                    actions{end+1} = struct('type','RESP','msg',encHello);
                    gw.logTxBackbone(encHello, t);
                    % TX of 7.5 ENC_HELLO clears lock
                    gw.radio.clearLock('ENC_HELLO_TX');
                end
                actions{end+1} = struct('effect','CLEAR_HANDSHAKE');
                
                % Schedule first ENC_HELLO retry (exponential backoff: t+10, t+30, t+70)
                gw.encHelloRetryCount = 0;
                gw.encHelloNextRetryTime = t + gw.ENC_HELLO_BASE_INTERVAL;  % First retry at t+10
                
                % Wait 2 TFs before starting recruitment (let ENC_HELLO propagate)
                gw.behavior.retryBackoff = 2;
            end
            
            actions{end+1} = struct('effect','RESET_PROSPECTS');
            actions{end+1} = struct('effect','RESET_TIMER');
        end
        
        function msg = createEncHello(obj, t)
            % Create comprehensive ENC_HELLO with all children info
            % Payload is encrypted with global key (contains local key!)
            gw = obj.gw;
            msg = [];
            
            if isempty(gw.parent) || ~gw.hasKey
                return;
            end
            
            % Gather children info
            gwChildren = gw.children;           % First-degree GWN children
            chChildren = gw.chChildren;         % First-degree CH children
            
            % Count sensors (from sensorTable)
            snCount = numel(gw.sensorTable);
            
            msg = WSN_Message(7, hex2dec(gw.hexID), gw.parent, []);
            msg.subtype = 5;  % ENC_HELLO
            msg.setEncHelloPayload(hex2dec(gw.hexID), gw.parent, gw.localKeyHex, ...
                numel(chChildren), snCount, gwChildren, chChildren, []);
            
            % ENCRYPT payload with global key (payload contains sensitive local key!)
            msg.payload = WSN_Crypto.encrypt(msg.payload, gw.encryptionKey);
            msg.payloadLen = numel(msg.payload);
            msg.setEncrypted(true);
            msg.addChecksum();
            
            gw.addLogBackbone(sprintf('t=%d [ENC_HELLO] TX: gwCh=%d, chCh=%d, sn=%d (encrypted)', ...
                t, numel(gwChildren), numel(chChildren), snCount), msg, t);
        end
        
        function actions = handle_ENC_HELLO(obj, msg, t)
            actions = {};
            gw = obj.gw;
            sender = msg.src;
            
            if isempty(gw.parent) || isa(gw, 'WSN_Sink')
                return;
            end
            
            % SECURE HANDSHAKE: Only accept ENC_HELLO from pendingChildren
            % This prevents malicious nodes from adding themselves via spoofed ENC_HELLO
            isPending = ~isempty(gw.pendingChildren) && any([gw.pendingChildren.id] == sender);
            
            if isPending
                % Promote from pendingChildren to children (handshake complete)
                gw.pendingChildren([gw.pendingChildren.id] == sender) = [];
                if ~ismember(sender, gw.children)
                    gw.children(end+1) = sender;
                    gw.addLogBackbone(sprintf('t=%d [HANDSHAKE] %s promoted to children (ENC_HELLO received)', ...
                        t, gw.fmtID(sender)), msg, t);
                end
            elseif ~ismember(sender, gw.children)
                % Not pending and not already a child - DROP (security violation)
                gw.addLogBackbone(sprintf('t=%d [SECURITY] DROP ENC_HELLO from %s - not in pendingChildren', ...
                    t, gw.fmtID(sender)), msg, t);
                return;
            end
            % If already in children (relay case), just forward
            
            % Terminal event: clear lock, move to secure
            % RX of 7.5 ENC_HELLO clears lock
            gw.radio.clearLock('ENC_HELLO_RX');
            actions{end+1} = struct('effect','CLEAR_HANDSHAKE');
            actions{end+1} = struct('effect','STATE','value',WSN_Config.STATE_SECURE);
            
            % Forward to parent (re-encrypt with our src)
            fwd = WSN_Message(7, hex2dec(gw.hexID), gw.parent, []);
            fwd.subtype = 5;
            fwd.flag = msg.flag;
            fwd.payload = msg.payload;
            fwd.payloadLen = msg.payloadLen;
            fwd.setEncrypted(msg.isEncrypted());
            fwd.addChecksum();
            actions{end+1} = struct('type','RESP','msg',fwd);
            gw.logTxBackbone(fwd,t);
        end
        
        function actions = handle_CH_HELLO(obj, msg, t)
            % CH_HELLO (Type 5): Handle based on subtype
            % 5.0/5.1 = CH_HELLO routing, 5.2 = SENSOR_AGG, 5.3 = CH_ACK
            actions = {};
            gw = obj.gw;
            
            % Route based on subtype
            if msg.subtype == WSN_Config.SENSOR_SUB_AGG  % 5.2 SENSOR_AGG
                actions = obj.handle_SENSOR_AGG(msg, t);
                return;
            elseif msg.subtype == WSN_Config.SENSOR_SUB_ACK  % 5.3 CH_ACK
                % ACK is terminal at GWN - just log
                gw.addLogAccess(sprintf('t=%d [5.3_RX] ACK from %s', t, gw.fmtID(msg.src)), msg, t);
                return;
            end
            
            % Original CH_HELLO (5.0/5.1) forwarding logic
            % Sink handles differently (terminates)
            if isa(gw, 'WSN_Sink')
                return;  % Sink will handle via override
            end
            
            % Need parent to forward. Buffer instead of dropping -- this
            % GWN may not have found its own backbone parent yet, but the
            % CH this describes is still real; flushPendingChHelloForward()
            % (called every tick from WSN_Gateway.step()) sends it once a
            % parent is available, instead of permanently losing it.
            if isempty(gw.parent)
                if numel(gw.pendingChHelloForward) >= gw.PENDING_CH_HELLO_MAX
                    gw.pendingChHelloForward(1) = [];  % drop oldest, keep buffer bounded
                end
                gw.pendingChHelloForward{end+1} = msg;
                gw.addLogBackbone(sprintf('t=%d [BUFFER] CH_HELLO - no parent yet (queued=%d)', ...
                    t, numel(gw.pendingChHelloForward)), [], t);
                return;
            end

            fwd = obj.buildChHelloForward(msg, t);
            obj.enqueueLocal(fwd, t);
        end

        function fwd = buildChHelloForward(obj, msg, t)
            % Build a forwarded CH_HELLO (5.0/5.1) addressed to our current parent
            gw = obj.gw;
            fwd = WSN_Message();
            fwd.type = WSN_Config.MSG_TYPE_CH_HELLO;
            fwd.subtype = msg.subtype;
            fwd.src = hex2dec(gw.hexID);   % Update SRC to this GWN
            fwd.dst = gw.parent;            % DST is our parent
            fwd.ttl = msg.ttl;
            fwd.seq = msg.seq;
            fwd.flag = msg.flag;
            fwd.payload = msg.payload;      % Preserve payload (CH ID, Parent GWN ID)
            fwd.payloadLen = msg.payloadLen;
            fwd.addChecksum();
        end

        function flushPendingChHelloForward(obj, t)
            % Called every tick from WSN_Gateway.step(). Sends any CH_HELLO
            % messages that were buffered while this GWN had no backbone
            % parent, now that one is available.
            gw = obj.gw;
            if isempty(gw.pendingChHelloForward) || isempty(gw.parent)
                return;
            end
            for i = 1:numel(gw.pendingChHelloForward)
                fwd = obj.buildChHelloForward(gw.pendingChHelloForward{i}, t);
                obj.enqueueLocal(fwd, t);
            end
            gw.addLogBackbone(sprintf('t=%d [FLUSH] Sent %d buffered CH_HELLO to parent %s', ...
                t, numel(gw.pendingChHelloForward), gw.fmtID(gw.parent)), [], t);
            gw.pendingChHelloForward = {};
        end
        
        function actions = handle_SENSOR_AGG(obj, msg, t)
            % 5.2 SENSOR_AGG from CH (access radio)
            % NOTE: Encrypted 5.2 from children are handled by UNIVERSAL RELAY above
            % This handler only processes unencrypted 5.2 from CHs
            actions = {};
            gw = obj.gw;
            sender = msg.src;
            
            % Parse and store sensor data locally
            obj.mergeSensorAgg(msg, t);

            % ML-IDS: record this CH's report arrival (silence detector,
            % ML_IDS_PLAN.md Phase 4 follow-up) and clear any prior flag
            idx = find([gw.chLastAggSeen.id] == sender, 1);
            if isempty(idx)
                gw.chLastAggSeen(end+1) = struct('id', sender, 'lastTime', t);
            else
                gw.chLastAggSeen(idx).lastTime = t;
            end
            gw.chAggSilenceFlagged = setdiff(gw.chAggSilenceFlagged, sender);

            % Sink handles 5.2 via override - no forwarding needed
            if isa(gw, 'WSN_Sink')
                return;
            end
            
            % Send ACK to CH (access radio)
            ackMsg = obj.createAggACK(sender, msg.seq, t);
            actions{end+1} = struct('type','RESP','msg',ackMsg);
            gw.addLogAccess(sprintf('t=%d [5.3_TX] ACK -> %s', t, gw.fmtID(sender)), ackMsg, t);
            
            % Forward 5.2 to parent (queue for phase-scheduled TX)
            if ~isempty(gw.parent) && gw.hasKey
                fwd = obj.createSensorAggForBackbone(msg, t);
                if ~isempty(fwd)
                    obj.enqueueLocal(fwd, t);
                end
            end
        end
        
        function actions = handlePanicMessage(obj, msg, t, ~)
            % Handle incoming PANIC message (Type 2)
            % GWN forwards PANIC to parent with decremented TTL
            actions = {};
            gw = obj.gw;
            sender = msg.src;
            if ismember(msg.uid, gw.seenPanicUIDs)
                return;  % Already processed
            end
            gw.seenPanicUIDs = [gw.seenPanicUIDs, msg.uid];
            
            % Prune old UIDs (keep last 100)
            if numel(gw.seenPanicUIDs) > 100
                gw.seenPanicUIDs = gw.seenPanicUIDs(end-99:end);
            end
            
            % Check TTL
            if msg.ttl <= 0
                gw.addLog(sprintf('t=%d [PANIC_DROP] TTL expired from %s', ...
                    t, gw.fmtID(sender)));
                return;
            end
            
            % Extract panic info from payload
            originalSrc = sender;
            sensorValue = 0;
            if msg.payloadLen >= 4
                originalSrc = typecast(msg.payload(1:2), 'uint16');
                sensorValue = typecast(msg.payload(3:4), 'uint16');
            end
            
            gw.addLog(sprintf('t=%d [PANIC_FWD] orig=%s val=%d -> parent TTL=%d', ...
                t, gw.fmtID(originalSrc), sensorValue, msg.ttl - 1));
            
            % Forward to parent with decremented TTL
            if ~isempty(gw.parent) && ~isa(gw, 'WSN_Sink')
                fwdMsg = WSN_Message();
                fwdMsg.type = WSN_Config.MSG_TYPE_PANIC;
                fwdMsg.subtype = msg.subtype;
                fwdMsg.src = hex2dec(gw.hexID);
                fwdMsg.dst = gw.parent;
                fwdMsg.ttl = msg.ttl - 1;
                fwdMsg.prio = msg.prio;
                fwdMsg.seq = msg.seq;
                fwdMsg.uid = msg.uid;
                fwdMsg.payload = msg.payload;
                fwdMsg.payloadLen = msg.payloadLen;
                fwdMsg.addChecksum();
                actions{end+1} = struct('type', 'RESP', 'msg', fwdMsg);
            elseif isa(gw, 'WSN_Sink')
                % Sink receives the PANIC - log it as received
                gw.addLog(sprintf('t=%d [PANIC_RECEIVED] *** EMERGENCY *** orig=%s sev=%d', ...
                    t, gw.fmtID(originalSrc), msg.prio));
            end
        end
        
        function handleSensorData(obj, msg, t, rssi)
            % Type 1: Direct sensor data from SN to GWN
            % Store locally - aggregation happens periodically (like CH)
            gw = obj.gw;
            sender = msg.src;
            
            % Parse payload: [SensorValue(2), Battery(1)]
            if msg.payloadLen < 3
                return;
            end
            sensorValue = double(typecast(msg.payload(1:2), 'uint16'));
            sensorBattery = double(msg.payload(3));
            
            % Update or add to sensor table (overwrite if exists)
            idx = find([gw.sensorTable.id] == sender, 1);
            if isempty(idx)
                gw.sensorTable(end+1) = struct( ...
                    'id', sender, ...
                    'lastTime', t, ...
                    'value', sensorValue, ...
                    'rssi', rssi, ...
                    'battery', sensorBattery);
                gw.addLogAccess(sprintf('t=%d [SENSOR_RX] NEW %s val=%d bat=%d%% (table=%d sensors)', ...
                    t, gw.fmtID(sender), sensorValue, sensorBattery, numel(gw.sensorTable)), msg, t);
            else
                gw.sensorTable(idx).lastTime = t;
                gw.sensorTable(idx).value = sensorValue;
                gw.sensorTable(idx).rssi = rssi;
                gw.sensorTable(idx).battery = sensorBattery;
                gw.addLogAccess(sprintf('t=%d [SENSOR_RX] UPDATE %s val=%d bat=%d%%', ...
                    t, gw.fmtID(sender), sensorValue, sensorBattery), msg, t);
            end
            % NOTE: Aggregation into 5.2 happens periodically via processSensorAggregation()
        end
        
        function mergeSensorAgg(obj, msg, t)
            % Merge received 5.2 sensor data into GWN's sensor table
            gw = obj.gw;
            
            if msg.payloadLen < 1
                return;
            end
            
            numSensors = msg.payload(1);
            offset = 2;  % Start after count byte
            
            for i = 1:numSensors
                if offset + 7 > msg.payloadLen + 1
                    break;  % Incomplete entry
                end
                
                sensorID = typecast(msg.payload(offset:offset+1), 'uint16');
                sensorTime = typecast(msg.payload(offset+2:offset+3), 'uint16');
                sensorValue = typecast(msg.payload(offset+4:offset+5), 'uint16');
                sensorRSSI = double(msg.payload(offset+6)) / 10;
                sensorBattery = double(msg.payload(offset+7));
                offset = offset + 8;
                
                % Update or add to sensor table
                idx = find([gw.sensorTable.id] == sensorID, 1);
                if isempty(idx)
                    gw.sensorTable(end+1) = struct( ...
                        'id', double(sensorID), ...
                        'lastTime', double(sensorTime), ...
                        'value', double(sensorValue), ...
                        'rssi', sensorRSSI, ...
                        'battery', sensorBattery);
                else
                    % Overwrite if newer
                    if sensorTime > gw.sensorTable(idx).lastTime
                        gw.sensorTable(idx).lastTime = double(sensorTime);
                        gw.sensorTable(idx).value = double(sensorValue);
                        gw.sensorTable(idx).rssi = sensorRSSI;
                        gw.sensorTable(idx).battery = sensorBattery;
                    end
                end
            end
        end
        
        function msg = createAggACK(obj, dst, seq, ~)
            % Create 5.3 CH_ACK message with local encryption
            gw = obj.gw;
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_HELLO;
            msg.subtype = WSN_Config.SENSOR_SUB_ACK;  % 5.3
            msg.src = hex2dec(gw.hexID);
            msg.dst = dst;
            msg.ttl = 1;
            msg.seq = seq;  % Echo back the sequence number
            
            % LOCAL ENCRYPTION: GWN encrypts 5.3 ACK with local key
            localKey = gw.deriveLocalKey();
            payload = uint8([]);  % Empty ACK payload
            if ~isempty(localKey)
                % Even empty payload, set encrypted flag for consistency
                msg.setEncrypted(true);
            end
            msg.payload = payload;
            msg.payloadLen = numel(payload);
            msg.addChecksum();
            msg.color = [1.0 0.7 0.2];  % Amber for 5.3 AGG_ACK
        end
        
        function msg = createRelayForward(obj, srcMsg, ~)
            % Create forwarded message for backbone relay (encrypted from child → parent)
            % Universal relay: preserves type, subtype, payload; updates src/dst
            gw = obj.gw;
            msg = [];
            
            if isempty(gw.parent) || ~gw.hasKey
                return;
            end
            
            msg = WSN_Message();
            msg.type = srcMsg.type;
            msg.subtype = srcMsg.subtype;
            msg.src = hex2dec(gw.hexID);  % Update src to this GWN
            msg.dst = gw.parent;           % Forward to parent
            msg.ttl = srcMsg.ttl;
            msg.seq = srcMsg.seq;
            msg.flag = srcMsg.flag;        % Preserve encrypted flag
            msg.payload = srcMsg.payload;  % Preserve encrypted payload
            msg.payloadLen = srcMsg.payloadLen;
            msg.addChecksum();
            msg.color = srcMsg.color;      % Preserve color for visualization
        end
        
        function msg = createSensorAggForBackbone(obj, srcMsg, t)
            % Create encrypted 5.2 for backbone transmission
            gw = obj.gw;
            msg = [];
            
            if isempty(gw.parent) || ~gw.hasKey
                return;
            end
            
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_HELLO;
            msg.subtype = WSN_Config.SENSOR_SUB_AGG;  % 5.2
            msg.src = hex2dec(gw.hexID);
            msg.dst = gw.parent;
            msg.ttl = srcMsg.ttl;
            msg.seq = srcMsg.seq;
            
            % Encrypt payload with global key for backbone
            msg.payload = WSN_Crypto.encrypt(srcMsg.payload, gw.encryptionKey);
            msg.payloadLen = numel(msg.payload);
            msg.setEncrypted(true);
            msg.addChecksum();
            msg.color = [0.6 0.2 0.8];  % Violet for 5.2 SENSOR_AGG
        end
        
        function msgs = processSensorAggregation(obj, t)
            % Process periodic 5.2 aggregation (like CH)
            % Creates aggregated 5.2 message from sensorTable, enqueues for phase-based TX
            msgs = {};
            gw = obj.gw;
            
            % Must have parent and be verified
            if isempty(gw.parent) || ~gw.isVerified || ~gw.hasKey
                return;
            end
            
            % Initialize aggregation period on first call
            if gw.aggPeriod == 0
                gw.aggPeriod = randi([WSN_Config.AGG_PERIOD_MIN, WSN_Config.AGG_PERIOD_MAX]);
                gw.nextAggTX = t + gw.aggPeriod;
                gw.addLogBackbone(sprintf('t=%d [AGG] Initialized: period=%d, first TX at t=%d', ...
                    t, gw.aggPeriod, gw.nextAggTX), [], t);
            end
            
            % Check if it's time to aggregate
            if t < gw.nextAggTX || isempty(gw.sensorTable)
                return;
            end
            
            % --- CREATE AGGREGATED 5.2 MESSAGE ---
            gw.addLogBackbone(sprintf('t=%d [AGG] Creating 5.2 with %d sensors', ...
                t, numel(gw.sensorTable)), [], t);
            
            % GROUP SENSORS BY RSSI LEVELS
            % RSSI levels: >-50 (excellent), -50 to -70 (good), -70 to -85 (fair), <-85 (poor)
            rssiLevels = [-50, -70, -85];  % Thresholds
            numLevels = numel(rssiLevels) + 1;  % 4 groups
            
            % Assign each sensor to an RSSI group
            rssiValues = [gw.sensorTable.rssi];
            groupAssign = ones(1, numel(rssiValues)) * numLevels;  % Default to worst group
            for lvl = 1:numel(rssiLevels)
                groupAssign(rssiValues > rssiLevels(lvl)) = lvl;
            end
            
            % Sort sensors within each group by RSSI (best first)
            [~, sortIdx] = sortrows([groupAssign(:), -rssiValues(:)]);
            sortedSensors = gw.sensorTable(sortIdx);
            sortedGroups = groupAssign(sortIdx);
            
            % Fragment calculation
            numSensors = min(numel(sortedSensors), WSN_Config.MAX_SENSORS_PER_FRAGMENT);
            totalFragments = ceil(numel(sortedSensors) / WSN_Config.MAX_SENSORS_PER_FRAGMENT);
            if totalFragments == 0
                totalFragments = 1;
            end
            fragIdx = 1;  % Single fragment for now (GWN sends one at a time)
            
            % Build payload with Fragment ID header + RSSI grouping:
            % [TotalFragments(1), FragmentIndex(1), NumGroups(1), 
            %  {GroupID(1), NumInGroup(1), {SensorData} x N} x G]
            payload = [uint8(totalFragments), uint8(fragIdx)];
            
            % Count sensors per group for this fragment
            sensorsThisFrag = sortedSensors(1:numSensors);
            groupsThisFrag = sortedGroups(1:numSensors);
            uniqueGroups = unique(groupsThisFrag);
            payload = [payload, uint8(numel(uniqueGroups))];  % NumGroups
            
            for g = uniqueGroups
                groupMask = (groupsThisFrag == g);
                groupSensors = sensorsThisFrag(groupMask);
                payload = [payload, uint8(g), uint8(numel(groupSensors))]; %
                
                for i = 1:numel(groupSensors)
                    s = groupSensors(i);
                    sensorEntry = [ ...
                        typecast(uint16(s.id), 'uint8'), ...        % 2 bytes
                        typecast(uint16(s.lastTime), 'uint8'), ...  % 2 bytes
                        typecast(uint16(s.value), 'uint8'), ...     % 2 bytes
                        uint8(round(abs(s.rssi))), ...              % 1 byte (absolute RSSI)
                        uint8(s.battery)];                          % 1 byte
                    payload = [payload, sensorEntry]; %
                end
            end
            
            % Apply layered encryption: globally encrypted original sender + double encrypted payload
            aggMsg = WSN_Message();
            aggMsg.type = WSN_Config.MSG_TYPE_CH_HELLO;
            aggMsg.subtype = WSN_Config.SENSOR_SUB_AGG;  % 5.2
            aggMsg.src = hex2dec(gw.hexID);        % Immediate sender (unencrypted)
            aggMsg.dst = gw.parent;                % Immediate receiver (unencrypted)
            aggMsg.originalSrc = hex2dec(gw.hexID); % Original sender (will be globally encrypted)
            aggMsg.ttl = 10;
            aggMsg.seq = mod(t, 256);
            
            % CRITICAL: Assign payload BEFORE encryption
            aggMsg.payload = payload;
            aggMsg.payloadLen = uint8(numel(payload));
            
            % Apply layered encryption
            localKey = gw.deriveLocalKey();
            aggMsg.applyLayeredEncryption(hex2dec(gw.hexID), gw.encryptionKey, localKey);
            
            aggMsg.addChecksum();
            aggMsg.color = [0.6 0.2 0.8];  % Violet for 5.2 SENSOR_AGG
            
            % Queue for phase-scheduled transmission (local data)
            obj.enqueueLocal(aggMsg, t);
            gw.addLogBackbone(sprintf('t=%d [AGG] 5.2 queued: frag %d/%d, %d sensors, %d bytes (double-encrypted)', ...
                t, fragIdx, totalFragments, numSensors, numel(payload)), [], t);
            
            % Schedule next aggregation
            gw.nextAggTX = t + gw.aggPeriod;
            gw.addLogBackbone(sprintf('t=%d [AGG] Next aggregation at t=%d', t, gw.nextAggTX), [], t);
            
            % CLEAR sensorTable after aggregation (collect fresh data until next period)
            gw.sensorTable = struct('id',{}, 'lastTime',{}, 'value',{}, 'rssi',{}, 'battery',{});
            gw.addLogBackbone(sprintf('t=%d [AGG] Cleared sensorTable (%d sensors) - ready for next collection period', ...
                t, numSensors), [], t);
        end
    end
    
    % =========================================================
    % HEARTBEAT TX
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

        % ====== DOWN/UP HANDLERS (New Functionality) ======
        function actions = handle_DOWN(obj, msg, t)
            actions = {};
            gw = obj.gw;
            
            % Extract targetID from payload [high, low, flags] (no TTL anymore)
            if msg.payloadLen < 3
                return;  % Invalid payload
            end
            
            targetID = bitor(bitshift(uint16(msg.payload(1)),8), uint16(msg.payload(2)));
            thisNodeID = hex2dec(gw.hexID);
            
            % Check if this node is the intended destination
            if targetID == thisNodeID
                % THIS NODE IS THE DESTINATION: generate UP response with complete neighbor table
                % UP payload: [numNeighbors (1), (neighborID(2), tier(1), status(1), distance(2)) x numNeighbors]
                upPayload = uint8([]);
                
                % Get all neighbors
                neighbors = gw.neighborTable;
                numNeighbors = numel(neighbors);
                upPayload = [upPayload, uint8(numNeighbors)];
                
                for i = 1:numNeighbors
                    nbr = neighbors(i);
                    nbrID = nbr.id;
                    
                    % Tier: 1=SENSOR, 2=CH, 3=GWN/SINK
                    if nbr.tier == 1
                        tier = 1;  % SENSOR
                    elseif nbr.tier == 2
                        tier = 2;  % CH
                    else
                        tier = 3;  % GWN/SINK
                    end
                    
                    % Status: 0=self, 1=parent, 2=neighbour, 3=child, 4=forwarding child (CH)
                    if nbrID == thisNodeID
                        status = 0;  % self
                    elseif ~isempty(gw.parent) && nbrID == gw.parent
                        status = 1;  % parent
                    elseif ismember(nbrID, gw.children)
                        status = 3;  % child
                    elseif ismember(nbrID, gw.chChildren)
                        status = 4;  % forwarding child (CH)
                    else
                        status = 2;  % neighbour
                    end
                    
                    % Distance: use stored RSSI as proxy, convert to uint16 (0-65535)
                    dist = uint16(max(0, min(65535, nbr.rssi * 100)));  % Scale RSSI to fit
                    
                    % Pack: ID(2), tier(1), status(1), distance(2)
                    upPayload = [upPayload, ...
                        bitshift(uint8(bitshift(nbrID,-8)),0), uint8(bitand(nbrID,255)), ...  % ID
                        uint8(tier), ...  % tier
                        uint8(status), ...  % status
                        bitshift(uint8(bitshift(dist,-8)),0), uint8(bitand(dist,255))];  % distance
                end
                
                % Fragment the payload into chunks (max 20 bytes per fragment for safety)
                maxFragmentSize = 20;
                numFragments = ceil(numel(upPayload) / maxFragmentSize);
                
                % Queue all fragments
                for fragIdx = 0:(numFragments-1)
                    startIdx = fragIdx * maxFragmentSize + 1;
                    endIdx = min((fragIdx + 1) * maxFragmentSize, numel(upPayload));
                    fragPayload = upPayload(startIdx:endIdx);
                    
                    upMsg = WSN_Message(7, hex2dec(gw.hexID), msg.src, []);
                    upMsg.subtype = 7;  % UP
                    % Encode fragment info in flag: [fragIdx (4b) | totalFrags (4b)]
                    upMsg.flag = uint8(bitshift(fragIdx,4) + bitand(numFragments-1,15));
                    upMsg.payload = fragPayload;
                    upMsg.payloadLen = uint8(numel(fragPayload));
                    upMsg.addChecksum();
                    gw.radio.txBuffer{end+1} = upMsg;
                end
                
                gw.addLog(sprintf('t=%d [GEN_UP] Neighbor table response (%d neighbors), %d fragments, replying to %s', ...
                    t, numNeighbors, numFragments, dec2hex(uint16(msg.src),4)));
                return;
            end
            
            % NOT THE DESTINATION: forward DOWN unchanged (no payload mutation)
            if ~isempty(gw.children)
                % Select random child to forward to
                selectedChild = gw.children(randi(numel(gw.children)));
                
                % Create DOWN message and forward (preserve payload and flags)
                downMsg = WSN_Message(7, hex2dec(gw.hexID), selectedChild, '');
                downMsg.subtype = 6;  % DOWN
                downMsg.payload = msg.payload;
                downMsg.payloadLen = msg.payloadLen;
                downMsg.flag = msg.flag;  % Preserve any flags
                downMsg.addChecksum();
                
                gw.radio.txBuffer{end+1} = downMsg;
                gw.addLog(sprintf('t=%d [FWD] DOWN (target %s) -> child %s', t, dec2hex(uint16(targetID),4), dec2hex(uint16(selectedChild),4)));
            else
                % No children: dead end, drop
                gw.addLog(sprintf('t=%d [DROP] DOWN (target %s) reached leaf node', t, dec2hex(uint16(targetID),4)));
            end
        end

        function actions = handle_UP(obj, msg, t)
            actions = {};
            gw = obj.gw;
            sender = msg.src;
            
            % UP packets propagate upward to parent
            if isempty(gw.parent)
                % Sink receives UP (end of route)
                gw.addLog(sprintf('t=%d [RX] UP from %s (SINK receives)', t, dec2hex(uint16(sender),4)));
                return;
            end
            
            % Forward UP to parent
            upMsg = WSN_Message(7, hex2dec(gw.hexID), gw.parent, '');
            upMsg.subtype = 7;  % UP
            upMsg.payload = msg.payload;
            upMsg.payloadLen = msg.payloadLen;
            upMsg.addChecksum();
            
            gw.radio.txBuffer{end+1} = upMsg;
            gw.addLog(sprintf('t=%d [FWD] UP from %s -> parent %s', t, dec2hex(uint16(sender),4), dec2hex(uint16(gw.parent),4)));
        end
    end
    
    % =========================================================
    % CH-GWN HANDSHAKE HANDLERS (Type 6)
    % =========================================================
    methods
        function actions = handleCHCMD(obj, msg, t, ~)
            % Route CH_CMD subtypes to handlers
            actions = {};
            
            switch msg.subtype
                case WSN_Config.CH_SUB_REQ      % 6.0 CH_REQ
                    actions = obj.handle_CH_REQ(msg, t);
                case WSN_Config.CH_SUB_KEY_ACK  % 6.2 KEY_ACK
                    actions = obj.handle_CH_KEY_ACK(msg, t);
                case WSN_Config.CH_SUB_JOINOK   % 6.4 CH_JOINOK
                    actions = obj.handle_CH_JOINOK(msg, t);
                case WSN_Config.CH_SUB_INFO     % 6.5 CH_INFO
                    actions = obj.handle_CH_INFO(msg, t);
            end
        end
        
        function actions = handle_CH_REQ(obj, msg, t)
            % 6.0 CH_REQ: CH wants to join this GWN
            % Response: 6.1 CH_ACK with local key OR 6.3 CH_REJECT
            actions = {};
            gw = obj.gw;
            sender = msg.src;
            
            % Must be verified GWN to accept CH
            if ~gw.isVerified
                gw.addLogAccess(sprintf('t=%d [CH_REJECT] %s (GWN not verified)', ...
                    t, dec2hex(uint16(sender), 4)), [], t);
                actions{end+1} = struct('type', 'RESP', 'msg', ...
                    obj.createCHReject(sender, t));
                return;
            end
            
            % Check if already locked with another partner (Access radio)
            if ~isempty(gw.radioAccess.handshakePartner) && gw.radioAccess.handshakePartner ~= sender
                gw.addLogAccess(sprintf('t=%d [CH_REJECT] %s (Access locked with %s)', ...
                    t, dec2hex(uint16(sender), 4), dec2hex(uint16(gw.radioAccess.handshakePartner), 4)), [], t);
                actions{end+1} = struct('type', 'RESP', 'msg', ...
                    obj.createCHReject(sender, t));
                return;
            end
            
            % Accept CH: Enter Access radio lock and send CH_ACK with local key
            gw.radioAccess.setLock(sender, WSN_Config.CH_ACCESS_LOCK_TIMER);
            
            % Generate local key for this CH
            localKey = obj.generateLocalKeyForCH(sender);
            
            % Store the local key for future use
            gw.chLocalKeys(dec2hex(uint16(sender),4)) = localKey;
            
            gw.addLogAccess(sprintf('t=%d [CH_ACK] -> %s (sending key)', ...
                t, dec2hex(uint16(sender), 4)), [], t);
            
            actions{end+1} = struct('type', 'RESP', 'msg', ...
                obj.createCHACK(sender, localKey, t));
        end
        
        function actions = handle_CH_KEY_ACK(obj, msg, t)
            % 6.2 KEY_ACK: CH confirmed receipt of key (encrypted)
            % Response: Clear lock, add CH to children, send 5.1 CH_HELLO to parent
            actions = {};
            gw = obj.gw;
            sender = msg.src;
            
            % Validate this is from our Access lock partner
            if isempty(gw.radioAccess.handshakePartner) || gw.radioAccess.handshakePartner ~= sender
                gw.addLogAccess(sprintf('t=%d [IGNORE] KEY_ACK from %s (not Access partner)', ...
                    t, dec2hex(uint16(sender), 4)), [], t);
                return;
            end
            
            % Clear Access radio lock
            gw.radioAccess.clearLock('CH_SUCCESS');
            
            % Add CH to children with brackets [AAxx]
            % Store CH children separately or mark them in children list
            if ~ismember(sender, gw.chChildren)
                if isempty(gw.chChildren)
                    gw.chChildren = sender;
                else
                    gw.chChildren = [gw.chChildren, sender];
                end
            end

            % ML-IDS: seed silence tracking at t=now, so a freshly-joined
            % CH isn't immediately flagged as silent before its first report
            if isempty(find([gw.chLastAggSeen.id] == sender, 1)) %#ok<EFIND>
                gw.chLastAggSeen(end+1) = struct('id', sender, 'lastTime', t);
            end

            gw.addLogAccess(sprintf('t=%d [CH_JOINED] %s added to children', ...
                t, dec2hex(uint16(sender), 4)), [], t);

            % Mark stale so announcePendingChChildren() (called every tick
            % from WSN_Gateway.step()) picks this up -- sends now if we
            % already have a backbone parent, or as soon as we get one.
            % Was previously a fire-once send here that silently dropped
            % forever if gw.parent was empty at this exact tick.
            gw.chChildrenAnnouncedToParent = [];
        end
        
        function actions = handle_CH_JOINOK(obj, msg, t)
            % 6.4 CH_JOINOK: Parent CH accepts this CH's join request
            actions = {};
            gw = obj.gw;
            sender = msg.src;  % Parent CH
            
            % Update status to verified
            gw.isVerified = true;
            
            % Set parent to sender
            gw.parent = sender;
            
            % Clear the lock
            actions{end+1} = struct('effect', 'CLEAR_HANDSHAKE');
            
            gw.addLogAccess(sprintf('t=%d [CH_JOINOK] Parent set to %s, verified', ...
                t, dec2hex(uint16(sender), 4)), [], t);
        end
        
        function actions = handle_CH_INFO(obj, msg, t)
            % 6.5 CH_INFO: Parent CH informs GWN of recruited secondary CH
            % Payload: {Recruited CH ID, Parent CH ID} encrypted in local key
            actions = {};
            gw = obj.gw;
            sender = msg.src;  % Parent CH
            
            % Decrypt payload using local key for this CH
            localKey = obj.getLocalKeyForCH(sender);
            if isempty(localKey)
                gw.addLogAccess(sprintf('t=%d [ERROR] CH_INFO from %s - no local key', ...
                    t, dec2hex(uint16(sender), 4)), [], t);
                return;
            end
            
            decryptedPayload = obj.decryptPayload(msg.payload, localKey);
            if numel(decryptedPayload) < 4
                gw.addLogAccess(sprintf('t=%d [ERROR] CH_INFO from %s - invalid payload', ...
                    t, dec2hex(uint16(sender), 4)), [], t);
                return;
            end
            
            % Parse: Recruited CH ID (2 bytes), Parent CH ID (2 bytes)
            recruitedID = typecast(decryptedPayload(1:2), 'uint16');
            parentCHID = typecast(decryptedPayload(3:4), 'uint16');
            
            if parentCHID ~= sender
                gw.addLogAccess(sprintf('t=%d [ERROR] CH_INFO from %s - parent mismatch %s', ...
                    t, dec2hex(uint16(sender), 4), dec2hex(uint16(parentCHID), 4)), [], t);
                return;
            end
            
            gw.addLogAccess(sprintf('t=%d [SECONDARY_CH] %s recruited by %s', ...
                t, dec2hex(uint16(recruitedID), 4), dec2hex(uint16(sender), 4)), [], t);

            % Track separately from first-degree chChildren (see property
            % comment on WSN_Gateway.secondaryChChildren) and mark stale so
            % announcePendingChChildren() picks it up -- same fire-once
            % drop-forever bug as handle_CH_KEY_ACK above, fixed the same way.
            if ~ismember(recruitedID, gw.secondaryChChildren)
                gw.secondaryChChildren = [gw.secondaryChChildren, recruitedID];
            end
            gw.chChildrenAnnouncedToParent = [];
        end

        function announcePendingChChildren(obj, t)
            % Called every tick from WSN_Gateway.step(). Sends a 5.1
            % CH_HELLO up the backbone for every CH (direct or secondary)
            % this GWN knows about, whenever the announced-to parent is
            % stale (no parent yet, parent just changed, or a new CH was
            % added since the last full announce). Re-announces everyone
            % on a parent change since the new parent doesn't know any of
            % them yet. See WSN_Gateway.chChildrenAnnouncedToParent.
            gw = obj.gw;
            if isa(gw, 'WSN_Sink'), return; end  % Sink terminates CH_HELLO, doesn't forward
            if isempty(gw.parent), return; end
            if isequal(gw.chChildrenAnnouncedToParent, gw.parent), return; end

            allCH = [gw.chChildren, gw.secondaryChChildren];
            for i = 1:numel(allCH)
                chHelloMsg = obj.createCHHello(allCH(i), t);
                obj.enqueueLocal(chHelloMsg, t);
                gw.addLogBackbone(sprintf('t=%d [CH_HELLO] (re)announce CH=%s -> parent %s', ...
                    t, gw.fmtID(allCH(i)), gw.fmtID(gw.parent)), [], t);
            end
            gw.chChildrenAnnouncedToParent = gw.parent;
        end
        
        function localKey = generateLocalKeyForCH(obj, chID)
            % Generate a local key for CH based on GWN's encryption key and CH ID
            gw = obj.gw;
            if isempty(gw.encryptionKey)
                % Fallback: use random key if no encryption key
                localKey = uint8(randi([0 255], 1, 16));
            else
                gk = uint8(hex2dec(reshape(gw.encryptionKey, 2, [])'));
                chBytes = typecast(uint16(chID), 'uint8');
                gwBytes = typecast(uint16(hex2dec(gw.hexID)), 'uint8');
                seed = [gk; chBytes(:); gwBytes(:)];
                localKey = gk(1:min(16, numel(gk)));
                for i = 1:numel(seed)
                    localKey(mod(i-1, numel(localKey))+1) = ...
                        bitxor(localKey(mod(i-1, numel(localKey))+1), seed(i));
                end
                % Ensure 16 bytes
                if numel(localKey) < 16
                    localKey = [localKey, zeros(1, 16-numel(localKey), 'uint8')];
                end
            end
        end
        
        function msg = createCHACK(obj, dst, localKey, t)
            % Create 6.1 CH_ACK message with local key in payload
            gw = obj.gw;
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_CMD;
            msg.subtype = WSN_Config.CH_SUB_ACK;  % 1
            msg.src = hex2dec(gw.hexID);
            msg.dst = dst;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            msg.flag = 0;
            msg.payload = localKey(:)';
            msg.payloadLen = numel(msg.payload);
            msg.addChecksum();
        end
        
        function msg = createCHReject(obj, dst, t)
            % Create 6.3 CH_REJECT message
            gw = obj.gw;
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_CMD;
            msg.subtype = WSN_Config.CH_SUB_REJECT;  % 3
            msg.src = hex2dec(gw.hexID);
            msg.dst = dst;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            msg.flag = 0;
            msg.payloadLen = 0;
            msg.payload = [];
            msg.addChecksum();
        end
        
        function msg = createCHHello(obj, chID, t)
            % Create 5.1 CH_HELLO message to parent (encrypted in local+global key)
            % Payload: CH ID (2 bytes), Parent ID/GWN ID (2 bytes)
            gw = obj.gw;
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_HELLO;
            msg.subtype = 1;  % 5.1 CH_HELLO
            msg.src = hex2dec(gw.hexID);
            msg.dst = gw.parent;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            msg.flag = bitset(0, 1, 1);  % Encrypted flag
            % Payload: CH ID + GWN ID (parent of CH)
            msg.payload = [typecast(uint16(chID), 'uint8'), ...
                           typecast(uint16(hex2dec(gw.hexID)), 'uint8')];
            msg.payloadLen = numel(msg.payload);
            msg.addChecksum();
        end
        
        function localKey = getLocalKeyForCH(obj, chID)
            % Retrieve stored local key for a CH
            gw = obj.gw;
            chHex = dec2hex(uint16(chID), 4);
            if gw.chLocalKeys.isKey(chHex)
                localKey = gw.chLocalKeys(chHex);
            else
                localKey = [];
            end
        end
        
        function msg = createCHINFO(obj, recruitedID, t)
            % Create 6.5 CH_INFO: {Recruited CH ID, Parent CH ID} encrypted in local key
            gw = obj.gw;
            parentID = gw.id;  % This GWN is the parent
            
            % Get local key for the recruited CH
            chHex = dec2hex(recruitedID, 4);
            if isKey(gw.chLocalKeys, chHex)
                localKey = gw.chLocalKeys(chHex);
            else
                localKey = [];  % No key, send unencrypted?
            end
            
            % Payload: Recruited ID (2), Parent ID (2)
            payload = [typecast(uint16(recruitedID), 'uint8'), typecast(uint16(parentID), 'uint8')];
            
            % Encrypt if key available
            if ~isempty(localKey)
                payload = obj.encryptPayload(payload, localKey);
            end
            
            msg = WSN_Message(6, hex2dec(gw.hexID), 0, payload);  % Dst=0 for broadcast? No, to parent.
            % Actually, in handleCHREQ, it's sent to obj.parent, which is the GWN.
            % But for CH, parent is CH or GWN.
            msg.subtype = WSN_Config.CH_SUB_INFO;
            msg.flag = bitset(0, 1, ~isempty(localKey));  % Encrypted flag
            msg.addChecksum();
        end
        
        function encrypted = encryptPayload(obj, payload, key)
            % Simple XOR decryption with key (repeated as needed)
            decrypted = payload;
            for i = 1:numel(payload)
                keyIdx = mod(i-1, numel(key)) + 1;
                decrypted(i) = bitxor(payload(i), key(keyIdx));
            end
        end
    end
end
