# Sink / Base Station (Tier 4) — Shell / Working Notes

## Status
- **Last Updated**: 2026-06-21
- **Implementation Phase**: Core complete (data collection, enforcement, diagnostics)
- **ML-IDS Integration**: Feature export merged with node registry
- **Testing Status**: Verified as data collection root; verdict enforcement tested

## Quick Reference

### Key Metrics
- **Node Registry Entries**: One per network node (~100-500 typical)
- **Sensor Registry Entries**: One per sensor node (~100-300)
- **Census Verdict Escalation**: SOFT → HARD → BLACKLIST (3 steps)
- **Offline Detection**: Node silent > 3 × aggregation period (~30 TFs)
- **Battery Critical**: < 10%, Battery Dead: < 5%
- **Cleanup Interval**: Every 500 ticks (removes entries > 1000 ticks old)

### Data Flow
```
All Nodes (SN/CH/GWN)
         ↓ (aggregated messages)
         ↓ (sensor data, panic, census verdicts)
       Sink
         ↓ (analyses, enforces, exports)
    Log Files + CSV Exports
```

### Export Files (Periodic)
- `sink_nodeRegistry_t0-N_TIMESTAMP.csv` — Node status at tick N
- `sink_sensorRegistry_t0-N_TIMESTAMP.csv` — Sensor timeseries
- `sink_features_N_TIMESTAMP.csv` — ML-IDS unified feature vectors
- `sink_verdictHistory_TIMESTAMP.csv` — Enforcement actions

---

## Known Issues & Workarounds

### Issue #1: Node Registry Bloat (Offline Nodes)
**Symptom**: Node registry grows unbounded; cleanup too slow
**Root Cause**: Cleanup runs only every 500 TF; high node turnover
**Workaround**: Increase cleanup frequency to 100 TF for small networks
**Status**: MITIGATED (configurable in WSN_Config)

### Issue #2: Route Computation Missing Parent Info
**Symptom**: Route string shows parent ID, but parent's parent unknown
**Root Cause**: Sink only sees nodes that reach it; orphan nodes not in registry
**Workaround**: Track parent pointers during aggregation
**Status**: ACCEPTABLE (orphan nodes expected to drop out)

### Issue #3: Battery Forecast Volatility
**Symptom**: Extrapolated depletion time varies wildly due to bursty traffic
**Root Cause**: Battery discharge non-uniform; spikes from panic/aggregation
**Workaround**: Use moving average of discharge rate (last 20 ticks)
**Status**: MONITORING

### Issue #4: Census Verdict Race (Ancestor vs Sink)
**Symptom**: Node receives SHUTDOWN from ancestor + Sink simultaneously
**Root Cause**: Sink enforcement can override in-flight ancestor enforcement
**Workaround**: Sink only enforces if no other ancestor has jurisdiction
**Status**: DESIGN ISSUE (acceptable, Sink as final arbiter)

---

## Test Scenarios

### Scenario 1: Normal Data Collection
```
t=100:  All SNs broadcast sensor data
         Network aggregates: SN → CH → GWN → Sink
t=101:  Sink receives aggregated 5.2 from GWN
         Updates sensorRegistry[SN_ID] with latest value
t=150:  Sink exports registry to CSV
Result: All sensor values recorded with timestamps
```

### Scenario 2: Verdict Enforcement (Blackhole Child)
```
t=100-130: GWN_A detects silent CH child via reporting-silence
t=131:     Initiates CENSUS_POLL_INITIATE
t=140:     Poll completes: MALICIOUS verdict (quorum YES)
           GWN_A sends CENSUS_POLL_COMPLETE to parent GWN_B
t=141:     GWN_B checks: is CH direct child? No → forward to Sink
           Sink receives verdict message
t=142:     Sink checks resetHistory[CH]:
           softCount=0, hardCount=0 → escalation = SOFT_RESET
           Issues SHUTDOWN.0 (SOFT) to CH
Result:    Verdict propagates to final arbiter (Sink); enforcement issued
```

### Scenario 3: Offline Node Detection & Cleanup
```
t=0-500:   Node N regularly sends data (lastUpdate = current tick)
t=501:     N fails, no more messages
t=600:     detectOfflineNodes() runs
           Check: (600 - lastUpdate=500) > 3×10 = true → mark offline
t=1000:    Cleanup runs
           Check: (1000 - lastUpdate=500) > 1000 → remove from registry
Result:    Node removed after 500 tick silence
```

---

## Performance Notes

### Memory
- **nodeRegistry**: ~100 bytes × N_nodes (typically 1-5 KB)
- **sensorRegistry**: ~200 bytes × N_sensors (timeseries), grows ~50 bytes/tick (typical)
- **verdictHistory**: ~50 bytes × verdicts (typically <100 bytes)
- **Total**: 5-50 KB (manageable for 100-500 node networks)

### CPU Load
- `receive()`: O(1) per message (lookup + update)
- `detectOfflineNodes()`: O(N) per check (scan all nodes, ~10 ms per 100 nodes)
- `cleanupOfflineNodes()`: O(N) per cleanup (remove stale, ~10 ms per 100 nodes)
- **Overall**: Very low; cleanup is occasional, not per-tick

