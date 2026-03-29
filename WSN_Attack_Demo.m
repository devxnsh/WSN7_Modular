function WSN_Attack_Demo(attackType, intensity, varargin)
% =========================================================================
% WSN_ATTACK_DEMO - Attack Pattern Training Environment
% =========================================================================
% Self-contained simulation with:
%   - WARMUP PHASE: 500-800 ticks of normal behavior (headless)
%   - ATTACK PHASE: GUI appears at t=0, one node turns malicious
%   - STANDARD GUI: Same layout patterns as WSN_GUI (stable, throttled)
%
% USAGE:
%   WSN_Attack_Demo()                     % Interactive
%   WSN_Attack_Demo(1, 5)                 % Flooding, intensity 5
%   WSN_Attack_Demo(4, 7, 'neighbors', 8) % Blackhole, 8 neighbors
%   WSN_Attack_Demo(3, 5, 'export', true) % Sybil + export CSV
%
% ATTACK TYPES: 0=NONE, 1=FLOOD, 2=PANIC, 3=SYBIL, 4=BLACKHOLE,
%               5=WORMHOLE, 6=GRAYHOLE, 7=DENIAL_SLEEP
% =========================================================================

    %% === CONFIGURATION ===
    WARMUP_TICKS = 600;        % Normal behavior before attack
    ATTACK_DURATION = 400;     % Ticks after attack starts
    GUI_REFRESH_RATE = 5;      % Update GUI every N ticks (like WSN_Config.ActiveRefresh)

    %% === PARSE ARGUMENTS ===
    if nargin < 1, attackType = selectAttackMenu(); end
    if attackType < 0, return; end
    if nargin < 2, intensity = 5; end

    p = inputParser;
    addParameter(p, 'neighbors', 6, @isnumeric);
    addParameter(p, 'duration', ATTACK_DURATION, @isnumeric);
    addParameter(p, 'export', false, @islogical);
    addParameter(p, 'fieldSize', 100, @isnumeric);
    addParameter(p, 'warmup', WARMUP_TICKS, @isnumeric);
    parse(p, varargin{:});

    cfg = p.Results;
    cfg.attackType = max(0, min(7, attackType));
    cfg.intensity = max(1, min(10, intensity));
    cfg.guiRefresh = GUI_REFRESH_RATE;

    %% === PRINT BANNER ===
    fprintf('\n');
    fprintf('╔════════════════════════════════════════════════════════════╗\n');
    fprintf('║        WSN ATTACK PATTERN TRAINING ENVIRONMENT             ║\n');
    fprintf('╠════════════════════════════════════════════════════════════╣\n');
    fprintf('║  Attack: %-12s  Intensity: %d/10                      ║\n', ...
        getAttackName(cfg.attackType), cfg.intensity);
    fprintf('║  Warmup: %-4d ticks     Attack Phase: %-4d ticks           ║\n', ...
        cfg.warmup, cfg.duration);
    fprintf('║  Neighbors: %-2d          Field Size: %-3d                    ║\n', ...
        cfg.neighbors, cfg.fieldSize);
    fprintf('╚════════════════════════════════════════════════════════════╝\n\n');

    %% === CREATE NODES ===
    nodes = createNodes(cfg);
    N = numel(nodes);

    %% === INITIALIZE OBSERVATION LOG ===
    totalTicks = cfg.warmup + cfg.duration;
    obsLog = initObservationLog(totalTicks, cfg.neighbors);

    %% === WARMUP PHASE (Headless - Normal Behavior) ===
    fprintf('[WARMUP] Running %d ticks of normal behavior...\n', cfg.warmup);
    for t = 1:cfg.warmup
        % All nodes behave normally during warmup
        runSimulationTick(nodes, t, cfg, false);  % isAttackActive = false
        obsLog = recordObservations(nodes, t, cfg, obsLog, false);

        if mod(t, 100) == 0
            fprintf('  Warmup: t=%d/%d\n', t, cfg.warmup);
        end
    end
    fprintf('[WARMUP] Complete. Baseline established.\n\n');

    %% === INITIALIZE GUI (Standard Layout) ===
    fprintf('[ATTACK] Initializing GUI...\n');
    gui = initStandardGUI(cfg, nodes);

    % Mark attacker
    nodes(1).isAttacker = true;
    nodes(1).attackStartTime = cfg.warmup + 1;

    fprintf('[ATTACK] Node %s turns MALICIOUS at t=%d\n', nodes(1).hexID, cfg.warmup + 1);
    fprintf('[ATTACK] Attack type: %s, Intensity: %d\n\n', getAttackName(cfg.attackType), cfg.intensity);

    %% === ATTACK PHASE (GUI Visible) ===
    fprintf('[ATTACK] Starting attack phase (%d ticks)...\n', cfg.duration);

    for t = (cfg.warmup + 1):(cfg.warmup + cfg.duration)
        % Check if GUI closed
        if ~ishandle(gui.fig)
            fprintf('[ATTACK] GUI closed, stopping.\n');
            break;
        end

        % Run simulation with attack active
        msgs = runSimulationTick(nodes, t, cfg, true);  % isAttackActive = true
        obsLog = recordObservations(nodes, t, cfg, obsLog, true);

        % Update GUI (throttled like WSN_GUI)
        displayT = t - cfg.warmup;  % Display relative time (0 = attack start)
        if mod(displayT, cfg.guiRefresh) == 0
            updateStandardGUI(gui, nodes, displayT, cfg, msgs);
            drawnow limitrate;
        end

        % Progress
        if mod(displayT, 50) == 0
            fprintf('  Attack phase: t=%d/%d\n', displayT, cfg.duration);
        end
    end

    %% === EXPORT TRAINING DATA ===
    if cfg.export
        exportTrainingData(obsLog, cfg);
    end

    %% === SUMMARY ===
    printSummary(nodes, obsLog, cfg);
    fprintf('\n[DEMO] Complete.\n');
