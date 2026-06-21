classdef WSN_Sink < WSN_Gateway
    % =========================================================
    % WSN SINK — TERMINAL NODE
    % Inherits Gateway FSM for handshake/retry/timeout logic
    %
    % Sink-specific responsibilities:
    %   - Sequential recruitment: build candidate list, iterate safely
    %   - Immunity to parent requests
    %   - Registry: track recruited nodes and routes
    %   - Sensor data aggregation: receive 5.2, track timeseries
    % =========================================================

    properties
        % Recruitment state: phases and candidates
        bootComplete    logical = false
        recruitmentDone logical = false
        recruitList     uint16  = uint16([])
        recruitPtr      uint16  = uint16(1)
        currentRecruit  uint16  = uint16(0)
        recruitThreshold double = 0.95  % Lower threshold if initial list exhausted

        % Registry: records from completed handshakes (extended with children info)
        nodeRegistry = struct('hexID',{}, 'parent',{}, 'route',{}, 'localKey',{}, ...
                              'chCount',{}, 'snCount',{}, 'gwChildren',{}, ...
                              'chChildren',{}, 'secondaryChildren',{}, 'lastUpdate',{})
        
        % Diagnostic probing
        lastDownProbeTime uint32 = uint32(0)
        terminalLogged    logical = false
        
        % -------- PHASE SCHEDULING (Root) --------
        % Sink is phase root: phaseOffset=0, always phaseInherited=true
        % Children inherit NOT(phaseOffset) during GLOBAL_KEY handshake
        
        % -------- SENSOR REGISTRY (Timeseries) --------
        sensorRegistry = struct('id',{}, 'hexID',{}, 'parentCH',{}, 'timeseries',{}, 'TrustScore',{})
        % timeseries: struct array with fields: time, value, rssi, battery
        
        % -------- GLOBAL TRUST REGISTRY --------
        % Consolidated trust scores for ALL nodes the Sink knows about
        % Sources: neighborTable, nodeRegistry, sensorRegistry
        globalTrustRegistry = struct('id',{}, 'hexID',{}, 'nodeType',{}, 'TrustScore',{}, ...
                                     'lastUpdate',{}, 'packetsReceived',{}, 'anomalyCount',{})
        % nodeType: 'GWN', 'CH', 'SENSOR', 'NEIGHBOR'

        % NOTE: trustDecisionMatrix / trustDecisionPolicy / trustDecisionWeights
        % are inherited from WSN_Gateway (GWN/WSN_Gateway.m) - do not redeclare
        % here. See WSN_Sink_Enforcement.evaluateTrustDecision/buildTrustMatrix
        % (SINK/Enforcement/WSN_Sink_Enforcement.m) for the Sink-specific override.
    end

    % =========================================================
    % CONSTRUCTOR
    % =========================================================
    methods
        function obj = WSN_Sink(id, pos)
            obj@WSN_Gateway(id, pos);

            obj.typeStr  = 'SINK';
            obj.parent   = [];
            obj.children = [];

            obj.minProspectiveChildren = 0;
            
            % PHASE ROOT: Sink has phaseOffset=0, always inherited
            obj.phaseOffset = 0;
            obj.phaseInherited = true;

            obj.nodeRegistry = struct( ...
                'hexID',{}, ...
                'parent',{}, ...
                'route',{}, ...
                'localKey',{}, ...
                'chCount',{}, ...
                'snCount',{}, ...
                'gwChildren',{}, ...
                'chChildren',{}, ...
                'secondaryChildren',{}, ...
                'lastUpdate',{} );
            
            % Initialize global trust registry
            obj.globalTrustRegistry = struct( ...
                'id',{}, ...
                'hexID',{}, ...
                'nodeType',{}, ...
                'TrustScore',{}, ...
                'lastUpdate',{}, ...
                'packetsReceived',{}, ...
                'anomalyCount',{} );
        end
    end

    % =========================================================
    % STEP — SEQUENTIAL RECRUITMENT WITH GUARD CLAUSES
    % =========================================================
    methods
        function msgs = step(obj, t, physAdj, allNodes)
            msgs = WSN_Message.empty;

            % --- PHASE 1: BOOT ---
            if t < WSN_Config.BootSteps
                msgs = step@WSN_Gateway(obj, t, physAdj, allNodes);
                if mod(t,WSN_Config.HelloInterval) == mod(obj.offset,WSN_Config.HelloInterval)
                    msgs = [msgs, obj.messaging.sendHeartbeat(t,'HB_BOOT')];
                end
                return;
            end

            % --- PHASE 2: FINALIZE BOOT (one-time) ---
            if ~obj.bootComplete
                obj.bootComplete = true;
                obj.state = WSN_Config.STATE_SECURE;
                obj.isVerified = true;
                obj.hasKey = true;
                obj.encryptionKey = WSN_Message.GLOBAL_AES_KEY_HEX;
                obj.multicastGroups = hex2dec('FF00');
                obj.addLog(sprintf('t=%d [SINK] Boot complete, ready to recruit', t));
            end

            % --- PHASE 3: BUILD RECRUITMENT LIST (one-time) ---
            if ~obj.recruitmentDone && isempty(obj.recruitList) && ~isempty(obj.neighborTable)
                obj.recruitList = obj.buildRecruitmentList(obj.recruitThreshold);
                obj.addLog(sprintf('t=%d [SINK] Recruitment targets (threshold %.2f): %d nodes', ...
                    t, obj.recruitThreshold, numel(obj.recruitList)));
            end

            % --- PHASE 4: RECRUITMENT COMPLETE? ---
            if obj.recruitmentDone
                % Log terminal status once
                if ~obj.terminalLogged
                    obj.addLog(sprintf('t=%d [SINK] Terminal: recruitment exhausted, %d children secured', t, numel(obj.children)));
                    obj.terminalLogged = true;
                end
                % Add heartbeat and return
                if mod(t,WSN_Config.HelloInterval) == mod(obj.offset,WSN_Config.HelloInterval)
                    hb = obj.messaging.sendHeartbeat(t,'ENC_HB');
                    if ~isempty(hb)
                        msgs = [msgs, hb];
                    end
                end
                return;
            end

            % --- PHASE 5: SEQUENTIAL RECRUITMENT (if not mid-handshake) ---
            if obj.currentRecruit == 0
                % Done when 2+ children secured
                if numel(obj.children) >= 2
                    obj.recruitmentDone = true;
                    obj.addLog(sprintf('t=%d [SINK] Recruitment complete, %d nodes secured', t, numel(obj.children)));
                    return;
                end
                
                % Walk pointer through pre-built list
                while obj.recruitPtr <= numel(obj.recruitList)
                    target = obj.recruitList(obj.recruitPtr);
                    
                    % Skip if already child or rejected
                    if ismember(target, obj.children)
                        obj.recruitPtr = obj.recruitPtr + 1;
                        continue;
                    end
                    idx = find([obj.neighborTable.id] == target, 1);
                    if ~isempty(idx) && obj.neighborTable(idx).status == obj.ST_REJECT
                        obj.recruitPtr = obj.recruitPtr + 1;
                        continue;
                    end
                    
                    % Found valid target
                    obj.behavior.retryTarget = target;
                    obj.behavior.retryCount = 0;
                    obj.currentRecruit = target;
                    return;
                end
                
                % List exhausted
                obj.recruitmentDone = true;
                obj.addLog(sprintf('t=%d [SINK] Recruitment exhausted, %d children', t, numel(obj.children)));
                % Return msgs (already has tokens from PHASE 7)
                return;
            end

            % --- PHASE 6: NORMAL OPERATION (ongoing recruitment + heartbeats) ---
            gwMsgs = step@WSN_Gateway(obj, t, physAdj, allNodes);
            msgs = [msgs, gwMsgs];  % Append gateway messages
            if mod(t,WSN_Config.HelloInterval) == mod(obj.offset,WSN_Config.HelloInterval)
                hb = obj.messaging.sendHeartbeat(t,'ENC_HB');
                if ~isempty(hb)
                    msgs = [msgs, hb];
                end
            end
        end

        function recruitList = buildRecruitmentList(obj, ~)
            % Build sorted list of ALL GWN neighbors by RSSI (once)
            % Sink walks this list with recruitPtr until 2 children secured
            nbrs = obj.neighborTable;
            if isempty(nbrs)
                recruitList = uint16([]);
                return;
            end
            
            gwnNbrs = nbrs([nbrs.tier] == 3);
            if isempty(gwnNbrs)
                recruitList = uint16([]);
                return;
            end
            
            [~, idx] = sort([gwnNbrs.rssi], 'descend');
            recruitList = uint16([gwnNbrs(idx).id]);
        end

        function sendHeartbeatOnly(obj, t, msgs)
            if mod(t,WSN_Config.HelloInterval) == mod(obj.offset,WSN_Config.HelloInterval)
                hb = obj.messaging.sendHeartbeat(t,'ENC_HB');
                if ~isempty(hb)
                    msgs = [msgs, hb];
                end
            end
        end
    end

    % =========================================================
    % RECEIVE — SINK-SPECIFIC HANDLERS
    % =========================================================
    methods
        function response = receive(obj, msg, t, rssi)
            response = [];
            if obj.isBlacklisted, return; end
            obj.battery = max(0, obj.battery - WSN_Config.RxCost);

            if ~msg.verifyChecksum()
                return;
            end

            % Route Type 0 (Hello) messages to gateway handler
            if msg.type == WSN_Config.MSG_TYPE_HELLO
                response = receive@WSN_Gateway(obj, msg, t, rssi);
                return;
            end

            % Route heartbeats to gateway handler
            if msg.type == 9
                response = receive@WSN_Gateway(obj, msg, t, rssi);
                return;
            end

            % ML-IDS CENSUS (Type 11) / SHUTDOWN (Type 12): route to gateway handler
            % (ML_IDS_PLAN.md Phase 4) -- Sink is the terminal adjudicator for any
            % POLL_COMPLETE whose suspect isn't a direct child of an intermediate node
            if msg.type == WSN_Config.MSG_TYPE_CENSUS || msg.type == WSN_Config.MSG_TYPE_SHUTDOWN
                response = receive@WSN_Gateway(obj, msg, t, rssi);
                return;
            end
            
            % =========================================================
            % SINK TERMINATION: Handle encrypted messages from children
            % Sink is the root - all encrypted relays terminate here
            % =========================================================
            if msg.isEncrypted() && ismember(msg.src, obj.children)
                obj.addLogBackbone(sprintf('t=%d [SINK] Received encrypted %s.%d from child %s - TERMINATING', ...
                    t, msg.getTypeStr(), msg.subtype, obj.fmtID(msg.src)), msg, t);
                % Route to appropriate handler based on type
                if msg.type == WSN_Config.MSG_TYPE_CH_HELLO  % Type 5
                    if msg.subtype == WSN_Config.SENSOR_SUB_AGG  % 5.2
                        obj.handleSensorAgg(msg, t);
                    else
                        obj.handleCHHello(msg, t);
                    end
                elseif msg.type == 7 && msg.subtype == 5  % Type 7.5 ENC_HELLO
                    % Forward ENC_HELLO from deeper nodes - route to handleEncHello
                    obj.handleEncHello(msg, t);
                end
                return;  % Message terminates at sink
            end
            
            % SENSOR DATA (Type 1): Direct sensor -> Sink, terminate into analytics
            if msg.type == WSN_Config.MSG_TYPE_SENSOR
                obj.handleDirectSensor(msg, t, rssi);
                return;
            end
            
            % CH_HELLO (Type 5): Handle based on subtype
            if msg.type == WSN_Config.MSG_TYPE_CH_HELLO
                if msg.subtype == WSN_Config.SENSOR_SUB_AGG  % 5.2 SENSOR_AGG
                    obj.handleSensorAgg(msg, t);
                    return;
                end
                % Original CH_HELLO handling (5.0/5.1)
                obj.handleCHHello(msg, t);
                return;
            end
            
            % TOKEN (Type 8): DEPRECATED - Phase scheduling replaces token-based flow control
            % Sink ignores all TOKEN messages now
            if msg.type == WSN_Config.MSG_TYPE_TOKEN
                obj.addLogBackbone(sprintf('t=%d [IGNORED] TOKEN.%d <- %s (phase scheduling active)', ...
                    t, msg.subtype, dec2hex(msg.src, 4)), msg, t);
                return;
            end

            if msg.type ~= 7
                return;
            end

            % Sink immunity: reject all PARENT_INIT (use gateway handler)
            if msg.subtype == 0
                response = receive@WSN_Gateway(obj, msg, t, rssi);
                return;
            end

            % PARENT_REJECT: mark sender rejected, clear current recruit, advance
            if msg.subtype == 3
                sender = msg.src;
                if sender == obj.currentRecruit
                    % Mark as rejected in neighbor table
                    idx = find([obj.neighborTable.id] == sender, 1);
                    if ~isempty(idx)
                        obj.neighborTable(idx).status = WSN_Config.ST_REJECT;
                    end
                    % Clear current recruit and advance pointer
                    obj.currentRecruit = uint16(0);
                    obj.behavior.retryTarget = [];
                    obj.behavior.retryCount = 0;
                    obj.recruitPtr = obj.recruitPtr + 1;
                    obj.handshakePartner = [];
                    obj.radio.clearLock('REJECT');
                    obj.state = WSN_Config.STATE_SECURE;  % Sink always returns to SECURE
                    obj.addLog(sprintf('t=%d [SINK] PARENT_REJECT from %s, trying next candidate', t, dec2hex(uint16(sender),4)));
                end
                return;
            end

            % ENC_HELLO: terminal event, advance recruitment
            if msg.subtype == 5 && msg.dst == hex2dec(obj.hexID)
                obj.handleEncHello(msg, t);
                return;
            end

            % Default: gateway handler
            response = receive@WSN_Gateway(obj, msg, t, rssi);
        end

        function handleEncHello(obj, msg, t)
            % Delegates to WSN_Sink_Registry (SINK/Registry/WSN_Sink_Registry.m)
            WSN_Sink_Registry.handleEncHello(obj, msg, t);
        end

        function handleCHHello(obj, msg, t)
            % Delegates to WSN_Sink_Registry (SINK/Registry/WSN_Sink_Registry.m)
            WSN_Sink_Registry.handleCHHello(obj, msg, t);
        end
    end

    % =========================================================
    % ROUTE TRACE
    % =========================================================
    methods
        function routeStr = traceRoute(obj, targetHex)
            % Delegates to WSN_Sink_Registry (SINK/Registry/WSN_Sink_Registry.m)
            routeStr = WSN_Sink_Registry.traceRoute(obj, targetHex);
        end
    end

    % =========================================================
    % TOKEN METHODS
    % =========================================================
    methods
        function localKeyHex = deriveRemoteLocalKey(obj, remoteID)
            % Delegates to WSN_Sink_Registry (SINK/Registry/WSN_Sink_Registry.m)
            localKeyHex = WSN_Sink_Registry.deriveRemoteLocalKey(obj, remoteID);
        end

        % =========================================================
        % DIRECT SENSOR DATA (Type 1) - Terminate into analytics
        % =========================================================
        function handleDirectSensor(obj, msg, t, rssi)
            % Delegates to WSN_Sink_Registry (SINK/Registry/WSN_Sink_Registry.m)
            WSN_Sink_Registry.handleDirectSensor(obj, msg, t, rssi);
        end

        % =========================================================
        % SENSOR DATA HANDLING (5.2 SENSOR_AGG)
        % =========================================================
        function handleSensorAgg(obj, msg, t)
            % Delegates to WSN_Sink_Registry (SINK/Registry/WSN_Sink_Registry.m)
            WSN_Sink_Registry.handleSensorAgg(obj, msg, t);
        end
    end

    % =========================================================
    % GLOBAL TRUST REGISTRY METHODS (Enforcement)
    % =========================================================
    methods
        function updateGlobalTrust(obj, nodeID, hexID, nodeType, t, isSuccess)
            % Delegates to WSN_Sink_Enforcement (SINK/Enforcement/WSN_Sink_Enforcement.m)
            WSN_Sink_Enforcement.updateGlobalTrust(obj, nodeID, hexID, nodeType, t, isSuccess);
        end

        function trust = getGlobalTrust(obj, nodeID)
            % Delegates to WSN_Sink_Enforcement (SINK/Enforcement/WSN_Sink_Enforcement.m)
            trust = WSN_Sink_Enforcement.getGlobalTrust(obj, nodeID);
        end

        function summary = getGlobalTrustSummary(obj)
            % Delegates to WSN_Sink_Enforcement (SINK/Enforcement/WSN_Sink_Enforcement.m)
            summary = WSN_Sink_Enforcement.getGlobalTrustSummary(obj);
        end

        function verdict = evaluateTrustDecision(obj, nodeID)
            % DORMANT: see WSN_Sink_Enforcement.evaluateTrustDecision - not
            % yet wired into any active call path.
            verdict = WSN_Sink_Enforcement.evaluateTrustDecision(obj, nodeID);
        end

        function matrix = buildTrustMatrix(obj)
            % DORMANT: see WSN_Sink_Enforcement.buildTrustMatrix - not yet
            % wired into any active call path.
            matrix = WSN_Sink_Enforcement.buildTrustMatrix(obj);
        end

        function count = getActiveSensorsCount(obj, t, windowSize)
            % Delegates to WSN_Sink_FeatureExport (SINK/FeatureExport/WSN_Sink_FeatureExport.m)
            if nargin < 3
                windowSize = 50;
            end
            count = WSN_Sink_FeatureExport.getActiveSensorsCount(obj, t, windowSize);
        end
    end
end
