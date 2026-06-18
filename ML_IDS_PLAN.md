# Dual-Tier ML-Enforced IDS for WSN7_Modular — Implementation Plan

## Context

`WSN7_Modular` is a MATLAB simulator implementing the 3-tier WSN architecture (Sensor → ClusterHead → Gateway → Sink, dual-radio backbone/access, attack injection for 7 attack types) described in the attached paper *"A Secure Architecture for ML-Enforced Attack Mitigation in Wireless Sensor Networks."* The paper's contribution on top of that architecture is a **dual-tier ML/trust framework**:

1. **Global tier (Sink)**: a classifier (paper: Decision Tree + Random Forest, RFC won at 99.68%) trained on a ~23-feature-per-node-per-round vector spanning Physical/MAC/Network/Security layers, classifying attack type.
2. **Local tier (node)**: a 6-feature lightweight subset (RSSI, PDR, retransmit count, residual energy, token-hold time, queue depth) paired with a trust-score + daisy-chain neighbor-polling mechanism that confirms and blacklists malicious nodes without heavy compute.

None of this ML/trust layer exists yet in the codebase. Exploration confirmed:
- Message types 11 (Census/polling), 12 (Shutdown/blacklist), 13 (Update/trust-push) are documented in `SPECIFICATION.md` as a wishlist but have **zero implementation** — confirmed via `WSN_Config.m` (only types 0,1,2,5,6,7,8,9 defined) and repo-wide grep.
- A working but one-sided trust accumulator already exists: `WSN_Sink.m:883-921` `updateGlobalTrust()` does real `+1`/`-5` adjustments, but every call site passes `isSuccess=true` (`WSN_Sink.m:651,668,815,832,875`) — the decrement branch is real code with no caller yet. This is the natural hook for attack-driven trust decay.
- `WSN_Attack_Demo.m` is empty (3 bytes) — a clean slate to become the dataset-generation driver script.
- Per-node telemetry needed for the paper's feature table is partially present (battery, RSSI, neighbor count, GWN queues, phase state) and partially missing (PDR, latency, duty cycle, SNR/BER/LQI, real hop count, retransmit/rekey/re-election counters) — confirmed file:line in exploration.

**Confirmed scope** (decided via clarifying questions): ML training/evaluation stays fully **offline in Python** — no live MATLAB↔Python bridge. MATLAB's job is to (a) generate richly-labeled per-node/per-window CSV datasets, and (b) implement the in-simulation local-tier mitigation (Census/Update/Shutdown) as **rule-based trust thresholds**, not a live model call. Two Python scripts separately train and report metrics for the global (Sink-observed) and local (node-tapped) models, mirroring the paper's methodology and figures (confusion matrix, per-class F1, RFC feature importance, accuracy comparison). The local-tier rule-based protocol in MATLAB and the offline-trained local ML model are deliberately separate: the former is the live mitigation mechanism, the latter exists purely to report comparative accuracy metrics like the paper does.

The intended outcome: a working rule-based trust/blacklist mitigation layer running inside the existing simulator, plus a reproducible offline pipeline (CSV → two Python training scripts → accuracy/F1/confusion-matrix/feature-importance reports) that lets the user show results "just like the paper," using the repo's richer 8-class attack set (Normal + Flooding, PanicFlood, Sybil, Blackhole, Wormhole, Grayhole, DenialOfSleep) instead of the paper's 5-class WSN-DS reference set.

**Two datasets, two vantage points**: the paper explicitly frames the global model as deployed *at the Sink*, "continuously receiv[ing] aggregated records from every CH via the GWN backhaul" — i.e. its training data should reflect only what actually arrives at the Sink (subject to attack-induced loss/delay/reroutes), not omniscient per-node ground truth. Meanwhile the local-tier model genuinely runs on a node's own directly-observable state (its own RSSI, retransmits, battery, queue). These are different vantage points and need **two separate exported datasets**:
- **Local Telemetry Dataset** — tapped at the source, per-node, full local self-visibility. Trains `train_local_model.py`.
- **Sink-Observed Dataset** — derived purely from `WSN_Sink.m`'s own registries (`sensorRegistry`, `nodeRegistry`, `globalTrustRegistry`) and payload-embedded self-reported values, reflecting only what the Sink can actually see (including gaps/silences caused by attacks). Trains `train_global_model.py`.

