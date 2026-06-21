%   % Suppress unused variable warnings - defensive initializations
%   % Suppress unused input argument warnings - API consistency
classdef WSN_ClusterHead < WSN_Node
    properties
        % --- FSM STATE ---
        state = WSN_Config.STATE_BOOT  % BOOT -> DISCOVERY -> HANDSHAKE -> SECURE
        isVerified = false             % Verified after KEY_ACK exchange
        localKey = []                  % Local key received from GWN (empty if parent is CH)
        
        % --- RECRUITMENT STATE ---
        retryTarget = []               % Current GWN being recruited
        retryCount = 0                 % Attempts so far for current target
        rejectedGWNs = []              % List of GWNs that rejected/timed out
        handshakePartner = []          % Lock partner during handshake
        isQualifiedToRecruit = false   % Can recruit other CHs (true only when GWN-anchored -- caps CH-CH chains at one hop)
        rejectedCHs = []               % List of CHs that rejected
        retryBackoff = 0               % Randomized backoff timer (2-5 timeframes)
        lastRejectResetTime = 0        % Last time rejectedGWNs/rejectedCHs were cleared

        % --- SENSOR DATA AGGREGATION ---
        sensorTable = struct('id',{}, 'lastTime',{}, 'value',{}, 'rssi',{}, 'battery',{})
        aggPeriod = 0                  % Fixed random period 7-10 TFs (set after verification)
        nextAggTX = 0                  % Next scheduled 5.2 TX time
        pendingAgg = []                % Pending 5.2 message awaiting ACK
        pendingAggSeq = 0              % Sequence number of pending 5.2
        aggRetryCount = 0              % Retry count for pending 5.2
        lastAggRetryTime = 0           % Last retry time for 5.2
        pendingFragments = []          % Array of fragment indices awaiting ACK
        
        % --- PANIC QUEUE (High Priority) ---
        panicQueue = []                % Queue of panic messages to forward (priority)
        seenPanicUIDs = []             % UIDs of already-processed panic messages

        % --- TRUST (ML_IDS_PLAN.md Phase 4) ---
        neighborTrust = struct('id',{}, 'score',{})  % Trust scores per neighbor

        % --- ML-IDS CENSUS PROTOCOL (ML_IDS_PLAN.md Phase 4) ---
        censusActivePolls = struct('pollUID',{}, 'suspectID',{}, 'startTick',{}, 'yesCount',{}, 'totalVoters',{}, 'voterIDs',{})
        censusSeenPolls = []
        resetHistory = struct('id',{}, 'softCount',{}, 'hardCount',{})  % escalation history for direct children

        % -------- DORMANT: TRUST-BASED DECISION MATRIX (not yet active) --------
        % Reserved hooks for a future composite trust/decision engine layered
        % on top of neighborTrust. Inert until wired up - see
        % WSN_ClusterHead_Enforcement.evaluateTrustDecision/buildTrustMatrix
        % (CH/Enforcement/WSN_ClusterHead_Enforcement.m).
        trustDecisionMatrix = []          % future: composite per-neighbor decision matrix
        trustDecisionPolicy = 'PASSIVE'   % future: 'PASSIVE' | 'ACTIVE' enforcement mode
        trustDecisionWeights = struct('packetSuccess', 1.0, 'censusVote', 0, 'neighborCorroboration', 0)
    end
    
    methods
        function obj = WSN_ClusterHead(id, pos)
            if nargin == 0, id=0; pos=[0 0]; end
            obj@WSN_Node(id, pos, WSN_Config.TIER_CH);
            obj.typeStr = 'CH';
            obj.txPower = WSN_Config.TxPower_CH;
            obj.state = WSN_Config.STATE_BOOT;
        end
        
        function updatePhysics(obj, ~)
            if obj.battery <= 0, obj.isAwake = false; return; end
            % CHs do NOT sleep - always awake with idle cost
            obj.isAwake = true;
            obj.battery = max(0, obj.battery - WSN_Config.IdleCost);
        end
        
        function msgs = step(obj, t, ~, ~)
            msgs = [];
            if obj.isBlacklisted, return; end

            % --- ML-IDS CENSUS: trigger polls / finalize timed-out polls ---
            censusMsgs = obj.checkCensusTriggers(t);
            if ~isempty(censusMsgs), msgs = [msgs, censusMsgs]; end

            % === ATTACK: FLOODING (Hello Flood) ===
            % Malicious CH broadcasts excessive ADV-CH messages with inflated TX power
            if WSN_Attack.isMaliciousNode(obj.id) && ...
               WSN_Attack.getAttackType(obj.id) == WSN_Attack.ATTACK_FLOODING
                floodCount = WSN_Attack.getFloodingBurstCount(obj.id, t);
                if floodCount > 0
                    % Temporarily inflate TX power for flooding
                    originalPower = obj.txPower;
                    obj.txPower = WSN_Attack.getFloodingTxPower(obj.id);
                    
                    % Broadcast multiple ADV-CH messages
                    for fi = 1:floodCount
                        floodMsg = obj.createHelloMessage(t);
                        floodMsg.uid = randi(1e9);  % Unique ID per flood message
                        msgs = [msgs, floodMsg];
                        obj.addLog(sprintf('t=%d [HELLO_TX] bat=%d%% nbr=%d', ...
                            t, uint8(obj.battery), numel(obj.neighborTable)));
                    end
                    
                    % Restore original power
                    obj.txPower = originalPower;
                end
            end
            
            % === ATTACK: PANIC FLOOD (Sinkhole Variant) ===
            % Malicious node broadcasts fake emergency alerts with inflated route metrics
            if WSN_Attack.isMaliciousNode(obj.id) && ...
               WSN_Attack.getAttackType(obj.id) == WSN_Attack.ATTACK_PANIC_FLOOD
                if WSN_Attack.shouldPanicFlood(obj.id, t)
                    panicMsg = WSN_Attack.createFakePanicBeacon(obj.id, obj.hexID, t);
                    if ~isempty(panicMsg)
                        msgs = [msgs, panicMsg];
                        obj.addLog(sprintf('t=%d [PANIC_TX] type=%d sev=%d', ...
                            t, panicMsg.subtype, 2));
                    end
                end
            end
            
            % === ATTACK: DENIAL OF SLEEP ===
            % Send spurious packets to prevent target nodes from sleeping
            if WSN_Attack.isMaliciousNode(obj.id) && ...
               WSN_Attack.getAttackType(obj.id) == WSN_Attack.ATTACK_DENIAL_SLEEP
                targets = WSN_Attack.getDenialOfSleepTargets(obj.id, obj.neighborTable, t);
                for ti = 1:numel(targets)
                    spamMsg = WSN_Attack.createSpuriousPacket(hex2dec(obj.hexID), targets(ti), t);
                    msgs = [msgs, spamMsg];
                    obj.addLog(sprintf('t=%d [TX] type=%d.%d -> %s', ...
                        t, spamMsg.type, spamMsg.subtype, dec2hex(uint16(targets(ti)), 4)));
                    % Track for double-line visual
                    WSN_Attack.addDoSTarget(obj.id, targets(ti), t + 5);
                end
            end
            
            % --- PHASE 2: HELLO BURST ---
            if t >= 0 && t == obj.nextHelloBurst
                helloMsg = obj.createHelloMessage(t);
                msgs = [msgs, helloMsg];
                obj.addLog(sprintf('t=%d [HELLO_TX] bat=%d%% nbr=%d', ...
                    t, uint8(obj.battery), numel(obj.neighborTable)));
                obj.scheduleNextHelloBurst(t);
            end
            
            % --- HANDSHAKE TIMEOUT CHECK ---
            if obj.state == WSN_Config.STATE_HANDSHAKE && ~isempty(obj.handshakePartner)
                obj.radio.lockTimer = obj.radio.lockTimer - 1;
                if obj.radio.lockTimer <= 0
                    obj.radio.timeout();
                    rejectMsg = obj.handleTimeout(t);
                    if ~isempty(rejectMsg)
                        msgs = [msgs, rejectMsg];
                    end
                    return;
                end
            end
            
            % --- SENSOR AGGREGATION (5.2) ---
            if obj.isVerified && t >= WSN_Config.SENSOR_START_TIME
                aggMsgs = obj.processSensorAggregation(t);
                msgs = [msgs, aggMsgs];
            end
            
            % --- CH RECRUITMENT FSM (after SetupTime) ---
            if t < WSN_Config.SetupTime
                return;
            end
            
            % Already verified - nothing to do
            if obj.isVerified
                return;
            end

            % Respect backoff timer if set and no active retry
            if obj.retryBackoff > 0 && isempty(obj.retryTarget)
                obj.retryBackoff = obj.retryBackoff - 1;
                return;
            end

            % Periodically forgive old rejections/timeouts -- a neighbor
            % rejected early (e.g. busy with another handshake) may be a
            % perfectly good target later. Without this, rejectedGWNs/
            % rejectedCHs only grow, and a CH with few nearby neighbors
            % could exhaust all of them permanently.
            if isempty(obj.retryTarget) && t >= obj.lastRejectResetTime + WSN_Config.CH_REJECTED_LIST_RESET_INTERVAL
                obj.rejectedGWNs = [];
                obj.rejectedCHs = [];
                obj.lastRejectResetTime = t;
            end

            switch obj.state
                case WSN_Config.STATE_BOOT
                    % Transition to DISCOVERY after SetupTime
                    obj.state = WSN_Config.STATE_DISCOVERY;
                    obj.addLog(sprintf('t=%d [STATE] BOOT->DISCOVERY', t));
                    
                case WSN_Config.STATE_DISCOVERY
                    % Find closest verified GWN
                    target = obj.findBestVerifiedGWN();
                    if isempty(target)
                        return;  % No verified GWN available yet
                    end
                    
                    % Start recruitment
                    obj.retryTarget = target;
                    obj.retryCount = 0;
                    obj.state = WSN_Config.STATE_SECURE;
                    obj.addLog(sprintf('t=%d [DISCO] Found verified GWN %s', t, dec2hex(uint16(target), 4)));
                    
                case WSN_Config.STATE_SECURE
                    % Cannot recruit while locked
                    if ~isempty(obj.handshakePartner)
                        return;
                    end

                    % First, try GWNs
                    if isempty(obj.retryTarget)
                        target = obj.findBestVerifiedGWN();
                        if isempty(target)
                            % No more GWNs, try CHs (only GWN-anchored CHs
                            % accept recruits -- see handleCHREQ)
                            target = obj.findBestVerifiedCH();
                            if isempty(target)
                                % No candidate visible yet. Don't give up --
                                % just wait: neighborTable keeps updating from
                                % HELLO reception every tick regardless of
                                % state, so the next verified GWN/CH to come
                                % into range (or get verified) is picked up
                                % automatically next tick.
                                return;
                            end
                        end
                        obj.retryTarget = target;
                        obj.retryCount = 0;
                    end

                    % CHECK MAX_RETRIES before sending
                    if obj.retryCount >= WSN_Config.CH_MAX_RETRIES
                        obj.addLog(sprintf('t=%d [REJECT] %s MAX_RETRIES=%d', ...
                            t, dec2hex(uint16(obj.retryTarget), 4), WSN_Config.CH_MAX_RETRIES));
                        % ML-IDS: target never responded -- distrust it (catches unresponsive/fake nodes)
                        obj.updateNeighborTrust(obj.retryTarget, -WSN_Config.TRUST_DELTA_FAIL_HARD);
                        % Add to rejected list based on tier
                        targetTier = obj.getNeighborTier(obj.retryTarget);
                        if targetTier == WSN_Config.TIER_GWN
                            obj.rejectedGWNs = [obj.rejectedGWNs, obj.retryTarget];
                        elseif targetTier == WSN_Config.TIER_CH
                            obj.rejectedCHs = [obj.rejectedCHs, obj.retryTarget];
                        end
                        obj.retryTarget = [];
                        obj.retryCount = 0;
                        % Set random backoff before next recruitment attempt
                        obj.retryBackoff = randi([2 5]);
                        return;
                    end

                    % Increment retry count BEFORE sending
                    obj.retryCount = obj.retryCount + 1;

                    % Send CH_REQ
                    reqMsg = obj.createCHREQ(obj.retryTarget, t);
                    msgs = [msgs, reqMsg];

                    % Enter lock on Access radio
                    obj.handshakePartner = obj.retryTarget;
                    obj.radio.setLock(obj.retryTarget, WSN_Config.CH_ACCESS_LOCK_TIMER);

                    obj.addLog(sprintf('t=%d [CH_REQ] (%d/%d) -> %s', ...
                        t, obj.retryCount, WSN_Config.CH_MAX_RETRIES, ...
                        dec2hex(uint16(obj.retryTarget), 4)));

                    obj.state = WSN_Config.STATE_HANDSHAKE;
                    
                case WSN_Config.STATE_HANDSHAKE
                    % Just wait for response or timeout (handled above)
            end
        end
        
        function response = receive(obj, msg, t, rssi)
            response = [];
            if obj.isBlacklisted, return; end

            myID = hex2dec(obj.hexID);
            dst = msg.dst;
            isBroadcast = isempty(dst) || dst == 0 || dst == hex2dec('FFFF');
            isForMe = (dst == myID);

            % --- HELLO MESSAGE (Type 0) - Always process broadcasts ---
            if msg.type == 0 && isBroadcast && msg.verifyChecksum()
                obj.handleHelloReception(msg, t, rssi);
                return;
            end

            % --- ML-IDS CENSUS (Type 11) ---
            if msg.type == WSN_Config.MSG_TYPE_CENSUS && msg.verifyChecksum()
                response = obj.handleCensusMessage(msg, t);
                return;
            end

            % --- ML-IDS SHUTDOWN (Type 12) ---
            if msg.type == WSN_Config.MSG_TYPE_SHUTDOWN && isForMe && msg.verifyChecksum()
                obj.handleShutdownMessage(msg, t);
                return;
            end

            % --- PANIC MESSAGE (Type 2) - HIGH PRIORITY ---
            if msg.type == WSN_Config.MSG_TYPE_PANIC && msg.verifyChecksum()
                if isBroadcast || isForMe
                    response = obj.handlePanicMessage(msg, t, rssi);
                    return;
                end
            end
            
            % --- SENSOR DATA (Type 1) - Process if for me ---
            if msg.type == WSN_Config.MSG_TYPE_SENSOR && isForMe && msg.verifyChecksum()
                obj.handleSensorData(msg, t, rssi);
                return;
            end
            
            % --- CH_HELLO (Type 5) - Handle 5.2 and 5.3 ---
            if msg.type == WSN_Config.MSG_TYPE_CH_HELLO && isForMe && msg.verifyChecksum()
                if msg.subtype == WSN_Config.SENSOR_SUB_AGG  % 5.2 SENSOR_AGG from child CH
                    response = obj.handleSensorAgg(msg, t, rssi);
                    return;
                elseif msg.subtype == WSN_Config.SENSOR_SUB_ACK  % 5.3 CH_ACK
                    obj.handleAggACK(msg, t);
                    return;
                end
            end
            
            % --- CH_CMD (Type 6) - Process if for me ---
            if msg.type == WSN_Config.MSG_TYPE_CH_CMD && isForMe && msg.verifyChecksum()
                response = obj.handleCHCMD(msg, t, rssi);
                return;
            end
        end
        
        function response = handleCHCMD(obj, msg, t, ~)
            response = [];
            
            switch msg.subtype
                case WSN_Config.CH_SUB_REQ     % 6.0 CH_REQ
                    response = obj.handleCHREQ(msg, t);
                    
                case WSN_Config.CH_SUB_ACK     % 6.1 CH_ACK from GWN
                    obj.handleCHACK(msg, t);
                    
                case WSN_Config.CH_SUB_JOINOK  % 6.4 CH_JOINOK from CH
                    obj.handleCHJOINOK(msg, t);
                    
                case WSN_Config.CH_SUB_REJECT  % 6.3 CH_REJECT from GWN or CH
                    obj.handleCHREJECT(msg, t);
                    
                case WSN_Config.CH_SUB_INFO    % 6.5 CH_INFO
                    obj.handle_CH_INFO(msg, t);
            end
        end
        
        function response = handleCHREQ(obj, msg, t)
            % 6.0 CH_REQ: CH wants to join this CH
            % Response: 6.4 CH_JOINOK if qualified, else 6.3 CH_REJECT
            response = [];
            sender = msg.src;
            
            % Only GWN-anchored CHs may recruit further CHs -- caps every
            % CH-CH chain at one hop (orphan-CH -> relay-CH -> GWN), instead
            % of the relay-CH itself being recruited through and extending
            % the chain indefinitely.
            if ~obj.isQualifiedToRecruit
                obj.addLog(sprintf('t=%d [CH_REJECT] %s (not qualified to recruit -- not GWN-anchored)', ...
                    t, dec2hex(uint16(sender), 4)));
                response = obj.createCHREJECT(sender, t);
                return;
            end
            
            % Check if already locked with another partner (Access radio)
            if ~isempty(obj.handshakePartner) && obj.handshakePartner ~= sender
                obj.addLog(sprintf('t=%d [CH_REJECT] %s (locked with %s)', ...
                    t, dec2hex(uint16(sender), 4), dec2hex(uint16(obj.handshakePartner), 4)));
                response = obj.createCHREJECT(sender, t);
                return;
            end
            
            % Accept CH: Enter Access radio lock and send CH_JOINOK
            obj.radio.setLock(sender, WSN_Config.CH_ACCESS_LOCK_TIMER);
            
            obj.addLog(sprintf('t=%d [CH_JOINOK] -> %s', ...
                t, dec2hex(uint16(sender), 4)));
            
            response = obj.createCHJOINOK(sender, t);
            
            % Add the recruited CH to children
            obj.children = [obj.children, sender];
            obj.addLog(sprintf('t=%d [CHILD_ADDED] %s', t, dec2hex(uint16(sender), 4)));
            
            % Send 6.5 CH_INFO to parent GWN (encrypted)
            if ~isempty(obj.parent)
                infoMsg = obj.createCHINFO(sender, t);
                obj.radio.requestTX(infoMsg);  % Send immediately
                obj.addLog(sprintf('t=%d [CH_INFO] -> parent %s (recruited %s)', ...
                    t, dec2hex(uint16(obj.parent), 4), dec2hex(uint16(sender), 4)));
            end
        end
        
        function handleCHJOINOK(obj, msg, t)
            % 6.4 CH_JOINOK: CH→CH join acceptance
            sender = msg.src;
            
            % Validate we're expecting this
            if obj.state ~= WSN_Config.STATE_HANDSHAKE || sender ~= obj.handshakePartner
                obj.addLog(sprintf('t=%d [IGNORE] CH_JOINOK from %s (not partner)', ...
                    t, dec2hex(uint16(sender), 4)));
                return;
            end
            
            obj.addLog(sprintf('t=%d [CH_JOINOK] from %s', ...
                t, dec2hex(uint16(sender), 4)));
            
            % Clear lock and mark verified
            obj.radio.clearLock('SUCCESS');
            obj.handshakePartner = [];
            obj.parent = sender;
            % Note: localKey stays empty - no key exchange in CH-CH
            obj.isVerified = true;
            obj.isQualifiedToRecruit = false;  % Not GWN-anchored -- cannot recruit further (one CH-CH hop max)
            obj.state = WSN_Config.STATE_SECURE;
            obj.retryTarget = [];
            obj.retryCount = 0;
            
            obj.addLog(sprintf('t=%d [VERIFIED] parent=CH %s (no localKey, unencrypted comms)', ...
                t, dec2hex(uint16(obj.parent), 4)));
        end
                function handle_CH_INFO(obj, msg, t)
            % 6.5 CH_INFO: Forward to parent
            if isempty(obj.parent)
                obj.addLog(sprintf('t=%d [DROP] CH_INFO - no parent', t));
                return;
            end
            
            % Forward the message to parent
            fwd = WSN_Message(6, hex2dec(obj.hexID), obj.parent, msg.payload);
            fwd.subtype = WSN_Config.CH_SUB_INFO;
            fwd.flag = msg.flag;  % Preserve encryption flags
            fwd.addChecksum();
            
            obj.radio.requestTX(fwd);
            obj.addLog(sprintf('t=%d [CH_INFO_FWD] -> parent %s', t, dec2hex(uint16(obj.parent), 4)));
        end
                function handleCHACK(obj, msg, t)
            % 6.1 CH_ACK: GWN→CH with local key in payload
            sender = msg.src;
            
            % Validate we're expecting this
            if obj.state ~= WSN_Config.STATE_HANDSHAKE || sender ~= obj.handshakePartner
                obj.addLog(sprintf('t=%d [IGNORE] CH_ACK from %s (not partner)', ...
                    t, dec2hex(uint16(sender), 4)));
                return;
            end
            
            % Extract local key from payload (first 16 bytes)
            if msg.payloadLen >= 16
                obj.localKey = msg.payload(1:16);
            else
                obj.addLog(sprintf('t=%d [ERROR] CH_ACK missing key payload', t));
                return;
            end
            
            obj.addLog(sprintf('t=%d [CH_ACK] Received key from %s', ...
                t, dec2hex(uint16(sender), 4)));
            
            % Refresh lock
            obj.radio.refreshLock(WSN_Config.CH_ACCESS_LOCK_TIMER);
            
            % Send 6.2 KEY_ACK encrypted in local key
            keyAckMsg = obj.createKEY_ACK(sender, t);
            obj.radio.requestTX(keyAckMsg);
            
            obj.addLog(sprintf('t=%d [KEY_ACK] -> %s (encrypted)', ...
                t, dec2hex(uint16(sender), 4)));
            
            % Clear lock and mark verified
            obj.radio.clearLock('SUCCESS');
            obj.handshakePartner = [];
            obj.parent = sender;
            % localKey was set earlier from CH_ACK payload - enables encrypted comms
            obj.isVerified = true;
            obj.isQualifiedToRecruit = true;  % Now qualified to recruit other CHs
            obj.state = WSN_Config.STATE_SECURE;
            obj.retryTarget = [];
            obj.retryCount = 0;
            
            obj.addLog(sprintf('t=%d [VERIFIED] parent=GWN %s (localKey set, encrypted comms)', ...
                t, dec2hex(uint16(obj.parent), 4)));
        end
        
        function handleCHREJECT(obj, msg, t)
            % 6.3 CH_REJECT: Move to next viable target
            sender = msg.src;
            
            obj.addLog(sprintf('t=%d [CH_REJECT] from %s', ...
                t, dec2hex(uint16(sender), 4)));
            
            % PURGE: If sender was our parent, clear it and purge local key
            if ~isempty(obj.parent) && obj.parent == sender
                obj.addLog(sprintf('t=%d [PURGE] parent %s (rejected)', t, dec2hex(uint16(sender),4)));
                obj.parent = [];
                obj.isVerified = false;
                obj.isQualifiedToRecruit = false;
                obj.localKey = [];  % Purge local key on rejection
            end
            
            % PURGE: If sender was a child, remove them
            if isprop(obj, 'children') && ~isempty(obj.children)
                obj.children(obj.children == sender) = [];
            end
            
            % Clear lock
            obj.radio.clearLock('REJECT');
            obj.handshakePartner = [];
            
            % Add to rejected list based on tier
            senderTier = obj.getNeighborTier(sender);
            if senderTier == WSN_Config.TIER_GWN
                obj.rejectedGWNs = [obj.rejectedGWNs, sender];
            elseif senderTier == WSN_Config.TIER_CH
                obj.rejectedCHs = [obj.rejectedCHs, sender];
            end
            
            obj.retryTarget = [];
            obj.retryCount = 0;
            obj.state = WSN_Config.STATE_SECURE;  % Will find new target next tick
        end
        
        function rejectMsg = handleTimeout(obj, t)
            % Handshake timed out - send CH_REJECT and purge (like GWN PARENT_REJECT)
            timedOutPartner = obj.handshakePartner;
            rejectMsg = [];
            
            obj.addLog(sprintf('t=%d [TIMEOUT] partner=%s retry=%d/%d', ...
                t, dec2hex(uint16(timedOutPartner), 4), ...
                obj.retryCount, WSN_Config.CH_MAX_RETRIES));
            
            % ORPHAN GUARD: Send CH_REJECT to notify partner they're not connected
            if ~isempty(timedOutPartner)
                rejectMsg = WSN_Message();
                rejectMsg.type = WSN_Config.MSG_TYPE_CH_CMD;
                rejectMsg.subtype = WSN_Config.CH_SUB_REJECT;  % 6.3
                rejectMsg.src = hex2dec(obj.hexID);
                rejectMsg.dst = timedOutPartner;
                rejectMsg.ttl = 1;
                rejectMsg.addChecksum();
                obj.addLog(sprintf('t=%d [TIMEOUT] Sent CH_REJECT to orphaned %s', ...
                    t, dec2hex(uint16(timedOutPartner), 4)));
            end

            obj.radio.clearLock('TIMEOUT');
            obj.handshakePartner = [];
            % Set random backoff before retrying same target
            obj.retryBackoff = randi([2 5]);
            obj.state = WSN_Config.STATE_SECURE;  % Will retry in SECURE
        end
        
        function target = findBestVerifiedGWN(obj)
            % Find closest verified GWN not in rejected list
            target = [];
            if isempty(obj.neighborTable), return; end
            
            % Filter: tier=3 (GWN), isVerified=true, not rejected
            candidates = obj.neighborTable;
            validIdx = ([candidates.tier] == WSN_Config.TIER_GWN) & ...
                       ([candidates.isVerified] == true);
            
            if ~isempty(obj.rejectedGWNs)
                validIdx = validIdx & ~ismember([candidates.id], obj.rejectedGWNs);
            end
            
            candidates = candidates(validIdx);
            if isempty(candidates), return; end
            
            % Sort by RSSI (descending) - closest/strongest first
            [~, ord] = sort([candidates.rssi], 'descend');
            target = candidates(ord(1)).id;
        end
        
        function target = findBestVerifiedCH(obj)
            % Find closest verified CH not in rejected list
            target = [];
            if isempty(obj.neighborTable), return; end
            
            % Filter: tier=2 (CH), isVerified=true, not rejected
            candidates = obj.neighborTable;
            validIdx = ([candidates.tier] == WSN_Config.TIER_CH) & ...
                       ([candidates.isVerified] == true);
            
            if ~isempty(obj.rejectedCHs)
                validIdx = validIdx & ~ismember([candidates.id], obj.rejectedCHs);
            end
            
            candidates = candidates(validIdx);
            if isempty(candidates), return; end
            
            % Sort by RSSI (descending) - closest/strongest first
            [~, ord] = sort([candidates.rssi], 'descend');
            target = candidates(ord(1)).id;
        end
        
        function tier = getNeighborTier(obj, id)
            % Get tier of neighbor by ID
            idx = find([obj.neighborTable.id] == id, 1);
            if isempty(idx)
                tier = 0;
            else
                tier = obj.neighborTable(idx).tier;
            end
        end
        
        function msg = createCHREQ(obj, dst, t)
            % Create 6.0 CH_REQ message
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_CMD;
            msg.subtype = WSN_Config.CH_SUB_REQ;  % 0
            msg.src = hex2dec(obj.hexID);
            msg.dst = dst;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            msg.flag = 0;
            msg.payloadLen = 0;
            msg.payload = [];
            msg.addChecksum();
        end
        
        function msg = createKEY_ACK(obj, dst, t)
            % Create 6.2 KEY_ACK message (encrypted in local key)
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_CMD;
            msg.subtype = WSN_Config.CH_SUB_KEY_ACK;  % 2
            msg.src = hex2dec(obj.hexID);
            msg.dst = dst;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            msg.flag = bitset(0, 1, 1);  % Encrypted flag
            % Payload: simple ACK (could add more data)
            msg.payload = obj.localKey;  % Echo key as confirmation
            msg.payloadLen = numel(msg.payload);
            msg.addChecksum();
        end
        
        function msg = createCHREJECT(obj, dst, t)
            % Create 6.3 CH_REJECT message
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_CMD;
            msg.subtype = WSN_Config.CH_SUB_REJECT;  % 3
            msg.src = hex2dec(obj.hexID);
            msg.dst = dst;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            msg.flag = 0;
            msg.payloadLen = 0;
            msg.payload = [];
            msg.addChecksum();
        end
        
        function msg = createCHJOINOK(obj, dst, t)
            % Create 6.4 CH_JOINOK message
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_CMD;
            msg.subtype = WSN_Config.CH_SUB_JOINOK;  % 4
            msg.src = hex2dec(obj.hexID);
            msg.dst = dst;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            msg.flag = 0;
            msg.payloadLen = 0;
            msg.payload = [];
            msg.addChecksum();
        end
        
        function msg = createCHINFO(obj, recruitedID, t)
            % Create 6.5 CH_INFO message to parent
            % Payload: {Recruited CH ID, Parent CH ID} encrypted if local key available
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_CMD;
            msg.subtype = WSN_Config.CH_SUB_INFO;  % 5
            msg.src = hex2dec(obj.hexID);
            msg.dst = obj.parent;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            
            % Payload: Recruited ID (2), Parent ID (2)
            plainPayload = [typecast(uint16(recruitedID), 'uint8'), ...
                            typecast(uint16(hex2dec(obj.hexID)), 'uint8')];
            
            % Encrypt with local key if available
            if ~isempty(obj.localKey)
                msg.payload = obj.encryptPayload(plainPayload, obj.localKey);
                msg.flag = bitset(0, 1, 1);  % Encrypted flag
            else
                msg.payload = plainPayload;
                msg.flag = 0;  % Not encrypted
            end
            msg.payloadLen = numel(msg.payload);
            msg.addChecksum();
        end
        
        function handleHelloReception(obj, msg, t, rssi)
            % Populate neighbor table from Hello message
            sender = msg.src;
            idx = find([obj.neighborTable.id] == sender, 1);
            
            % Extract tier, battery, neighborCount from Hello payload
            if msg.payloadLen >= 2
                [tier, battery, neighborCount] = msg.getHelloPayload();
            else
                tier = 0; battery = 0; neighborCount = 0;
            end
            
            % Extract verified status from message flag
            senderVerified = msg.isVerified();
            
            % Ensure isVerified field exists in neighbor table
            if ~isempty(obj.neighborTable) && ~isfield(obj.neighborTable, 'isVerified')
                [obj.neighborTable.isVerified] = deal(false);
            end
            
            if isempty(idx)
                obj.neighborTable(end+1) = struct( ...
                    'id', sender, 'lastSeen', t, 'rssi', rssi, ...
                    'TrustScore', 50, 'commRange', 0, 'status', 0, ...
                    'tier', tier, 'battery', battery, 'neighborCount', neighborCount, ...
                    'isVerified', senderVerified);
                % Local log only for NEW neighbors
                obj.addLog(sprintf('t=%d [HELLO] NEW %s tier=%d verified=%d', ...
                    t, dec2hex(uint16(sender),4), tier, senderVerified));
            else
                % Silent update - no log for updates
                obj.neighborTable(idx).lastSeen = t;
                obj.neighborTable(idx).rssi = rssi;
                obj.neighborTable(idx).tier = tier;
                obj.neighborTable(idx).battery = battery;
                obj.neighborTable(idx).neighborCount = neighborCount;
                obj.neighborTable(idx).isVerified = senderVerified;
            end
        end
        
        function encrypted = encryptPayload(obj, payload, key)
            % Simple XOR encryption with key (repeated as needed)
            encrypted = payload;
            for i = 1:numel(payload)
                keyIdx = mod(i-1, numel(key)) + 1;
                encrypted(i) = bitxor(payload(i), key(keyIdx));
            end
        end

        % =====================================================
        % TRUST (ML_IDS_PLAN.md Phase 4) - per-neighbor rule-based score
        % Delegates to WSN_ClusterHead_Enforcement (CH/Enforcement/)
        % =====================================================
        function score = getNeighborTrust(obj, neighborID)
            score = WSN_ClusterHead_Enforcement.getNeighborTrust(obj, neighborID);
        end

        function updateNeighborTrust(obj, neighborID, delta)
            WSN_ClusterHead_Enforcement.updateNeighborTrust(obj, neighborID, delta);
        end

        % =====================================================
        % ML-IDS CENSUS / SHUTDOWN PROTOCOL (ML_IDS_PLAN.md Phase 4)
        % Delegates to WSN_ClusterHead_Enforcement (CH/Enforcement/)
        % =====================================================
        function msgs = checkCensusTriggers(obj, t)
            msgs = WSN_ClusterHead_Enforcement.checkCensusTriggers(obj, t);
        end

        function response = handleCensusMessage(obj, msg, t)
            response = WSN_ClusterHead_Enforcement.handleCensusMessage(obj, msg, t);
        end

        function response = handlePollComplete(obj, msg, t)
            response = WSN_ClusterHead_Enforcement.handlePollComplete(obj, msg, t);
        end

        function handleShutdownMessage(obj, msg, t)
            WSN_ClusterHead_Enforcement.handleShutdownMessage(obj, msg, t);
        end

        function verdict = evaluateTrustDecision(obj, neighborID)
            % DORMANT: see WSN_ClusterHead_Enforcement.evaluateTrustDecision
            % - not yet wired into any active call path.
            verdict = WSN_ClusterHead_Enforcement.evaluateTrustDecision(obj, neighborID);
        end

        function matrix = buildTrustMatrix(obj)
            % DORMANT: see WSN_ClusterHead_Enforcement.buildTrustMatrix - not
            % yet wired into any active call path.
            matrix = WSN_ClusterHead_Enforcement.buildTrustMatrix(obj);
        end

        % =========================================================
        % SENSOR DATA HANDLING (inbound) - Delegates to
        % WSN_ClusterHead_Registry (CH/Registry/)
        % =========================================================

        function handleSensorData(obj, msg, t, rssi)
            WSN_ClusterHead_Registry.handleSensorData(obj, msg, t, rssi);
        end

        function msgs = processSensorAggregation(obj, t)
            msgs = WSN_ClusterHead_Registry.processSensorAggregation(obj, t);
        end

        function response = handleSensorAgg(obj, msg, t, rssi)
            response = WSN_ClusterHead_Registry.handleSensorAgg(obj, msg, t, rssi);
        end

        function mergeSensorAgg(obj, msg, t, rssi)
            WSN_ClusterHead_Registry.mergeSensorAgg(obj, msg, t, rssi);
        end

        % =========================================================
        % SENSOR DATA EXPORT (outbound 5.2/5.3) - Delegates to
        % WSN_ClusterHead_FeatureExport (CH/FeatureExport/)
        % =========================================================

        function msgs = createSensorAgg(obj, t)
            msgs = WSN_ClusterHead_FeatureExport.createSensorAgg(obj, t);
        end

        function handleAggACK(obj, msg, t)
            WSN_ClusterHead_FeatureExport.handleAggACK(obj, msg, t);
        end

        function msg = createAggACK(obj, dst, seq, t, fragIdx, totalFrags)
            if nargin < 5
                fragIdx = [];
                totalFrags = [];
            end
            msg = WSN_ClusterHead_FeatureExport.createAggACK(obj, dst, seq, t, fragIdx, totalFrags);
        end
        
        % =====================================================
        % PANIC MESSAGE HANDLING (Type 2) - HIGH PRIORITY
        % =====================================================
        function response = handlePanicMessage(obj, msg, t, rssi)
            % Handle incoming panic message with high priority
            % CHs aggregate panic information and forward to parent/sink
            response = [];
            sender = msg.src;
            
            % Check if already seen this panic (deduplication by UID)
            if ismember(msg.uid, obj.seenPanicUIDs)
                return;  % Already processed
            end
            obj.seenPanicUIDs = [obj.seenPanicUIDs, msg.uid];
            
            % Prune old UIDs (keep last 100)
            if numel(obj.seenPanicUIDs) > 100
                obj.seenPanicUIDs = obj.seenPanicUIDs(end-99:end);
            end
            
            % Check TTL
            if msg.ttl <= 0
                obj.addLog(sprintf('t=%d [PANIC_DROP] TTL expired from %s', ...
                    t, dec2hex(uint16(sender), 4)));
                return;
            end
            
            % Extract panic info from payload
            panicType = msg.subtype;
            severity = msg.prio;
            originalSrc = sender;
            sensorValue = 0;
            
            if msg.payloadLen >= 4
                originalSrc = typecast(msg.payload(1:2), 'uint16');
                sensorValue = typecast(msg.payload(3:4), 'uint16');
            end
            
            % Log panic reception with priority
            panicTypeStr = obj.getPanicTypeStr(panicType);
            obj.addLog(sprintf('t=%d [PANIC_RX] *** %s *** sev=%d from=%s orig=%s val=%d', ...
                t, panicTypeStr, severity, dec2hex(uint16(sender), 4), ...
                dec2hex(uint16(originalSrc), 4), sensorValue));
            
            % Forward to parent with high priority
            if ~isempty(obj.parent)
                fwdMsg = obj.createPanicForward(msg);
                response = fwdMsg;
                obj.addLog(sprintf('t=%d [PANIC_FWD] -> parent %s (TTL=%d)', ...
                    t, dec2hex(uint16(obj.parent), 4), fwdMsg.ttl));
            elseif severity >= WSN_Config.PANIC_SEV_HIGH
                % No parent but high severity - broadcast to find route
                fwdMsg = obj.createPanicForward(msg);
                fwdMsg.dst = [];  % Broadcast
                response = fwdMsg;
                obj.addLog(sprintf('t=%d [PANIC_FWD] -> broadcast (orphan, TTL=%d)', t, fwdMsg.ttl));
            end
        end
        
        function fwdMsg = createPanicForward(obj, origMsg)
            % Create forwarded panic message with decremented TTL
            fwdMsg = WSN_Message();
            fwdMsg.type = WSN_Config.MSG_TYPE_PANIC;
            fwdMsg.subtype = origMsg.subtype;
            fwdMsg.src = hex2dec(obj.hexID);  % CH is now the forwarder
            fwdMsg.dst = obj.parent;           % Forward to parent
            fwdMsg.ttl = origMsg.ttl - 1;      % Decrement TTL
            fwdMsg.prio = origMsg.prio;        % Preserve priority
            fwdMsg.seq = origMsg.seq;
            fwdMsg.uid = origMsg.uid;          % Preserve UID for deduplication
            
            % Copy payload (contains original sender + data)
            fwdMsg.payload = origMsg.payload;
            fwdMsg.payloadLen = origMsg.payloadLen;
            
            fwdMsg.addChecksum();
            fwdMsg.color = [1.0 0.2 0.2];  % Red for panic
        end
        
        function str = getPanicTypeStr(~, panicType)
            % Get human-readable panic type string
            switch panicType
                case WSN_Config.PANIC_SUB_ANOMALY
                    str = 'ANOMALY';
                case WSN_Config.PANIC_SUB_BATTERY_CRIT
                    str = 'BATTERY_CRITICAL';
                case WSN_Config.PANIC_SUB_INTRUSION
                    str = 'INTRUSION';
                case WSN_Config.PANIC_SUB_LINK_LOSS
                    str = 'LINK_LOSS';
                otherwise
                    str = sprintf('PANIC_%d', panicType);
            end
        end
    end
end
