# Fix IDS metrics: retier attack dataset generation + local-model feature gaps

## Context

The dual-tier IDS (`ML_IDS_PLAN.md`) is fully implemented and already trained — `ml/results/global` and `ml/results/local` contain real metrics, not placeholders. They're poor: the global (Sink) model's per-class F1 ranges 0.27-0.85 across the 7 attack classes despite trying 6+ algorithms (DT, RF, ExtraTrees, XGBoost, LightGBM) and SMOTE/resampling — all already exhausted and logged in `AI_ENGINE_DEBUG_PROMPT.md`. The local (node) model, reframed as a binary Attack/Normal trigger per the architecture paper's own guidance, gets ~1-2% precision on "Attack" (179065:1015 class ratio). Further algorithm tuning has hit a documented ceiling (macro-F1 0.79 ceiling found after the LightGBM trial) — the problem is not the model, it's the dataset.

**Root cause (confirmed against the actual generated CSVs, not just code reading):**

```
sink_dataset.csv: NodeType x AttackTypeName crosstab
NodeType   Blackhole DenialOfSleep Flooding Grayhole Normal  PanicFlood Sybil Wormhole
CH                 0             0        0        0   4551           0     0        0
GWN                0             0        0        0  13760           0     0        0
SENSOR            83            67      100       83 226983          98    72       96
```

100% of attack-labeled rows in **both** `local_dataset.csv` and `sink_dataset.csv` come from a Sensor-tier attacker. This traces to `WSN_Attack_Demo.m:30`, which defaults `attackerTier = WSN_Config.TIER_SENSOR` for the entire dataset-generation grid. That default silently cripples the relay-dependent attacks:

- **Blackhole/Grayhole at Sensor tier** (`WSN_Sensor.m:354-382`) can only drop Census/Shutdown/Panic messages the sensor happens to relay — rare events, since sensors don't aggregate other nodes' traffic in this architecture.
- **Blackhole/Grayhole at CH tier** (`WSN_ClusterHead.m:993-1006`, `:1152-1174`) drops every child's SENSOR_AGG uplink continuously, every aggregation cycle (`AGG_PERIOD_MIN/MAX` = 7-10 ticks, `WSN_Config.m:70-71` → 5-7 drop opportunities per 50-tick feature window).
- GWN tier has its own dedicated dual-radio drop logic (`shouldDropBlackholeGWN`/`shouldDropGrayholeGWN`, `WSN_Attack.m:740,860`) that never fires either.

**Verified directly against the reference dataset paper** (`Journal of Sensors - 2016 - Almomani - WSN-DS...pdf`, extracted via `pdftotext`, full text read) that this project's architecture paper benchmarks against: Blackhole and Grayhole are **defined** in WSN-DS as the attacker "advertising itself as a CH" (Algorithm 1/2, paper §5.1-5.2: *"The Blackhole attacker assumes the role of CH and it will keep dropping these data packets"*). There is no sensor-tier variant in the reference methodology — the current dataset's Sensor-tier Blackhole/Grayhole rows are not real instances of the attack as defined by the very paper this project is reproducing. This also incidentally confirms the current 6+-algorithm/resampling search was never going to fix these two classes — the data didn't contain the attack.

**Secondary bug, found while tracing the local model's 6 paper-mandated features:** `PhaseHoldTime` is NaN for 100% of Tier 1 (Sensor) and Tier 2 (CH) rows (only Tier 3/GWN is populated) — confirmed via `local_dataset.csv` groupby. Root cause: `WSN_FeatureExport.m:179` and `:261` gate the computation on `isprop(nodeObj, 'currentPhase')`, a property that only exists on `WSN_Gateway`/`WSN_Sink` objects (the token/phase backbone system Sensors/CHs don't participate in). Since 100% of attack rows are currently Sensor-tier, this means one of the local model's 6 official features is a dead, constant-imputed (`-1` sentinel) value on every single attack example it has ever been trained on.