Both datasets share the same join keys (node index/hex ID + time window) and the same supervised labels from `WSN_Attack`'s ground truth, but their feature columns differ by design.

## Approach

### 1. Two feature-export schemas, two vantage points

Both use the same window length = `WSN_Config.FEATURE_WINDOW_LEN = 50`, a divisor of the existing `AUTOLOG_INTERVAL=250` (`WSN_Main.m:31`), and the same labeling rule: label = `WSN_Attack.getAttackType(nodeIdx)` if active at window-close, else Normal — victim nodes (e.g., a sensor whose CH is blackholing it) are still labeled Normal for their own row, matching WSN-DS's convention of labeling by the originating node's role (documented as a known caveat, not a bug).

#### 1a. Local Telemetry Dataset (tapped at source — trains the local-tier model)

One row per `(node, window)`, built from each node's own directly-observable state, captured inline in the simulation's tick loop (not reconstructed from arrival order anywhere) via tap calls at existing event sites — sidesteps any "packets reach the Sink jumbled" concern entirely, since these values are recorded at the point of occurrence, not inferred post-hoc from Sink-side logs.

- **Reused as-is**: RSSI (`WSN_Main.m:324`), TxPower, QueueDepth (`WSN_Gateway.m:60-61`, GWN/Sink only), NeighborCount, ResidualEnergy (=battery).
- **Derived purely from RSSI (no new physics code)**: LQI, SNR_dB, BER, PER — all computed from the RSSI value already attached to each delivered message at `WSN_Main.m:324`. Recommendation: avoid touching `WSN_Physics.m` entirely; do not add idle-channel noise sampling.
- **New per-window counters** (tap existing event sites, no new state machines): PDR (TX/RX tally), Latency (5.2/5.3 ACK pairing), DutyCycle (`WSN_Sensor.m:53,58` awake/sleep toggle), ReElectionFreq (`WSN_ClusterHead.m:198` dvsScaleCount, `WSN_Sensor.m:213` parent-change), RetransmitCount (`WSN_Gateway_Behavior.m:362-374`), KeyOverhead (existing encryption-flag taps), IntrusionRate (PANIC subtype 2 RX), PacketInjectionCount (tap alongside every `WSN_Attack.recordGroundTruth` call).
- **Documented proxies**: `PhaseHoldTime` in place of literal "Token Time" (repo uses phase scheduling, not tokens — `WSN_Config.PHASE_TX_DURATION`), `TxGain` as `txPower/NormalPower` ratio.
- **Local-tier 6-feature subset** = literal column subset: `RSSI, PDR, RetransmitCount, ResidualEnergy, PhaseHoldTime, QueueDepth`.