end

%% ========================================================================
%% NODE CREATION
%% ========================================================================
function nodes = createNodes(cfg)
    % Create nodes with full state tracking (like real WSN nodes)
    N = cfg.neighbors + 1;
    center = cfg.fieldSize / 2;
    radius = cfg.fieldSize * 0.35;

    % Pre-allocate struct array
    nodeTemplate = struct(...
        'id', 0, ...
        'hexID', '', ...
        'pos', [0 0], ...
        'tier', 1, ...
        'battery', 100, ...
        'txPower', 1.0, ...
        'isAttacker', false, ...
        'attackStartTime', 0, ...
        ... % Radio state
        'txCount', 0, ...
        'rxCount', 0, ...
        'lastTxTime', 0, ...
        'lastRxTime', 0, ...
        ... % Message tracking
        'rxBuffer', {{}}, ...
        'msgTypeHist', zeros(1, 16), ...
        'rssiHistory', [], ...
        ... % Logs (like real nodes)
        'log', {{}}, ...
        'logBackbone', {{}}, ...
        'logAccess', {{}}, ...
        ... % Neighbor tracking
        'neighborTable', struct('hexID', {}, 'rssi', {}, 'lastSeen', {}, 'tier', {}), ...
        ... % Per-tick state
        'rxThisTick', {{}}, ...
        'txThisTick', false ...
    );

    nodes = repmat(nodeTemplate, 1, N);

    % Attacker at center
    nodes(1).id = 1;
    nodes(1).hexID = 'AAAA';
    nodes(1).pos = [center, center];
    nodes(1).tier = 3;
    nodes(1).battery = 100;
    nodes(1).txPower = 1.0;

    % Observers in ring (mixed tiers)
    tierPool = [1, 1, 2, 2, 3, 3];
    for i = 1:cfg.neighbors
        angle = (i-1) * 2 * pi / cfg.neighbors;
        r = radius * (0.85 + 0.3 * rand());

        nodes(i+1).id = i + 1;
        nodes(i+1).hexID = sprintf('%04X', i);
        nodes(i+1).pos = [center + r*cos(angle), center + r*sin(angle)];
        nodes(i+1).tier = tierPool(mod(i-1, numel(tierPool)) + 1);
        nodes(i+1).battery = 85 + 15*rand();
        nodes(i+1).txPower = 0.6 + 0.4*rand();
    end
end

%% ========================================================================
%% SIMULATION TICK
%% ========================================================================
function msgs = runSimulationTick(nodes, t, cfg, isAttackActive)
    N = numel(nodes);
    msgs = {};

    % Reset per-tick state
    for i = 1:N
        nodes(i).rxThisTick = {};
        nodes(i).txThisTick = false;
    end

    % Generate messages
    for i = 1:N
        if i == 1 && isAttackActive
            % Attacker generates attack messages
            nodeMsgs = generateAttackMessages(nodes(i), t, cfg);
        else
            % Normal node behavior
            nodeMsgs = generateNormalMessages(nodes(i), t, cfg);
        end
        msgs = [msgs, nodeMsgs]; %#ok<AGROW>
    end

    % Deliver messages (simplified physics)
    for m = 1:numel(msgs)
        msg = msgs{m};
        srcIdx = msg.srcIdx;
        srcPos = nodes(srcIdx).pos;

        for i = 1:N
            if i == srcIdx, continue; end

            % Distance-based RSSI with fading
            dist = norm(nodes(i).pos - srcPos);
            rssi = msg.txPower * (1 / max(0.1, dist)^2) * 100;
            rssi = rssi * (0.6 + 0.8 * rand());  % Rayleigh-like fading

            if rssi > 0.15  % Sensitivity threshold
                msg.rssi = rssi;
                msg.rxTime = t;
                nodes(i).rxThisTick{end+1} = msg;
                nodes(i).rxCount = nodes(i).rxCount + 1;
                nodes(i).msgTypeHist(msg.type + 1) = nodes(i).msgTypeHist(msg.type + 1) + 1;
                nodes(i).rssiHistory(end+1) = rssi;
                nodes(i).lastRxTime = t;

                % Update neighbor table
                updateNeighborTable(nodes(i), msg, t);

                % Log reception
                logEntry = sprintf('t=%d [RX] Type.%d.%d <- %s RSSI=%.1f', ...
                    t, msg.type, msg.subtype, msg.srcHex, rssi);
                nodes(i).log{end+1} = logEntry;
            end
        end
    end

    % Handle attack-specific effects
    if isAttackActive
        handleAttackEffects(nodes, t, cfg);
    end

    % Update battery
    for i = 1:N
        baseDrain = 0.005;
        txDrain = 0.02 * (nodes(i).txThisTick);
        rxDrain = 0.01 * numel(nodes(i).rxThisTick);

        % Denial of sleep increases neighbor drain
        if cfg.attackType == 7 && isAttackActive && i > 1
            rxDrain = rxDrain * 1.5;
        end

        nodes(i).battery = max(0, nodes(i).battery - baseDrain - txDrain - rxDrain);
    end