**User-selected scope** (via clarifying question): a *targeted* retier — add CH-tier attacker scenarios only for the relay/drain-dependent attacks (Blackhole, Grayhole, Wormhole, DenialOfSleep), not a full tier×attack factorial — plus a low-medium-effort fix to the local model's feature gaps, cross-checked against the WSN-DS paper's own 23-feature schema. **Local-tier model/algorithm choice is explicitly out of scope** — the user is separately experimenting with a different model for that tier.

## Attack-by-attack verification against the paper (all 7, not just Blackhole/Grayhole)

The first pass only checked Blackhole/Grayhole. Per request, here is the full check — every attack type's code was read (not assumed) and compared against WSN-DS where the paper covers it; where it doesn't, the repo's own code is checked for tier-gating logic instead.

| Attack | In WSN-DS? | Paper's definition | This repo's actual mechanism | Tier verdict |
|---|---|---|---|---|
| **Blackhole** | Yes — Algorithm 1, §5.1 | Attacker explicitly *becomes* the CH and drops all relayed packets: *"The Blackhole attacker assumes the role of CH and it will keep dropping these data packets."* | `WSN_ClusterHead.m:993-1006` drops every child's continuous SENSOR_AGG uplink. `WSN_Sensor.m:354-382` (current 100% of data) can only drop the rare Census/Shutdown/Panic message it happens to relay — sensors don't aggregate other nodes' traffic at all in this architecture. | **Mismatch, confirmed bug** → retier to CH |
| **Grayhole** | Yes — Algorithm 2, §5.2 | Same CH role-play, selective/random drop instead of total. | Same asymmetry as Blackhole (`WSN_ClusterHead.m:1006-1009` vs `WSN_Sensor.m:374-380`). | **Mismatch, confirmed bug** → retier to CH |
| **Flooding** | Yes — Algorithm 3, §5.3, but paper-specific to LEACH's *rotating* CH-election (excess `ADV_CH` broadcasts at high power to manipulate which node gets joined) | This repo has fixed tiers, not LEACH's per-round CH election, so it's adapted as a generic Hello-flood (Type 0, excess broadcasts + inflated TX power). Implemented **identically and correctly at both Sensor** (`WSN_Sensor.m:77-88`) **and GWN tier** (`WSN_Gateway_Behavior.m:34-42`) — confirmed by reading both call sites, not just one. | **No mismatch** — valid protocol adaptation, tier-portable by design, current Sensor-tier choice is fine as-is |
| **Scheduling** | Yes — Algorithm 4, §5.4 (TDMA slot-collision attack) | **Not implemented anywhere in this repo** (no `ATTACK_SCHEDULING` constant exists) — a pre-existing scope difference already acknowledged in `ML_IDS_PLAN.md`'s "richer 8-class attack set," not a new finding. | Out of scope, unchanged |
| **PanicFlood** | No — not in WSN-DS at all (repo-original, built on this codebase's own PANIC/Type-2 message) | N/A | `shouldPanicFlood` (`WSN_Attack.m:1730-1774`) has **no tier gating in the code at all** — purely intensity/cooldown-driven. Sensor is the architecturally natural origin since PANIC is sensor-style anomaly alerting in this protocol. | **No mismatch** — appropriate tier by design |
| **Sybil** | No — paper explicitly names this as future work (§7: *"this work can be extended to include... Wormhole or Sybil"*) | N/A | `getSybilIdentityWithTier(nodeIdx, targetTier)` (`WSN_Attack.m:1161-1203`) lets the attacker fabricate a fake identity claiming **any** tier (1/2/3) regardless of its own real tier — intensity even controls how "bold" the impersonated tier is. The attack already simulates cross-tier impersonation by design, independent of host tier. | **No mismatch** — already tier-flexible by construction |
| **Wormhole** | No — same future-work mention as Sybil | N/A | `shouldWormholeRelay` (`WSN_Attack.m:1621-1685`) has no tier gating in the *code* — it tunnels between two endpoint indices regardless of tier. But the *network effect* is structurally weak at Sensor tier for the same underlying reason as Blackhole/Grayhole: sensors don't carry other nodes' relayed traffic, so there's little to meaningfully tunnel. A CH-tier wormhole would visibly redirect real aggregated cluster traffic (the `RerouteCount`/`HopCount` signal the Sink dataset is designed to catch). | **Mismatch by effect, not by code gate** → retier to CH (already in scope) |
| **DenialOfSleep** | No — repo-original (Vampire-style attack, separate literature from WSN-DS) | N/A | `getDenialOfSleepTargets` (`WSN_Attack.m:1512-1583`) only ever targets `neighborTable` entries with `tier==1` (Sensor) — i.e. it drains nearby sensors regardless of the attacker's own tier. A CH/GWN attacker's neighbor table includes its **recruited sensor children**, a much larger and more topologically central target pool than a lone Sensor's peer neighbors. Same mechanism, meaningfully stronger signal at CH tier. | **Weaker-but-not-broken at Sensor tier, meaningfully stronger at CH** → retier to CH (already in scope) |

**Net result: the targeted-retier scope (Blackhole, Grayhole, Wormhole, DenialOfSleep → CH tier; Flooding, PanicFlood, Sybil stay at Sensor tier) is confirmed correct for all 7 attacks, not just the 2 originally checked.** This section exists to show the other 5 were actually checked against the paper/code rather than assumed.

## Recommended approach

### 0. Persist this plan into the project

Save this plan as `WSN7_Modular/IDS_METRICS_IMPROVEMENT_PLAN.md` (this file), matching the existing reference-doc convention in the repo (`ML_IDS_PLAN.md`, `DATASET_GENERATION.md`, `CENSUS_PROTOCOL.md`, `AI_ENGINE_DEBUG_PROMPT.md` all live at the project root) so it's discoverable alongside the docs it extends.

### 1. `WSN_FeatureExport.m` — two feature fixes (benefit both datasets, both tiers)

**a) Add a per-window energy-consumption-delta feature.** WSN-DS's own schema includes `Energy_consumption` (consumption *rate*, not absolute) as a top-level attribute (paper §4, Table 4) — this codebase currently only snapshots absolute `ResidualEnergy` (`n.battery` at flush time, `WSN_FeatureExport.m:301`). A drain-rate feature is the literal signal DenialOfSleep ("Vampire") attacks produce and is currently absent. Implementation: track `d.batteryAtWindowStart(idx)` (new persistent-struct field, set on the first tap seen each window — mirror the existing `prevPhase`/`phaseRunLen` accumulator pattern at lines 178-195), compute `EnergyConsumed = batteryAtWindowStart - n.battery` at flush, add to both the CSV header (`:356-361`) and row-builder (`:299-303`).

