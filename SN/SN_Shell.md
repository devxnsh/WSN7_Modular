# Sensor Node (SN/Tier 1) — Shell / Working Notes

## Status
- **Last Updated**: 2026-06-21
- **Implementation Phase**: Core + ML-IDS Phase 4 complete
- **Testing Status**: Verified in simulation with attacks (FLOODING, PANIC_FLOOD, BLACKHOLE, GRAYHOLE, SYBIL)

## Quick Reference

### Key Metrics
- **Sensor Period**: 3-7 TFs (random fixed at init)
- **Sleep Cycle**: 20 TFs normal, 35 TFs orphan mode
- **Wake Window**: 3 TFs normal (15% duty), 2 TFs orphan (~6% duty)
- **Panic Cooldown**: 500 TFs (very conservative to avoid floods)
- **Trust Range**: 0-100 (initial: 50)
- **Census Timeout**: 10 TFs
- **Orphan Entry**: 5 consecutive failed TX attempts

### State Machine
```
INIT → (HELLO RX) → NEIGHBOR_TABLE → SELECT_TARGET → SENSOR_TX
                          ↑                              ↓
                          └─────────────────────────────┘
                                     ↓
                          (No target) → ORPHAN_MODE
                                     ↓
                    (Target re-discovered) → NORMAL_MODE
```

### Battery Profile (100% → 0%)
- Sleep: 0.05 units/TF (20% of idle cost)
- Idle: 0.5 units/TF (awake, RX mode)
- TX_Sensor: ~1.0 units/msg
- TX_Panic: ~1.2 units/msg
- **Lifetime**: ~200 TF at 100% duty, ~1000+ TF with 15% duty cycle

---

## TODO / In Progress

### Priority 1 (Current/Blocker)
- [ ] Verify neighbor table cleanup (stale neighbors after T=N)
- [ ] Test orphan mode re-entry with high packet loss
- [ ] Validate panic deduplication across network (UID leakage?)

### Priority 2 (Optimization)
- [ ] Sensor value generation: make configurable (drift, spike chance)
- [ ] Trust decay over time (currently sticky)
- [ ] RSSI-based trust boost (reward strong neighbors)
- [ ] Aggregated sensor statistics for Sink reports

### Priority 3 (Future Features)
- [ ] In-network aggregation (SN-SN local fusion)
- [ ] Adaptive sensor period (based on anomaly score)
- [ ] Energy-aware neighbor selection (prefer healthy batteries)
- [ ] Reputation matrix (multi-neighbor scoring)

---

## Known Issues & Workarounds

### Issue #1: Orphan Recovery Oscillation
**Symptom**: Node enters/exits orphan mode rapidly
**Root Cause**: Threshold (5 failures) too low with transient link flaps
**Workaround**: Increase `orphanThreshold` to 8-10
**Status**: MONITORING (rare at current tx_power settings)

### Issue #2: Trust Score Decay Too Slow
**Symptom**: Malicious neighbors remain undetected for long periods
**Root Cause**: Trust updates only on message failure, not inactivity
**Workaround**: Census polling compensates with quorum voting
**Status**: ACCEPTABLE (Phase 4 voting is more robust than trust alone)

### Issue #3: Panic Message Loop
**Symptom**: High-severity panic floods network if no parent
**Root Cause**: Orphan broadcasts link-loss panic every orphan-check cycle
**Workaround**: Panic cooldown (500 TF) prevents re-TX
**Status**: MITIGATED (cooldown works, but consider cooldown per panic-subtype)

### Issue #4: Neighbor Verification Stale
**Symptom**: Node sends to unverified neighbor after GWN key revoked
**Root Cause**: Neighbor table never refreshed after loss of GWN parent
**Workaround**: Trust penalties on failed delivery
**Status**: TRACKING (May need periodic verification re-check)

---

## Decision Matrix / Trust Scoring