end

function msgs = generateNormalMessages(node, t, cfg)
    msgs = {};

    % Tier-based normal behavior
    switch node.tier
        case 1  % Sensor - periodic data
            period = 20 + mod(node.id * 7, 10);
            if mod(t, period) == mod(node.id, period)
                msgs{end+1} = createMessage(node, 1, 0, t);  % SENSOR_DATA
                node.txThisTick = true;
                node.txCount = node.txCount + 1;
                node.lastTxTime = t;
            end

        case 2  % CH - aggregation + occasional Hello
            if mod(t, 30) == mod(node.id * 3, 30)
                msgs{end+1} = createMessage(node, 5, 2, t);  % SENSOR_AGG
                node.txThisTick = true;
                node.txCount = node.txCount + 1;
                node.lastTxTime = t;
            end
            if mod(t, 50) == mod(node.id * 5, 50)
                msgs{end+1} = createMessage(node, 0, 0, t);  % HELLO
                node.txThisTick = true;
            end

        case 3  % GWN - Hello + occasional CMD
            if mod(t, 25) == mod(node.id * 2, 25)
                msgs{end+1} = createMessage(node, 0, 0, t);  % HELLO
                node.txThisTick = true;
                node.txCount = node.txCount + 1;
                node.lastTxTime = t;
            end
            if mod(t, 60) == mod(node.id, 60)
                msgs{end+1} = createMessage(node, 7, 5, t);  % ENC_HELLO
                node.txThisTick = true;
            end
    end
end

function msgs = generateAttackMessages(node, t, cfg)
    msgs = {};
    baseRate = 11 - cfg.intensity;  % 1=fast, 10=slow

    switch cfg.attackType
        case 0  % BASELINE - normal behavior
            msgs = generateNormalMessages(node, t, cfg);

        case 1  % FLOODING - excessive Hellos
            burstSize = ceil(cfg.intensity / 2);
            if mod(t, max(1, baseRate)) == 0
                for b = 1:burstSize
                    msgs{end+1} = createMessage(node, 0, 0, t);
                    msgs{end}.isAttack = true;
                end
                node.txThisTick = true;
                node.txCount = node.txCount + burstSize;
                node.lastTxTime = t;
                node.log{end+1} = sprintf('t=%d [ATTACK] FLOOD burst=%d', t, burstSize);
            end

        case 2  % PANIC_FLOOD - false emergencies
            if mod(t, max(2, baseRate)) == 0
                subtype = mod(floor(t/10), 4);  % Rotate subtypes
                msgs{end+1} = createMessage(node, 2, subtype, t);
                msgs{end}.isAttack = true;
                node.txThisTick = true;
                node.txCount = node.txCount + 1;
                node.lastTxTime = t;
                node.log{end+1} = sprintf('t=%d [ATTACK] PANIC subtype=%d', t, subtype);
            end

        case 3  % SYBIL - multiple identities
            numIDs = ceil(cfg.intensity / 3) + 1;
            if mod(t, max(3, baseRate)) == 0
                for id = 1:numIDs
                    msg = createMessage(node, 0, 0, t);
                    msg.spoofedHex = sprintf('SYB%d', id);
                    msg.isAttack = true;
                    msgs{end+1} = msg;
                end
                node.txThisTick = true;
                node.txCount = node.txCount + numIDs;
                node.lastTxTime = t;
                node.log{end+1} = sprintf('t=%d [ATTACK] SYBIL identities=%d', t, numIDs);
            end

        case 4  % BLACKHOLE - normal Hello, drop on RX
            if mod(t, 20) == 0
                msgs{end+1} = createMessage(node, 0, 0, t);
                node.txThisTick = true;
            end
            % Dropping handled in handleAttackEffects

        case 5  % WORMHOLE - tunnel packets
            if mod(t, max(2, baseRate)) == 0
                msg = createMessage(node, 7, 0, t);
                msg.isWormhole = true;
                msg.isAttack = true;
                msgs{end+1} = msg;
                node.txThisTick = true;
                node.txCount = node.txCount + 1;
                node.lastTxTime = t;
            end

        case 6  % GRAYHOLE - normal Hello, selective drop
            if mod(t, 15) == 0
                msgs{end+1} = createMessage(node, 0, 0, t);
                node.txThisTick = true;
            end
            % Dropping handled in handleAttackEffects

        case 7  % DENIAL_SLEEP - wake packets
            if mod(t, max(1, baseRate)) == 0
                msg = createMessage(node, 9, 0, t);  % Heartbeat
                msg.isWake = true;
                msg.isAttack = true;
                msgs{end+1} = msg;
                node.txThisTick = true;
                node.txCount = node.txCount + 1;
                node.lastTxTime = t;
                node.log{end+1} = sprintf('t=%d [ATTACK] WAKE packet', t);
            end
    end