**b) Give Sensor/CH tiers a real PhaseHoldTime proxy instead of a dead NaN.** Reuse the existing `tapTx`/`tapTxSuccess` event taps (already wired from `WSN_Main.m` per `AI_ENGINE_DEBUG_PROMPT.md`'s Phase 1-2 summary) to derive "ticks since last successful TX" as the Sensor/CH analogue, computed and stored alongside the existing GWN token-phase metric rather than replacing it — document it explicitly as a per-tier proxy in `FEATURE_MAPPING.md`, consistent with this project's existing "Documented proxies" convention.

**Left out of scope (documented, not fixed now):** `QueueDepth` is similarly GWN-rich-only (gated on `isprop(n,'Q_fwd') && isprop(n,'Q_local')`, `:270`) — CH's `sensorTable` aggregation backlog could seed a CH-tier proxy later, but defaults to a defensible literal `0` (not NaN) today, so it's lower priority than (a)/(b) and left alone to keep this pass low-medium-effort.

**Local-tier model/algorithm choice is explicitly OUT OF SCOPE for this plan.** The user is separately experimenting with a different model for the local tier. This plan's entire local-model contribution is the two feature fixes above (PhaseHoldTime proxy, energy-delta) so that whatever model gets trained next has real signal to learn from instead of a dead constant column — no new model architecture, no hyperparameter sweep, and no `--resample` retry for `train_local_model.py` are part of this plan. `train_local_model.py` is re-run completely unmodified in the Verification section purely to sanity-check the new columns aren't degenerate before the user swaps in their own model.

### 2. `WSN_Attack_Demo.m` — per-attack-type tier override + concrete regeneration grid

Currently `attackerTier` is one fixed value applied to every scenario in the grid (`:26-35`, used at `:68`). Replace the single `attackerTier` option with an internal per-attack-type default table (a small `containers.Map` or switch keyed on `sc.attackType`, built where `candidates`/`attackerIdx` are computed at `:68`) so each attack type gets its evidence-backed tier automatically, while still accepting an explicit override for ad-hoc single-tier testing:

| Attack | Tier | Intensities |
|---|---|---|
| Normal baseline | — | — (1 scenario) |
| Flooding, PanicFlood, Sybil | `TIER_SENSOR` (unchanged) | [1, 5, 10] → 9 scenarios |
| Blackhole, Grayhole, Wormhole, DenialOfSleep | `TIER_CH` (new) | [1, 5, 10] → 12 scenarios |

22 scenarios total — deliberately trimmed from the file's current 5-level default (`[1,3,5,7,10]`) to keep this a low-medium-effort, ~same-order-of-magnitude run as the existing dataset (which itself took on the order of hours in this environment per `DATASET_GENERATION.md`).

**This must be a full clean regeneration of `logs/local_dataset.csv` and `logs/sink_dataset.csv`, not an incremental append** — the Section 1 feature-export changes alter every row's columns, including the existing Sensor-tier scenarios, so mixing old and newly-generated rows would silently mix two different column semantics. As a side effect, this also picks up three real engine fixes (GWN:CH topology ratio, trust-collision fix, silence detector) that landed after the original dataset was generated and were deliberately never reflected in it (`DATASET_GENERATION.md`'s existing caveat), and refreshes the stale `CHRatio`/`ActiveSensorsRatio` columns for free.

