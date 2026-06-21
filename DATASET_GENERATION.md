# Dataset Generation (ML_IDS_PLAN.md Phase 3)

## What `WSN_Attack_Demo.m` does

For each `(attackType, intensity)` scenario it:
1. Generates a fresh topology (`WSN_TopologyGenerator.generateTopology`).
2. Picks one node of the configured tier (default: Sensor) as the attacker and calls `WSN_Attack.setMalicious(...)`, with the attack activating at `t = warmup` (default 400 — after `WSN_Config.SENSOR_START_TIME = 350`, so sensor reporting has already begun when the attack starts).
3. Runs `WSN_Main(1e9, 100, nodes, duration)` — fully headless (the GUI never becomes visible because `1e9 > duration`), for exactly `duration` ticks (default 700).
4. Reads the scenario's freshly-produced `logs/local_features_*.csv` and `logs/sink_features_*.csv`, tags every row with `ScenarioID`, `RequestedAttackType`, `RequestedIntensity`, `AttackerNodeIdx`, and accumulates them.

After all scenarios, it writes `logs/local_dataset.csv` (trains the local-tier model) and `logs/sink_dataset.csv` (trains the global-tier model).

A `Normal` baseline scenario (no malicious node) runs first by default, so the dataset has a non-attacked reference population in addition to whatever Normal-labeled rows naturally occur in attack scenarios (the attacker before its warmup activates, and every non-attacker node throughout).

## Running it

```matlab
WSN_Attack_Demo()   % default grid: 1 baseline + 7 attack types x 3 intensities [1,5,10] = 22 runs
```

Useful overrides:

```matlab
% Quick smoke test (2 runs, ~minutes not hours)
WSN_Attack_Demo('attackTypes', [WSN_Attack.ATTACK_BLACKHOLE], 'intensities', [1], ...
                 'duration', 300, 'warmup', 200)

% Full grid with longer per-scenario duration for more feature windows
WSN_Attack_Demo('duration', 1500, 'warmup', 400, 'intensities', [1, 3, 5, 7, 10])

% Attack from a Cluster Head instead of a Sensor
WSN_Attack_Demo('attackerTier', WSN_Config.TIER_CH)
```

**Runtime**: each scenario is a full simulation run. In a slow/sandboxed environment this took roughly 15-20 minutes per 500-tick run during development (dominated by MATLAB startup overhead, not the instrumentation) — the default 22-scenario grid at duration=700 could take several hours there. It should be substantially faster in a normal interactive MATLAB desktop session. Start with a small `attackTypes`/`intensities` override to gauge your own environment's pace before committing to the full grid.

## Known caveat: labeling convention

A node that is a *victim* of another node's attack (e.g., a sensor whose Cluster Head is blackholing its data) is still labeled `Normal` in its own row — the label reflects the originating node's role, not network health, matching the convention used by the reference WSN-DS dataset. The victim's anomalous behavior (e.g. elevated `ReportingGap` in the Sink-Observed dataset) still shows up as a feature value on its `Normal`-labeled row — this is realistic noise, not a bug, and is exactly the kind of signal a real classifier has to learn to disregard or use cautiously.

## Rebalancing (Phase 6)

The default grid samples Wormhole at the same rate as other attacks even though it inherently needs paired endpoints and is rarer by construction. Once Phase 5's training scripts reveal real class-imbalance severity (`results/global/class_distribution.csv`), come back here and increase the relative number of scenarios for under-represented classes (e.g. more Wormhole/DenialOfSleep runs, longer `duration` for rarer attacks) before regenerating the dataset.

## Caveat (2026-06-19): topology ratio fixed after this dataset was generated

`WSN_TopologyGenerator.m`'s GWN:CH population ratio was fixed after `logs/local_dataset.csv`/
`logs/sink_dataset.csv` were generated (see `AI_ENGINE_DEBUG_PROMPT.md`'s Phase 4 verification
section) — GWNs no longer outnumber CHs. The dataset was **not** regenerated, since none of the
labels or attack-relevant feature columns depend on that ratio. The only stale columns are the
two network-wide context columns in `sink_dataset.csv` — `CHRatio` and `ActiveSensorsRatio` —
which reflect the pre-fix topology distribution. Regenerate only if those two columns'
freshness matters for your use case.

## Output files

- `logs/local_dataset.csv` — input to `ml/train_local_model.py`.
- `logs/sink_dataset.csv` — input to `ml/train_global_model.py`.
- Per-scenario intermediates (`logs/local_features_*.csv`, `logs/sink_features_*.csv`, `logs/attack_log_*.csv`, etc.) are left in `logs/` after a run — safe to delete once the two `*_dataset.csv` files are produced, unless you want to inspect a specific scenario in isolation.