end

function msg = createMessage(node, msgType, subtype, t)
    msg = struct(...
        'srcIdx', node.id, ...
        'srcHex', node.hexID, ...
        'type', msgType, ...
        'subtype', subtype, ...
        'txTime', t, ...
        'txPower', node.txPower, ...
        'srcPos', node.pos, ...
        'srcTier', node.tier, ...
        'isAttack', false, ...
        'spoofedHex', '', ...
        'isWormhole', false, ...
        'isWake', false, ...
        'rssi', 0, ...
        'rxTime', 0 ...
    );
end

function handleAttackEffects(nodes, t, cfg)
    attacker = nodes(1);

    switch cfg.attackType
        case 4  % BLACKHOLE - drop incoming data
            dropRate = cfg.intensity / 10;
            dropped = 0;
            for m = 1:numel(attacker.rxThisTick)
                if rand() < dropRate
                    attacker.rxThisTick{m}.dropped = true;
                    dropped = dropped + 1;
                end
            end
            if dropped > 0
                attacker.log{end+1} = sprintf('t=%d [ATTACK] BLACKHOLE dropped=%d', t, dropped);
            end

        case 6  % GRAYHOLE - selective drop (data types)
            dropRate = cfg.intensity / 15;
            dropped = 0;
            for m = 1:numel(attacker.rxThisTick)
                msg = attacker.rxThisTick{m};
                % Drop sensor data (type 1) and aggregations (type 5)
                if (msg.type == 1 || msg.type == 5) && rand() < dropRate
                    attacker.rxThisTick{m}.dropped = true;
                    dropped = dropped + 1;
                end
            end
            if dropped > 0
                attacker.log{end+1} = sprintf('t=%d [ATTACK] GRAYHOLE dropped=%d', t, dropped);
            end
    end
end

function updateNeighborTable(node, msg, t)
    % Find existing entry or add new
    found = false;
    srcHex = msg.srcHex;
    if ~isempty(msg.spoofedHex)
        srcHex = msg.spoofedHex;  % Use spoofed ID for Sybil
    end

    for n = 1:numel(node.neighborTable)
        if strcmp(node.neighborTable(n).hexID, srcHex)
            node.neighborTable(n).rssi = msg.rssi;
            node.neighborTable(n).lastSeen = t;
            found = true;
            break;
        end
    end

    if ~found
        newEntry = struct('hexID', srcHex, 'rssi', msg.rssi, 'lastSeen', t, 'tier', msg.srcTier);
        node.neighborTable(end+1) = newEntry;
    end
end

%% ========================================================================
%% OBSERVATION LOGGING
%% ========================================================================
function obsLog = initObservationLog(totalTicks, numNeighbors)
    obsLog = struct();
    obsLog.time = zeros(totalTicks, 1);
    obsLog.phase = zeros(totalTicks, 1);  % 0=warmup, 1=attack

    % Per neighbor per tick
    obsLog.rxFromAttacker = zeros(totalTicks, numNeighbors);
    obsLog.rxTotal = zeros(totalTicks, numNeighbors);
    obsLog.avgRSSI = zeros(totalTicks, numNeighbors);
    obsLog.battery = zeros(totalTicks, numNeighbors);
    obsLog.neighborCount = zeros(totalTicks, numNeighbors);
    obsLog.spoofedCount = zeros(totalTicks, numNeighbors);
    obsLog.isAnomalous = zeros(totalTicks, numNeighbors);
end

