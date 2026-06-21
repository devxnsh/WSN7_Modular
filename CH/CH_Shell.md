# Cluster Head (CH/Tier 2) — Shell / Working Notes

## Status
- **Last Updated**: 2026-06-21
- **Implementation Phase**: Core + ML-IDS Phase 4 complete (Reporting-Silence detector added)
- **Testing Status**: Verified in multi-hop topologies; census voting works; blackhole/grayhole detection via silence

## Quick Reference

### Key Metrics
- **Aggregation Period**: 7-10 TFs (random fixed after verification)
- **Fragment Size**: Max 10 sensors per message
- **Retry Interval**: 5 TFs
- **Max Retries**: 3 per pending aggregation
- **Handshake Timeout**: 20 TFs lock timer
- **Max Recruitment Retries**: 3 attempts per target
- **Backoff After Max Retries**: 2-5 TFs random
- **Trust Range**: 0-100 (initial: 50)
- **Census Timeout**: 10 TFs
- **Reporting-Silence Threshold**: 3 × AGG_PERIOD (e.g., 30 TFs for 10 TF period)
- **Escalation Steps**: SOFT → HARD → BLACKLIST (3 steps to enforcement)

### State Machine
```
BOOT → DISCOVERY (wait for verified GWN)
         ↓ [Found]
      SECURE (no active recruitment)
         ↓
      [Find target] → HANDSHAKE (await ACK/REJECT)
                         ↓ [ACK] [REJECT]
                    [KEY_ACK]  [Retry next]
                         ↓        ↓
                    VERIFIED ← SECURE
                         ↓
                    [Aggregate & Forward]
```

### Child Management
- **Sensor Children**: Any SN that sends Type 1 SENSOR data (auto-registered)
- **CH Children**: CHs that successfully complete CH-CH handshake (explicit recruitment)
- **Pending Children**: CHs awaiting ENC_HELLO confirmation (timeout 15 TF)

### Battery Profile (100% → 0%)
- Idle: 0.5 units/TF (always awake, no sleep cycles)
- TX_Hello: ~0.5 units/msg
- TX_Aggregation: ~1.2 units/msg (varies with fragment count)
- TX_Handshake: ~0.8 units/msg
- **Lifetime**: ~200 TF at 100% activity (no sleep advantage like SNs)

---

## TODO / In Progress

### Priority 1 (Current/Blocker)
- [ ] Verify reporting-silence detector with various aggregation periods
- [ ] Test CH-CH chain integrity (one-hop limit enforcement)
- [ ] Validate fragment assembly after loss/reorder
- [ ] Check pending child timeout eviction (15 TF stale removal)

### Priority 2 (Optimization)
- [ ] Sensor priority aggregation (send high-priority data first)
- [ ] Adaptive aggregation period (based on child count)
- [ ] Dual-parent failover (backup GWN if primary fails)
- [ ] Stale neighbor cleanup (remove if not heard from for N periods)

### Priority 3 (Future Features)
- [ ] In-network data fusion (temporal alignment of sensor values)
- [ ] Lossy compression (quantization of sensor values)
- [ ] Rate limiting on child SNs (control sensor TX frequency)
- [ ] Sink feedback loop (receive latency info from parent, adjust period)

---

## Known Issues & Workarounds

> **See also**: `RECRUITMENT_RACE_CONDITIONS.md` (root) - a dedicated
> 2026-06-21 audit of GWN-GWN, GWN-CH, and CH-CH handshake race conditions.
> Conclusion for CH-CH specifically: the one-hop-limit lock-conflict check
> correctly rejects concurrent recruitment attempts (not a bug); the
> GWN-CH "lost CH_ACK" case costs a multi-timeout delay but no data
> corruption. No new CH-CH race beyond Issue #6 below was found.

### Issue #1: CH-CH Recruitment Loop Prevention
**Symptom**: CH recruits another CH, which recruits a third (violates one-hop limit)
**Root Cause**: First CH-CH link should set `isQualifiedToRecruit = false`
**Status**: FIXED (v1.2) — GWN-anchored CHs only set `isQualifiedToRecruit = true`
**Verification**: Check CH_JOINOK handler at line 409

