% Type 1,5,6,7,8,9 work perfectly.
% Observe Data Flow and Token Passing.
%#ok<*NASGU>   % Suppress "value assigned might be unused" - defensive initializations
%#ok<*FXSET>   % Suppress "nested function loop index" warnings - inherent to MATLAB script structure
function WSN_Main(varargin)
% Parse arguments: WSN_Main(startGUIAt, printInterval, nodes, simSteps, attackCfg)
% Default: WSN_Main() = GUI visible from t=0, runs to WSN_Config.SimSteps
% WSN_Main(100) = GUI becomes visible at t=100; the simulation itself
%                 still runs to WSN_Config.SimSteps (10000 by default) --
%                 this argument does NOT stop the run early.
% WSN_Main(100, 5) = same, prints status every 5 ticks before t=100
% WSN_Main(100, 1, nodes) = headless with pre-created nodes (for WSN_Attack.run)
% WSN_Main(1e9, 50, nodes, 500) = fully headless (GUI never shown, since
%                 startGUIAt > simSteps), runs exactly 500 ticks then
%                 exits and exports logs/CSVs. This is the form used by
%                 WSN_Attack_Demo.m's batch driver (ML_IDS_PLAN.md Phase 3).
% WSN_Main(0, 1, [], [], struct('ActivateAttacks', true)) = GUI mode with
%                 randomized-but-constrained attacks enabled at start.
%                 attackCfg is decoupled from the default start: omitting it
%                 (or ActivateAttacks=false) guarantees NO node ever becomes
%                 an attacker, in both GUI and headless mode. See
%                 WSN_Attack.defaultConfig() / WSN_Attack.configure() for the
%                 full set of optional fields (all randomized when omitted).
preCreatedNodes = [];
simSteps = WSN_Config.SimSteps;
attackCfg = [];
if isempty(varargin)
    startGUIAt = 0;
    printInterval = 1;
else
    startGUIAt = varargin{1};
    if numel(varargin) >= 2
        printInterval = varargin{2};
    else
        printInterval = 1;
    end
    if numel(varargin) >= 3
        preCreatedNodes = varargin{3};
    end
    if numel(varargin) >= 4 && ~isempty(varargin{4})
        simSteps = varargin{4};
    end
    if numel(varargin) >= 5 && ~isempty(varargin{5})
        attackCfg = varargin{5};
    end
end

% Headless mode flag for optimized logging
isHeadless = startGUIAt > 0; %#ok<NASGU> % Used by nested functions

% Autolog settings: export every 250 timeframes
AUTOLOG_INTERVAL = 250;
lastAutolog = 0;

% Ensure logs directory exists
if ~exist('logs', 'dir')
    mkdir('logs');
end

% 1. INITIALIZATION
close all; rng('shuffle');
clc;
% Generate Topology (or use pre-created nodes from WSN_Attack.run)
if ~isempty(preCreatedNodes)
    nodes = preCreatedNodes;
    fprintf('[MAIN] Using pre-created topology (%d nodes)\n', numel(nodes));
else
    nodes = WSN_TopologyGenerator.generateTopology(WSN_Config.NodeCount, WSN_Config.FieldSize);
end

% === ATTACK SYSTEM INITIALIZATION (decoupled from default start) ===
% Attacks are OFF by default. Three ways attack state can arrive here:
%   1. Explicit attackCfg (5th arg) - always takes precedence; see
%      WSN_Attack.configure() for the ActivateAttacks contract.
%   2. Pre-configured data (legacy escape hatch) - a caller such as
%      WSN_Attack_Demo.m or WSN_Attack.run() already called
%      WSN_Attack.init()/setMalicious() on this exact node set before
%      invoking WSN_Main; that configuration is preserved as-is.
%   3. Neither supplied - ActivateAttacks defaults to false, which is a
%      hard guarantee that no node becomes an attacker for the whole run
%      (applies identically to GUI and headless mode).
existingData = WSN_Attack.getData();
preConfigured = ~isempty(existingData) && isfield(existingData, 'isMalicious') ...
                && numel(existingData.isMalicious) == numel(nodes);

if ~isempty(attackCfg)
    WSN_Attack.configure(numel(nodes), nodes, attackCfg);
    atkSummary = WSN_Attack.getAttackSummary();
    fprintf('[ATTACK] Configured via attackCfg: %d malicious node(s)\n', atkSummary.numMalicious);
elseif preConfigured
    fprintf('[ATTACK] Using pre-configured attacks (%d malicious nodes)\n', sum(existingData.isMalicious));
else
    WSN_Attack.configure(numel(nodes), nodes, struct('ActivateAttacks', false));
    fprintf('[ATTACK] No attackCfg provided - attacks disabled (ActivateAttacks=false)\n');
end