function obsLog = recordObservations(nodes, t, cfg, obsLog, isAttackActive)
    obsLog.time(t) = t;
    obsLog.phase(t) = isAttackActive;

    for i = 2:numel(nodes)
        nIdx = i - 1;
        node = nodes(i);

        % Count messages from attacker
        fromAttacker = 0;
        spoofed = 0;
        rssiVals = [];

        for m = 1:numel(node.rxThisTick)
            msg = node.rxThisTick{m};
            if msg.srcIdx == 1
                fromAttacker = fromAttacker + 1;
                rssiVals(end+1) = msg.rssi; %#ok<AGROW>
            end
            if ~isempty(msg.spoofedHex)
                spoofed = spoofed + 1;
            end
        end

        obsLog.rxFromAttacker(t, nIdx) = fromAttacker;
        obsLog.rxTotal(t, nIdx) = numel(node.rxThisTick);
        obsLog.battery(t, nIdx) = node.battery;
        obsLog.neighborCount(t, nIdx) = numel(node.neighborTable);
        obsLog.spoofedCount(t, nIdx) = spoofed;

        if ~isempty(rssiVals)
            obsLog.avgRSSI(t, nIdx) = mean(rssiVals);
        end

        % Ground truth
        obsLog.isAnomalous(t, nIdx) = isAttackActive && fromAttacker > 0 && cfg.attackType > 0;
    end
end

%% ========================================================================
%% STANDARD GUI (Matching WSN_GUI Layout)
%% ========================================================================
function gui = initStandardGUI(cfg, nodes)
    gui = struct();

    % Main figure (similar to WSN_GUI)
    gui.fig = figure('Name', sprintf('WSN Attack Demo: %s (I=%d)', ...
        getAttackName(cfg.attackType), cfg.intensity), ...
        'NumberTitle', 'off', ...
        'Position', [50 50 1200 700], ...
        'Color', [0.15 0.15 0.2], ...
        'MenuBar', 'none', ...
        'ToolBar', 'figure');

    % === LEFT PANEL: Topology ===
    gui.axTopo = axes('Parent', gui.fig, 'Position', [0.02 0.35 0.4 0.6]);
    hold(gui.axTopo, 'on');
    axis(gui.axTopo, [0 cfg.fieldSize 0 cfg.fieldSize]);
    axis(gui.axTopo, 'square');
    set(gui.axTopo, 'Color', [0.1 0.1 0.12], 'XColor', [0.5 0.5 0.5], 'YColor', [0.5 0.5 0.5]);
    title(gui.axTopo, 'Network Topology', 'Color', 'w', 'FontSize', 11);
    grid(gui.axTopo, 'on');
    set(gui.axTopo, 'GridColor', [0.3 0.3 0.3], 'GridAlpha', 0.5);

    % Draw nodes
    tierColors = {[0.3 0.9 0.3], [0.9 0.7 0.2], [0.3 0.6 1.0]};  % Sensor, CH, GWN
    attackerColor = [1.0 0.2 0.2];

    gui.nodeScatters = gobjects(numel(nodes), 1);
    gui.nodeLabels = gobjects(numel(nodes), 1);

    for i = 1:numel(nodes)
        if nodes(i).isAttacker
            col = attackerColor;
            sz = 180;
        else
            col = tierColors{nodes(i).tier};
            sz = 60 + nodes(i).tier * 25;
        end

        gui.nodeScatters(i) = scatter(gui.axTopo, nodes(i).pos(1), nodes(i).pos(2), ...
            sz, col, 'filled', 'MarkerEdgeColor', 'w', 'LineWidth', 1.5);

        gui.nodeLabels(i) = text(gui.axTopo, nodes(i).pos(1), nodes(i).pos(2) - 5, ...
            nodes(i).hexID, 'Color', 'w', 'FontSize', 9, 'FontWeight', 'bold', ...
            'HorizontalAlignment', 'center');
    end

    % === RIGHT TOP: Network Table (like WSN_GUI_NetworkState) ===
    gui.panelTable = uipanel('Parent', gui.fig, 'Position', [0.44 0.5 0.54 0.48], ...
        'BackgroundColor', [0.12 0.12 0.15], 'BorderType', 'line', ...
        'HighlightColor', [0.3 0.3 0.4], 'Title', 'Network State', ...
        'ForegroundColor', 'w', 'FontSize', 10);

    colNames = {'ID', 'Tier', 'Battery', 'TX', 'RX', 'Neighbors', 'Last RX', 'Status'};
    gui.tblNetwork = uitable('Parent', gui.panelTable, ...
        'Units', 'normalized', 'Position', [0.01 0.01 0.98 0.95], ...
        'ColumnName', colNames, ...
        'ColumnWidth', {50, 45, 60, 45, 45, 65, 55, 70}, ...
        'RowName', {}, ...
        'FontSize', 9, ...
        'BackgroundColor', [0.15 0.15 0.18; 0.12 0.12 0.15], ...
        'ForegroundColor', [0.9 0.9 0.9]);

    % === RIGHT BOTTOM: Inspector (like WSN_GUI_ControlDeck) ===
    gui.panelInspector = uipanel('Parent', gui.fig, 'Position', [0.44 0.02 0.26 0.46], ...
        'BackgroundColor', [0.12 0.12 0.15], 'BorderType', 'line', ...
        'HighlightColor', [0.3 0.3 0.4], 'Title', 'Node Inspector', ...
        'ForegroundColor', 'w', 'FontSize', 10);

    % Node selector dropdown
    nodeIDs = arrayfun(@(n) n.hexID, nodes, 'UniformOutput', false);
    gui.ddTarget = uicontrol('Parent', gui.panelInspector, 'Style', 'popupmenu', ...
        'String', nodeIDs, 'Units', 'normalized', 'Position', [0.05 0.88 0.9 0.08], ...
        'FontSize', 9, 'Callback', @(~,~) updateInspector(gui, nodes, 0));

    % Inspector text
    gui.txtInspector = uicontrol('Parent', gui.panelInspector, 'Style', 'edit', ...
        'Units', 'normalized', 'Position', [0.05 0.02 0.9 0.82], ...
        'Max', 20, 'Min', 1, 'Enable', 'inactive', ...
        'HorizontalAlignment', 'left', 'FontName', 'Consolas', 'FontSize', 9, ...
        'BackgroundColor', [0.1 0.1 0.12], 'ForegroundColor', [0.8 0.9 0.8]);

    % === BOTTOM RIGHT: Log Panel ===
    gui.panelLog = uipanel('Parent', gui.fig, 'Position', [0.71 0.02 0.27 0.46], ...
        'BackgroundColor', [0.12 0.12 0.15], 'BorderType', 'line', ...
        'HighlightColor', [0.3 0.3 0.4], 'Title', 'Attacker Log', ...
        'ForegroundColor', 'w', 'FontSize', 10);

    gui.txtLog = uicontrol('Parent', gui.panelLog, 'Style', 'edit', ...
        'Units', 'normalized', 'Position', [0.02 0.02 0.96 0.96], ...
        'Max', 50, 'Min', 1, 'Enable', 'inactive', ...
        'HorizontalAlignment', 'left', 'FontName', 'Consolas', 'FontSize', 8, ...
        'BackgroundColor', [0.08 0.08 0.1], 'ForegroundColor', [1 0.6 0.6]);

    % === BOTTOM LEFT: Status Panel ===
    gui.panelStatus = uipanel('Parent', gui.fig, 'Position', [0.02 0.02 0.4 0.3], ...
        'BackgroundColor', [0.12 0.12 0.15], 'BorderType', 'line', ...
        'HighlightColor', [0.3 0.3 0.4], 'Title', 'Simulation Status', ...
        'ForegroundColor', 'w', 'FontSize', 10);

    gui.txtStatus = uicontrol('Parent', gui.panelStatus, 'Style', 'text', ...
        'Units', 'normalized', 'Position', [0.02 0.02 0.96 0.9], ...
        'HorizontalAlignment', 'left', 'FontName', 'Consolas', 'FontSize', 10, ...
        'BackgroundColor', [0.12 0.12 0.15], 'ForegroundColor', [0.7 0.9 1.0]);

    % Store message history for links
    gui.linkHandles = [];
    gui.lastMsgs = {};
