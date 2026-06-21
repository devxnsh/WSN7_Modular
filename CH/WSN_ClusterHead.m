%   % Suppress unused variable warnings - defensive initializations
%   % Suppress unused input argument warnings - API consistency
classdef WSN_ClusterHead < WSN_Node
    properties
        % --- FSM STATE ---
        state = WSN_Config.STATE_BOOT  % BOOT -> DISCOVERY -> HANDSHAKE -> SECURE
        isVerified = false             % Verified after KEY_ACK exchange
        localKey = []                  % Local key received from GWN (empty if parent is CH)
        
        % --- RECRUITMENT STATE ---
        retryTarget = []               % Current GWN/CH neighbor being recruited (relay target, not necessarily the GWN itself)
        retryCount = 0                 % Attempts so far for current target
        rejectedGWNs = []              % List of GWNs that rejected/timed out
        handshakePartner = []          % Lock partner during handshake
        rejectedCHs = []               % List of CHs that rejected
        retryBackoff = 0               % Randomized backoff timer (2-5 timeframes)
        lastRejectResetTime = 0        % Last time rejectedGWNs/rejectedCHs were cleared

        % --- TRANSPARENT RELAY / LATCH (replaces the old one-hop CH-CH cap) ---
        % Any verified CH may now relay an arbitrary-depth chain of further
        % CHs up to the GWN, acting as a transparent "latch": it physically
        % retransmits the handshake/data verbatim (no re-encryption, no
        % re-sourcing) while the GWN ends up individually verifying+keying
        % every CH regardless of depth, oblivious to the relay. See
        % handleCHREQ / relayMessageIfNotMine and CH_Documentation.md.
        passkey = []                   % 5-bit (0-31) verification passkey issued by GWN alongside localKey
        relayTable = struct('leafID',{}, 'nextHop',{}, 'lastActive',{})  % One row per CH this latch relays for: leafID -> immediate physical neighbor to forward toward
        relayQueue = {}                 % FIFO of in-flight data/fragment messages awaiting this CH's own next TX opportunity (control/recruitment/priority traffic bypasses this entirely)
        pendingRelayFragments = struct('leafID',{}, 'nextHop',{}, 'seq',{}, 'fragIdx',{}, 'totalFrags',{}, 'msg',{}, 'retryCount',{}, 'lastRetryTime',{})  % Generalizes pendingAgg/pendingFragments into a table: one outstanding per-hop ACK per leaf this latch relays for
        localTxBudgetCounter = 0        % Fairness counter: guarantees this CH's own local TX isn't permanently starved behind relay traffic (WSN_Config.RELAY_LOCAL_TX_FAIRNESS)

        % --- CH PEER-DISCOVERY DVS (verified CH widens its own txPower
        % footprint so a still-unverified peer CH can hear it and choose to
        % join -- see WSN_Config.CH_PEER_DVS_*). Mirrors
        % WSN_Gateway.checkChDiscoveryDVS. Used to be gated on
        % isQualifiedToRecruit (one-hop cap); now gates on isVerified alone
        % since any verified CH can relay. Deliberately more conservative
        % than the GWN's equivalent (battery-limited, single radio, no
        % charging circuit -- see updatePhysics), and slower still now that
        % relay chains do most of the connectivity-propagation work
        % passively (see CH_Documentation.md).
        chPeerDvsLastCheckTime = 0
        chPeerDvsLastChildCount = 0
        chPeerDvsScaleCount = 0

        % --- CH ORPHAN-RESCUE DVS (still-unverified CH past
        % WSN_Config.CH_ORPHAN_DVS_START_TIME widens its own footprint to
        % discover ANY verified GWN or CH). Last-resort: only fires once the
        % normal passive recruitment FSM below has had a long, unforced
        % chance to find a candidate on its own. Only ever widens HELLO
        % broadcast range -- the SECURE-state FSM still owns CH_REQ
        % initiation/retry once a verified candidate appears in
        % neighborTable.
        chOrphanDvsLastCheckTime = 0
        chOrphanDvsScaleCount = 0

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

            % --- CH PEER-DISCOVERY DVS: widen footprint for unverified peer CHs ---
            obj.checkChPeerDiscoveryDVS(t);

            % --- CH ORPHAN-RESCUE DVS: still-unverified past t=600, widen footprint ---
            obj.checkChOrphanDVS(t);

            % --- RELAY/LATCH QUEUE: flush queued data/fragments for relayed
            % CHs (control/recruitment/priority traffic never queues -- it is
            % always sent immediately from its own handler) ---
            relayMsgs = obj.processRelayQueue(t);
            if ~isempty(relayMsgs), msgs = [msgs, relayMsgs]; end

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
            
            % --- TRANSPARENT RELAY INTERCEPT ---
            % A message wire-addressed to me (isForMe) but logically
            % concerning a DIFFERENT CH (msg.originalSrc set and not my own
            % ID) means I'm an intermediate latch, not the endpoint -- relay
            % it verbatim per my relayTable instead of processing it as my
            % own business. 6.0 CH_REQ and 6.4 CH_JOINOK are excluded: 6.0
            % does its own relay-and-establish inside handleCHREQ, and 6.4 is
            % always hop-local only (never carries a relayed originalSrc).
            if isForMe && msg.verifyChecksum() && msg.originalSrc ~= 0 && msg.originalSrc ~= myID
                isRelayEligible = (msg.type == WSN_Config.MSG_TYPE_CH_CMD && msg.subtype ~= WSN_Config.CH_SUB_REQ && msg.subtype ~= WSN_Config.CH_SUB_JOINOK) || ...
                    (msg.type == WSN_Config.MSG_TYPE_CH_HELLO && (msg.subtype == WSN_Config.SENSOR_SUB_AGG || msg.subtype == WSN_Config.SENSOR_SUB_ACK));
                if isRelayEligible
                    response = obj.relayMessageIfNotMine(msg, t);
                    return;
                end
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
                    
                case WSN_Config.CH_SUB_JOINOK  % 6.4 CH_JOINOK: hop-local "I'll latch for you" ack
                    obj.handleCHJOINOK(msg, t);

                case WSN_Config.CH_SUB_REJECT  % 6.3 CH_REJECT: hop-local rejection (relayed rejects are intercepted earlier, see receive())
                    obj.handleCHREJECT(msg, t);
            end
        end
        
        function response = handleCHREQ(obj, msg, t)
            % 6.0 CH_REQ: a neighboring CH wants to join the network through
            % me. Under the relay-latch model (replaces the old one-hop
            % isQualifiedToRecruit cap) this is "not a message of its own" --
            % it's always treated as a relay request: I become a transparent
            % latch for the requester's true identity (msg.originalSrc, or
            % msg.src if this is the requester's very first hop) and forward
            % the SAME request one hop further toward my own parent, exactly
            % like createRelayForward does for the GWN-GWN backbone. The GWN
            % ultimately verifies+keys the requester directly and is
            % oblivious to how many hops the request crossed.
            response = [];
            sender = msg.src;
            leafID = msg.originalSrc;
            if leafID == 0, leafID = sender; end  % First hop: requester is its own leaf

            % I can only relay if I myself have an upstream path -- mirrors
            % the old "not qualified" rejection, now meaning "no parent yet"
            % rather than "not GWN-anchored" (every verified CH qualifies).
            if isempty(obj.parent)
                obj.addLog(sprintf('t=%d [CH_REJECT] %s (no upstream path yet)', ...
                    t, dec2hex(uint16(sender), 4)));
                response = obj.createCHREJECT(sender, t, leafID);
                return;
            end

            % Accept: refresh/add the relayTable route for this leaf.
            obj.addRelayRoute(leafID, sender, t);

            % Three control messages this tick: hop-local 6.4 JOINOK (back
            % to the requester), the relayed 6.0 CH_REQ (up to my parent),
            % and a 6.5 CH_INFO topology announcement (also up to my
            % parent). All three are returned as the function's `response`
            % array rather than via obj.radio.requestTX -- the radio only
            % accepts ONE requestTX per tick (txPending guard), but
            % WSN_Main's receive()-response path pushes every element of
            % `response` straight onto txBuffer and lets them depart one
            % per tick on their own (see Simulator/WSN_Main.m ~line 488),
            % which is also exactly the per-hop latency this design wants.
            response = [obj.createCHJOINOK(sender, t)];

            fwd = WSN_Message();
            fwd.type = WSN_Config.MSG_TYPE_CH_CMD;
            fwd.subtype = WSN_Config.CH_SUB_REQ;
            fwd.src = hex2dec(obj.hexID);
            fwd.dst = obj.parent;
            fwd.originalSrc = leafID;
            fwd.ttl = msg.ttl;
            fwd.seq = msg.seq;
            fwd.addChecksum();
            response = [response, fwd];

            response = [response, obj.createCHINFO(leafID, t)];

            obj.addLog(sprintf('t=%d [CH_JOINOK+RELAY+INFO] latching for %s -> requester %s, parent %s', ...
                t, dec2hex(uint16(leafID), 4), dec2hex(uint16(sender), 4), dec2hex(uint16(obj.parent), 4)));
        end
        
        function handleCHJOINOK(obj, msg, t)
            % 6.4 CH_JOINOK: hop-local-only ack from the adjacent CH I just
            % sent a CH_REQ to, confirming "I'll latch/relay for you." This
            % is NOT end-to-end verification -- it carries no key and does
            % not set isVerified/parent. It just refreshes my handshake lock
            % timer so I don't time out while the rest of the relay chain
            % (possibly several more hops, each with its own latency) is
            % still working on reaching the GWN. Real verification arrives
            % later via 6.1 CH_ACK, reverse-latched back down this same path.
            sender = msg.src;

            if obj.state ~= WSN_Config.STATE_HANDSHAKE || sender ~= obj.handshakePartner
                obj.addLog(sprintf('t=%d [IGNORE] CH_JOINOK from %s (not partner)', ...
                    t, dec2hex(uint16(sender), 4)));
                return;
            end

            obj.addLog(sprintf('t=%d [CH_JOINOK] %s will latch for me -- awaiting GWN CH_ACK', ...
                t, dec2hex(uint16(sender), 4)));
            obj.radio.refreshLock(WSN_Config.CH_ACCESS_LOCK_TIMER);
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
            
            % Extract local key (first 16 bytes) + the new 5-bit passkey
            % (byte 17), issued together by the GWN regardless of how many
            % relay hops this ACK crossed to reach me.
            if msg.payloadLen >= 17
                obj.localKey = msg.payload(1:16);
                obj.passkey = msg.payload(17);
            else
                obj.addLog(sprintf('t=%d [ERROR] CH_ACK missing key/passkey payload', t));
                return;
            end

            obj.addLog(sprintf('t=%d [CH_ACK] Received key+passkey=%d from %s', ...
                t, obj.passkey, dec2hex(uint16(sender), 4)));
            
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
            % localKey/passkey were set earlier from CH_ACK payload - enables
            % encrypted, passkey-stamped comms. Any verified CH can now
            % relay further CHs (no more isQualifiedToRecruit one-hop gate).
            obj.isVerified = true;
            obj.state = WSN_Config.STATE_SECURE;
            obj.retryTarget = [];
            obj.retryCount = 0;
            % Verified -- any orphan-rescue txPower boost has served its
            % purpose; reset to baseline. CH_PEER_DVS takes over from here
            % if this CH's own further-CH recruitment stalls.
            obj.txPower = WSN_Config.TxPower_CH;
            obj.chOrphanDvsScaleCount = 0;

            obj.addLog(sprintf('t=%d [VERIFIED] parent=%s (localKey+passkey set, encrypted comms)', ...
                t, dec2hex(uint16(obj.parent), 4)));
        end

        function handleCHREJECT(obj, msg, t)
            % 6.3 CH_REJECT: hop-local rejection (a relayed reject for a
            % DIFFERENT CH's identity is intercepted earlier in receive() and
            % never reaches here -- see relayMessageIfNotMine). Move to next
            % viable target.
            sender = msg.src;

            obj.addLog(sprintf('t=%d [CH_REJECT] from %s', ...
                t, dec2hex(uint16(sender), 4)));

            % PURGE: If sender was our parent, clear it and purge local key/passkey
            if ~isempty(obj.parent) && obj.parent == sender
                obj.addLog(sprintf('t=%d [PURGE] parent %s (rejected)', t, dec2hex(uint16(sender),4)));
                obj.parent = [];
                obj.isVerified = false;
                obj.localKey = [];   % Purge local key on rejection
                obj.passkey = [];    % Purge passkey on rejection
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

        % =====================================================
        % TRANSPARENT RELAY / LATCH (replaces the old one-hop CH-CH cap)
        % =====================================================
        function addRelayRoute(obj, leafID, nextHop, t)
            % Add/refresh the relayTable row for leafID -> nextHop (the
            % immediate physical neighbor to forward toward, both uplink
            % and downlink, for this leaf).
            idx = find([obj.relayTable.leafID] == leafID, 1);
            if isempty(idx)
                obj.relayTable(end+1) = struct('leafID', leafID, 'nextHop', nextHop, 'lastActive', t);
            else
                obj.relayTable(idx).nextHop = nextHop;
                obj.relayTable(idx).lastActive = t;
            end
        end

        function nextHop = findRelayRoute(obj, leafID)
            % Look up the immediate neighbor to forward toward for leafID.
            % Empty if this CH is not latching for that leaf.
            nextHop = [];
            if isempty(obj.relayTable), return; end
            idx = find([obj.relayTable.leafID] == leafID, 1);
            if ~isempty(idx)
                nextHop = obj.relayTable(idx).nextHop;
            end
        end

        function purgeRelayRoute(obj, leafID)
            % Tear down a stale relay route (explicit reject/timeout for
            % that leaf) -- mirrors how rejectedCHs purges a failed target.
            if isempty(obj.relayTable), return; end
            obj.relayTable([obj.relayTable.leafID] == leafID) = [];
            obj.pendingRelayFragments([obj.pendingRelayFragments.leafID] == leafID) = [];
        end

        function response = relayMessageIfNotMine(obj, msg, t)
            % Single chokepoint for transparent forwarding, both uplink
            % (toward the GWN) and downlink (back toward the leaf). Rewrites
            % src/dst to the immediate next physical hop (so WSN_Main's
            % physAdj-based delivery succeeds) while leaving originalSrc,
            % payload, flag and ttl untouched -- "without any insignia,
            % encryption or passkey" beyond what was already there.
            % Control/recruitment/priority messages (6.1/6.2/6.3/6.5) are
            % sent immediately; only 5.2/5.3 data/fragment traffic queues
            % (see processRelayQueue).
            response = [];
            leafID = msg.originalSrc;
            downstreamHop = obj.findRelayRoute(leafID);

            if isempty(downstreamHop)
                % No route for this leaf (route purged/never established) --
                % nothing to relay to; drop silently rather than guessing.
                obj.addLog(sprintf('t=%d [RELAY_DROP] no route for %s', t, dec2hex(uint16(leafID), 4)));
                return;
            end

            % Direction: if this hop arrived FROM the recorded downstream
            % neighbor, it's travelling uplink (toward the GWN) and the next
            % hop is my own parent. Otherwise it arrived from upstream (my
            % parent or an even-deeper relay) and is travelling downlink
            % back toward the leaf, so the next hop is the recorded
            % downstream neighbor.
            if msg.src == downstreamHop
                nextHop = obj.parent;
                if isempty(nextHop)
                    % Lost my own upstream path -- can't continue relaying
                    % this leaf uplink. Tear down the now-useless route.
                    obj.addLog(sprintf('t=%d [RELAY_DROP] no parent to relay %s uplink', t, dec2hex(uint16(leafID), 4)));
                    obj.purgeRelayRoute(leafID);
                    return;
                end
            else
                nextHop = downstreamHop;
            end

            isData = (msg.type == WSN_Config.MSG_TYPE_CH_HELLO);
            if isData && msg.subtype == WSN_Config.SENSOR_SUB_AGG
                % 5.2 fragment: queue for this CH's own next TX opportunity,
                % track for independent per-hop ACK/resend, and ACK the
                % immediate sender right away (hop-by-hop reliability -- the
                % sender doesn't wait for the whole chain, just this hop).
                obj.enqueueRelayFragment(leafID, nextHop, msg, t);
                totalFrags = 1; fragIdx = 1;
                if msg.payloadLen >= 2
                    totalFrags = msg.payload(1); fragIdx = msg.payload(2);
                end
                response = obj.createAggACK(msg.src, msg.seq, t, fragIdx, totalFrags);
            elseif isData && msg.subtype == WSN_Config.SENSOR_SUB_ACK
                % 5.3 ack for something WE forwarded -- clears our own
                % pending retry for this hop; terminates here (does not
                % itself need further relaying back to the leaf, since the
                % leaf already got its own immediate hop's ack).
                obj.clearRelayFragmentAck(leafID, msg);
            else
                % Control/recruitment/priority: returned as `response` (not
                % obj.radio.requestTX -- the radio only accepts one requestTX
                % per tick; `response` is the unthrottled receive()-response
                % channel, see the comment in handleCHREQ above) so it's
                % never delayed behind queued data (6.3 CH_REJECT also tears
                % down the route it concerns).
                fwd = WSN_Message();
                fwd.type = msg.type;
                fwd.subtype = msg.subtype;
                fwd.src = hex2dec(obj.hexID);
                fwd.dst = nextHop;
                fwd.originalSrc = msg.originalSrc;
                fwd.ttl = msg.ttl;
                fwd.seq = msg.seq;
                fwd.flag = msg.flag;
                fwd.payload = msg.payload;
                fwd.payloadLen = msg.payloadLen;
                fwd.prio = msg.prio;
                fwd.addChecksum();
                fwd.color = msg.color;

                response = fwd;
                if msg.type == WSN_Config.MSG_TYPE_CH_CMD && msg.subtype == WSN_Config.CH_SUB_REJECT
                    obj.purgeRelayRoute(leafID);
                end
            end
        end

        function enqueueRelayFragment(obj, leafID, nextHop, msg, t)
            % Queue a relayed 5.2 fragment for this CH's own next TX slot,
            % and track it for independent per-hop ACK/resend (generalizes
            % the single pendingAgg/pendingFragments singleton into a table
            % keyed by leaf+fragment, since a latch can have several leaves'
            % fragments in flight concurrently).
            fragIdx = 1;
            if msg.payloadLen >= 2
                fragIdx = msg.payload(2);
            end
            if numel(obj.relayQueue) >= WSN_Config.RELAY_QUEUE_MAX
                obj.relayQueue(1) = [];  % Drop oldest to bound memory
            end
            obj.relayQueue{end+1} = struct('leafID', leafID, 'nextHop', nextHop, 'msg', msg, 'fragIdx', fragIdx);
        end

        function clearRelayFragmentAck(obj, leafID, ackMsg)
            % 5.3 received for a fragment we relayed -- clear the matching
            % pendingRelayFragments row.
            if isempty(obj.pendingRelayFragments), return; end
            fragIdx = 1;
            if ackMsg.payloadLen >= 2
                fragIdx = ackMsg.payload(2);
            end
            keep = ~(([obj.pendingRelayFragments.leafID] == leafID) & ...
                     ([obj.pendingRelayFragments.fragIdx] == fragIdx));
            obj.pendingRelayFragments = obj.pendingRelayFragments(keep);
        end

        function msgs = processRelayQueue(obj, t)
            % Flush queued relayed data/fragments on this CH's own cadence,
            % retry per-hop-unACKed fragments, and apply fairness so a busy
            % latch is never permanently stuck only forwarding (guarantees
            % >=1 local TX for every RELAY_LOCAL_TX_FAIRNESS relay TXs).
            % Control/recruitment/priority traffic never passes through
            % here -- it is always sent immediately from its own handler.
            msgs = [];

            % --- RETRY unACKed relayed fragments (per-hop reliability) ---
            if ~isempty(obj.pendingRelayFragments)
                stillPending = obj.pendingRelayFragments;
                for i = 1:numel(stillPending)
                    row = stillPending(i);
                    if (t - row.lastRetryTime) < WSN_Config.RELAY_FRAG_RETRY_INTERVAL
                        continue;
                    end
                    if row.retryCount >= WSN_Config.RELAY_FRAG_MAX_RETRIES
                        obj.addLog(sprintf('t=%d [RELAY_FRAG_DROPPED] leaf=%s frag=%d after %d retries (next hop %s unresponsive)', ...
                            t, dec2hex(uint16(row.leafID), 4), row.fragIdx, row.retryCount, dec2hex(uint16(row.nextHop), 4)));
                        obj.pendingRelayFragments([obj.pendingRelayFragments.leafID] == row.leafID & ...
                            [obj.pendingRelayFragments.fragIdx] == row.fragIdx) = [];
                        continue;
                    end
                    msgs = [msgs, row.msg]; %#ok<AGROW>
                    idx = find([obj.pendingRelayFragments.leafID] == row.leafID & ...
                        [obj.pendingRelayFragments.fragIdx] == row.fragIdx, 1);
                    if ~isempty(idx)
                        obj.pendingRelayFragments(idx).retryCount = obj.pendingRelayFragments(idx).retryCount + 1;
                        obj.pendingRelayFragments(idx).lastRetryTime = t;
                    end
                end
            end

            % --- FLUSH ONE QUEUED ITEM PER TICK, WITH LOCAL-TRAFFIC FAIRNESS ---
            preferLocal = obj.localTxBudgetCounter >= WSN_Config.RELAY_LOCAL_TX_FAIRNESS;
            haveLocalPending = ~isempty(obj.pendingAgg);
            if preferLocal && haveLocalPending
                % Defer to the existing sensor-aggregation pipeline this
                % tick (it runs separately in step()); just reset the
                % fairness counter so relay traffic resumes after.
                obj.localTxBudgetCounter = 0;
                return;
            end

            if ~isempty(obj.relayQueue)
                item = obj.relayQueue{1};
                obj.relayQueue(1) = [];

                fwd = WSN_Message();
                fwd.type = item.msg.type;
                fwd.subtype = item.msg.subtype;
                fwd.src = hex2dec(obj.hexID);
                fwd.dst = item.nextHop;
                fwd.originalSrc = item.msg.originalSrc;
                fwd.ttl = item.msg.ttl;
                fwd.seq = item.msg.seq;
                fwd.flag = item.msg.flag;
                fwd.payload = item.msg.payload;
                fwd.payloadLen = item.msg.payloadLen;
                fwd.addChecksum();
                fwd.color = item.msg.color;

                totalFrags = 1;
                if item.msg.payloadLen >= 1
                    totalFrags = item.msg.payload(1);
                end
                obj.pendingRelayFragments(end+1) = struct('leafID', item.leafID, ...
                    'nextHop', item.nextHop, 'seq', fwd.seq, 'fragIdx', item.fragIdx, ...
                    'totalFrags', totalFrags, 'msg', fwd, 'retryCount', 0, 'lastRetryTime', t);

                msgs = [msgs, fwd]; %#ok<AGROW>
                obj.localTxBudgetCounter = obj.localTxBudgetCounter + 1;
                obj.addLog(sprintf('t=%d [RELAY_TX] leaf=%s frag=%d -> %s', ...
                    t, dec2hex(uint16(item.leafID), 4), item.fragIdx, dec2hex(uint16(item.nextHop), 4)));
            end
        end

        function checkChPeerDiscoveryDVS(obj, t)
            % Verified, GWN-anchored CH periodically widens its own
            % txPower footprint if its CH-child count has stalled, so a
            % still-unverified peer CH further out can hear its HELLO and
            % choose to send a CH_REQ. This is "appear in range" only --
            % it never causes this CH to initiate anything; the judgement
            % to pair still belongs entirely to the unverified peer's own
            % SECURE-state FSM. See WSN_Config.CH_PEER_DVS_* comment for
            % why this is deliberately more conservative than the GWN's
            % equivalent (checkChDiscoveryDVS in WSN_Gateway.m).
            if ~WSN_Config.CH_PEER_DVS_ENABLED, return; end
            if ~obj.isVerified, return; end
            if t < obj.chPeerDvsLastCheckTime + WSN_Config.CH_PEER_DVS_CHECK_INTERVAL
                return;
            end

            currentCount = numel(obj.relayTable);
            stalled = currentCount <= obj.chPeerDvsLastChildCount;

            if stalled && obj.chPeerDvsScaleCount < WSN_Config.CH_PEER_DVS_MAX_SCALE_ATTEMPTS ...
                    && obj.txPower < WSN_Config.MaxCHPeerPower
                oldPower = obj.txPower;
                obj.txPower = min(WSN_Config.MaxCHPeerPower, ...
                    obj.txPower * WSN_Config.CH_PEER_DVS_SCALE_FACTOR);
                obj.chPeerDvsScaleCount = obj.chPeerDvsScaleCount + 1;
                obj.addLog(sprintf('t=%d [CH_PEER_DVS] No new CH child since t=%d -- txPower %.2f -> %.2f (attempt %d/%d)', ...
                    t, obj.chPeerDvsLastCheckTime, oldPower, obj.txPower, ...
                    obj.chPeerDvsScaleCount, WSN_Config.CH_PEER_DVS_MAX_SCALE_ATTEMPTS));
            elseif ~stalled && obj.txPower > WSN_Config.TxPower_CH
                oldPower = obj.txPower;
                obj.txPower = WSN_Config.TxPower_CH;
                obj.chPeerDvsScaleCount = 0;
                obj.addLog(sprintf('t=%d [CH_PEER_DVS] New CH child found -- txPower reset %.2f -> %.2f (budget refreshed)', ...
                    t, oldPower, obj.txPower));
            end

            obj.chPeerDvsLastCheckTime = t;
            obj.chPeerDvsLastChildCount = currentCount;
        end

        function checkChOrphanDVS(obj, t)
            % Last-resort: a CH still unverified this far into the run
            % widens its OWN footprint so a distant verified GWN/CH's
            % normal HELLO range overlap is more likely, rather than
            % waiting indefinitely on someone else's DVS boost to reach
            % it. Still passive discovery only (boosts HELLO broadcast
            % range) -- once a verified candidate lands in neighborTable,
            % the existing SECURE-state FSM (findBestVerifiedGWN/CH,
            % CH_REQ, CH_MAX_RETRIES, retryBackoff) drives the actual
            % connection-request initiation and retries exactly as it
            % already does for any other candidate.
            if ~WSN_Config.CH_ORPHAN_DVS_ENABLED, return; end
            if t < WSN_Config.CH_ORPHAN_DVS_START_TIME, return; end
            if obj.isVerified, return; end
            if t < obj.chOrphanDvsLastCheckTime + WSN_Config.CH_ORPHAN_DVS_CHECK_INTERVAL
                return;
            end

            if obj.chOrphanDvsScaleCount < WSN_Config.CH_ORPHAN_DVS_MAX_SCALE_ATTEMPTS ...
                    && obj.txPower < WSN_Config.MaxCHOrphanPower
                oldPower = obj.txPower;
                obj.txPower = min(WSN_Config.MaxCHOrphanPower, ...
                    obj.txPower * WSN_Config.CH_ORPHAN_DVS_SCALE_FACTOR);
                obj.chOrphanDvsScaleCount = obj.chOrphanDvsScaleCount + 1;
                obj.addLog(sprintf('t=%d [CH_ORPHAN_DVS] Still unverified past t=%d -- txPower %.2f -> %.2f (attempt %d/%d)', ...
                    t, WSN_Config.CH_ORPHAN_DVS_START_TIME, oldPower, obj.txPower, ...
                    obj.chOrphanDvsScaleCount, WSN_Config.CH_ORPHAN_DVS_MAX_SCALE_ATTEMPTS));
            end

            obj.chOrphanDvsLastCheckTime = t;
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
            % Create 6.0 CH_REQ message. originalSrc = own ID -- this is
            % always the leaf at the point of creation (relays preserve it
            % unchanged when forwarding, see handleCHREQ).
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_CMD;
            msg.subtype = WSN_Config.CH_SUB_REQ;  % 0
            msg.src = hex2dec(obj.hexID);
            msg.dst = dst;
            msg.originalSrc = hex2dec(obj.hexID);
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            msg.flag = 0;
            msg.payloadLen = 0;
            msg.payload = [];
            msg.addChecksum();
        end

        function msg = createKEY_ACK(obj, dst, t)
            % Create 6.2 KEY_ACK message (encrypted in local key). The
            % passkey is appended as the last payload byte BEFORE encryption
            % (i.e. it's inside the same encrypted envelope as the key echo),
            % per spec. originalSrc = own ID so a multi-hop reverse path back
            % to the GWN can route it even though wire dst is just the next
            % hop.
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_CMD;
            msg.subtype = WSN_Config.CH_SUB_KEY_ACK;  % 2
            msg.src = hex2dec(obj.hexID);
            msg.dst = dst;
            msg.originalSrc = hex2dec(obj.hexID);
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            msg.flag = bitset(0, 1, 1);  % Encrypted flag
            % Payload: echoed key + appended passkey (confirmation)
            msg.payload = [obj.localKey(:)', uint8(obj.passkey)];
            msg.payloadLen = numel(msg.payload);
            msg.addChecksum();
        end

        function msg = createCHREJECT(obj, dst, t, leafID)
            % Create 6.3 CH_REJECT message. leafID (optional) is the true
            % identity being rejected when this rejection is itself a reply
            % to a relayed CH_REQ -- defaults to dst (hop-local rejection,
            % no relay involved) when omitted.
            if nargin < 4 || isempty(leafID)
                leafID = dst;
            end
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_CMD;
            msg.subtype = WSN_Config.CH_SUB_REJECT;  % 3
            msg.src = hex2dec(obj.hexID);
            msg.dst = dst;
            msg.originalSrc = leafID;
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
            % Create 6.5 CH_INFO: hop-by-hop relay-topology announcement.
            % Sent fresh by a latch the moment it accepts a new relay
            % (handleCHREQ), and relayed one hop further by every subsequent
            % latch on the path (see relayMessageIfNotMine) so GWN/Sink/
            % ML-IDS/GUI keep accurate path visibility even though the
            % actual data/handshake path stays transparent. originalSrc =
            % the leaf this announcement is about.
            % Payload: {Recruited/leaf CH ID, Parent CH ID} + appended
            % passkey (if available), encrypted if local key available.
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_CH_CMD;
            msg.subtype = WSN_Config.CH_SUB_INFO;  % 5
            msg.src = hex2dec(obj.hexID);
            msg.dst = obj.parent;
            msg.originalSrc = recruitedID;
            msg.ttl = 1;
            msg.seq = mod(t, 256);

            % Payload: Recruited/leaf ID (2), immediate-latch ID (2).
            % Deliberately UNENCRYPTED: unlike the old one-hop model, a 6.5
            % announcement may now cross multiple relay hops verbatim before
            % reaching the GWN (relayMessageIfNotMine never re-encrypts), so
            % there is no single "the sender's localKey" the GWN could
            % reliably decrypt it with once it's been relayed past its
            % originating latch. CH_INFO is a visibility-only side-channel
            % (registries/ML-IDS/GUI) -- the security-critical exchange is
            % the real KEY_ACK/passkey handshake per leaf, unaffected by this.
            msg.payload = [typecast(uint16(recruitedID), 'uint8'), ...
                           typecast(uint16(hex2dec(obj.hexID)), 'uint8')];
            msg.flag = 0;
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