% === ML-IDS FEATURE EXPORT INITIALIZATION (ML_IDS_PLAN.md Phase 1-2) ===
WSN_FeatureExport.init(nodes);
WSN_SinkFeatureExport.init();
featureWindowStart = 1;

% Initialize GUI
gui = WSN_GUI(nodes, WSN_Config.FieldSize);
if startGUIAt > 0
    set(gui.fig, 'Visible', 'off');
end

% Initialize Queues & Visuals
queue = {};
visualLines = [];

% Initial Physical Connectivity Calculation (Get both Phys and Stable matrices)
[physAdj, stblAdj, distMat] = WSN_Physics.updateConnectivity(nodes); % % Available for debugging
% --- ID TRANSLATION HELPERS ---
% O(1) hexID->array-index lookup (was O(N) per call via arrayfun+find,
% called multiple times per message delivery in the loop below). Node
% membership/hexIDs are fixed for the life of a run (nodes is only assigned
% once, above), so building this map once is safe and returns identical
% results - including [] on a miss, exactly like the old find(...,1)
% behavior - for every input.
hexIDtoIdx = containers.Map('KeyType', 'double', 'ValueType', 'double');
for k = 1:numel(nodes)
    hexIDtoIdx(hex2dec(nodes(k).hexID)) = k;
end
id2idx = @(hid) lookupNodeIdx(hexIDtoIdx, hid);
idx2id = @(idx) hex2dec(nodes(idx).hexID); % % Helper function