end

function updateStandardGUI(gui, nodes, t, cfg, msgs)
    if ~ishandle(gui.fig), return; end

    % === Update Network Table ===
    N = numel(nodes);
    tableData = cell(N, 8);
    for i = 1:N
        node = nodes(i);

        if node.isAttacker
            status = sprintf('ATTACK:%s', getAttackName(cfg.attackType));
        elseif node.battery < 20
            status = 'LOW_BATT';
        else
            status = 'NORMAL';
        end

        tableData{i, 1} = node.hexID;
        tableData{i, 2} = sprintf('T%d', node.tier);
        tableData{i, 3} = sprintf('%.1f%%', node.battery);
        tableData{i, 4} = num2str(node.txCount);
        tableData{i, 5} = num2str(node.rxCount);
        tableData{i, 6} = num2str(numel(node.neighborTable));
        tableData{i, 7} = num2str(node.lastRxTime);
        tableData{i, 8} = status;
    end
    set(gui.tblNetwork, 'Data', tableData);

    % === Update Inspector ===
    updateInspector(gui, nodes, t);

    % === Update Attacker Log ===
    attacker = nodes(1);
    if numel(attacker.log) > 0
        logLines = attacker.log(max(1, end-25):end);  % Last 25 lines
        set(gui.txtLog, 'String', logLines);
    end

    % === Update Status Panel ===
    statusStr = sprintf([...
        'Time: t = %d (since attack start)\n' ...
        'Attack: %s | Intensity: %d/10\n' ...
        'Attacker Battery: %.1f%%\n' ...
        'Attacker TX Count: %d\n' ...
        'Neighbor Avg Battery: %.1f%%\n' ...
        'Total Messages This Tick: %d'], ...
        t, getAttackName(cfg.attackType), cfg.intensity, ...
        nodes(1).battery, nodes(1).txCount, ...
        mean([nodes(2:end).battery]), numel(msgs));
    set(gui.txtStatus, 'String', statusStr);

    % === Update Topology Links ===
    % Clear old links
    delete(findobj(gui.axTopo, 'Tag', 'msgLink'));

    % Draw new links for this tick (only attack messages from attacker)
    attackColor = getAttackColor(cfg.attackType);
    for m = 1:numel(msgs)
        msg = msgs{m};
        if msg.srcIdx == 1 && msg.isAttack
            srcPos = nodes(1).pos;
            % Draw to all neighbors
            for i = 2:min(4, numel(nodes))  % Limit to avoid clutter
                dstPos = nodes(i).pos;
                line(gui.axTopo, [srcPos(1), dstPos(1)], [srcPos(2), dstPos(2)], ...
                    'Color', [attackColor 0.6], 'LineWidth', 2, 'Tag', 'msgLink');
            end
        end
    end

    % === Update Node Colors Based on RX ===
    for i = 1:numel(nodes)
        rxCount = numel(nodes(i).rxThisTick);
        if rxCount > 3
            set(gui.nodeScatters(i), 'MarkerEdgeColor', [1 1 0], 'LineWidth', 3);
        elseif rxCount > 1
            set(gui.nodeScatters(i), 'MarkerEdgeColor', [1 0.7 0.3], 'LineWidth', 2);
        else
            set(gui.nodeScatters(i), 'MarkerEdgeColor', 'w', 'LineWidth', 1.5);
        end
    end