### Issue #2: Aggregation Message Loss Invisible
**Symptom**: Child CH stops sending 5.2 messages, parent doesn't detect (previously)
**Root Cause**: Parent only retries pending 5.2 on its end; doesn't track child silence
**Solution**: Reporting-Silence detector — tracks last 5.2 arrival time per child
**Status**: FIXED (v1.3) — Automatically initiates census poll if no agg for 3×period

### Issue #3: CH_INFO Relay Drops If Orphan
**Symptom**: CH recruits a child, but parent GWN orphaned → ch_info lost forever
**Root Cause**: WSN_Gateway_Messaging.handle_CH_HELLO had no retry buffer
**Solution**: Added pendingChHelloForward buffer; flushes when parent acquired
**Status**: FIXED (v1.4) — GWN side; CH side always sends immediately

### Issue #4: Pending Aggregation Retry Skips First Fragment
**Symptom**: Multi-fragment 5.2, first fragment ACKed, retries skip fragment 2
**Root Cause**: Only first fragment stored in pendingAgg; retries all fragments
**Workaround**: pendingFragments array tracks which fragments pending
**Status**: MITIGATED (v1.3) — fragment-level tracking in pendingFragments

### Issue #5: Trust Doesn't Recover After Transient Failure
**Symptom**: CH fails handshake once, never retried (permanently rejected)
**Root Cause**: rejectedGWNs list never cleared (grows unbounded)
**Solution**: Periodic reset of rejectedGWNs every CH_REJECTED_LIST_RESET_INTERVAL (100 TF)
**Status**: FIXED (v1.1) — Forgiveness window implemented

### Issue #6: Handshake Lock Can't Recover from Partial Failure
**Symptom**: CH sends CH_REQ, receives partial ACK, lock stuck forever
**Root Cause**: Radio lock not cleared on bad checksum or timeout
**Solution**: handleTimeout() sends REJECT to partner as orphan guard
**Status**: MITIGATED (v1.2) — Timeout recovery added; but radio lock may persist in edge case
**Future**: Consider lock reset on bad checksum

---

## Decision Matrix / Trust Scoring

### Trust Deltas (Recruitment Context)
```
Event                               Delta    Trigger
─────────────────────────────────────────────────────────
Successful KEY_ACK reception         +5       (rare, end of handshake)
Failed recruitment (MAX_RETRIES)    -30       (immediate, strong penalty)
5.2 ACK received                     +2       (per aggregation cycle)
5.2 Aggregation silence (3×period)  -20       (automatically polled)
Malicious verdict from census       -50       (confirmed threat)
Non-response in census poll          -3       (uncooperative)
Data corruption / bad checksum      -10       (data integrity issue)
```

### Trust Thresholds
- **TRUST_INITIAL** = 50.0
- **TRUST_CENSUS_TRIGGER** = 30.0 (suspect, initiate poll)
- **TRUST_MIN** = 0.0
- **TRUST_MAX** = 100.0

---

## Test Scenarios

### Scenario 1: Normal GWN-Anchored CH Recruitment
```
t=50:    CH wakes, enters DISCOVERY, finds verified GWN
t=51:    CH sends CH_REQ to GWN
t=52:    GWN responds with CH_ACK + local key
t=53:    CH sends KEY_ACK (encrypted)
         Lock cleared, isQualifiedToRecruit = true
t=54:    CH sends aggregated sensor data to GWN (5.2)
Result:  Verified, can recruit other CHs
```

### Scenario 2: CH-CH Recruitment (Secondary CH)
```
t=100:   Primary CH (GWN-anchored, isQualified=true) sends HELLO
t=101:   Secondary CH receives HELLO, populates neighbor table
t=102:   Secondary CH enters DISCOVERY, finds Primary CH (verified)
t=103:   Secondary CH sends CH_REQ to Primary
t=104:   Primary responds with CH_JOINOK (no key exchange)
         Secondary: isQualifiedToRecruit = false (not GWN-anchored)
Result:  One-hop CH-CH chain; Secondary cannot recruit further
```

### Scenario 3: Aggregation with Fragment Loss
```
t=105:   CH has 25 sensors from children, creates 3 fragments (5.2)
t=106:   Fragment 1/3 sent to GWN parent
t=107:   GWN sends 5.3 ACK for frag 1
t=108:   Fragment 2/3 sent → lost in network (no ACK)
t=113:   5 TFs elapsed, CH retries pending (frag 2/3)
t=114:   GWN receives retry, sends ACK
Result:  Automatic retry recovers loss; aggregation eventually delivered
```