### Trust Deltas (Example)
```
Event                               Delta    Reason
─────────────────────────────────────────────────────────
Message ACK received                +3       Positive signal
Successful forward                  +2       Confirmation
Message drop / timeout              -5       Broken link / unresponsive
Malicious verdict from census       -50      Confirmed threat
Data corruption / bad checksum      -10      Data integrity issue
Response to census poll             +1       Cooperation
Non-response to poll (timeout)      -3       Uncooperative
```

### Trust Thresholds
- **TRUST_INITIAL** = 50.0 (neutral, unknown neighbor)
- **TRUST_CENSUS_TRIGGER** = 30.0 (suspect, initiate poll)
- **TRUST_MIN** = 0.0 (blacklist, no comms)
- **TRUST_MAX** = 100.0 (fully trusted, direct parent)

### Threat Verdict
```
If trust < 30.0 AND msg.type in [PANIC_FLOOD, BLACKHOLE, SYBIL]:
  → Initiate CENSUS_POLL_INITIATE broadcast
  
Poll Result:
  yesVotes / totalVotes ≥ 50% → MALICIOUS (verdict=1)
  yesVotes / totalVotes < 50% → CLEARED (verdict=0)
  totalVotes < CENSUS_MIN_VOTERS → INCONCLUSIVE (verdict=2)
```

---

## Test Scenarios

### Scenario 1: Normal Operation (No Attacks)
```
t=100:   SNs wake, send HELLO
t=102:   SN receives CH/GWN HELLO, populates neighbor table
t=105:   SN sensor period triggers, sends Type 1 message
t=110:   SN repeats sensor cycle (every period + jitter)
Result:  Steady uplink traffic, trust scores remain neutral
```

### Scenario 2: Flooding Attack (Malicious SN broadcasts many HELLOs)
```
t=100:   Malicious SN inflates TX power, sends 10x HELLO/cycle
Result:  
  - Other SNs receive unusual number of HELLOs
  - Trust not directly impacted (HELLO is discovery, not data)
  - Attack visible in packet log, but not automatically detected
  - Mitigation: rate limiting in future, or Sink-based analysis
```

### Scenario 3: Census Voting (Distrust Consensus)
```
t=50:    SN_A.trust[SN_B] drops to 25 (some bad interactions)
t=51:    SN_A initiates CENSUS poll on SN_B
t=52-60: SN_C, SN_D, SN_E receive poll, check their trust[SN_B]
         - SN_C.trust[SN_B] = 28 → vote YES
         - SN_D.trust[SN_B] = 45 → vote NO
         - SN_E.trust[SN_B] = 55 → vote NO
t=61:    Poll timeout: 1 YES / 3 votes = 33% < 50% → CLEARED
         SN_A resets SN_B.trust to TRUST_INITIAL (50)
Result:  Innocent node exonerated; malicious node would be voted out
```

### Scenario 4: Orphan Mode (No CH in Range)
```
t=105-150: SN attempts sensor TX, finds no verified target (5 times)
t=151:     orphanCheckCount = 5 → isOrphaned = true
t=152:     Extended sleep: 2 TF awake per 35 TF cycle (~6% duty)
           Broadcast link-loss panic
t=200:     CH enters range, SN receives HELLO with verified=1
t=201:     SN re-discovers parent, exits orphan mode
           nextSensorTX recalculated, normal cycle resumes
Result:    Graceful degradation with energy savings in disconnected scenarios
```

---

## Performance Notes

### CPU Load
- `step()`: O(n) where n = neighbors (typically 5-10)
- `receive()`: O(1) for message dispatch
- `checkCensusTriggers()`: O(m) where m = active polls (typically 1-2)
- **Overall**: Very low, dominated by WSN_Node base class

### Memory
- **neighborTable**: One entry per neighbor (~50 bytes each, ~5-10 neighbors)
- **censusActivePolls**: One entry per active poll (~100 bytes, ~1-2 active)
- **seenPanicUIDs**: Fixed circular buffer (last 50 UIDs, ~200 bytes)
- **Total**: ~500-1000 bytes per SN (negligible)

