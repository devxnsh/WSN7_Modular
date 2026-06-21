function WSN_Launcher(varargin)
% WSN_LAUNCHER  Root entry point: initializes paths, builds the topology,
% and starts the simulator (GUI or headless) with a decoupled attack
% configuration.
%
% Usage (name-value pairs, all optional):
%   WSN_Launcher()
%       GUI mode, default topology, NO attacks (ActivateAttacks=false is
%       the hard default - no node ever becomes an attacker).
%
%   WSN_Launcher('ActivateAttacks', true)
%       GUI mode, randomized-but-constrained attacks (random attacker
%       count/tier/type/intensity/start-time, all within sane bounds).
%
%   WSN_Launcher('Headless', true, 'SimSteps', 2000)
%       Fully headless run (GUI never shown), no attacks.
%
%   WSN_Launcher('Headless', true, 'SimSteps', 2000, 'ActivateAttacks', true, ...
%                'NumAttackers', 3, 'AttackTypes', WSN_Attack.ATTACK_BLACKHOLE, ...
%                'IntensityRange', [5 8])
%       Headless run with a partially-specified attack config; any field
%       left out is still randomized within bounds by WSN_Attack.configure().
%
%   WSN_Launcher('HeadlessSteps', 300, 'SimSteps', 2000)
%       PARTIAL HEADLESS: runs ticks 1-300 with the GUI window hidden (no
%       redraw cost), then the GUI window becomes visible at t=300 and the
%       run continues live to t=2000. Equivalent to 'StartGUIAt', 300 - the
%       node count/topology/attacks are identical to a normal GUI run, only
%       the early ticks skip rendering. Useful for fast-forwarding past an
%       uninteresting warmup period before watching the network live.
%
% Name-Value Arguments:
%   Headless         (false)  true => GUI is never shown (startGUIAt = 1e9)
%   StartGUIAt       ([])     explicit GUI-visible tick; overrides Headless
%   HeadlessSteps    ([])     alias for StartGUIAt - "run N steps headless,
%                              then show the GUI" (more discoverable name
%                              for the same partial-headless behavior)
%   PrintInterval    (1)      console status print cadence
%   SimSteps         ([])     defaults to WSN_Config.SimSteps
%   Nodes            ([])     pre-built topology; default generates a new one
%                              via WSN_TopologyGenerator
%   ActivateAttacks  (false)  master attack switch (see WSN_Attack.defaultConfig)
%   NumAttackers     ([])     optional - random (~10% of nodes) if omitted
%   AttackTypes      ([])     optional - random from all 7 attack types if omitted
%   IntensityRange   ([])     optional - [1 10] if omitted
%   Tiers            ([])     optional - {'Sensor','CH','GWN'} if omitted (Sink
%                              is never eligible regardless of this setting)
%   StartTimeRange   ([])     optional - [0 300] if omitted
%   Seed             ([])     optional - rng seed for reproducible attack draws
%
% See also: WSN_Main, WSN_Attack.configure, WSN_Attack.defaultConfig

    p = inputParser;
    addParameter(p, 'Headless', false);
    addParameter(p, 'StartGUIAt', []);
    addParameter(p, 'HeadlessSteps', []);
    addParameter(p, 'PrintInterval', 1);
    addParameter(p, 'SimSteps', []);
    addParameter(p, 'Nodes', []);
    addParameter(p, 'ActivateAttacks', false);
    addParameter(p, 'NumAttackers', []);
    addParameter(p, 'AttackTypes', []);
    addParameter(p, 'IntensityRange', []);
    addParameter(p, 'Tiers', []);
    addParameter(p, 'StartTimeRange', []);
    addParameter(p, 'Seed', []);
    parse(p, varargin{:});
    opt = p.Results;

    % --- 1. PATH SETUP ---
    rootDir = fileparts(mfilename('fullpath'));
    if exist(fullfile(rootDir, 'addpath_setup.m'), 'file')
        addpath_setup();
    end

    % --- 2. TOPOLOGY ---
    if isempty(opt.Nodes)
        fprintf('[LAUNCHER] Generating topology: %d nodes in [%d x %d] field...\n', ...
            WSN_Config.NodeCount, WSN_Config.FieldSize(1), WSN_Config.FieldSize(2));
        nodes = WSN_TopologyGenerator.generateTopology(WSN_Config.NodeCount, WSN_Config.FieldSize);
    else
        nodes = opt.Nodes;
        fprintf('[LAUNCHER] Using supplied topology (%d nodes)\n', numel(nodes));
    end

    % --- 3. GUI VISIBILITY ---
    % StartGUIAt and HeadlessSteps are the same underlying knob (the tick at
    % which WSN_Main reveals the GUI window); HeadlessSteps is just the more
    % discoverable name for "run N steps headless, then show the GUI".
    if ~isempty(opt.StartGUIAt)
        startGUIAt = opt.StartGUIAt;
    elseif ~isempty(opt.HeadlessSteps)
        startGUIAt = opt.HeadlessSteps;
    elseif opt.Headless
        startGUIAt = 1e9;
    else
        startGUIAt = 0;
    end

    simSteps = opt.SimSteps;
    if isempty(simSteps)
        simSteps = WSN_Config.SimSteps;
    end

    % --- 4. DECOUPLED ATTACK CONFIG ---
    % ActivateAttacks is the only required-effective field; everything else
    % is optional and randomized-but-constrained by WSN_Attack.configure()
    % when omitted. ActivateAttacks=false (the default) guarantees no node
    % ever becomes an attacker, identically in GUI and headless mode.
    attackCfg = struct( ...
        'ActivateAttacks', opt.ActivateAttacks, ...
        'NumAttackers',    opt.NumAttackers, ...
        'AttackTypes',     opt.AttackTypes, ...
        'IntensityRange',  opt.IntensityRange, ...
        'Tiers',           opt.Tiers, ...
        'StartTimeRange',  opt.StartTimeRange, ...
        'Seed',            opt.Seed );

    % --- 5. START SIMULATOR ---
    fprintf('[LAUNCHER] Starting WSN_Main (Headless=%d, SimSteps=%d, ActivateAttacks=%d)\n', ...
        opt.Headless, simSteps, attackCfg.ActivateAttacks);
    WSN_Main(startGUIAt, opt.PrintInterval, nodes, simSteps, attackCfg);
end