### Scenario 4: Reporting-Silence Detection (Blackhole Child)
```
t=100:   CH recruits malicious child CH (blackhole)
t=105:   Malicious child starts dropping 5.2 (silent attack)
t=110:   CH hasn't received 5.2 from child for 10 TFs (>3×period)
t=111:   CH initiates CENSUS_POLL on child
t=112-120: Other CHs vote on child's trustworthiness
t=121:   Verdict: MALICIOUS (quorum YES)
         CH issues SHUTDOWN.HARD_RESET to child
Result:  Blackhole attack detected and remediated
```

### Scenario 5: Census Voting & Escalation
```
t=200:   CH_A.trust[CH_B] drops to 25 (failed 5.2 aggregation)
t=201:   CH_A initiates CENSUS poll on CH_B (as direct child)
t=202-210: CH_C, CH_D, CH_E vote (all have trust[CH_B] ≥ 30) → vote NO
t=211:   Poll timeout: 0 YES / 3 NO = CLEARED
         CH_A resets CH_B.trust to TRUST_INITIAL
         
[Later, if repeated malicious behavior]
t=300:   CH_A.trust[CH_B] drops to 25 again
t=301:   Second CENSUS poll (first SOFT_RESET counted)
t=310:   Verdict: MALICIOUS → SOFT_RESET issued
         resetHistory[CH_B].softCount = 1
         
t=400:   Third distrust event
t=401:   Third CENSUS poll
t=410:   Verdict: MALICIOUS → HARD_RESET issued
         resetHistory[CH_B].hardCount = 1
         resetHistory[CH_B].softCount incremented
         
[After 3rd escalation]
t=500:   Fourth distrust event
t=501:   Fourth CENSUS poll
t=510:   Verdict: MALICIOUS → BLACKLIST issued
         CH_B now isBlacklisted = true, permanently silenced
Result:  Escalating enforcement prevents repeated attacks
```

---

## Performance Notes

### CPU Load
- `step()`: O(n) where n = neighbors (typically 10-15)
- `processSensorAggregation()`: O(m log m) where m = children (sort by RSSI)
- `handleSensorAgg()`: O(m) where m = sensor entries per fragment
- `checkCensusTriggers()`: O(k) where k = active polls (typically 1-2)
- **Overall**: Moderate, dominated by aggregation sort

### Memory
- **sensorTable**: One entry per child SN (~50 bytes each, ~20-30 SNs)
- **neighborTable**: One entry per CH/GWN neighbor (~50 bytes, ~5-10 neighbors)
- **censusActivePolls**: One entry per active poll (~100 bytes, ~1-2 active)
- **chLastAggSeen**: One entry per CH child (~30 bytes, ~5-10 CH children)
- **Total**: ~2-3 KB per CH (manageable)

### Network Traffic (per CH per 100 TF)
- HELLO TX: ~3 msgs (one per phase burst period)
- AGGREGATION (5.2) TX: ~10-15 msgs (one per 7-10 TF, fragmented)
- AGGREGATION (5.3) RX: ~10-15 msgs (ACKs from parent)
- PANIC FWD: ~0.5-1 msg (from children, high priority)
- CENSUS: ~1-2 msgs (polls + votes, depending on threats)
- **Total**: ~25-30 msgs per 100 TF (0.25-0.30 msg/TF per node)
- **Comparison**: ~2x SNs (due to aggregation), 1/3 of GWNs (no dual-radio overhead)

---

## Integration Points

### Calling WSN_ClusterHead from WSN_Main
```matlab
% In WSN_Main, STEP phase
nodes(i).step(t, physAdj)                % CH returns [msgs]
nodes(i).receive(msg, t, rssi)           % CH processes inbound
```

### Calling from WSN_Attack
```matlab
% Malicious CH behaviors
WSN_Attack.isMaliciousNode(ch_idx, t)
WSN_Attack.getAttackType(ch_idx)
WSN_Attack.shouldDropBlackhole(ch_idx, t)
WSN_Attack.shouldDropGrayhole(ch_idx, t)
WSN_Attack.getDenialOfSleepTargets(ch_idx, neighborTable, t)
```

### Calling from WSN_Gateway (Parent GWN)
```matlab
% Receive aggregation, handshake messages
nodes(gwn_idx).receive(5.2_msg, t, rssi)  % Aggregation
nodes(gwn_idx).receive(6.x_msg, t, rssi)  % Handshake
```

