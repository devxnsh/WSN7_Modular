function WSN_Attack_Demo(varargin)
% WSN_ATTACK_DEMO - Headless batch driver for ML-IDS dataset generation.
% (ML_IDS_PLAN.md Phase 3)
%
% Runs one short, fully-headless simulation per (attackType, intensity)
% scenario -- each with a single attacker node activated after a warmup
% period -- and concatenates the resulting per-window feature CSVs
% (produced by WSN_FeatureExport / WSN_SinkFeatureExport) into two master
% datasets: logs/local_dataset.csv and logs/sink_dataset.csv.
%
% Usage:
%   WSN_Attack_Demo()                              % default grid
%   WSN_Attack_Demo('intensities', [1 10])         % override intensity levels
%   WSN_Attack_Demo('duration', 1000)              % ticks per scenario
%   WSN_Attack_Demo('warmup', 400)                 % ticks before attack activates
%   WSN_Attack_Demo('attackerTier', WSN_Config.TIER_CH)  % attack from a CH instead of a Sensor
%   WSN_Attack_Demo('includeNormalBaseline', false)
%
% NOTE ON RUNTIME: each scenario is a full WSN_Main(...) simulation run.
% In a slow/sandboxed environment this can take many minutes per scenario;
% the default grid (1 baseline + 7 attack types x 3 intensities = 22 runs)
% can take hours. Tune 'intensities' and 'duration' down for a quick test,
% and see DATASET_GENERATION.md for guidance on scaling the grid up once
% you know your environment's per-tick cost.

opts = struct( ...
    'intensities', [1, 3, 5, 7, 10], ...
    'duration', 2000, ...
    'warmup', 600, ...
    'attackerTier', WSN_Config.TIER_SENSOR, ...
    'includeNormalBaseline', true, ...
    'attackTypes', [WSN_Attack.ATTACK_FLOODING, WSN_Attack.ATTACK_PANIC_FLOOD, WSN_Attack.ATTACK_SYBIL, ...
                     WSN_Attack.ATTACK_BLACKHOLE, WSN_Attack.ATTACK_WORMHOLE, WSN_Attack.ATTACK_GRAYHOLE, ...
                     WSN_Attack.ATTACK_DENIAL_SLEEP], ...
    'outDir', 'logs');

for i = 1:2:numel(varargin)
    opts.(varargin{i}) = varargin{i+1};
end

if ~exist(opts.outDir, 'dir')
    mkdir(opts.outDir);
end

scenarios = {};
if opts.includeNormalBaseline
    scenarios{end+1} = struct('attackType', WSN_Attack.ATTACK_NONE, 'intensity', 0);
end
for a = opts.attackTypes
    for inten = opts.intensities
        scenarios{end+1} = struct('attackType', a, 'intensity', inten); %#ok<AGROW>
    end
end

localTables = {};
sinkTables = {};

for s = 1:numel(scenarios)
    sc = scenarios{s};
    scenarioID = sprintf('S%03d_AT%d_I%d', s, sc.attackType, sc.intensity);
    fprintf('\n=== SCENARIO %d/%d: %s ===\n', s, numel(scenarios), scenarioID);

    nodes = WSN_TopologyGenerator.generateTopology(WSN_Config.NodeCount, WSN_Config.FieldSize);
    WSN_Attack.init(numel(nodes));

    attackerIdx = 0;
    if sc.attackType ~= WSN_Attack.ATTACK_NONE
        candidates = find(arrayfun(@(n) n.tier == opts.attackerTier, nodes));
        candidates = candidates(~arrayfun(@(i) isa(nodes(i), 'WSN_Sink'), candidates));
        if isempty(candidates)
            fprintf('  [SKIP] no eligible tier-%d node for attacker\n', opts.attackerTier);
            continue;
        end
        attackerIdx = candidates(randi(numel(candidates)));
        WSN_Attack.setMalicious(attackerIdx, sc.attackType, sc.intensity, nodes, opts.warmup);
        fprintf('  Attacker: node %d (%s), type=%d intensity=%d, active from t=%d\n', ...
            attackerIdx, nodes(attackerIdx).hexID, sc.attackType, sc.intensity, opts.warmup);
    else
        fprintf('  Normal baseline run (no malicious node)\n');
    end

    % Snapshot existing feature CSVs so the newly-produced ones can be identified
    beforeLocal = dir(fullfile(opts.outDir, 'local_features_*.csv'));
    beforeSink  = dir(fullfile(opts.outDir, 'sink_features_*.csv'));

    % Fully headless: startGUIAt (1e9) > duration, so the GUI is never shown
    WSN_Main(1e9, 100, nodes, opts.duration);

    afterLocal = dir(fullfile(opts.outDir, 'local_features_*.csv'));
    afterSink  = dir(fullfile(opts.outDir, 'sink_features_*.csv'));
    newLocal = setdiff({afterLocal.name}, {beforeLocal.name});
    newSink  = setdiff({afterSink.name}, {beforeSink.name});

    if ~isempty(newLocal)
        tl = readFeatureCSV(fullfile(opts.outDir, newLocal{1}));
        tl.ScenarioID = repmat({scenarioID}, height(tl), 1);
        tl.RequestedAttackType = repmat(sc.attackType, height(tl), 1);
        tl.RequestedIntensity = repmat(sc.intensity, height(tl), 1);
        tl.AttackerNodeIdx = repmat(attackerIdx, height(tl), 1);
        localTables{end+1} = tl; %#ok<AGROW>
    else
        fprintf('  [WARN] no local_features_*.csv produced for this scenario\n');
    end

    if ~isempty(newSink)
        ts = readFeatureCSV(fullfile(opts.outDir, newSink{1}));
        ts.ScenarioID = repmat({scenarioID}, height(ts), 1);
        ts.RequestedAttackType = repmat(sc.attackType, height(ts), 1);
        ts.RequestedIntensity = repmat(sc.intensity, height(ts), 1);
        ts.AttackerNodeIdx = repmat(attackerIdx, height(ts), 1);
        sinkTables{end+1} = ts; %#ok<AGROW>
    else
        fprintf('  [WARN] no sink_features_*.csv produced for this scenario\n');
    end
end

if ~isempty(localTables)
    localDataset = vertcat(localTables{:});
    writetable(localDataset, fullfile(opts.outDir, 'local_dataset.csv'));
    fprintf('\n[DONE] %s: %d rows\n', fullfile(opts.outDir, 'local_dataset.csv'), height(localDataset));
else
    fprintf('\n[DONE] No local feature rows collected -- local_dataset.csv not written.\n');
end

if ~isempty(sinkTables)
    sinkDataset = vertcat(sinkTables{:});
    writetable(sinkDataset, fullfile(opts.outDir, 'sink_dataset.csv'));
    fprintf('[DONE] %s: %d rows\n', fullfile(opts.outDir, 'sink_dataset.csv'), height(sinkDataset));
else
    fprintf('[DONE] No sink feature rows collected -- sink_dataset.csv not written.\n');
end

end

function t = readFeatureCSV(filename)
% readtable() auto-detects column types from the first rows. NodeHexID
% values like "0001"/"0013" look numeric and get silently parsed to plain
% numbers (losing the tier prefix and leading zeros), while letter-bearing
% values like "AA01"/"FF01"/"000A" don't parse and become NaN. Force
% NodeHexID to import as text so every row keeps its real hex ID.
opts = detectImportOptions(filename);
opts = setvartype(opts, 'NodeHexID', 'string');
t = readtable(filename, opts);
end