New module `WSN_FeatureExport.m` (static-method class, persistent-store pattern like `WSN_Attack.m`'s `pDataStore`) owns all new counters in its own struct array keyed by node index — **not** new properties bolted onto `WSN_Node`/`WSN_Sensor`/`WSN_Gateway`/`WSN_ClusterHead`. Exposes `tap*()` methods called from existing event sites, `flushWindow(nodes,t)` called every 50 ticks from `WSN_Main.m`, and `exportCSV(filename)` mirroring `WSN_Attack.exportGroundTruth()` (`WSN_Attack.m:1923-1936`) → `logs/local_features_<timestamp>.csv`.

#### 1b. Sink-Observed Dataset (derived from Sink's own state — trains the global-tier model)

One row per `(claimed-source node, window)`, but every column is computed **only** from what `WSN_Sink.m` already holds or directly receives — no peeking at other nodes' internal state. This is what makes it a realistic stand-in for "what a deployed Sink-side model could actually use," and it naturally captures attack effects as *absences/irregularities* rather than raw physical metrics:

| Column | Derivation (Sink-visible only) |
|---|---|
| `ReportsReceived` | count of `sensorRegistry(idx).timeseries` entries (or `globalTrustRegistry.packetsReceived` delta) falling in this window |
| `ReportingGap` | ticks since the previous report at window start — large gaps are a strong Blackhole/Grayhole/DoS signal, purely from `sensorRegistry.timeseries(end).time` deltas |
| `ExpectedReportRatio` | `ReportsReceived / expectedCount`, where expected count derives from the known 3-7 tick sensor reporting interval (SPECIFICATION.md) — a Sink-side PDR proxy |
| `SelfReportedBattery` | last `sensorBattery` value in payload this window (`WSN_Sink.m:608,776` — self-reported, could be falsified by a malicious node; that is itself a realistic signal, not a flaw) |
| `ReportedRSSI` / `RSSIQualityBucket` | last reported RSSI value/bucket already computed at `WSN_Sink.m:621-630,745-750` |
| `RerouteCount` | count of distinct entries appended to `routeHistory` this window (`WSN_Sink.m:686-693,840-853`) — a Sinkhole/Wormhole/instability signal |
| `HopCount` | length of `traceRoute()`'s resolved path (`WSN_Sink.m:515-554`) — a **real** measured hop count via the registry, not a proxy |
| `RekeyEvent` | whether `nodeRegistry(idx).localKey` changed this window (`WSN_Sink.m:397`) — a Sink-native rekeying signal |
| `TrustScore` / `AnomalyCount` | from `sensorRegistry`/`globalTrustRegistry` at window close (`WSN_Sink.m:42-43,883-921`); `AnomalyCount` only becomes informative once Phase 4's Census wiring supplies real `isSuccess=false` calls — documented as such |
| `CHRatio` / `ActiveSensorsRatio` | network-wide context columns (same value repeated per row this window) from `nodeRegistry` tier counts and `getActiveSensorsCount()` (`WSN_Sink.m:965-986`) |

New module `WSN_SinkFeatureExport.m`, same static/persistent-store pattern, but reading from `obj.sensorRegistry`/`obj.nodeRegistry`/`obj.globalTrustRegistry` at window close rather than tapping arbitrary node-internal events — kept as a separate class from `WSN_FeatureExport.m` (single-responsibility split, consistent with the existing `WSN_Gateway`/`WSN_Gateway_Behavior`/`WSN_Gateway_Messaging` delegate pattern). Exports to `logs/sink_features_<timestamp>.csv`.

### 2. Census(11)/Update(13)/Shutdown(12) protocol — rule-based, MATLAB-native

New `WSN_Config.m` constants: message types 11/12/13, subtypes (`CENSUS_POLL_INITIATE/YES/NO/COMPLETE`, `SHUTDOWN_SOFT/HARD/BLACKLIST`, `UPDATE_TRUST_DELTA/THRESHOLD_SET`), and trust thresholds (`TRUST_INITIAL=50`, `TRUST_CENSUS_TRIGGER=20`, `TRUST_BLACKLIST_THRESHOLD=5`, success/fail deltas, quorum ratio, poll timeout).

**Daisy-chain polling**: a node `A` whose local trust for neighbor `B` drops below `TRUST_CENSUS_TRIGGER` broadcasts `11.0 POLL_INITIATE` (TTL=1, single-hop, mirrors existing PANIC pattern). Neighbors who also know `B` vote `11.1 YES`/`11.2 NO` based on their own trust of `B`. `A` collects votes for `CENSUS_POLL_TIMEOUT` ticks; verdict = malicious if `yesCount/totalVoters >= CENSUS_QUORUM_YES_RATIO` and `totalVoters >= CENSUS_MIN_VOTERS`, else cleared/inconclusive. `A` sends `11.3 POLL_COMPLETE` uplink toward the Sink so the (already-existing-but-dead) `globalTrustRegistry` decrement path finally gets a real caller.

**Escalation ladder**: 1st confirmed-malicious verdict → `12.0 SOFT_RESET` (clears local trust/queue state, node keeps operating); `RESET_ESCALATION_COUNT` soft resets → `12.1 HARD_RESET` (forces back to `STATE_BOOT`, re-handshake); further escalation → `12.2 BLACKLIST` (permanent — parent stops routing to it, Sink marks it dead, new `isBlacklisted` flag short-circuits `receive()`/`step()`, mirroring the existing `battery<=0` dead-node pattern at `WSN_Node.m:109-111`).

Dispatch follows the codebase's existing two-level pattern (flat type-check chain + nested subtype switch, as in `WSN_Gateway_Messaging.m:227-330` and `WSN_ClusterHead.m:313-332`) — added independently to `WSN_Sensor.m`, `WSN_ClusterHead.m`, and `WSN_Gateway_Messaging.m` since there's no single shared receive() chokepoint in this codebase (`WSN_Sensor`/`WSN_Gateway` override `receive()` directly, bypassing `WSN_Node.m`'s gatekeeper). The one shared chokepoint addition: `isBlacklisted` flag + short-circuit in `WSN_Node.m:100`, since blacklisting must be universal.

`WSN_GUI_SinkAnalytics.m` already renders a Trust column (`:172-201`) reading from the registry this work finally populates with real dynamic values — needs only a one-line conditional to flag blacklisted rows, no structural GUI change.

### 3. Dataset generation

Turn empty `WSN_Attack_Demo.m` into a headless batch-runner driver: for each of the 7 attack types × intensity grid (1/5/10) × a few attacker-count/tier combos, configure `WSN_Attack.setMalicious(...)`, run `WSN_Main` headless, collect outputs into concatenated `local_dataset.csv` / `sink_dataset.csv`. A later tuning pass (once class imbalance is visible from real runs) oversamples rare attack types (e.g. Wormhole, which needs paired endpoints and will be naturally rarer) so stratified train/test splitting doesn't choke on near-empty classes.

### 4. Python training scripts (offline only)

Two scripts sharing a small `wsn_ids_common.py` helper (CSV loading, plotting, metric helpers), living under a new `WSN7_Modular/ml/` directory:
- **`train_global_model.py`**: consumes `sink_features_*.csv` (Section 1b). Stratified 80/20 split, class-weighted Decision Tree + Random Forest, confusion matrix (CSV+PNG), per-class F1, RFC feature importance, accuracy comparison table — mirrors the paper's Sink-tier section exactly, but trained on genuinely Sink-observable signals (reporting gaps, reroutes, registry-derived hop count) rather than omniscient per-node physical metrics.
- **`train_local_model.py`**: consumes `local_features_*.csv` (Section 1a), restricted to the 6-column local subset, deliberately shallow models (capped depth/tree count). Since it reads a different dataset than the global script (different vantage point, not just a column subset of the same file), the "approaches full accuracy with fewer features" comparison from the paper is reframed honestly: this script reports its own accuracy/F1 standalone, and a comparison note in `RESULTS.md` (not an automated delta file) discusses how the two tiers perform on their respective, legitimately-available feature sets rather than assuming a strict subset relationship.

Both scripts report metrics; no model artifact is ever loaded back into MATLAB, consistent with the offline-only decision.

### 5. Reference markdown files

- `FEATURE_MAPPING.md` — paper parameter → CSV column → derivation table, proxy/limitation caveats.
- `CENSUS_PROTOCOL.md` — full protocol spec, trust rule table, polling state machine, escalation ladder, worked example trace.
- `DATASET_GENERATION.md` — how to reproduce the datasets (scenario grid, row counts, rebalancing rationale).
- `RESULTS.md` — actual metrics from the Python runs (accuracy/F1/confusion matrices/feature importance for both tiers), with honest discussion of any gap vs. the paper's 99.68% (different simulator, richer 8-class label set, proxy features — not treated as a defect).
- `PROTOCOL_EXTENSIONS.md` (optional) — short addendum updating `SPECIFICATION.md`'s Types 11-13 rows from placeholder to implemented.

## Phased Rollout

1. **Instrumentation hooks** — new `WSN_FeatureExport.m` (local, tap-based) + new `WSN_SinkFeatureExport.m` (reads `WSN_Sink.m`'s registries) — no CSV yet from either.
2. **Window aggregation + dual CSV export** — `FEATURE_WINDOW_LEN` constant, `flushWindow`/`exportCSV` on both modules, called from `WSN_Main.m`.
3. **Dataset generation runs** — build out `WSN_Attack_Demo.m` driver, produce both `local_dataset.csv` and `sink_dataset.csv`.
4. **Census/Shutdown/Update protocol** — full rule-based mitigation layer.
5. **Python training scripts** — `train_global_model.py`, `train_local_model.py`, `wsn_ids_common.py`.
6. **Dataset rebalancing** — tune the Phase 3 scenario grid based on real class-imbalance findings from Phase 5.
7. **Reference documentation** — write the markdown files above, re-verifying file:line references against as-built code.

Phases 1-3 (data pipeline) and 4 (protocol) are mutually independent and can proceed in either order; Phase 5 depends on Phase 3; Phase 6 depends on Phase 5; Phase 7 depends on everything being code-complete.

## Critical Files

- `WSN_Attack.m` — ground-truth source of truth (`groundTruth`, `recordGroundTruth`, `exportGroundTruth`); every new packet-injection tap and the label join depend on its existing API.
- `WSN_Config.m` — single insertion point for all new constants (message types 11-13, subtypes, trust thresholds, `FEATURE_WINDOW_LEN`).
- `WSN_Main.m` — owns the timestep loop, the per-message RSSI computation (`:324`), and the existing autolog/export call sites (`:92-96,462-466`) the new feature-window flush and CSV export hook into.
- `WSN_Gateway_Messaging.m` — canonical dispatch-pattern example (`:227-330`) and host for new GWN/Sink-side Census/Shutdown/Update handlers (Sink extends Gateway and shares this delegate).
- `WSN_Sink.m` — owns `globalTrustRegistry`/`sensorRegistry`/`nodeRegistry`, the only currently-real (if one-sided) trust logic (`updateGlobalTrust`, `:883-921`), `traceRoute()` (`:515-554`), and `handleDirectSensor`/`handleSensorAgg` (`:598-876`) — the entire source of truth for the Sink-Observed dataset, plus Census verdict adjudication and Shutdown-issuance authority.
- `WSN_Sensor.m` — owns the only existing stub per-neighbor trust structure (`neighborTrust`, `:23,502-534`) that daisy-chain polling activates for the first time.
- New: `WSN_FeatureExport.m` (local dataset), `WSN_SinkFeatureExport.m` (Sink-observed dataset), `WSN7_Modular/ml/train_global_model.py`, `train_local_model.py`, `wsn_ids_common.py`.

## Verification

- **Phase 1-2**: Run `WSN_Main(1000)` headless with no attack; inspect `logs/local_features_*.csv` for plausible non-placeholder values (RSSI in realistic range, PDR ≈ 1.0, battery monotonically declining, all labels Normal), and `logs/sink_features_*.csv` for sane `ReportsReceived`/`ReportingGap`/`HopCount` values on whichever sensors are actually reaching the Sink.
- **Phase 3**: Run the `WSN_Attack_Demo.m` driver for one attack/intensity combo; confirm both concatenated datasets contain rows labeled with that `AttackTypeName`; the attacker's own `local_dataset.csv` rows show anomalous `PacketInjectionCount`/`RetransmitCount`; and for Blackhole/Grayhole/DoS, victim sensors' `sink_dataset.csv` rows show elevated `ReportingGap`/depressed `ExpectedReportRatio` even while labeled Normal.
- **Phase 4**: Inject an intensity-1 Blackhole attack via the existing GUI/headless attack controls; trace through logs that a neighbor's local trust score for the attacker decays, a `POLL_INITIATE` fires, votes circulate and reach quorum, a malicious verdict is reached, and SOFT_RESET → (if repeated) HARD_RESET → BLACKLIST fires as designed. Also confirm `globalTrustRegistry.anomalyCount` (dead code before this phase) now increments via real Census-driven calls.
- **Phase 5-6**: Run `python train_global_model.py --csv sink_dataset.csv` and `python train_local_model.py --csv local_dataset.csv`; confirm confusion matrices, per-class F1, RFC feature importance, and each script's standalone metrics are produced with real (not degenerate/all-zero) numbers across all 8 classes after rebalancing.
- **Phase 7**: Spot-check the produced markdown docs' file:line references against the as-built code after all MATLAB edits land.