end

function updateInspector(gui, nodes, ~)
    if ~ishandle(gui.fig), return; end

    idx = get(gui.ddTarget, 'Value');
    if idx > numel(nodes), return; end

    node = nodes(idx);

    % Build inspector text
    lines = {};
    lines{end+1} = sprintf('=== Node: %s ===', node.hexID);
    lines{end+1} = sprintf('Tier: %d | ID: %d', node.tier, node.id);
    lines{end+1} = sprintf('Position: (%.1f, %.1f)', node.pos(1), node.pos(2));
    lines{end+1} = '';
    lines{end+1} = sprintf('Battery: %.2f%%', node.battery);
    lines{end+1} = sprintf('TX Power: %.2f', node.txPower);
    lines{end+1} = '';
    lines{end+1} = sprintf('TX Count: %d', node.txCount);
    lines{end+1} = sprintf('RX Count: %d', node.rxCount);
    lines{end+1} = sprintf('Last TX: t=%d', node.lastTxTime);
    lines{end+1} = sprintf('Last RX: t=%d', node.lastRxTime);
    lines{end+1} = '';
    lines{end+1} = sprintf('Neighbors: %d', numel(node.neighborTable));

    % Neighbor list
    for n = 1:min(5, numel(node.neighborTable))
        nb = node.neighborTable(n);
        lines{end+1} = sprintf('  %s T%d RSSI=%.1f', nb.hexID, nb.tier, nb.rssi);
    end
    if numel(node.neighborTable) > 5
        lines{end+1} = sprintf('  ... +%d more', numel(node.neighborTable) - 5);
    end

    lines{end+1} = '';
    if node.isAttacker
        lines{end+1} = '>>> ATTACKER <<<';
    else
        lines{end+1} = 'Status: NORMAL';
    end

    set(gui.txtInspector, 'String', lines);
end

%% ========================================================================
%% EXPORT
%% ========================================================================
function exportTrainingData(obsLog, cfg)
    filename = sprintf('attack_data_%s_I%d_%s.csv', ...
        lower(getAttackName(cfg.attackType)), cfg.intensity, ...
        datestr(now, 'yyyymmdd_HHMMSS'));

    fprintf('[EXPORT] Writing %s...\n', filename);

    % Build table
    totalTicks = cfg.warmup + cfg.duration;
    rows = totalTicks * cfg.neighbors;

    data = zeros(rows, 10);
    row = 1;
    for t = 1:totalTicks
        for n = 1:cfg.neighbors
            data(row, 1) = t;
            data(row, 2) = obsLog.phase(t);  % 0=warmup, 1=attack
            data(row, 3) = n;  % Neighbor index
            data(row, 4) = obsLog.rxFromAttacker(t, n);
            data(row, 5) = obsLog.rxTotal(t, n);
            data(row, 6) = obsLog.avgRSSI(t, n);
            data(row, 7) = obsLog.battery(t, n);
            data(row, 8) = obsLog.neighborCount(t, n);
            data(row, 9) = obsLog.spoofedCount(t, n);
            data(row, 10) = obsLog.isAnomalous(t, n);
            row = row + 1;
        end
    end

    T = array2table(data, 'VariableNames', ...
        {'Time', 'Phase', 'NeighborIdx', 'RxFromAttacker', 'RxTotal', ...
         'AvgRSSI', 'Battery', 'NeighborCount', 'SpoofedIDs', 'IsAnomalous'});
    T.AttackType = repmat({getAttackName(cfg.attackType)}, rows, 1);
    T.Intensity = repmat(cfg.intensity, rows, 1);

    writetable(T, filename);
    fprintf('[EXPORT] Saved %d rows\n', rows);
