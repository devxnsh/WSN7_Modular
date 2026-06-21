classdef WSN_Gateway < WSN_Node
    % =========================================================
    % WSN GATEWAY â€” FACADE / STATE OWNER
    % Delegates FSM to Behavior, protocol to Messaging
    % =========================================================

    properties
        % -------- ORIGINAL PROPERTIES (UNCHANGED) --------
        controlPower = 6.0
        state = 0
        bootTime = 0
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
        radioAccess % HC12 Access radio (separate from Backbone radio)
        
        % -------- DUAL-RADIO LOGS --------
        logBackbone = {}   % LoRa backbone radio logs
        logAccess = {}     % HC12 access radio logs
        
        % -------- CH CHILDREN (separate from GWN children) --------
        chChildren = []          % List of recruited (first-degree) CH IDs
        secondaryChChildren = [] % CH IDs learned about via a relay-CH's CH_INFO (not direct children)
        chLocalKeys = containers.Map()  % Map of CH hexID to local key

        % --- CH REGISTRATION ANNOUNCE-TO-BACKBONE TRACKING ---
        % Notifying the Sink of a CH child (direct or secondary) used to be
        % a fire-once CH_HELLO sent the moment it was learned about -- if
        % this GWN didn't have its own backbone parent at that exact tick,
        % the notification was silently dropped forever (see
        % IDS_METRICS_IMPROVEMENT_PLAN.md / AI_ENGINE_DEBUG_PROMPT.md
        % "CH Recruitment" entry). Track the parent ID the full chChildren/
        % secondaryChChildren set was last announced to, and re-announce
        % whenever it goes stale (no parent yet, or parent changed/was
        % newly acquired, or a new CH was added).
        chChildrenAnnouncedToParent = []

        % --- PENDING CH_HELLO RELAY BUFFER ---
        % A multi-hop relay of someone else's CH_HELLO has the same
        % drop-forever bug as the registration case above, just one layer
        % further out: WSN_Gateway_Messaging.handle_CH_HELLO used to drop
        % an inbound CH_HELLO permanently if THIS GWN didn't have its own
        % parent at the exact tick it arrived. Buffer it instead and flush
        % once a parent is available (see flushPendingChHelloForward()).
        pendingChHelloForward = {}  % Cell array of raw WSN_Message objects awaiting a parent
        PENDING_CH_HELLO_MAX = 30   % Cap to avoid unbounded growth if permanently orphaned

        % --- CH-DISCOVERY DYNAMIC VOLTAGE SCALING (DVS) ---
        % CHs are recruited passively (they send CH_REQ on hearing our
        % HELLO; we never "search" for them), so unlike the GWN-GWN
        % backbone DVS above, there's no rejection signal to react to --
        % instead, periodically check whether chChildren has grown since
        % the last check, and if not, boost controlPower so our HELLO/
        % CH_ACK reach further out (see IDS_METRICS_IMPROVEMENT_PLAN.md;
        % moved here from the old CH-side DVS, which wasted a power-
        % constrained CH's own battery compensating for a GWN coverage gap).
        chDvsLastCheckTime = 0
        chDvsLastChildCount = 0
        chDvsScaleCount = 0

        % --- ML-IDS REPORTING-SILENCE DETECTOR (ML_IDS_PLAN.md Phase 4 follow-up) ---
        % Tracks last 5.2 SENSOR_AGG arrival per CH child -- catches a
        % Blackhole/Grayhole CH that stops relaying upward, since that
        % attack fake-ACKs its own children and is otherwise invisible to
        % any retry-based trigger (see WSN_Config.SILENCE_GRACE_MULTIPLIER).
        chLastAggSeen = struct('id',{}, 'lastTime',{})
        chAggSilenceFlagged = []
        % Pending children: awaiting ENC_HELLO confirmation (secure handshake)
        % Struct array: {id, addedAt} - times out after PENDING_CHILD_TIMEOUT
        pendingChildren = struct('id',{},'addedAt',{})
        PENDING_CHILD_TIMEOUT = 15  % TFs to wait for ENC_HELLO before purging
        
        % -------- PHASE SCHEDULING STATE (replaces TOKEN system) --------
        phaseOffset = 0                     % 0 or 1, inherited from parent (NOT of parent's offset)
        currentPhase = 0                    % Current radio phase: PHASE_RX=0, PHASE_TX=1, PHASE_IDLE=2
        phaseInherited = false              % True once phaseOffset received from parent
        
        % -------- DUAL QUEUES (Phase-Scheduled Backbone) --------
        % Q_fwd: Forwarding queue (childâ†’parent relay) - STRICT PRIORITY
        % Q_local: Local queue (own data: CH_HELLO, SENSOR_AGG)
        Q_fwd = {}                          % Cell array of messages to forward
        Q_local = {}                        % Cell array of locally generated messages
        
        % -------- PANIC DEDUPLICATION --------
        seenPanicUIDs = []                  % Array of seen PANIC UIDs for deduplication
        
        % -------- SENSOR DATA AGGREGATION (for direct SN->GWN) --------
        sensorTable = struct('id',{}, 'lastTime',{}, 'value',{}, 'rssi',{}, 'battery',{});
        aggPeriod = 0                  % Fixed random period 7-10 TFs (set after verification)
        nextAggTX = 0                  % Next scheduled 5.2 TX time
        lastChargeTime = 0             % Last time GWN was charged
        
        % -------- ENC_HELLO RETRY (Exponential Backoff) --------
        encHelloRetryCount = 0         % Number of ENC_HELLO retries sent
        encHelloNextRetryTime = 0      % Next time to send ENC_HELLO retry
        ENC_HELLO_MAX_RETRIES = 3      % Max retry attempts
        ENC_HELLO_BASE_INTERVAL = 10   % Base retry interval (exponential: 10, 30, 70)
        
        % NOTE: Access radio lock uses radioAccess.handshakePartner (independent from Backbone)
        % Backbone radio lock uses radio.handshakePartner (for GWN-GWN FSM)

        % --- ML-IDS CENSUS PROTOCOL (ML_IDS_PLAN.md Phase 4) ---
        % Dedicated behavioral-trust store, deliberately separate from
        % neighborTable.TrustScore (a pre-existing field that encodes
        % Hello/Heartbeat verification confidence, not Census behavior --
        % reusing it caused every fresh GWN-GWN link to start below
        % TRUST_CENSUS_TRIGGER and false-trigger Census from t=2 onward).
        neighborTrust = struct('id',{}, 'score',{})
        censusActivePolls = struct('pollUID',{}, 'suspectID',{}, 'startTick',{}, 'yesCount',{}, 'totalVoters',{}, 'voterIDs',{})
        censusSeenPolls = []
        resetHistory = struct('id',{}, 'softCount',{}, 'hardCount',{})  % escalation history for direct children

        % -------- DORMANT: TRUST-BASED DECISION MATRIX (not yet active) --------
        trustDecisionMatrix = []          % future: composite per-node decision matrix
        trustDecisionPolicy = 'PASSIVE'   % future: 'PASSIVE' | 'ACTIVE' enforcement mode
        trustDecisionWeights = struct('packetSuccess', 1.0, 'censusVote', 0, 'neighborCorroboration', 0)
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
                'TrustScore',{}, ...
                'commRange',{}, ...
                'status',{}, ...
                'tier',{}, ...
                'battery',{}, ...
                'neighborCount',{}, ...
                'isVerified',{} );

            % -------- CREATE DELEGATES --------
            obj.behavior  = WSN_Gateway_Behavior(obj);
            obj.messaging = WSN_Gateway_Messaging(obj);
            obj.radioAccess = WSN_Radio(obj, 'ACCESS');  % HC12 Access radio (independent lock)
            % Note: obj.radio (from WSN_Node) is BACKBONE by default
            
            % -------- INIT DUAL-RADIO LOGS --------
            obj.logBackbone = {};
            obj.logAccess = {};
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

            % GWNs do NOT sleep - always awake with idle cost
            obj.isAwake = true;
            obj.battery = max(0, obj.battery - WSN_Config.IdleCost);
            
            % --- CHARGING CIRCUIT ---
            % GWNs charge 1% per timeframe (always charging)
            if isa(obj, 'WSN_Sink')
                obj.battery = min(100, obj.battery + 1.5);  % Sink: +1.5% per TF
            else
                obj.battery = min(100, obj.battery + 1.0);  % Regular GWN: +1% per TF
            end

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
    % STEP â€” FACADE
    % =========================================================
    methods
        function msgs = step(obj, t, physAdj, allNodes)
            %
            msgs = WSN_Message.empty;
            if obj.isBlacklisted, return; end

            % --- ML-IDS CENSUS: trigger polls / finalize timed-out polls ---
            censusMsgs = obj.checkCensusTriggers(t);
            if ~isempty(censusMsgs), msgs = [msgs, censusMsgs]; end

            % ---- ACCESS RADIO LOCK TIMEOUT (CH handshake) ----
            % Access radio has its own lock independent of Backbone
            if ~isempty(obj.radioAccess.handshakePartner) && obj.radioAccess.lockTimer > 0
                obj.radioAccess.lockTimer = obj.radioAccess.lockTimer - 1;
                if obj.radioAccess.lockTimer <= 0
                    % ORPHAN GUARD: Send CH_REJECT to timed-out CH partner
                    timedOutPartner = obj.radioAccess.handshakePartner;
                    if ~isempty(timedOutPartner)
                        rejectMsg = WSN_Message();
                        rejectMsg.type = WSN_Config.MSG_TYPE_CH_CMD;
                        rejectMsg.subtype = WSN_Config.CH_SUB_REJECT;  % 6.3
                        rejectMsg.src = hex2dec(obj.hexID);
                        rejectMsg.dst = timedOutPartner;
                        rejectMsg.ttl = 1;
                        rejectMsg.addChecksum();
                        obj.radioAccess.requestTX(rejectMsg);
                        obj.addLogAccess(sprintf('t=%d [TIMEOUT] Sent CH_REJECT to orphaned %s', ...
                            t, dec2hex(uint16(timedOutPartner), 4)), [], t);
                        
                        % Purge from children if they were registered
                        if isprop(obj, 'accessChildren') && ~isempty(obj.accessChildren)
                            obj.accessChildren(obj.accessChildren == timedOutPartner) = [];
                        end
                    end
                    obj.radioAccess.timeout();  % Use radio's timeout method
                end
            end

            % ---- BEHAVIOR DECIDES WHAT TO DO ----
            actions = obj.behavior.step(t);
            obj.behavior.apply(actions, t);
            % ---- MESSAGING MATERIALIZES PACKETS ----
            msgs = obj.messaging.emit(actions, t);
            
            % ---- PHASE 2: HELLO MESSAGES (parallel to boot) ----
            % Transmit Hello during boot and periodically after (via Access radio)
            if t >= 0 && t == obj.nextHelloBurst
                helloMsg = obj.createHelloMessage(t);
                msgs = [msgs, helloMsg];
                % Local Access log only (no global event bus for Hello)
                obj.addLogAccess(sprintf('t=%d [HELLO_TX] bcast battery=%.1f%%', ...
                    t, obj.battery), [], t);
                obj.scheduleNextHelloBurst(t);
            end

            % ---- CH-DISCOVERY DVS: periodic stall check ----
            obj.checkChDiscoveryDVS(t);

            % ---- ANNOUNCE PENDING CH CHILDREN TO BACKBONE PARENT ----
            obj.messaging.announcePendingChChildren(t);

            % ---- FLUSH BUFFERED CH_HELLO RELAYS ----
            obj.messaging.flushPendingChHelloForward(t);
        end

        function checkChDiscoveryDVS(obj, t)
            % Periodically check whether chChildren has grown since the
            % last check; if not, scale controlPower up so HELLO/CH_ACK
            % reach further out to distant/orphaned CHs. See property
            % comment above chDvsLastCheckTime for rationale.
            if ~WSN_Config.GWN_CH_DVS_ENABLED, return; end
            if t < obj.chDvsLastCheckTime + WSN_Config.GWN_CH_DVS_CHECK_INTERVAL
                return;
            end

            currentCount = numel(obj.chChildren);
            stalled = currentCount <= obj.chDvsLastChildCount;

            if stalled && obj.chDvsScaleCount < WSN_Config.GWN_CH_DVS_MAX_SCALE_ATTEMPTS ...
                    && obj.controlPower < WSN_Config.MaxGWNPower
                oldPower = obj.controlPower;
                obj.controlPower = min(WSN_Config.MaxGWNPower, ...
                    obj.controlPower * WSN_Config.GWN_CH_DVS_SCALE_FACTOR);
                obj.chDvsScaleCount = obj.chDvsScaleCount + 1;
                obj.addLogAccess(sprintf('t=%d [CH_DVS] No new CH children since t=%d -- controlPower %.2f -> %.2f (attempt %d/%d)', ...
                    t, obj.chDvsLastCheckTime, oldPower, obj.controlPower, ...
                    obj.chDvsScaleCount, WSN_Config.GWN_CH_DVS_MAX_SCALE_ATTEMPTS), [], t);
            elseif ~stalled && obj.controlPower > WSN_Config.TxPower_GWN_Control
                % GWN_Shell.md Issue #4 fix: growth resumed (a new CH child
                % was found since the last check), so the boost served its
                % purpose - reset controlPower back to baseline and refresh
                % the scale-attempt budget. Without this, controlPower only
                % ever ratchets up (capped at MaxGWNPower) and never comes
                % back down even after discovery is no longer stalled,
                % needlessly running the access radio hotter than necessary
                % (more interference/energy draw on every subsequent HELLO/
                % CH_ACK) for the rest of the node's life.
                oldPower = obj.controlPower;
                obj.controlPower = WSN_Config.TxPower_GWN_Control;
                obj.chDvsScaleCount = 0;
                obj.addLogAccess(sprintf('t=%d [CH_DVS] New CH child found -- controlPower reset %.2f -> %.2f (budget refreshed)', ...
                    t, oldPower, obj.controlPower), [], t);
            end

            obj.chDvsLastCheckTime = t;
            obj.chDvsLastChildCount = currentCount;
        end
    end

    % =========================================================
    % RECEIVE â€” FACADE
    % =========================================================
    methods
        function response = receive(obj, msg, t, rssi)
            response = [];
            if obj.isBlacklisted, return; end

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
            localKeyHex = WSN_Gateway_Registry.deriveLocalKey(obj);
        end

        % =====================================================
        % TRUST (ML_IDS_PLAN.md Phase 4) - operates on obj.neighborTrust
        % (NOT neighborTable.TrustScore -- see property comment above)
        % Delegated to WSN_Gateway_Enforcement (GWN/Enforcement/)
        % =====================================================
        function score = getNeighborTrust(obj, neighborID)
            score = WSN_Gateway_Enforcement.getNeighborTrust(obj, neighborID);
        end

        function updateNeighborTrust(obj, neighborID, delta)
            WSN_Gateway_Enforcement.updateNeighborTrust(obj, neighborID, delta);
        end

        % =====================================================
        % ML-IDS CENSUS / SHUTDOWN PROTOCOL (ML_IDS_PLAN.md Phase 4)
        % Delegated to WSN_Gateway_Enforcement (GWN/Enforcement/)
        % =====================================================
        function msgs = checkCensusTriggers(obj, t)
            msgs = WSN_Gateway_Enforcement.checkCensusTriggers(obj, t);
        end

        function response = handleCensusMessage(obj, msg, t)
            response = WSN_Gateway_Enforcement.handleCensusMessage(obj, msg, t);
        end

        function response = handlePollComplete(obj, msg, t)
            response = WSN_Gateway_Enforcement.handlePollComplete(obj, msg, t);
        end

        function handleShutdownMessage(obj, msg, t)
            WSN_Gateway_Enforcement.handleShutdownMessage(obj, msg, t);
        end

        % ----------------------------------------------------------
        % DORMANT: trust-based decision matrix (not yet wired in)
        % ----------------------------------------------------------
        function verdict = evaluateTrustDecision(obj, neighborID)
            verdict = WSN_Gateway_Enforcement.evaluateTrustDecision(obj, neighborID);
        end

        function matrix = buildTrustMatrix(obj)
            matrix = WSN_Gateway_Enforcement.buildTrustMatrix(obj);
        end

        % ----------------------------------------------------------
        % FEATURE-EXPORT ACCESSORS (delegated to WSN_Gateway_FeatureExport)
        % ----------------------------------------------------------
        function n = getActiveChildrenCount(obj)
            n = WSN_Gateway_FeatureExport.getActiveChildrenCount(obj);
        end

        function n = getSilencedChildrenCount(obj)
            n = WSN_Gateway_FeatureExport.getSilencedChildrenCount(obj);
        end

        function row = getTrustFeatureSnapshot(obj, neighborID)
            row = WSN_Gateway_FeatureExport.getTrustFeatureSnapshot(obj, neighborID);
        end


        % -------- DUAL-RADIO LOGGING --------
        function addLogBackbone(obj, txt, ~, ~)
            % Log to Backbone (LoRa) radio log ONLY (no global event feed)
            if isempty(obj.logBackbone)
                obj.logBackbone = {txt};
            else
                obj.logBackbone{end+1} = txt;
            end
            % Also add to unified log (local only - no msg means no global emit)
            obj.addLog(sprintf('[BB] %s', txt));
        end
        
        function addLogAccess(obj, txt, ~, ~)
            % Log to Access (HC12) radio log ONLY (no global event feed)
            if isempty(obj.logAccess)
                obj.logAccess = {txt};
            else
                obj.logAccess{end+1} = txt;
            end
            % Also add to unified log (local only - no msg means no global emit)
            obj.addLog(sprintf('[AC] %s', txt));
        end
        
        function addLogBoth(obj, txt, ~, ~)
            % Log to BOTH radio logs (for common node events like neighbor count)
            % Local only - no global event feed emission
            if isempty(obj.logBackbone)
                obj.logBackbone = {txt};
            else
                obj.logBackbone{end+1} = txt;
            end
            if isempty(obj.logAccess)
                obj.logAccess = {txt};
            else
                obj.logAccess{end+1} = txt;
            end
            % Also add to unified log (local only)
            obj.addLog(txt);
        end
        
        function logTxBackbone(obj, msg, t)
            % Log TX to backbone local log only (HB, GWN-GWN)
            txt = sprintf('t=%d [TX] %s.%d -> %s', t, msg.getTypeStr(), msg.subtype, obj.fmtID(msg.dst));
            obj.addLogBackbone(txt, [], t);
        end
        
        function logTxAccess(obj, msg, t)
            % Log TX to access local log only (CMD, handshake)
            txt = sprintf('t=%d [TX] %s.%d -> %s', t, msg.getTypeStr(), msg.subtype, obj.fmtID(msg.dst));
            obj.addLogAccess(txt, [], t);
        end
    end


end
