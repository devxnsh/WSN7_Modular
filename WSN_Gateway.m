classdef WSN_Gateway < WSN_Node
    % =========================================================
    % WSN GATEWAY — FACADE / STATE OWNER
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
        chChildren = []          % List of recruited CH IDs
        secondaryChildren = []   % List of secondary CH IDs recruited by our CHs
        chLocalKeys = containers.Map()  % Map of CH hexID to local key
        % Pending children: awaiting ENC_HELLO confirmation (secure handshake)
        % Struct array: {id, addedAt} - times out after PENDING_CHILD_TIMEOUT
        pendingChildren = struct('id',{},'addedAt',{})
        PENDING_CHILD_TIMEOUT = 15  % TFs to wait for ENC_HELLO before purging
        
        % -------- PHASE SCHEDULING STATE (replaces TOKEN system) --------
        phaseOffset = 0                     % 0 or 1, inherited from parent (NOT of parent's offset)
        currentPhase = 0                    % Current radio phase: PHASE_RX=0, PHASE_TX=1, PHASE_IDLE=2
        phaseInherited = false              % True once phaseOffset received from parent
        
        % -------- DUAL QUEUES (Phase-Scheduled Backbone) --------
        % Q_fwd: Forwarding queue (child→parent relay) - STRICT PRIORITY
        % Q_local: Local queue (own data: CH_HELLO, SENSOR_AGG)
        Q_fwd = {}                          % Cell array of messages to forward
        Q_local = {}                        % Cell array of locally generated messages
        
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
    % STEP — FACADE
    % =========================================================
    methods
        function msgs = step(obj, t, physAdj, allNodes)
            %#ok<INUSD>
            msgs = WSN_Message.empty;

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
            % Guard against empty or invalid encryption key
            if isempty(obj.encryptionKey) || ~ischar(obj.encryptionKey) || mod(numel(obj.encryptionKey), 2) ~= 0
                localKeyHex = '';  % Return empty if no valid key
                return;
            end
            
            try
                gk = uint8(hex2dec(reshape(obj.encryptionKey,2,[])'));
                if numel(gk) < 8
                    localKeyHex = '';
                    return;
                end
                idBytes = typecast(uint16(hex2dec(obj.hexID)),'uint8');
                pBytes  = typecast(uint16(obj.parent),'uint8');
                seed = [gk; idBytes(:); pBytes(:)];
                lk = gk(1:8);
                for i = 1:numel(seed)
                    lk(mod(i-1,8)+1) = bitxor(lk(mod(i-1,8)+1), seed(i));
                end
                localKeyHex = upper(reshape(dec2hex(lk,2).',1,[]));
            catch
                localKeyHex = '';  % Return empty on any error
            end
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