% 2. SIMULATION LOOP
try
    for t = 1:simSteps
        % Stop if GUI is closed
        if ~ishandle(gui.fig), break; end

        % Headless logging and GUI visibility
        if t < startGUIAt
            if mod(t, printInterval) == 0
                fprintf('t=%d\n', t);
            end
        elseif t == startGUIAt
            set(gui.fig, 'Visible', 'on');
            isHeadless = false;  % Switch to headed mode
        end
        
        % AUTOLOG: Export logs every AUTOLOG_INTERVAL timeframes
        if mod(t, AUTOLOG_INTERVAL) == 0 && t > lastAutolog
            lastAutolog = t;
            autoExportLogs(nodes, t, gui);
        end

        % --- RESET TICK-LOCAL STATE FOR ALL RADIOS ---
        for i = 1:numel(nodes)
            nodes(i).radio.resetTick();
            if isa(nodes(i), 'WSN_Gateway') && ~isempty(nodes(i).radioAccess)
                nodes(i).radioAccess.resetTick();
            end
        end

        % --- A. PHYSICS REFRESH (Every Timestep) ---
        % Always recalculate physics - critical for message delivery
        % Rayleigh fading on physAdj means links can change each timestep
        [physAdj, stblAdj, distMat] = WSN_Physics.updateConnectivity(nodes);

        % --- A2. GUI REFRESH (Throttled) ---
        if t >= startGUIAt && mod(t, WSN_Config.ActiveRefresh) == 0
            % Update Tables and Inspector
            gui.updateNetworkTable(nodes,t);
            gui.updateInspector(nodes, t);

            % Update Sink Graphs
            gui.updateSinkAnalytics(nodes, t);
        end

        % --- B. UPDATE PHYSICS & BATTERY ---
        for i = 1:numel(nodes)
            nodes(i).updatePhysics(t);
            WSN_FeatureExport.tapTick(i, nodes(i), t);
        end

        % --- C. MESSAGE GENERATION (Step) ---
        newMsgs = {};
        for i = 1:numel(nodes)
            % Polymorphic Step: Sink needs 'allNodes' for adaptive logic
            if isa(nodes(i), 'WSN_Sink')
                generated = nodes(i).step(t, physAdj, nodes);
            else
                generated = nodes(i).step(t, physAdj);
            end

            if ~isempty(generated)
                for g = generated
                    WSN_FeatureExport.tapTx(i, g, t);
                    hex = g.serialize();                 % HARD TX BOUNDARY
                    % Skip global event bus for Hello (Type 0) and Heartbeat (Type 9)
                    if g.type ~= WSN_Config.MSG_TYPE_HELLO && g.type ~= WSN_Config.MSG_TYPE_HB
                        WSN_GUI_GlobalEventBus.emit(t, hex); % TX sees real frame
                    end
                    newMsgs{end+1} = hex;
                    
                    % --- Apply TX Cost (scales with controlPower) ---
                    baseCost = WSN_Config.BaseTxCost;
                    if isprop(nodes(i), 'controlPower')
                        powerRatio = nodes(i).controlPower / WSN_Config.TxPower_GWN_Control;
                        txCost = baseCost * powerRatio;
                    else
                        txCost = baseCost;
                    end
                    nodes(i).battery = max(0, nodes(i).battery - txCost);
                end
            end

        end

        % --- C2. SYBIL HELLO INJECTION ---
        % Inject fake HELLO messages from Sybil nodes' fake identities
        for i = 1:numel(nodes)
            if WSN_Attack.isMaliciousNode(i, t) && ...
               WSN_Attack.getAttackType(i) == WSN_Attack.ATTACK_SYBIL
                sybilMsgs = WSN_Attack.getSybilHelloMessages(i, t, nodes(i).pos, WSN_Config.HelloRange);
                for j = 1:numel(sybilMsgs)
                    sm = sybilMsgs{j};
                    % Broadcast fake HELLO to all nodes in range of the fake position
                    for dstIdx = 1:numel(nodes)
                        if dstIdx == i, continue; end  % Don't send to self
                        dist = norm(nodes(dstIdx).pos - sm.pos);
                        if dist <= sm.range
                            % Calculate fake RSSI based on fake position
                            fakeRSSI = max(0.1, 1.0 - dist / sm.range);
                            nodes(dstIdx).radio.pushRX(sm.msg, fakeRSSI);
                        end
                    end
                end
            end
        end

        % --- D. MESSAGE DELIVERY (Processing) ---
        currentBatch = [queue, newMsgs];
        queue = {}; % Clear for next frame
        for k = 1:numel(currentBatch)
            hex = currentBatch{k};

            [msg, ok] = WSN_Message.deserialize(hex);
            if ~ok
                % DROP: corrupted, truncated, legacy, or bad checksum
                continue;
            end
            m = msg;

            srcIdx = id2idx(m.src);
            if isempty(srcIdx), continue; end

            % 1. Determine Destinations (Safe Multicast Check)
            destinations = [];
            logDst = 'UNK';

            % Check for Broadcast (Empty, Scalar 0, or 0xFFFF)
            isBroadcast = isempty(m.dst) || (isscalar(m.dst) && (m.dst == 0 || m.dst == hex2dec('FFFF')));
            
            % Check for Multicast Group (e.g., FF00 for verified GWNs)
            isMulticastGroup = isscalar(m.dst) && m.dst == hex2dec('FF00');

            if isBroadcast
                % Broadcast: find all nodes in range via adjacency matrix
                % Adjacency already encodes range physics
                destinations = find(physAdj(srcIdx, :));
                logDst = 'BCAST';
                
            elseif isMulticastGroup
                % Multicast Group: find nodes subscribed to this group AND in range
                destinations = [];
                for di = 1:numel(nodes)
                    if di == srcIdx, continue; end
                    if isprop(nodes(di), 'multicastGroups') && ismember(m.dst, nodes(di).multicastGroups)
                        if physAdj(srcIdx, di)
                            destinations(end+1) = di; %
                        end
                    end
                end
                logDst = 'MCAST_FF00';

            elseif isscalar(m.dst)
                dstIdx = id2idx(m.dst);
                if isempty(dstIdx), continue; end
                
                % Unicast: adjacency matrix determines reachability
                % Physics already encodes range constraints
                if physAdj(srcIdx, dstIdx)
                    destinations = dstIdx;
                else
                    % Out of range; physics blocks it
                    continue;
                end
                logDst = nodes(dstIdx).hexID;

            else
                % Multicast: m.dst is vector of hex-dec IDs
                % Only include destinations within range (per adjacency)
                destinations = [];
                for hid = m.dst
                    di = id2idx(hid);
                    if ~isempty(di)
                        % Physics determines reachability
                        if physAdj(srcIdx, di)
                            destinations(end+1) = di; %
                        end
                    end
                end
                logDst = 'MULTI';
            end
            
            % If no destinations in range, message dies
            if isempty(destinations)
                continue;
            end
            
            % === WORMHOLE ATTACK PROCESSING ===
            % Check if sender is a wormhole endpoint - relay to other endpoint
            if WSN_Attack.isMaliciousNode(srcIdx, t) && ...
               WSN_Attack.getAttackType(srcIdx) == WSN_Attack.ATTACK_WORMHOLE
                [shouldRelay, otherEndpoint] = WSN_Attack.shouldWormholeRelay(srcIdx, t);
                if shouldRelay && ~isempty(otherEndpoint)
                    % Relay message to wormhole partner (out-of-band, lossless)
                    wormholeRSSI = WSN_Attack.getWormholeRSSI(srcIdx);
                    if otherEndpoint <= numel(nodes)
                        nodes(otherEndpoint).radio.pushRX(m, wormholeRSSI);
                        % Log wormhole relay
                        if isprop(nodes(srcIdx), 'addLog')
                            nodes(srcIdx).addLog(sprintf('t=%d [WORMHOLE_RELAY] -> endpoint %d', t, otherEndpoint));
                        end
                    end
                end
            end

            % 2. Attempt Delivery
            anyDelivered = false;
            for dID = destinations
                % Safety check for invalid IDs
                if dID < 1 || dID > numel(nodes), continue; end

                % Protocol Filter: Heartbeats (Type 9) only for GWNs (Tier 3)
                if m.type == 9 && nodes(dID).tier ~= 3
                    continue;
                end
                
                % Protocol Filter: ENC_HB (Type 9, subtype 3) on FF00 - only verified nodes can receive
                if m.type == 9 && m.subtype == 3 && m.dst == hex2dec('FF00')
                    if ~isprop(nodes(dID), 'isVerified') || ~nodes(dID).isVerified
                        continue;  % Drop: receiver not verified
                    end
                end

                % --- RELIABLE CHANNEL LOGIC ---
                canDeliver = false;

                % Channel selection based on SENDER and RECEIVER tiers, not message type
                % GWN-GWN (tier 3 to tier 3): LoRa backbone → stblAdj (no fading)
                % Any link involving CH/Sensor: HC12 access → physAdj (Rayleigh fading)
                if nodes(srcIdx).tier == 3 && nodes(dID).tier == 3
                    % GWN-GWN: stable LoRa backbone
                    if stblAdj(srcIdx, dID), canDeliver = true; end
                else
                    % CH/Sensor involved: HC12 access radio with fading
                    if physAdj(srcIdx, dID), canDeliver = true; end
                end

                if canDeliver
                    % Calculate RSSI based on Sender's Power
                    dist = distMat(srcIdx, dID);

                    if nodes(srcIdx).tier == 3 && nodes(dID).tier == 3
                        if isprop(nodes(srcIdx), 'controlPower')
                            pwr = nodes(srcIdx).controlPower;
                        else
                            pwr = nodes(srcIdx).txPower;
                        end
                    else
                        pwr = nodes(srcIdx).txPower;
                    end

                    rssi = pwr * (1/(max(0.1, dist)^WSN_Config.PathLossExp)) * 100;

                    % DUAL-RADIO ROUTING (GWN only)
                    % Broadcasts (Hello/Heartbeat) → Access radio (HC12)
                    % CH_CMD (Type 6) → Access radio (HC12) - CH-GWN handshake
                    % FSM messages (CMD Type 7) → Backbone radio (LoRa)
                    isBroadcast = m.dst == 0 || m.dst == hex2dec('FFFF');
                    isBroadcastType = m.type == 0 || m.type == 9;  % Hello or Heartbeat
                    isCH_CMD = m.type == WSN_Config.MSG_TYPE_CH_CMD;  % Type 6
                    
                    if isa(nodes(dID), 'WSN_Gateway')
                        if (isBroadcast && isBroadcastType) || isCH_CMD
                            % Broadcast or CH_CMD to Access radio (HC12)
                            nodes(dID).radioAccess.pushRX(m, rssi);
                        else
                            % GWN-GWN FSM to Backbone radio (LoRa)
                            nodes(dID).radio.pushRX(m, rssi);
                        end
                    else
                        % Non-GWN nodes use single radio
                        nodes(dID).radio.pushRX(m, rssi);
                    end
                    WSN_FeatureExport.tapRx(dID, rssi, m, t);
                    anyDelivered = true;

                    % ---- GLOBAL EVENT FEED (RX) ----
                    % COMMENTED OUT: Each receiving node emits, causing duplicates
                    % May be useful when propagation delay is introduced
                    % Skip global event bus for Hello (Type 0) and Heartbeat (Type 9)
                    % if m.type ~= WSN_Config.MSG_TYPE_HELLO && m.type ~= WSN_Config.MSG_TYPE_HB
                    %     WSN_GUI_GlobalEventBus.emit(t, m);
                    % end



                    % VISUALIZATION
                    % Only build visual-line entries when the GUI is (or
                    % will become) visible this tick. visualLines is only
                    % ever read inside the "t >= startGUIAt" render block
                    % below, where it's pruned by expiry before first use -
                    % so any entries built before startGUIAt would already
                    % be expired and discarded by that first prune. Gating
                    % construction here produces identical rendered output
                    % while avoiding unbounded accumulation (visualLines was
                    % never pruned, so it grew for the entire run) and the
                    % classifyPacket() call cost during headless ticks.
                    if t >= startGUIAt
                        [col, lw, ls] = classifyPacket(m, nodes, srcIdx, t);

                        % Skip visualization for Hello messages (Type 0) from NORMAL nodes
                        % But DO draw them if they're from malicious nodes (stark colors)
                        if m.type == WSN_Config.MSG_TYPE_HELLO
                            if ~WSN_Attack.isMaliciousNode(srcIdx, t)
                                % Normal Hello: skip visualization
                                continue;
                            end
                            % Malicious Hello: draw with stark color (short lifetime)
                            lifetime = 1;
                        elseif m.type == WSN_Config.MSG_TYPE_HB
                            % Heartbeat: skip if normal, draw if malicious
                            if ~WSN_Attack.isMaliciousNode(srcIdx, t)
                                continue;
                            end
                            % Malicious Heartbeat: draw with stark color
                            lifetime = 1;
                        elseif m.type == WSN_Config.MSG_TYPE_TOKEN || m.type == WSN_Config.MSG_TYPE_SENSOR
                            % TOKEN and SENSOR packets expire immediately (flash effect)
                            lifetime = 1;
                        else
                            % All other messages: longer lifetime
                            lifetime = 5;
                        end

                        vl = struct( ...
                            'srcPos', nodes(srcIdx).pos, ...
                            'dstPos', nodes(dID).pos, ...
                            'color',  col, ...
                            'style',  ls, ...
                            'width',  lw, ...
                            'expiry', t+lifetime );

                        visualLines = [visualLines, vl];
                    end
                end
            end
            if anyDelivered
                WSN_FeatureExport.tapTxSuccess(srcIdx, t);
            end
        end
        % --- D2. RADIO STEP & PROTOCOL DELIVERY ---
        for i = 1:numel(nodes)

            % -------- BACKBONE RADIO (LoRa): FSM & Unicast --------
            [txOut, rxMsg, rxRSSI] = nodes(i).radio.step(t);

            if ~isempty(txOut)
                WSN_FeatureExport.tapTx(i, txOut{1}, t);
                queue{end+1} = txOut{1}.serialize();
                % Skip global event bus for Hello (Type 0) and Heartbeat (Type 9)
                if txOut{1}.type ~= WSN_Config.MSG_TYPE_HELLO && txOut{1}.type ~= WSN_Config.MSG_TYPE_HB
                    WSN_GUI_GlobalEventBus.emit(t, txOut{1});
                end
            end

            % -------- RX → PROTOCOL (responses deferred) --------
            if ~isempty(rxMsg)
                response = nodes(i).receive(rxMsg, t, rxRSSI);

                % IMPORTANT: do NOT allow immediate TX in same timestep
                if ~isempty(response)
                    for r = response
                        % enqueue into radio buffer only; TX will occur at t+1
                        nodes(i).radio.txBuffer{end+1} = r;
                    end
                end
            end
            
            % -------- ACCESS RADIO (HC12): Broadcasts only (GWN) --------
            if isa(nodes(i), 'WSN_Gateway') && ~isempty(nodes(i).radioAccess)
                [txOut_acc, rxMsg_acc, rxRSSI_acc] = nodes(i).radioAccess.step(t);

                if ~isempty(txOut_acc)
                    WSN_FeatureExport.tapTx(i, txOut_acc{1}, t);
                    queue{end+1} = txOut_acc{1}.serialize();
                    % Skip global event bus for Hello (Type 0) and Heartbeat (Type 9)
                    if txOut_acc{1}.type ~= WSN_Config.MSG_TYPE_HELLO && txOut_acc{1}.type ~= WSN_Config.MSG_TYPE_HB
                        WSN_GUI_GlobalEventBus.emit(t, txOut_acc{1});
                    end
                end

                % -------- RX BROADCAST → PROTOCOL --------
                if ~isempty(rxMsg_acc)
                    response = nodes(i).receive(rxMsg_acc, t, rxRSSI_acc);

                    if ~isempty(response)
                        for r = response
                            nodes(i).radioAccess.txBuffer{end+1} = r;
                        end
                    end
                end
            end
        end

        % --- ML-IDS FEATURE WINDOW FLUSH (every FEATURE_WINDOW_LEN ticks) ---
        if mod(t, WSN_Config.FEATURE_WINDOW_LEN) == 0
            WSN_FeatureExport.flushWindow(nodes, t);
            sinkIdxForFeatures = find(arrayfun(@(n) isa(n, 'WSN_Sink'), nodes), 1);
            if ~isempty(sinkIdxForFeatures)
                WSN_SinkFeatureExport.flushWindow(nodes(sinkIdxForFeatures), id2idx, t, featureWindowStart);
            end
            featureWindowStart = t + 1;
        end

        % --- E. RENDER UPDATE (Only when GUI visible) ---
        if t >= startGUIAt
            if ~isempty(visualLines)
                visualLines = visualLines([visualLines.expiry] >= t);
            end

            gui.updateNetwork(nodes, physAdj, t);
            gui.drawPackets(visualLines, t);
            gui.drawAttackVisuals(nodes, t);  % Ghost links, Sybil nodes, DoS lines
            drawnow limitrate;
        end
    end
    
    % === ATTACK LOG EXPORT (end of simulation) ===
    attackSummary = WSN_Attack.getAttackSummary();
    if attackSummary.numMalicious > 0
        attackLogFile = sprintf('logs/attack_log_%s.csv', datestr(now, 'yyyymmdd_HHMMSS'));
        WSN_Attack.exportGroundTruth(attackLogFile);
        fprintf('[ATTACK] Summary: %d malicious nodes, %d ground truth entries\n', ...
            attackSummary.numMalicious, attackSummary.groundTruthEntries);
    end

    % === ML-IDS FEATURE DATASET EXPORT (end of simulation, ML_IDS_PLAN.md Phase 1-2) ===
    timestampStr = datestr(now, 'yyyymmdd_HHMMSS');
    WSN_FeatureExport.exportCSV(sprintf('logs/local_features_%s.csv', timestampStr));
    WSN_SinkFeatureExport.exportCSV(sprintf('logs/sink_features_%s.csv', timestampStr));

