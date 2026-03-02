classdef WSN_Gateway_Behavior < handle
    % =========================================================
    % WSN GATEWAY BEHAVIOR — FSM + SEQUENTIAL RECRUITMENT
    % Owns WHEN decisions, radio owns locking
    % =========================================================

    properties
        gw   % owning gateway
        bootTime = 0
        % ---- RECRUITMENT STATE ----
        retryTarget    = []      % current neighbor being recruited
        retryCount     = 0       % attempts so far
        retryBackoff   = 0       % randomized backoff timer

    end

    % =========================================================
    % CONSTRUCTOR
    % =========================================================
    methods
        function obj = WSN_Gateway_Behavior(gateway)
            obj.gw = gateway;
            obj.bootTime = 0;
        end
    end

    % =========================================================
    % STEP FSM
    % =========================================================
    methods
        function actions = step(obj, t)
            gw = obj.gw;
            actions = {};
            
            % === ATTACK: FLOODING (Hello Flood) ===
            % Malicious GWN broadcasts excessive HELLO messages with inflated TX power
            if WSN_Attack.isMaliciousNode(gw.id) && ...
               WSN_Attack.getAttackType(gw.id) == WSN_Attack.ATTACK_FLOODING
                floodCount = WSN_Attack.getFloodingBurstCount(gw.id, t);
                if floodCount > 0
                    % Temporarily inflate TX power for flooding
                    originalPower = gw.txPower;
                    gw.txPower = WSN_Attack.getFloodingTxPower(gw.id);
                    
                    % Broadcast multiple HELLO messages
                    for fi = 1:floodCount
                        floodMsg = gw.createHelloMessage(t);
                        floodMsg.uid = randi(1e9);  % Unique ID per flood message
                        actions{end+1} = struct('type', 'RESP', 'msg', floodMsg);
                        gw.addLog(sprintf('t=%d [HELLO_TX] bat=%d%% nbr=%d', ...
                            t, uint8(gw.battery), numel(gw.neighborTable)));
                    end
                    
                    % Restore original power
                    gw.txPower = originalPower;
                end
            end
            
            % === ATTACK: PANIC FLOOD (Sinkhole Variant) ===
            % Malicious GWN broadcasts fake emergency alerts
            if WSN_Attack.isMaliciousNode(gw.id) && ...
               WSN_Attack.getAttackType(gw.id) == WSN_Attack.ATTACK_PANIC_FLOOD
                if WSN_Attack.shouldPanicFlood(gw.id, t)
                    panicMsg = WSN_Attack.createFakePanicBeacon(gw.id, gw.hexID, t);
                    if ~isempty(panicMsg)
                        actions{end+1} = struct('type', 'RESP', 'msg', panicMsg);
                        gw.addLog(sprintf('t=%d [PANIC_TX] type=%d sev=%d', ...
                            t, panicMsg.subtype, 2));
                    end
                end
            end
            
            % =================================================
            % GWN CHARGING (every GWN_CHARGE_INTERVAL timeframes)
            % =================================================
            if mod(t, WSN_Config.GWN_CHARGE_INTERVAL) == 0 && t > gw.lastChargeTime
                gw.battery = min(100, gw.battery + WSN_Config.GWN_CHARGE_AMOUNT);
                gw.lastChargeTime = t;
            end
            
            % =================================================
            % GLOBAL HANDSHAKE TIMEOUT (FSM-OWNED)
            % =================================================
            if ~isempty(gw.handshakePartner)

                % decrement lockTimer here (FSM owns time)
                gw.radio.lockTimer = gw.radio.lockTimer - 1;

                if gw.radio.lockTimer <= 0
                    gw.radio.lockExpired = true;
                end
            end

            % =================================================
            % PURGE PENDING CHILDREN (timeout waiting for ENC_HELLO)
            % Send PARENT_REJECT to timed-out nodes so they clear their parent
            % =================================================
            if ~isempty(gw.pendingChildren)
                timedOut = [gw.pendingChildren.addedAt] < (t - gw.PENDING_CHILD_TIMEOUT);
                if any(timedOut)
                    for i = find(timedOut)
                        childID = gw.pendingChildren(i).id;
                        % Send PARENT_REJECT so child clears its parent field
                        rejectMsg = WSN_Message(7, hex2dec(gw.hexID), childID, []);
                        rejectMsg.subtype = 3;  % PARENT_REJECT
                        rejectMsg.addChecksum();
                        actions{end+1} = struct('type', 'RESP', 'msg', rejectMsg);
                        gw.addLogBackbone(sprintf('t=%d [TIMEOUT] Pending child %s timed out (no ENC_HELLO) -> PARENT_REJECT', ...
                            t, gw.fmtID(childID)), rejectMsg, t);
                    end
                    gw.pendingChildren(timedOut) = [];
                end
            end

            % =================================================
            % PURGE DEAD NEIGHBORS
            % =================================================
            if ~isempty(gw.neighborTable)
                timeout = 3 * WSN_Config.HelloInterval;
                dead = [gw.neighborTable.lastSeen] < (t - timeout);

                if any(dead)
                    deadIDs = [gw.neighborTable(dead).id];
                    gw.neighborTable(dead) = [];

                    % remove only dead children
                    if ~isempty(gw.children)
                        gw.children = setdiff(gw.children, intersect(gw.children, deadIDs));
                    end

                    % parent loss
                    if ~isempty(gw.parent) && ismember(gw.parent, deadIDs)
                        gw.addLog(sprintf('t=%d [CRITICAL] Parent lost', t));
                        gw.parent = [];
                        gw.hasKey = false;
                        gw.isVerified = false;
                        gw.state = WSN_Config.STATE_DISCOVERY;
                    end
                end
            end

            % =================================================
            % INTERVAL SELECTION
            % =================================================
            currInt = WSN_Config.HelloInterval;
            if gw.crazyTimer > 0 || gw.state < WSN_Config.STATE_SECURE
                currInt = WSN_Config.AggressiveInterval;
            end

            % =================================================
            % PERIODIC ENC_HELLO RETRY (Exponential Backoff)
            % Sends at t+10, t+30, t+70 after initial (intervals: 10, 20, 40)
            % CONTINUES INDEFINITELY after handshake for path registry refresh
            % =================================================
            if gw.isVerified && ~isa(gw, 'WSN_Sink')
                if t >= gw.encHelloNextRetryTime && gw.encHelloNextRetryTime > 0
                    encHello = gw.messaging.createEncHello(t);
                    if ~isempty(encHello)
                        actions{end+1} = struct('type', 'RESP', 'msg', encHello);
                        gw.encHelloRetryCount = gw.encHelloRetryCount + 1;
                        
                        % Schedule next retry with exponential backoff
                        % Intervals: 10, 20, 40, 80, 160, ... (base * 2^retryCount)
                        % After max retries, continue with maximum interval for registry refresh
                        if gw.encHelloRetryCount < gw.ENC_HELLO_MAX_RETRIES
                            nextInterval = gw.ENC_HELLO_BASE_INTERVAL * (2 ^ gw.encHelloRetryCount);
                        else
                            % Continue with maximum interval for path registry refresh
                            nextInterval = gw.ENC_HELLO_BASE_INTERVAL * (2 ^ gw.ENC_HELLO_MAX_RETRIES);
                        end
                        gw.encHelloNextRetryTime = t + nextInterval;
                        
                        if gw.encHelloRetryCount <= gw.ENC_HELLO_MAX_RETRIES
                            gw.addLogBackbone(sprintf('t=%d [ENC_HELLO] Retry %d/%d sent (next at t=%d)', ...
                                t, gw.encHelloRetryCount, gw.ENC_HELLO_MAX_RETRIES, gw.encHelloNextRetryTime), [], t);
                        else
                            gw.addLogBackbone(sprintf('t=%d [ENC_HELLO] Registry refresh #%d sent (next at t=%d)', ...
                                t, gw.encHelloRetryCount - gw.ENC_HELLO_MAX_RETRIES, gw.encHelloNextRetryTime), [], t);
                        end
                    end
                end
            end

            % =================================================
            % PERIODIC ENC_HB (Encrypted Heartbeat) for backbone mesh
            % Sent by verified GWNs to maintain mesh connectivity
            % =================================================
            if gw.isVerified && gw.state >= WSN_Config.STATE_SECURE && ...
                    mod(t, WSN_Config.HelloInterval) == mod(gw.offset, WSN_Config.HelloInterval)
                actions{end+1} = struct('type','HB','hb','ENC_HB');
            end

            % =================================================
            % PERIODIC SENSOR AGGREGATION (queue to Q_local)
            % =================================================
            if gw.isVerified && ~isempty(gw.parent) && gw.hasKey && t >= WSN_Config.SENSOR_START_TIME
                aggMsgs = gw.messaging.processSensorAggregation(t);
                for i = 1:numel(aggMsgs)
                    actions{end+1} = struct('type', 'RESP', 'msg', aggMsgs{i});
                end
            end
            
            % =================================================
            % PHASE-BASED BACKBONE SCHEDULING (replaces TOKEN system)
            % GWN must be in SECURE STATE to use phase scheduling
            % =================================================
            if gw.state == WSN_Config.STATE_SECURE && gw.isVerified && gw.phaseInherited && t >= WSN_Config.PHASE_START_TIME
                % Compute current phase from global key and time
                currentPhase = gw.messaging.computePhase(t);
                gw.currentPhase = currentPhase;

                % SINK SPECIAL: default to RX unless there is an actual need to TX
                if isa(gw, 'WSN_Sink')
                    if currentPhase == WSN_Config.PHASE_TX
                        % Allow TX only if there are queued messages or pending radio TX
                        hasQueued = ~isempty(gw.Q_fwd) || ~isempty(gw.Q_local) || ~isempty(gw.radio.txBuffer);
                        if hasQueued
                            txMsg = gw.messaging.dequeueForTx(t);
                            if ~isempty(txMsg)
                                actions{end+1} = struct('type', 'RESP', 'msg', txMsg);
                                gw.addLogBackbone(sprintf('t=%d [SINK PHASE_TX] Sent %s.%d -> %s (Q_fwd=%d, Q_local=%d)', ...
                                    t, txMsg.getTypeStr(), txMsg.subtype, gw.fmtID(txMsg.dst), numel(gw.Q_fwd), numel(gw.Q_local)), txMsg, t);
                            else
                                gw.addLogBackbone(sprintf('t=%d [SINK PHASE_TX] No dequeuable messages (holding RX)', t), [], t);
                            end
                        else
                            % Stay in RX - sink remains listening when idle
                            gw.addLogBackbone(sprintf('t=%d [SINK] Idle - remaining in RX (no pending TX)', t), [], t);
                        end
                    else
                        gw.addLogBackbone(sprintf('t=%d [SINK PHASE_RX] Listening (Q_fwd=%d, Q_local=%d)', ...
                            t, numel(gw.Q_fwd), numel(gw.Q_local)), [], t);
                    end
                else
                    % Regular GWN behavior
                    if currentPhase == WSN_Config.PHASE_TX
                        % TX PHASE: Send queued messages to parent (strict priority: Q_fwd first)
                        txMsg = gw.messaging.dequeueForTx(t);
                        if ~isempty(txMsg)
                            actions{end+1} = struct('type', 'RESP', 'msg', txMsg);
                            gw.addLogBackbone(sprintf('t=%d [PHASE_TX] Sent %s.%d -> %s (Q_fwd=%d, Q_local=%d)', ...
                                t, txMsg.getTypeStr(), txMsg.subtype, gw.fmtID(txMsg.dst), ...
                                numel(gw.Q_fwd), numel(gw.Q_local)), txMsg, t);
                        else
                            gw.addLogBackbone(sprintf('t=%d [PHASE_TX] IDLE (queues empty)', t), [], t);
                        end
                    else
                        % RX PHASE: Ready to receive from children
                        gw.addLogBackbone(sprintf('t=%d [PHASE_RX] Listening (Q_fwd=%d, Q_local=%d)', ...
                            t, numel(gw.Q_fwd), numel(gw.Q_local)), [], t);
                    end
                end
            end

            % =================================================
            % FSM
            % =================================================
            switch gw.state

                % ---------------- BOOT ----------------
                % ---------------- BOOT ----------------
                case WSN_Config.STATE_BOOT

                    % Initialize boot timer once
                    if gw.bootTime == 0
                        gw.bootTime = t;
                    end

                    % Periodic BOOT heartbeat (only if not locked)
                    if isempty(gw.handshakePartner) && mod(t,currInt)==mod(gw.offset,currInt)
                        actions{end+1} = struct('type','HB','hb','HB_BOOT');
                    end

                    % ---- Check BOOT window expiry ----
                    if (t - gw.bootTime) < WSN_Config.BootSteps
                        return;
                    end

                    % ---- Count same-tier neighbors ----
                    nbrs = gw.neighborTable;
                    if numel(gw.neighborTable) >= WSN_Config.MinBootNeighbors
                        gw.state    = WSN_Config.STATE_DISCOVERY;
                        gw.bootTime = 0;
                        gw.addLog(sprintf( ...
                            't=%d [STATE] BOOT→DISCOVERY (neighbors=%d)', ...
                            t, numel(gw.neighborTable)));
                        return;
                    end

                    % ---- BOOT COMPLETE BUT < MIN NEIGHBORS: BLOCK DISCOVERY ----
                    gw.addLog(sprintf('t=%d [BOOT][FAILED] Insufficient neighbors (%d<%d), staying in BOOT', ...
                        t, numel(gw.neighborTable), WSN_Config.MinBootNeighbors));
                    return;

                case WSN_Config.STATE_DISCOVERY
                    % GUARD: Don't transmit if radio is locked
                    if ~isempty(gw.handshakePartner)
                        return;
                    end
                    if mod(t,currInt)==mod(gw.offset,currInt)
                        actions{end+1} = struct('type','HB','hb','HB_DISC');
                    end

                    % ---------------- HANDSHAKE ----------------
                case WSN_Config.STATE_HANDSHAKE

                    % RX may have resolved handshake - but ONLY go SECURE if we have key
                    if isempty(gw.handshakePartner)
                        % SINK SPECIAL CASE: Sink has no parent by design, always return to SECURE
                        if isa(gw, 'WSN_Sink')
                            gw.state = WSN_Config.STATE_SECURE;
                            return;
                        end
                        
                        if gw.hasKey && ~isempty(gw.parent)
                            gw.state = WSN_Config.STATE_SECURE;
                        else
                            % Partner cleared but we don't have key - revert to DISCOVERY
                            gw.addLog(sprintf('t=%d [HANDSHAKE] Partner cleared but no key - reverting to DISCOVERY', t));
                            if ~isempty(gw.parent)
                                gw.addLog(sprintf('t=%d [HANDSHAKE] Purging orphan parent %s', t, dec2hex(uint16(gw.parent), 4)));
                                gw.parent = [];
                            end
                            gw.hasKey = false;
                            gw.encryptionKey = '';
                            gw.isVerified = false;
                            gw.state = WSN_Config.STATE_DISCOVERY;
                        end
                        return;
                    end

                    % Only react to timeout
                    if ~gw.radio.lockExpired
                        return;
                    end

                    % ---- TIMEOUT: State-based recovery ----
                    gw.radio.lockExpired = false;
                    timedOutPartner = gw.handshakePartner;
                    
                    % ========== SINK SPECIAL CASE: TIMEOUT HANDLING ==========
                    % Sink has no parent by design - handle timeouts differently
                    if isa(gw, 'WSN_Sink')
                        % Purge timed-out partner from children if exists
                        if ~isempty(timedOutPartner) && ismember(timedOutPartner, gw.children)
                            gw.children = setdiff(gw.children, timedOutPartner);
                            gw.addLog(sprintf('t=%d [SINK_TIMEOUT] Purged %s from children', ...
                                t, dec2hex(uint16(timedOutPartner), 4)));
                            
                            % ORPHAN GUARD: Send PARENT_REJECT to notify child they're orphaned
                            % This handles dropped ENC_HELLO - child thinks we're parent but we gave up
                            rejectMsg = WSN_Message(7, hex2dec(gw.hexID), timedOutPartner, []);
                            rejectMsg.subtype = 3;  % PARENT_REJECT
                            rejectMsg.addChecksum();
                            gw.radio.requestTX(rejectMsg);
                            gw.logTxBackbone(rejectMsg, t);
                            gw.addLog(sprintf('t=%d [SINK_TIMEOUT] Sent PARENT_REJECT to orphaned %s', ...
                                t, dec2hex(uint16(timedOutPartner), 4)));
                        end
                        
                        % Increment retry count
                        obj.retryCount = obj.retryCount + 1;
                        if obj.retryCount >= WSN_Config.MAX_RETRIES
                            % Max retries exhausted - reject and reset currentRecruit
                            if ~isempty(timedOutPartner)
                                idx = find([gw.neighborTable.id] == timedOutPartner, 1);
                                if ~isempty(idx)
                                    gw.neighborTable(idx).status = gw.ST_REJECT;
                                end
                            end
                            gw.addLog(sprintf('t=%d [SINK_TIMEOUT] Exhausted %d retries for %s - REJECTED', ...
                                t, WSN_Config.MAX_RETRIES, dec2hex(uint16(timedOutPartner), 4)));
                            obj.retryTarget = [];
                            obj.retryCount = 0;
                            gw.currentRecruit = uint16(0);
                            gw.recruitPtr = gw.recruitPtr + 1;
                        else
                            gw.addLog(sprintf('t=%d [SINK_TIMEOUT] Attempt %d/%d for %s - will retry', ...
                                t, obj.retryCount, WSN_Config.MAX_RETRIES, dec2hex(uint16(timedOutPartner), 4)));
                        end
                        
                        gw.handshakePartner = [];
                        gw.radio.clearLock();
                        gw.state = WSN_Config.STATE_SECURE;
                        return;
                    end
                    
                    % ========== STATE-BASED FSM LOCK BREAK ==========
                    % Determine recovery action based on WHAT WE HAVE, not role
                    
                    if gw.hasKey && ~isempty(gw.parent)
                        % CASE 1: Has key + Has parent = FUNCTIONAL
                        % Send ENC_HELLO if not already done (receiver completing handshake)
                        if ~gw.isVerified
                            encHello = obj.messaging.createEncHello(t);
                            if ~isempty(encHello)
                                gw.radio.requestTX(encHello);
                                gw.logTx(encHello, t);
                                gw.addLog(sprintf('t=%d [TIMEOUT-RECOVERY] Sending ENC_HELLO to complete handshake', t));
                            end
                            gw.isVerified = true;
                        end
                        
                        % Purge handshakePartner from pendingChildren first (secure handshake)
                        if ~isempty(timedOutPartner) && ~isempty(gw.pendingChildren) && any([gw.pendingChildren.id] == timedOutPartner)
                            gw.pendingChildren([gw.pendingChildren.id] == timedOutPartner) = [];
                            gw.addLog(sprintf('t=%d [TIMEOUT] Purged %s from pendingChildren', ...
                                t, dec2hex(uint16(timedOutPartner), 4)));
                            
                            % Send PARENT_REJECT so child clears its parent field
                            rejectMsg = WSN_Message(7, hex2dec(gw.hexID), timedOutPartner, []);
                            rejectMsg.subtype = 3;  % PARENT_REJECT
                            rejectMsg.addChecksum();
                            gw.radio.requestTX(rejectMsg);
                            gw.logTxBackbone(rejectMsg, t);
                            gw.addLog(sprintf('t=%d [TIMEOUT] Sent PARENT_REJECT to pending %s', ...
                                t, dec2hex(uint16(timedOutPartner), 4)));
                        end
                        
                        % Also purge handshakePartner from children if exists (shouldn't happen now)
                        if ~isempty(timedOutPartner) && ismember(timedOutPartner, gw.children)
                            gw.children = setdiff(gw.children, timedOutPartner);
                            gw.addLog(sprintf('t=%d [TIMEOUT] Purged %s from children', ...
                                t, dec2hex(uint16(timedOutPartner), 4)));
                            
                            % ORPHAN GUARD: Send PARENT_REJECT to notify child they're orphaned
                            % This handles dropped ENC_HELLO - child thinks we're parent but we gave up
                            rejectMsg = WSN_Message(7, hex2dec(gw.hexID), timedOutPartner, []);
                            rejectMsg.subtype = 3;  % PARENT_REJECT
                            rejectMsg.addChecksum();
                            gw.radio.requestTX(rejectMsg);
                            gw.logTxBackbone(rejectMsg, t);
                            gw.addLog(sprintf('t=%d [TIMEOUT] Sent PARENT_REJECT to orphaned %s', ...
                                t, dec2hex(uint16(timedOutPartner), 4)));
                        end
                        
                        % Handle retry logic for either case
                        if ~isempty(timedOutPartner)
                            % NOTE: retryCount is incremented when retry is ATTEMPTED in STATE_SECURE
                            % Check if max would be exceeded on next retry
                            if (obj.retryCount + 1) >= WSN_Config.MAX_RETRIES
                                % Max retries will be exhausted - reject this target now
                                idx = find([gw.neighborTable.id] == timedOutPartner, 1);
                                if ~isempty(idx)
                                    gw.neighborTable(idx).status = gw.ST_REJECT;
                                end
                                gw.addLog(sprintf('t=%d [TIMEOUT] Will exhaust %d retries for %s - REJECTED', ...
                                    t, WSN_Config.MAX_RETRIES, dec2hex(uint16(timedOutPartner), 4)));
                                obj.retryTarget = [];
                                obj.retryCount = 0;
                                obj.retryBackoff = randi([1 WSN_Config.HelloInterval]);
                            else
                                gw.addLog(sprintf('t=%d [TIMEOUT] Attempt %d/%d for %s - will retry', ...
                                    t, obj.retryCount + 1, WSN_Config.MAX_RETRIES, dec2hex(uint16(timedOutPartner), 4)));
                            end
                        end
                        
                        gw.handshakePartner = [];
                        gw.radio.clearLock();
                        gw.state = WSN_Config.STATE_SECURE;
                        return;
                        
                    elseif gw.hasKey && isempty(gw.parent)
                        % CASE 2: Has key + No parent = ORPHAN KEY (shouldn't happen)
                        gw.addLog(sprintf('t=%d [TIMEOUT] ORPHAN KEY - dropping key, returning to DISCOVERY', t));
                        gw.hasKey = false;
                        gw.encryptionKey = '';
                        gw.isVerified = false;
                        gw.handshakePartner = [];
                        gw.radio.clearLock();
                        gw.state = WSN_Config.STATE_DISCOVERY;
                        return;
                        
                    elseif ~gw.hasKey && ~isempty(gw.parent)
                        % CASE 3: No key + Has parent = PARTIAL HANDSHAKE
                        % Got ACK_JOIN (parent set) but never got GLOBAL_KEY
                        gw.addLog(sprintf('t=%d [TIMEOUT] PARTIAL - dropping parent %s, returning to DISCOVERY', ...
                            t, dec2hex(uint16(gw.parent), 4)));
                        
                        % Mark recruiter as rejected so they don't retry us
                        if ~isempty(timedOutPartner)
                            idx = find([gw.neighborTable.id] == timedOutPartner, 1);
                            if ~isempty(idx)
                                gw.neighborTable(idx).status = gw.ST_REJECT;
                            end
                        end
                        
                        gw.parent = [];
                        gw.handshakePartner = [];
                        gw.radio.clearLock();
                        gw.state = WSN_Config.STATE_DISCOVERY;
                        return;
                        
                    else
                        % CASE 4: No key + No parent = CLEAN SLATE
                        gw.addLog(sprintf('t=%d [TIMEOUT] CLEAN SLATE - returning to DISCOVERY', t));
                        gw.handshakePartner = [];
                        gw.radio.clearLock();
                        gw.state = WSN_Config.STATE_DISCOVERY;
                        return;
                    end

                case WSN_Config.STATE_SECURE
                    % --- GUARD CLAUSES (fail-fast) ---
                    % Respect backoff timer if no active retry
                    if obj.retryBackoff > 0 && isempty(obj.retryTarget)
                        obj.retryBackoff = obj.retryBackoff - 1;
                        return;
                    end

                    % Cannot recruit while radio is locked
                    if ~isempty(gw.handshakePartner)
                        return;
                    end

                    % Non-sink must be verified before recruiting
                    if ~isa(gw,'WSN_Sink') && ~gw.isVerified
                        return;
                    end

                    % Non-sink recruits only one child
                    if ~isa(gw,'WSN_Sink') && ~isempty(gw.children)
                        return;
                    end

                    % Need neighbors to recruit
                    nbrs = gw.neighborTable;
                    if isempty(nbrs), return; end

                    % --- CHECK IF ALL NEIGHBORS EXHAUSTED ---
                    % CRITICAL: Both Sink and GWNs only recruit tier=3 (GWN) nodes
                    % Ensures recruitment stays within Backbone/Control physics
                    valid = find([nbrs.status] ~= gw.ST_REJECT & [nbrs.tier] == 3);
                    
                    % Exclude parent from recruitment
                    if ~isempty(gw.parent)
                        valid = valid([nbrs(valid).id] ~= gw.parent);
                    end
                    
                    % Exclude already-verified GWNs (they're part of the network)
                    % Saves time by not trying to recruit nodes that will reject
                    if ~isempty(valid) && isfield(nbrs, 'isVerified')
                        verifiedMask = [nbrs(valid).isVerified];
                        valid = valid(~verifiedMask);
                    end

                    % TERMINAL GUARD: All neighbors rejected and no more options
                    if isempty(valid)
                        % All neighbors rejected: Check if we can scale power
                        if isprop(gw,'controlPower') && gw.controlPower < WSN_Config.MaxGWNPower
                            oldP = gw.controlPower;
                            gw.controlPower = min(WSN_Config.MaxGWNPower, gw.controlPower * 1.10);
                            gw.addLog(sprintf('t=%d [SCALE_EXHAUSTED] Power %.2f -> %.2f (all neighbors rejected)', ...
                                t, oldP, gw.controlPower));
                            % Note: Rejected neighbors stay rejected. Let them age out naturally.
                            % If power increase reaches them, they'll still reject (stronger signal).
                        else
                            % === TERMINAL CONDITION: ALL NEIGHBORS REJECTED AT MAX POWER ===
                            % Node will naturally stay in STATE_SECURE but won't recruit
                            % (valid list stays empty, so early return prevents any action)
                            gw.addLog(sprintf('t=%d [TERMINAL] All neighbors rejected at Max Power. Waiting.', t));
                        end
                        return;
                    end

                    % --- RECRUITMENT LOGIC ---
                    % Resolve active retry or pick next candidate
                    if isempty(obj.retryTarget)
                        % Select strongest neighbor
                        [~, ord] = sort([nbrs(valid).rssi],'descend');
                        obj.retryTarget = nbrs(valid(ord(1))).id;
                        obj.retryCount = 0;
                    else
                        % CHECK MAX_RETRIES BEFORE RETRYING EXISTING TARGET
                        obj.retryCount = obj.retryCount + 1;
                        if obj.retryCount >= WSN_Config.MAX_RETRIES
                            % Max retries exhausted - reject and pick next
                            idx = find([gw.neighborTable.id] == obj.retryTarget, 1);
                            if ~isempty(idx)
                                gw.neighborTable(idx).status = gw.ST_REJECT;
                            end
                            gw.addLog(sprintf('t=%d [RETRY_EXHAUST] %s rejected after %d attempts', ...
                                t, dec2hex(uint16(obj.retryTarget), 4), WSN_Config.MAX_RETRIES));
                            obj.retryTarget = [];
                            obj.retryCount = 0;
                            obj.retryBackoff = randi([1 WSN_Config.HelloInterval]);
                            return;  % Will pick new target next tick
                        end
                    end

                    % Initiate handshake
                    actions{end+1} = struct( ...
                        'effect','SET_HANDSHAKE', ...
                        'value', obj.retryTarget);
                    actions{end+1} = struct( ...
                        'type','SEND', ...
                        'cmd','PARENT_INIT', ...
                        'dst',obj.retryTarget);

                    gw.addLog(sprintf( ...
                        't=%d [RECRUIT] INIT(%d/%d) -> %s', ...
                        t, obj.retryCount+1, WSN_Config.MAX_RETRIES, ...
                        dec2hex(uint16(obj.retryTarget),4)));

                    gw.state = WSN_Config.STATE_HANDSHAKE;
                    % Note: Periodic ENC_HB is sent before FSM switch (no need to duplicate here)
            end
        end
    end

    % =========================================================
    % APPLY ACTIONS FROM RX (FSM SIDE-EFFECTS ONLY)
    % =========================================================
    methods
        function apply(obj, actions, t)
            gw = obj.gw;
            
            % State name mapping for logging
            stateNames = {'BOOT', 'DISCOVERY', 'HANDSHAKE', 'SECURE', 'DORMANT'};

            for k = 1:numel(actions)
                a = actions{k};
                if ~isfield(a,'effect'), continue; end

                switch a.effect
                    case 'SET_PARENT'
                        oldParent = gw.parent;
                        gw.parent = a.value;
                        if isempty(oldParent)
                            gw.addLogBackbone(sprintf('t=%d [PARENT] Set parent -> %s', ...
                                t, dec2hex(uint16(a.value), 4)), [], t);
                        else
                            gw.addLogBackbone(sprintf('t=%d [PARENT] Changed %s -> %s', ...
                                t, dec2hex(uint16(oldParent), 4), dec2hex(uint16(a.value), 4)), [], t);
                        end

                    case 'STATE'
                        oldState = gw.state;
                        gw.state = a.value;
                        % Log state transition
                        if oldState ~= a.value
                            oldName = 'UNK';
                            newName = 'UNK';
                            if oldState >= 0 && oldState < numel(stateNames)
                                oldName = stateNames{oldState + 1};
                            end
                            if a.value >= 0 && a.value < numel(stateNames)
                                newName = stateNames{a.value + 1};
                            end
                            gw.addLogBackbone(sprintf('t=%d [STATE] %s -> %s', t, oldName, newName), [], t);
                        end
                        
                    case 'SET_HANDSHAKE'
                        gw.handshakePartner = a.value;
                        gw.radio.setLock(a.value, WSN_Config.HandshakeTimeout);
                        gw.addLogBackbone(sprintf('t=%d [HANDSHAKE] Lock set with %s (timer=%d)', ...
                            t, dec2hex(uint16(a.value), 4), WSN_Config.HandshakeTimeout), [], t);

                    case 'MARK_CHILD'
                        if ~ismember(a.value, gw.children)
                            gw.children(end+1) = a.value;
                            gw.addLogBackbone(sprintf('t=%d [CHILD] Added GWN child %s (total: %d)', ...
                                t, dec2hex(uint16(a.value), 4), numel(gw.children)), [], t);
                        end

                    case 'REJECT_NEIGHBOR'
                        idx = find([gw.neighborTable.id]==a.value,1);
                        if ~isempty(idx)
                            gw.neighborTable(idx).status = gw.ST_REJECT;
                            gw.addLogBackbone(sprintf('t=%d [REJECT] Neighbor %s marked REJECT', ...
                                t, dec2hex(uint16(a.value), 4)), [], t);
                        end

                    case 'RESET_PROSPECTS'
                        idx = find([gw.neighborTable.status]==gw.ST_PROSP);
                        if ~isempty(idx)
                            [gw.neighborTable(idx).status] = deal(gw.ST_NONE);
                            gw.addLogBackbone(sprintf('t=%d [PROSPECT] Reset %d prospects to NONE', ...
                                t, numel(idx)), [], t);
                        end
                        gw.candidatePtr = 1;
                        gw.crazyTimer   = WSN_Config.CrazyDuration_Neighbor;
                        
                    case 'CLEAR_HANDSHAKE'
                        clearedPartner = gw.handshakePartner;
                        gw.handshakePartner = [];
                        gw.radio.clearLock('COMPLETE');
                        
                        if ~isempty(clearedPartner)
                            gw.addLogBackbone(sprintf('t=%d [HANDSHAKE] Lock cleared (was with %s)', ...
                                t, dec2hex(uint16(clearedPartner), 4)), [], t);
                        end

                        % Reset retry state if:
                        % (a) handshake succeeded (retryTarget is now a child)
                        % (b) retry target is marked ST_REJECT (rejection received at any point)
                        % (c) max retries exhausted
                        shouldResetRetry = false;
                        resetReason = '';
                        
                        % Check if retry target is now a child (success case)
                        if ~isempty(obj.retryTarget) && ismember(obj.retryTarget, gw.children)
                            shouldResetRetry = true;
                            resetReason = 'now child';
                        end
                        
                        % Check if retry target was rejected (any retry count)
                        if ~isempty(obj.retryTarget)
                            idx = find([gw.neighborTable.id] == obj.retryTarget, 1);
                            if ~isempty(idx) && gw.neighborTable(idx).status == gw.ST_REJECT
                                shouldResetRetry = true;
                                resetReason = 'rejected';
                            end
                        end
                        
                        % Check if max retries exhausted
                        if ~isempty(obj.retryTarget) && obj.retryCount >= WSN_Config.MAX_RETRIES
                            shouldResetRetry = true;
                            resetReason = sprintf('max retries (%d)', WSN_Config.MAX_RETRIES);
                            % Mark the exhausted target as rejected to prevent future retries
                            idx = find([gw.neighborTable.id] == obj.retryTarget, 1);
                            if ~isempty(idx)
                                gw.neighborTable(idx).status = gw.ST_REJECT;
                            end
                        end
                        
                        if shouldResetRetry
                            oldTarget = obj.retryTarget;
                            obj.retryTarget  = [];
                            obj.retryCount   = 0;
                            obj.retryBackoff = 0;
                            if ~isempty(oldTarget)
                                gw.addLogBackbone(sprintf('t=%d [RETRY] Reset retry state for %s (%s)', ...
                                    t, dec2hex(uint16(oldTarget), 4), resetReason), [], t);
                            end
                        end

                    case 'RESET_TIMER'
                        if ~isempty(gw.handshakePartner)
                            gw.radio.setLock(gw.handshakePartner, WSN_Config.HandshakeTimeout);
                        end

                end
            end
        end
    end
    
end