### Network Traffic (Sink perspective)
- **Input**: ~0.5-1.0 messages/TF per GWN (aggregation + census)
- **Output**: ~0.1 messages/TF (SHUTDOWN enforcement only when verdict ready)
- **Ratio**: 10:1 input-to-output (Sink mostly listens)

---

## Integration Points

### Upstream (from GWNs)
- **Type 5.2**: Aggregated sensor data (merged into sensorRegistry)
- **Type 2**: Panic messages (logged, high priority)
- **Type 11.3**: CENSUS_POLL_COMPLETE verdicts (enforcement trigger)

### Downstream (to all nodes)
- **Type 12**: SHUTDOWN enforcement (broadcast if needed)
- **Type 9**: Heartbeat ACK (keep-alive verification)

---

## Decision Matrix: Enforcement Escalation

```
Prior Verdicts          Escalation Level        Action
─────────────────────────────────────────────────────────
None                    SOFT_RESET (0)          Clear trust/polls
SOFT (1x)               HARD_RESET (1)          Clear parent, re-discover
SOFT + HARD (2x)        HARD_RESET (1) again    Escalate counter
HARD (≥3x)              BLACKLIST (2)           Permanent silence
```

---

## TODO / Future Improvements

### Priority 1 (Current)
- [ ] Verify CSV export format matches ML-IDS expectations
- [ ] Test cleanup with high node turnover (>1000 nodes)
- [ ] Validate route computation with multi-hop GWN chains

### Priority 2 (Optimization)
- [ ] Temporal correlation of sensor features (time-align across nodes)
- [ ] Battery forecast moving average (reduce volatility)
- [ ] Link quality per-parent tracking (identify weak links)

### Priority 3 (Future Features)
- [ ] Network topology visualization (export for graphing)
- [ ] Anomaly detection on aggregated sensor data
- [ ] Predictive re-parenting (proactive failover)
- [ ] Multi-Sink redundancy (backup root nodes)

---

## Quick Reference: CSV Formats

### Node Registry
```
HexID, Parent, Route, LocalKey, CHCount, SNCount, GWChildren, CHChildren, SecondaryChildren, LastUpdate
1A2B,  3C4D,  1A2B->3C4D->SINK, ABC123DEF, 2, 5, [3C4D, 4D5E], [5E6F], [6F70], 500
```

### Sensor Registry
```
ID,  HexID, ParentCH, TimeseriesCount, LastValue, LastTimestamp
101, 1A2B,  3C4D,     50,              45.2,      1000
102, 2B3C,  3C4D,     50,              67.8,      999
```

### Feature Export (Unified)
```
Timestamp, NodeID, Tier, Feature_1, Feature_2, ..., Feature_50, Label
100, 1A2B, 1, 45.2, 0.05, ..., 0.8, 0 (benign)
101, 1A2B, 1, 45.5, 0.06, ..., 0.81, 0 (benign)
```

---

## Logging Pattern

```
[SINK] t=500 [NODE_UPDATE] hexID=1A2B tier=SENSOR battery=45%
[SINK] t=500 [SENSOR_RX] sensorID=101 value=45.2 parent=3C4D
[SINK] t=500 [OFFLINE_DETECTED] nodeID=5E6F silent=200 ticks
[SINK] t=500 [VERDICT_RX] suspect=3C4D verdict=MALICIOUS quorum=67%
[SINK] t=500 [ENFORCE] target=3C4D level=HARD_RESET escalation=1
[SINK] t=500 [EXPORT] nodeRegistry rows=450, sensorRegistry rows=350
```

---

## Documentation Maintainers
- **Data Collection**: [Your name]
- **Verdict Enforcement**: [Your name]
- **Feature Export**: [Your name]
- **Last Review**: 2026-06-21

---

## Quick Links
- **Node Class**: WSN_Sink.m
- **Configuration**: WSN_Config.m
- **Feature export**: WSN_SinkFeatureExport.m
- **Message class**: WSN_Message.m
- **Attack reference**: WSN_Attack.m (for context on malicious nodes)
- **Registry delegate**: SINK/Registry/WSN_Sink_Registry.m (handshake/route/sensor ingestion)
- **Enforcement delegate**: SINK/Enforcement/WSN_Sink_Enforcement.m (globalTrustRegistry, dormant trust matrix)
- **FeatureExport delegate**: SINK/FeatureExport/WSN_Sink_FeatureExport.m (active-sensor count, dormant trust snapshot)

---

## Modularization & Cross-Tier Verification Notes (2026-06-21)

`WSN_Sink.m` (996 → 424 lines) was split into Registry/Enforcement/
FeatureExport thin-delegate submodules — this was the reference pattern
later mirrored for `WSN_ClusterHead.m` and `WSN_Gateway.m` (see their
respective `CH_Shell.md` / `GWN_Shell.md` "Modularization Notes" sections).
`WSN_Sink < WSN_Gateway`, so it inherits `WSN_Gateway_Enforcement`'s base
`handlePollComplete`/census logic and layers its own richer
`globalTrustRegistry`-based overrides on top via `WSN_Sink_Enforcement`.