catch ME
    % --- ERROR TRAPPING ---
    fprintf('CRASH AT t=%d: %s\n', t, ME.message);
    for k=1:length(ME.stack)
        fprintf('  File: %s, Line: %d\n', ME.stack(k).name, ME.stack(k).line);
    end
    errordlg(sprintf('Simulation Crashed at t=%d\n%s', t, ME.message), 'WSN Error');
end
    function [col, lw, ls] = classifyPacket(m, nodes, srcIdx, t)
        % Classify packet color, line width, style
        % Uses attack colors for malicious node traffic
        
        % ---------- MALICIOUS SOURCE CHECK ----------
        % If source is malicious, use attack-specific colors
        isMalicious = false;
        if nargin >= 4 && ~isempty(srcIdx) && srcIdx > 0 && srcIdx <= numel(nodes)
            isMalicious = WSN_Attack.isMaliciousNode(srcIdx, t);
        end
        
        if isMalicious
            % Use attack colors for all messages from malicious nodes
            attackColor = WSN_Attack.getMessageColor(srcIdx);
            if ~isempty(attackColor)
                col = attackColor;
                lw  = 2.5;  % Emphasize attack traffic
                ls  = '-';
                return;
            end
        end
        
        % ---------- DEFAULT ----------
        col = [1 0.4 0.7];   % pink
        lw  = 0.5;
        ls  = '-';

        % ---------- HELLO MESSAGES (Type 0) ----------
        % Normally skipped, but if explicitly called with a hello from malicious source,
        % the attack color override above will have already returned.
        % This branch is only reached for normal nodes.
        if m.type == WSN_Config.MSG_TYPE_HELLO
            col = [0 0 0];       % won't be used
            lw  = 0;
            ls  = 'none';        % no line
            return;
        end

        % ---------- HEARTBEATS ----------
        if m.type == 9
            if m.subtype == 3   % ENC_HB
                col = [0.6 0 0.8];   % purple
                lw  = 0.8;
            else
                ls = '--';           % discovery / hello
            end
            return;
        end
        
        % ---------- TYPE 1: SENSOR DATA ----------
        if m.type == WSN_Config.MSG_TYPE_SENSOR
            col = [0.3 0.5 1.0];  % Blue
            lw  = 0.5;            % Thin line
            ls  = '-';
            return;
        end
        
        % ---------- TYPE 2: PANIC MESSAGES ----------
        if m.type == WSN_Config.MSG_TYPE_PANIC
            col = [1.0 0.2 0.2];  % Bright red
            lw  = 3.0;            % Thick to stand out
            ls  = '-';            % Solid line
            return;
        end
        
        % ---------- CH_HELLO (Type 5) ----------
        if m.type == WSN_Config.MSG_TYPE_CH_HELLO
            if m.subtype == 2       % 5.2 SENSOR_AGG
                col = [0.6 0.2 0.8]; % Violet
                lw  = 1.0;
                ls  = '--';          % Dashed
            elseif m.subtype == 3   % 5.3 AGG_ACK
                col = [1.0 0.7 0.2]; % Amber
                lw  = 0.8;
                ls  = '--';          % Dashed
            else                    % 5.0/5.1 CH_HELLO
                col = [0 0.5 0];     % darker green
                lw  = 2.0;
                ls  = '-';
            end
            return;
        end
        
        % ---------- TOKEN FRAMES (Type 8) ----------
        if m.type == WSN_Config.MSG_TYPE_TOKEN
            switch m.subtype
                case 0  % TOKEN_DOWN (8.0)
                    col = [1 0.84 0];    % bright gold
                    lw  = 4.0;
                    ls  = '-';
                case 1  % TOKEN_REQ (8.1)
                    col = [1 0.5 0];     % orange
                    lw  = 3.5;
                    ls  = '--';
                case 2  % PATH_COMPLETE (8.2)
                    col = [0 1 0.8];     % bright teal
                    lw  = 3.5;
                    ls  = '-';
            end
            return;
        end
        
        % ---------- CH_CMD FRAMES (Type 6) ----------
        if m.type == WSN_Config.MSG_TYPE_CH_CMD
            switch m.subtype
                case 0  % CH_REQ
                    col = [0 0.8 1];     % bright cyan
                    lw  = 2.5;
                    ls  = '-';
                case 1  % CH_ACK
                    col = [0 1 0.5];     % bright green-cyan
                    lw  = 3.0;
                    ls  = '-';
                case 2  % KEY_ACK
                    col = [1 0.8 0];     % gold
                    lw  = 3.0;
                    ls  = '-';
                case 3  % CH_REJECT
                    col = [1 0 0.5];     % magenta-red
                    lw  = 2.0;
                    ls  = '--';
            end
            return;
        end

        % ---------- CMD FRAMES (Type 7) ----------
        if m.type ~= 7
            return;
        end

        switch m.subtype
            case 0  % PARENT_INIT
                col = [0 1 0];
                lw  = 1.0;

            case 1  % REQ_JOIN
                col = [0 1 1];       % cyan
                lw  = 1.2;

            case 2  % ACK_JOIN
                col = [0 0.8 0];
                lw  = 2.0;
                ls  = '--';

            case 3  % PARENT_REJECT
                col = [1 0 0];
                lw  = 0.8;

            case 4  % GLOBAL_KEY
                col = [0.9 0.6 0];   % amber
                lw  = 1.2;

            case 5  % ENC_HELLO
                col = [0.4 0.4 1];   % blue
                lw  = 1.0;

            case 6  % DOWN (diagnostic probe)
                col = [0.5 0.5 0.5]; % gray
                lw  = 0.7;
                ls  = '--';

            case 7  % UP (diagnostic response)
                col = [0.7 0.5 0];   % orange
                lw  = 0.7;
                ls  = '--';
        end
    end

    function autoExportLogs(nodes, t, gui)
        % AUTOLOG: Export Global Feed + Sink Registries only
        % Called every AUTOLOG_INTERVAL timeframes (e.g., 250)
        % NOTE: Individual node logs omitted for storage efficiency
        
        timestamp = datestr(now, 'yyyymmdd_HHMMSS');
        
        try
            % 1. GLOBAL LOG (from GlobalEventFeed)
            if ~isempty(gui) && isprop(gui, 'globalEventFeed') && ~isempty(gui.globalEventFeed) && isvalid(gui.globalEventFeed)
                data = get(gui.globalEventFeed.logTable, 'Data');
                if ~isempty(data)
                    globalFile = sprintf('logs/global_t0-%d_%s.csv', t, timestamp);
                    fid = fopen(globalFile, 'w');
                    fprintf(fid, 'Timestamp,Frame,Inference,Type,Subtype,Source,Destination,PayloadLen,Encrypted,Verified,ChecksumOK,Payload,Direction\n');
                    for i = size(data, 1):-1:1
                        row = data(i, :);
                        frame = strrep(char(row{2}), ',', ';');
                        inference = strrep(char(row{3}), ',', ';');
                        payload = strrep(char(row{12}), ',', ';');
                        fprintf(fid, '%d,\"%s\",\"%s\",%d,%d,%s,%s,%d,%d,%d,%d,\"%s\",TX\n', ...
                            row{1}, frame, inference, row{4}, row{5}, char(row{6}), char(row{7}), ...
                            row{8}, row{9}, row{10}, row{11}, payload);
                    end
                    fclose(fid);
                end
            end
            
            % 2. COMBINED FEED (all nodes unified log in one file)
            % NOTE ON PERSISTENCE: this block clears each node's
            % log/logBackbone/logAccess (string history) after exporting it
            % - see the per-field comments below. That clearing is scoped
            % ONLY to those three text-log arrays. Trust state
            % (neighborTrust on SN/CH/GWN, globalTrustRegistry/resetHistory
            % on Sink) lives in entirely separate node properties that this
            % function never reads or writes, so trust scores persist for
            % the life of the node regardless of how often logs are
            % exported/cleared. The only code path that resets trust is the
            % intentional SHUTDOWN_SOFT_RESET handler (attack-response
            % trust reset, part of the Census/Shutdown protocol) - not
            % autolog.
            combinedFile = sprintf('logs/combined_t0-%d_%s.csv', t, timestamp);
            fid = fopen(combinedFile, 'w');
            fprintf(fid, 'NodeID,NodeType,Tier,RadioType,LogEntry\n');
            combinedCount = 0;
            for i = 1:numel(nodes)
                n = nodes(i);
                nodeID = n.hexID;
                nodeType = n.typeStr;
                
                % Backbone log (GWN/Sink only)
                if isprop(n, 'logBackbone') && ~isempty(n.logBackbone)
                    for j = 1:numel(n.logBackbone)
                        entry = strrep(char(n.logBackbone{j}), ',', ';');
                        fprintf(fid, '%s,%s,%d,BACKBONE,\"%s\"\n', nodeID, nodeType, n.tier, entry);
                        combinedCount = combinedCount + 1;
                    end
                    % Clear after export - logs are never capped (addLog
                    % appends with no eviction), so without this each
                    % subsequent autolog re-exports the ENTIRE history
                    % again (duplicating prior exports) and the per-export
                    % cost grows ~O(t), making total autolog cost ~O(t^2)
                    % over a run. Exported data already landed in this
                    % file; the in-memory log only needs to hold entries
                    % since the LAST export.
                    n.logBackbone = {};
                end

                % Access log (GWN/Sink only)
                if isprop(n, 'logAccess') && ~isempty(n.logAccess)
                    for j = 1:numel(n.logAccess)
                        entry = strrep(char(n.logAccess{j}), ',', ';');
                        fprintf(fid, '%s,%s,%d,ACCESS,\"%s\"\n', nodeID, nodeType, n.tier, entry);
                        combinedCount = combinedCount + 1;
                    end
                    n.logAccess = {};
                end

                % Unified log (all nodes)
                if isprop(n, 'log') && ~isempty(n.log)
                    for j = 1:numel(n.log)
                        entry = strrep(char(n.log{j}), ',', ';');
                        fprintf(fid, '%s,%s,%d,UNIFIED,\"%s\"\n', nodeID, nodeType, n.tier, entry);
                        combinedCount = combinedCount + 1;
                    end
                    n.log = {};
                end
            end
            fclose(fid);
            if combinedCount == 0
                delete(combinedFile);
            end
            
            % 3. SINK REGISTRY (if Sink exists)
            sinkIdx = find(arrayfun(@(n) isa(n, 'WSN_Sink'), nodes), 1);
            if ~isempty(sinkIdx)
                sink = nodes(sinkIdx);
                
                % Node Registry
                if ~isempty(sink.nodeRegistry)
                    regFile = sprintf('logs/sink_nodeRegistry_t0-%d_%s.csv', t, timestamp);
                    fid = fopen(regFile, 'w');
                    fprintf(fid, 'HexID,Parent,Route,LocalKey,CHCount,SNCount,GWChildren,CHChildren,SecondaryChildren,LastUpdate\n');
                    for j = 1:numel(sink.nodeRegistry)
                        r = sink.nodeRegistry(j);
                        gwCh = strjoin(arrayfun(@(x) dec2hex(x,4), r.gwChildren, 'UniformOutput', false), ';');
                        chCh = strjoin(arrayfun(@(x) dec2hex(x,4), r.chChildren, 'UniformOutput', false), ';');
                        secCh = strjoin(arrayfun(@(x) dec2hex(x,4), r.secondaryChildren, 'UniformOutput', false), ';');
                        fprintf(fid, '%s,%s,\"%s\",%s,%d,%d,[%s],[%s],[%s],%d\n', ...
                            r.hexID, r.parent, r.route, r.localKey, r.chCount, r.snCount, ...
                            gwCh, chCh, secCh, r.lastUpdate);
                    end
                    fclose(fid);
                end
                
                % Sensor Registry
                if ~isempty(sink.sensorRegistry)
                    sensorFile = sprintf('logs/sink_sensorRegistry_t0-%d_%s.csv', t, timestamp);
                    fid = fopen(sensorFile, 'w');
                    fprintf(fid, 'ID,HexID,ParentCH,TimeseriesCount,LastValue,LastTimestamp\n');
                    for j = 1:numel(sink.sensorRegistry)
                        s = sink.sensorRegistry(j);
                        tsCount = numel(s.timeseries);
                        lastVal = 0; lastT = 0;
                        if tsCount > 0
                            lastVal = s.timeseries(end).value;
                            lastT = s.timeseries(end).time;
                        end
                        pCH = '';
                        if isnumeric(s.parentCH)
                            pCH = dec2hex(uint16(s.parentCH), 4);
                        else
                            pCH = char(s.parentCH);
                        end
                        fprintf(fid, '%d,%s,%s,%d,%d,%d\n', s.id, s.hexID, pCH, tsCount, lastVal, lastT);
                    end
                    fclose(fid);
                end
            end
            
            fprintf('[AUTOLOG] t=%d: Logs exported to logs/\n', t);
        catch ME
            fprintf('[AUTOLOG] Export failed at t=%d: %s\n', t, ME.message);
        end
    end

end

function idx = lookupNodeIdx(map, hid)
    % O(1) hexID->array-index lookup backing id2idx (see "ID TRANSLATION
    % HELPERS" near the top of WSN_Main). Mirrors the exact miss behavior
    % of the old find(arrayfun(...), 1) implementation: returns [] for an
    % empty/unmatched hid instead of erroring on a missing containers.Map key.
    if isempty(hid) || ~isKey(map, double(hid))
        idx = [];
    else
        idx = map(double(hid));
    end
end