Flag clearly: expect a long MATLAB run (likely multiple hours at current `duration=2000`/`warmup=600` defaults) — run the smoke test in the Execution Steps below first to confirm the per-attack tier table and new feature columns look right before committing to the full 22-scenario grid, and run the full grid in the background.

### 3. Python training scripts — re-run unmodified first, then targeted follow-ups

No algorithm changes as a first step. `train_global_model.py`/`train_local_model.py` already use a more sophisticated model menu (DT/RF/ExtraTrees/LightGBM) than either reference paper (WSN-DS itself only used a plain ANN/MLP, topping out at 98.53% per their Table 12; the architecture paper used DT/RF). Re-run both scripts unmodified against the regenerated CSVs first, so the F1 delta on Blackhole/Grayhole/Wormhole/DenialOfSleep isolates how much came from real CH-tier signal vs. anything else.

Two bounded, paper-justified follow-ups to try only after that baseline is in hand:
- Retry `--resample` (SMOTE) on the global script — `AI_ENGINE_DEBUG_PROMPT.md` found it regressed results at 53-145 real minority rows, but explicitly flagged "revisit after rebalancing increases minority row counts." CH-tier scenarios should materially raise real per-class counts for the 4 affected classes, so this assumption may finally hold — re-test empirically, don't assume.
- Optionally add an `MLPClassifier` to `train_global_model.py`'s model menu — it's literally what the WSN-DS paper itself found best on this style of dataset (10-fold CV, 2 hidden layers, 98.53%) and has never been tried in this project's own trial-and-error log. Cheap to add via the same `evaluate_model`/`save_*` helpers in `wsn_ids_common.py`; not expected to beat LightGBM but worth one data point since it's the one model family from either reference paper that hasn't been tested here.

### Critical files