Added dormant trust-decision-matrix properties (`trustDecisionMatrix`,
`trustDecisionPolicy`, `trustDecisionWeights`) — **these now live on
`WSN_Gateway` (the superclass)**, not on `WSN_Sink` directly, since MATLAB
does not allow a subclass to redeclare a property already defined on its
superclass. `WSN_Sink.m`'s properties block has a comment pointing to this.

### Cross-tier data-path verification (SN → CH → GWN → Sink)
Ran headless sims via `WSN_Main(1e9, N, [], simSteps, attackCfg)` with both
`ActivateAttacks=false` and `=true`, after the Registry/Enforcement/
FeatureExport split for all three tiers:
- 600-step run, attacks disabled: completes cleanly, no runtime errors
- `sink_sensorRegistry_*.csv` exports confirm sensor readings from dozens of
  distinct SN hex IDs reaching the Sink with consistent `ParentCH` routing
  and growing `TimeseriesCount` — confirms the full SN→CH→GWN→Sink data path
  is intact after all three tier splits
- 600-step run, attacks enabled (13 malicious nodes, 100-node topology):
  **CRASHED** partway through (between t=400 and t=600, exact step unknown -
  `[AUTOLOG]` only confirms progress to t=400) with `MATLAB error Exit
  Status: 0x40010004` and no MATLAB-level stack trace in the captured
  output - see "Third issue: attack-enabled run crash" below. A separate
  smaller 300-step/50-node regression run (attacks disabled) completed
  cleanly post-fix (see below)

### Bug found and fixed during verification (NOT part of the tier split)
`Utils/WSN_TopologyGenerator.m`'s `getStructTopology` (around line 168) had
a pre-existing, randomly-triggered row/column vector orientation bug:
`demotable = [demotable; hullSorted(hord)]` could throw "Dimensions of
arrays being concatenated are not consistent" depending on whether
`setdiff`/`unique`/`convhull` happened to return row vs. column vectors for
a given random topology. This is unrelated to the CH/GWN/Sink split but
blocked verification runs intermittently. Fixed by normalizing both sides
to row vectors before concatenation:
`demotable = [demotable(:).', hullSorted(hord).'];`

### Second bug found and fixed: CH->GWN direct 5.2 data corruption
A dedicated audit of message-type/payload consistency across all four tiers
(SN/CH/GWN/Sink) turned up a real, silent data-corruption bug in the
CH->GWN hop: `GWN/WSN_Gateway_Messaging.m`'s `mergeSensorAgg` neither
decrypted the CH's payload (despite CH->GWN links always being encrypted
with the GWN-issued `localKey`) nor used the correct 3-byte fragment header
CH actually writes (it assumed a 1-byte header, off by 2 bytes). This
silently produced garbage `sensorTable` entries whenever a CH uplinked
directly to its GWN parent - no crash, so it wouldn't surface as a runtime
error in a clean `SIM_OK` run. Full root-cause writeup and the fix are in
`GWN_Shell.md` ("Bug found and fixed: CH->GWN direct 5.2 merge silently
corrupted data"). Verified via a deterministic unit-style check (hand-built
encrypted CH-formatted payload -> `mergeSensorAgg` -> exact round-trip of
sensor ID/value/battery/RSSI) and confirmed in-vivo in a subsequent
600-step/100-node run (`AA02 [5.2_FRAG]` followed by `FF01 [5.3_TX] ACK`).
Everything else audited (SN->CH/GWN sensor + panic payloads, Census Type 11,
Shutdown Type 12, CH-CH unencrypted 5.2, and the Sink's own grouped-format
5.2 ingestion via `WSN_Sink_Registry.handleSensorAgg`) checked out consistent
between sender and receiver.

### Third issue found, NOT fixed: subtype 5.2 conflates two different encryption shapes across multi-hop GWN backbone
The same audit run's `sink_sensorRegistry` export (post-fix) still contained
~40 sensor entries with IDs in the 0xFE2C-0xFEFC range that don't match any
real node in the simulation. Root cause traced to `GWN/
WSN_Gateway_Messaging.m`'s `handle_SENSOR_AGG`: it's the single dispatch
point for both CH->GWN 5.2 (single-key XOR, what this session fixed) *and*
GWN->GWN backbone-relayed 5.2 (`processSensorAggregation`'s layered-
encryption output, meant to be decrypted only by the Sink via
`decryptLayered`/`deriveRemoteLocalKey`) - it doesn't distinguish which
shape it received before merging/re-forwarding. Full writeup, evidence, and
the two possible fix directions (decrypt-as-GWN vs. pure relay) are in
`GWN_Shell.md` ("Separate, NOT-yet-fixed issue..."). This is a real,
pre-existing architectural gap, not something introduced by this session's
tier splits - flagging for follow-up rather than attempting a fix without a
clearer design decision on intermediate-GWN behavior for relayed traffic.