---

## Modularization Notes (2026-06-21)

`CH_Behavior.m`/`CH_Messaging.m` (FSM-vs-protocol split, described below as
the original plan) were never wired up — confirmed zero references from
`WSN_ClusterHead.m`; they remain unused docs-only stubs. Instead, the tier
was split using the same Registry/Enforcement/FeatureExport pattern applied
to `WSN_Sink.m` (and subsequently `WSN_Gateway.m`):

- **CH/Enforcement/WSN_ClusterHead_Enforcement.m**: `getNeighborTrust`,
  `updateNeighborTrust`, `checkCensusTriggers`, `handleCensusMessage`,
  `handlePollComplete`, `handleShutdownMessage`, plus dormant
  `evaluateTrustDecision` / `buildTrustMatrix`
- **CH/Registry/WSN_ClusterHead_Registry.m**: inbound sensor ingestion —
  `handleSensorData`, `processSensorAggregation`, `handleSensorAgg`,
  `mergeSensorAgg`
- **CH/FeatureExport/WSN_ClusterHead_FeatureExport.m**: outbound 5.2/5.3
  export pipeline — `createSensorAgg`, `handleAggACK`, `createAggACK`, plus
  dormant `getTrustFeatureSnapshot`

`WSN_ClusterHead.m` (reduced 1396 → 919 lines) keeps the FSM/handshake
methods (`step`, `receive`, `createCHREQ`, `handleCHJOINOK`, etc.) and
`encryptPayload` (used by `createCHINFO`) — these are tightly coupled to
the radio-lock FSM and were deliberately left in place rather than risk
splitting a state machine across files. All extracted methods are called
via `obj.method(...)` thin wrappers, never directly between static helper
classes.

Added dormant trust-decision-matrix properties (`trustDecisionMatrix`,
`trustDecisionPolicy`, `trustDecisionWeights`) to the properties block.

Verified: all CH-tier classes parse via `meta.class.fromName`; headless
runs confirm sensor-aggregation data still reaches the Sink.

### Cross-tier bug found (GWN-side, not CH) during 5.2 audit
CH's 5.2 SENSOR_AGG encode (`CH/FeatureExport/WSN_ClusterHead_FeatureExport.m`,
`createSensorAgg`) and CH's own CH<->CH merge (`CH/Registry/
WSN_ClusterHead_Registry.m`, `mergeSensorAgg`) are both correct and consistent
with each other. The receiving end on a direct GWN parent
(`GWN/WSN_Gateway_Messaging.m`'s `mergeSensorAgg`) had a decrypt-and-header-
offset bug that silently corrupted CH->GWN data - see "Bug found and fixed"
in `GWN_Shell.md` for the full writeup and fix. No change needed on the CH
side.

### Original Plan (superseded, kept for history)
The original idea was a CH_Behavior/CH_Messaging FSM-vs-protocol split
(1400 LOC → 3 × 500 LOC). That pattern was not pursued for CH because the
user's actual request was to mirror the Sink's Registry/Enforcement/
FeatureExport structure, which is a different axis of decomposition
(trust/export-pipeline vs. FSM, not behavior vs. protocol).

---

## Documentation Maintainers
- **Core Logic**: [User/Developer Name]
- **Reporting-Silence Detector**: [User/Developer Name]
- **ML-IDS Phase 4**: [User/Developer Name]
- **Last Review**: 2026-06-21

---

## Quick Links to Related Code
- Base class: `WSN_Node.m` (properties, logging)
- Message class: `WSN_Message.m` (serialization)
- Config: `WSN_Config.m` (constants)
- Parent: `WSN_Gateway.m` (receives 5.2, handles CH_HELLO forward)
- Attack system: `WSN_Attack.m` (attack types, drops)
- Feature export: `WSN_FeatureExport.m` (ML training data)
- Encryption: `WSN_Crypto.m` (XOR encryption stub)
- Enforcement delegate: `CH/Enforcement/WSN_ClusterHead_Enforcement.m` (trust, census/shutdown)
- Registry delegate: `CH/Registry/WSN_ClusterHead_Registry.m` (inbound sensor ingestion)
- FeatureExport delegate: `CH/FeatureExport/WSN_ClusterHead_FeatureExport.m` (outbound 5.2/5.3 pipeline)