- `WSN_FeatureExport.m` — energy-delta feature, PhaseHoldTime tier-aware proxy (lines 178-195, 260-303, 355-361 are the touch points).
- `WSN_Attack_Demo.m` — per-attack-type tier override (`:26-35`, `:68`), regeneration grid.
- `WSN_SinkFeatureExport.m` — add the same `EnergyConsumed` column for parity with the local dataset (mirrors `SelfReportedBattery` handling already there).
- `ml/train_global_model.py`, `ml/train_local_model.py`, `ml/wsn_ids_common.py` — re-run as-is against regenerated CSVs; optional MLP addition and resample retry land here.
- `DATASET_GENERATION.md`, `FEATURE_MAPPING.md` — update once the above is implemented (new tier-per-attack grid, new `EnergyConsumed`/PhaseHoldTime-proxy columns, resolved `CHRatio`/`ActiveSensorsRatio` staleness caveat).

## Execution steps (runbook)

MATLAB is on PATH in this environment (`C:\Program Files\MATLAB\R2024a\bin\matlab`), so these are real commands to run from a shell in `WSN7_Modular/`, not just MATLAB-console instructions.

```bash
# 1. Smoke test: confirm the per-attack tier table + new feature columns before committing to the full grid
matlab -batch "WSN_Attack_Demo('attackTypes',[WSN_Attack.ATTACK_BLACKHOLE],'intensities',[1],'duration',300,'warmup',200)"
# -> inspect the freshly-written logs/local_features_*.csv / sink_features_*.csv for the CH-tier attacker row

# 2. Full regeneration (run in background / overnight; trimmed to 3 intensity levels per the plan)
matlab -batch "WSN_Attack_Demo('intensities',[1,5,10])"
# -> writes logs/local_dataset.csv and logs/sink_dataset.csv (full clean overwrite)

# 3. Confirm the tier mismatch is actually fixed (same crosstab used to diagnose the bug)
python -c "
import pandas as pd
sink = pd.read_csv('logs/sink_dataset.csv', low_memory=False)
print(pd.crosstab(sink['NodeType'], sink['AttackTypeName']).to_string())
"

# 4. Re-train both models, unmodified
cd ml
python train_global_model.py --csv ../logs/sink_dataset.csv
python train_local_model.py --csv ../logs/local_dataset.csv
# -> compare ml/results/global/per_class_f1.csv and ml/results/local/precision_recall.csv
#    against the currently-committed results for the 4 retiered classes
```

Step 4's `train_local_model.py` run is a sanity check only (confirms the new columns aren't degenerate) — swapping in the user's own local-tier model is a separate, later step outside this plan.

## Verification

1. **Smoke test first**: run the single-scenario CH-tier Blackhole smoke test above; inspect the freshly-produced `logs/local_features_*.csv`/`sink_features_*.csv` for the attacker's CH-tier rows — `EnergyConsumed` should be a small positive number (not NaN/0-constant), `PhaseHoldTime` should be non-NaN for the CH attacker, and `ReportingGap`/`ExpectedReportRatio` in the sink-side export should show clear anomalies (this is the same signal `AI_ENGINE_DEBUG_PROMPT.md`'s Phase 4 silence detector already proved fires correctly).
2. **Full regeneration**: run the 22-scenario grid (background/overnight); confirm `logs/local_dataset.csv`/`sink_dataset.csv` row counts roughly double the old per-class counts for the 4 retiered attacks at CH tier (new) while keeping comparable Sensor-tier counts for Flooding/PanicFlood/Sybil (carried over from the regen, not literally reused).
3. **Crosstab check**: re-run the same `NodeType x AttackTypeName` crosstab used to find this bug — confirm Blackhole/Grayhole/Wormhole/DenialOfSleep now show nonzero CH-tier rows.
4. **Re-train**: `python train_global_model.py --csv ../logs/sink_dataset.csv` and `python train_local_model.py --csv ../logs/local_dataset.csv` unmodified; compare new `per_class_f1.csv`/`full_report.json` against the current committed results for the 4 retiered classes specifically — expect a real lift, not just noise, since CH-tier Blackhole/Grayhole now has the continuous-drop signal the reference paper's own attack definition requires.
5. **Local model**: check `precision_recall.csv` — Attack recall should hold steady-or-improve (still the metric that matters for a trigger role) while precision is watched for any movement now that PhaseHoldTime/EnergyConsumed are real signals instead of constants.