### Network Traffic (per SN per 100 TF)
- HELLO TX: ~3 msgs (one per phase burst period)
- SENSOR TX: ~14-15 msgs (one per 7-8 TF avg, adjusted for orphan)
- PANIC TX: ~0.2 msgs (avg, rare, cooldown gated)
- CENSUS: ~0.5 msgs (polls + votes, depending on threats)
- **Total**: ~18-20 msgs per 100 TF (0.18-0.20 msg/TF per node)

---

## Integration Points

### Calling WSN_Sensor from WSN_Main
```matlab
% In WSN_Main, STEP phase (t=1:simSteps)
nodes(i).step(t, physAdj)                % SN returns [msgs]
nodes(i).receive(msg, t, rssi)           % SN processes inbound
```

### Calling from WSN_Attack
```matlab
% In WSN_Attack system
WSN_Attack.isMaliciousNode(sn_idx, t)    % Check if compromised
WSN_Attack.getAttackType(sn_idx)         % Get attack type
WSN_Attack.shouldDropBlackhole(sn_idx, t) % Decide drop
```

### Calling from WSN_FeatureExport (ML-IDS)
```matlab
% In WSN_Main during TX/RX
WSN_FeatureExport.tapTx(i, msg, t)      % Log TX for IDS training
WSN_FeatureExport.tapRx(i, rssi, msg, t) % Log RX for IDS training
```

---

## Future Refactoring (Post-Modularization)

Once this refactoring is complete, SN_Behavior and SN_Messaging will be separated into dedicated files:

- **SN_Behavior.m**: Trust, census, panic logic (high-level decisions)
- **SN_Messaging.m**: Message creation, parsing, handlers (low-level protocol)
- **WSN_Sensor.m**: Thin facade, delegates to above two

This will improve:
- Readability (1500 LOC → 3 × 500 LOC)
- Testability (test behavior without message format details)
- Reusability (Behavior logic applicable to other tiers)

### Modularization Status (2026-06-21)
Unlike CH/GWN/Sink, **SN was not split** into Registry/Enforcement/
FeatureExport submodules — the user's request scoped the split to CH and
GWN only ("similar to the internal folder structure found in the Sink").
`WSN_Sensor.m` remains a single monolithic class (`SN_Behavior.m`/
`SN_Messaging.m` above are still unused docs-only stubs, same as CH's were
before its split).

What *was* added: dormant trust-decision-matrix hooks, mirroring the
pattern in `WSN_ClusterHead_Enforcement` / `WSN_Gateway_Enforcement` /
`WSN_Sink_Enforcement` —
- Properties: `trustDecisionMatrix`, `trustDecisionPolicy`,
  `trustDecisionWeights` (inert, `PASSIVE` policy)
- Methods: `evaluateTrustDecision(obj, neighborID)` (returns a placeholder
  `ALLOW` verdict), `buildTrustMatrix(obj)` (returns `obj.neighborTrust`
  as-is)

Neither hook is wired into any active call path (`handlePanicReception`'s
existing trust gate still uses `getNeighborTrust` directly, unchanged).
Verified: `WSN_Sensor` parses via `meta.class.fromName` after the addition.

---

## Documentation Maintainers
- **Core Logic**: [User/Developer Name]
- **ML-IDS Phase 4**: [User/Developer Name]
- **Attack Integration**: [User/Developer Name]
- **Last Review**: 2026-06-21

---

## Quick Links to Related Code
- Base class: `WSN_Node.m` (properties, logging, HELLO burst)
- Message class: `WSN_Message.m` (serialization, type constants)
- Config: `WSN_Config.m` (all constants like PANIC_ANOMALY_THRESHOLD)
- Attack system: `WSN_Attack.m` (attack types, drops, sybil)
- Feature export: `WSN_FeatureExport.m` (ML training data)
- Sink: `WSN_Sink.m` (receives/aggregates sensor + panic data)