end

%% ========================================================================
%% SUMMARY
%% ========================================================================
function printSummary(nodes, obsLog, cfg)
    fprintf('\n');
    fprintf('╔════════════════════════════════════════════════════════════════╗\n');
    fprintf('║                      SIMULATION SUMMARY                        ║\n');
    fprintf('╠════════════════════════════════════════════════════════════════╣\n');
    fprintf('║  Attack: %-12s   Intensity: %d/10                        ║\n', ...
        getAttackName(cfg.attackType), cfg.intensity);
    fprintf('║  Warmup: %-4d ticks     Attack: %-4d ticks                     ║\n', ...
        cfg.warmup, cfg.duration);
    fprintf('╠════════════════════════════════════════════════════════════════╣\n');

    % Attacker stats
    fprintf('║  ATTACKER (Node %s):                                          ║\n', nodes(1).hexID);
    fprintf('║    Final Battery: %5.1f%%   Total TX: %-5d                     ║\n', ...
        nodes(1).battery, nodes(1).txCount);
    fprintf('║    Log Entries: %-4d                                           ║\n', ...
        numel(nodes(1).log));

    % Neighbor stats
    avgBatt = mean([nodes(2:end).battery]);
    totalRxFromAttacker = sum(obsLog.rxFromAttacker(:));
    anomalyRate = 100 * sum(obsLog.isAnomalous(:)) / numel(obsLog.isAnomalous);

    fprintf('║  NEIGHBORS:                                                    ║\n');
    fprintf('║    Avg Final Battery: %5.1f%%                                   ║\n', avgBatt);
    fprintf('║    Total RX from Attacker: %-6d                              ║\n', totalRxFromAttacker);
    fprintf('║    Anomaly Rate: %5.1f%%                                        ║\n', anomalyRate);
    fprintf('╚════════════════════════════════════════════════════════════════╝\n');
end

%% ========================================================================
%% HELPERS
%% ========================================================================
function attackType = selectAttackMenu()
    fprintf('\n');
    fprintf('╔═══════════════════════════════════════════════════╗\n');
    fprintf('║       WSN ATTACK PATTERN TRAINING DEMO            ║\n');
    fprintf('╠═══════════════════════════════════════════════════╣\n');
    fprintf('║  [0] BASELINE      - Normal (control group)       ║\n');
    fprintf('║  [1] FLOODING      - Hello flood                  ║\n');
    fprintf('║  [2] PANIC_FLOOD   - False emergencies            ║\n');
    fprintf('║  [3] SYBIL         - Identity spoofing            ║\n');
    fprintf('║  [4] BLACKHOLE     - Silent drop                  ║\n');
    fprintf('║  [5] WORMHOLE      - Tunnel relay                 ║\n');
    fprintf('║  [6] GRAYHOLE      - Selective drop               ║\n');
    fprintf('║  [7] DENIAL_SLEEP  - Battery drain                ║\n');
    fprintf('║                                                   ║\n');
    fprintf('║  [Q] Quit                                         ║\n');
    fprintf('╚═══════════════════════════════════════════════════╝\n');

    choice = input('Select [0-7, Q]: ', 's');
    if strcmpi(choice, 'Q') || isempty(choice)
        attackType = -1;
    else
        attackType = str2double(choice);
        if isnan(attackType) || attackType < 0 || attackType > 7
            attackType = 0;
        end
    end
end

function name = getAttackName(attackType)
    names = {'BASELINE', 'FLOODING', 'PANIC_FLOOD', 'SYBIL', ...
             'BLACKHOLE', 'WORMHOLE', 'GRAYHOLE', 'DENIAL_SLEEP'};
    if attackType >= 0 && attackType <= 7
        name = names{attackType + 1};
    else
        name = 'UNKNOWN';
    end
end

function color = getAttackColor(attackType)
    colors = {
        [0.5 0.5 0.5],   % BASELINE
        [1.0 0.0 0.5],   % FLOODING
        [1.0 0.0 0.0],   % PANIC
        [1.0 0.5 0.0],   % SYBIL
        [0.2 0.2 0.2],   % BLACKHOLE
        [0.6 0.0 1.0],   % WORMHOLE
        [0.7 0.7 0.3],   % GRAYHOLE
        [1.0 1.0 0.0]    % DENIAL
    };
    color = colors{attackType + 1};
end
