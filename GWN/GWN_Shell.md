# Gateway (GWN/Tier 3) — Shell / Working Notes

## Status
- **Last Updated**: 2026-06-21
- **Implementation**: Core + dual-radio + ML-IDS Phase 4 complete
- **Key Feature**: Reporting-silence detector (catches Blackhole/Grayhole attacks)
- **Testing**: Verified in mesh topologies with backbone FSM + CH recruitment

## Quick Reference

### Dual-Radio Architecture
- **Backbone (LoRa)**: GWN-to-GWN, stable links, FSM protocol, Type 7 CMD messages
- **Access (HC12)**: CH/SN discovery, HELLO broadcast, handshake (Type 6 CH_CMD)
- **Routing**: Message type determines which radio (FSM → backbone, discovery → access)

### Key Metrics
- **Backbone Parent Selection**: Token-based collision avoidance
- **CH Recruitment Retries**: Max 3 attempts per target
- **Handshake Timeout**: 20 TFs (per radio lock)
- **Aggregation Period**: 7-10 TFs (from first CH child)
- **Reporting-Silence Threshold**: 3 × aggregation period
- **Escalation Steps**: SOFT → HARD → BLACKLIST (3 step enforcement)
- **Pending CH Timeout**: 15 TFs (awaiting ENC_HELLO confirmation)
- **Pending CH_HELLO Buffer**: Max 30 messages (prevents orphan relay loss)

### Battery Profile (100% → 0%)
- Idle: 0.5 units/TF (always awake, no sleep like GWNs)
- Backbone TX (FSM/Token): ~1.0 units/msg
- Access TX (HELLO/CH_ACK): ~0.8 units/msg
- Aggregation RX/TX: ~1.5 units/msg (with encryption)
- **Lifetime**: ~150-200 TF (high activity due to two radios)

---

## Known Issues & Workarounds

> **See also**: `RECRUITMENT_RACE_CONDITIONS.md` (root) - a dedicated
> 2026-06-21 audit of GWN-GWN, GWN-CH, and CH-CH handshake race conditions,
> documented but deliberately not fixed. Two plausible GWN-GWN races found
> (late-ENC_HELLO-vs-reassigned-lock, queued-effect rejection window).

### Issue #1: CH_HELLO Relay Drop (Orphan GWN Parent)
**Symptom**: CH recruits another CH, sends CH_INFO to parent; parent GWN orphaned → CH_INFO lost
**Root Cause**: handle_CH_HELLO dropped relay if GWN lacked parent
**Solution**: pendingChHelloForward buffer + flushPendingChHelloForward() on parent acquired
**Status**: FIXED (v1.4)
**Reference**: See flushPendingChHelloForward() in WSN_Gateway_Behavior.m

### Issue #2: Aggregation Loss Invisible (Reporting-Silence)
**Symptom**: Child CH goes silent (Blackhole), stops sending 5.2, parent doesn't detect
**Root Cause**: Parent only retries its own pending 5.2; doesn't track child silence
**Solution**: Track chLastAggSeen; initiate census poll if silence > 3 × period
**Status**: FIXED (v1.3)
**Reference**: checkReportingSilence() in WSN_Gateway_Behavior.m

### Issue #3: Backbone FSM Deadlock on Token Loss
**Status**: OBSOLETE (confirmed 2026-06-21) — Token-based flow control (Type
8: TOKEN_DOWN/TOKEN_REQ/PATH_COMPLETE) has been fully replaced by phase
scheduling. `handleReceive` now just logs `[IGNORED] TOKEN.%d ... (phase
scheduling active)` and returns for every Type 8 message
(`WSN_Gateway_Messaging.m:296-300`) — no GWN ever acts on a TOKEN frame
anymore, so the deadlock this issue describes can no longer occur. Left
here for history rather than deleted; `GWN_Index.m` still documents Type 8
as if active and should be read with this in mind.

### Issue #4: DVS Power Boost Doesn't Reset
**Status**: FIXED (2026-06-21) — `checkChDiscoveryDVS` (`GWN/WSN_Gateway.m`)
only ever scaled `controlPower` up on a stall and never reduced it once
discovery resumed. Added the symmetric case: when a new CH child is found
(`~stalled`) and `controlPower` is above baseline, reset it back to
`WSN_Config.TxPower_GWN_Control` and refresh `chDvsScaleCount` to 0 (so a
future stall can scale up again instead of having already exhausted its
attempt budget from a prior, now-resolved stall). Verified: parses cleanly,
included in the standard headless regression run.

### Issue #5: CH-Discovery DVS Ran Before This GWN Was Itself Verified
**Status**: FIXED (2026-06-21) — `checkChDiscoveryDVS` had no gate on this
GWN's own `isVerified`, so an unverified GWN (no confirmed backbone path to
the Sink yet) could still spend access-radio power-scaling budget recruiting
CHs it had nowhere to forward data for. Added `if ~obj.isVerified, return;
end` at the top of `checkChDiscoveryDVS`. This is also now one half of a
matched pair: the CH side gained its own, more conservative DVS
(`checkChPeerDiscoveryDVS` / `checkChOrphanDVS` in
`CH/WSN_ClusterHead.m`, documented in `CH_Documentation.md` §8) so
connectivity-frontier widening is no longer GWN-only.

---

## Decision Matrix / Trust Scoring

### Trust Deltas (GWN Context)
```
Event                               Delta    Context
────────────────────────────────────────────────────
Backbone ACK from parent             +3      (FSM handshake)
CH recruitment success               +2      (per child)
CH aggregation timeout              -10      (first phase)
Reporting-silence (>3×period)       -20      (automatic poll)
Malicious verdict from census       -50      (confirmed)
Failed backbone recruitment (MAX_R) -30      (strong penalty)
```

### Thresholds
- **TRUST_INITIAL** = 50.0
- **TRUST_CENSUS_TRIGGER** = 30.0 (initiate poll)
- **SILENCE_GRACE_MULTIPLIER** = 3 (report-silence timer)

---

## Test Scenarios

### Scenario 1: Normal GWN-to-GWN Backbone + CH Recruitment
```
t=50:    GWN_A discovers GWN_B (backbone HELLO)
t=51:    GWN_A sends PARENT_INIT to GWN_B (FSM)
t=52:    GWN_B responds with PARENT_ACK
t=53:    GWN_A sends REQ_JOIN → ACK_JOIN chain
t=54:    VERIFIED, forwards sensor data to GWN_B
t=60:    CH_C sends HELLO to GWN_A (access radio)
t=61:    CH_C sends CH_REQ to GWN_A
t=62:    GWN_A sends CH_ACK + local key
t=63:    CH_C sends KEY_ACK (encrypted) → VERIFIED
         GWN_A adds to chChildren, sends CH_INFO to GWN_B
Result:  Mesh topology: SN → CH → GWN_A → GWN_B → Sink
```

### Scenario 2: Reporting-Silence Detection (Blackhole Child)
```
t=100:   GWN has verified CH child, aggregation period = 10 TF
t=105:   Malicious CH stops forwarding (blackhole attack)
t=110:   GWN hasn't received 5.2 from CH (silence = 10 TF = 1 period)
t=115:   Silence = 15 TF (still < 3×10)
t=125:   Silence = 25 TF (still < 3×10)
t=131:   Silence = 31 TF > 3×10 = 30 TF → trigger census poll
t=132:   CENSUS_POLL_INITIATE broadcast on suspect CH
t=140:   Votes collected, verdict = MALICIOUS (quorum met)
         GWN sends SHUTDOWN.HARD_RESET to CH
Result:  Blackhole attack detected after 30 TF silence
```

### Scenario 3: CH_HELLO Relay Buffering
```
t=60:    CH_C sends CH_INFO to GWN_A (recruited CH_D)
t=61:    GWN_A wants to relay to parent GWN_B
         (but GWN_A orphaned, no parent yet)
t=62:    CH_INFO queued in pendingChHelloForward (size = 1)
t=70:    GWN_A discovers & recruits parent GWN_B
t=71:    flushPendingChHelloForward() called
         Replay pending CH_INFO to GWN_B
         Clear buffer
Result:  CH_D eventually announced to ancestor despite transient orphan state
```

---

## Performance Notes

### CPU Load
- `step()`: O(n) where n = neighbors (GWNs + CHs, typically 5-15)
- `processSensorAggregation()`: O(m log m) where m = CH children (sort)
- `checkReportingSilence()`: O(k) where k = CH children
- **Overall**: Moderate, dominated by FSM + aggregation

### Memory
- **neighborTable**: ~50 bytes × (GWNs + CHs), typically ~1 KB
- **chChildren**: ~5-10 CH IDs, ~50 bytes
- **sensorTable**: ~5000 bytes (aggregated from all children)
- **chLastAggSeen**: ~30 bytes × CH children
- **pendingChHelloForward**: Up to 30 messages, ~500 bytes
- **Total**: ~2-3 KB per GWN

### Network Traffic (per GWN per 100 TF)
- Backbone (GWN-GWN): ~10 FSM/Token messages
- Access (CH discovery): ~3-5 HELLO broadcasts
- CH recruitment: ~2-3 messages (CH_REQ/ACK chain)
- Aggregation (5.2/5.3): ~15-20 messages (from children)
- Panic: ~1-2 messages (forwarded from children)
- Census: ~2-3 messages (polls + votes)
- **Total**: ~35-45 messages per 100 TF (0.35-0.45 msg/TF)

---

## Integration with Other Tiers

### Upstream (to parent GWN or Sink)
- Forward aggregated sensor data (5.2) from CH children
- Relay panic messages (Type 2)
- Forward census verdicts (Type 11)
- Participate in backbone FSM (Type 7)

### Downstream (to CH/SN children via Access Radio)
- Broadcast HELLO for discovery
- Respond to CH_REQ with CH_ACK + key
- Send heartbeats (Type 9, multicast FF00)
- Receive aggregation + ACK (Type 5.2/5.3)

---

## TODO / Future Improvements

### Priority 1 (Current)
- [ ] Verify reporting-silence with various aggregation periods
- [ ] Test DVS power adjustment on CH count changes
- [ ] Validate pending CH_HELLO flush logic under network loss

### Priority 2 (Optimization)
- [ ] Adaptive aggregation period (based on CH count)
- [ ] Dual-parent failover (backup GWN if primary fails)
- [ ] Stale neighbor cleanup (remove if no HELLO > N periods)
- [ ] Sensor data compression (lossy quantization)

### Priority 3 (Future Features)
- [ ] Geographic routing (position-aware parent selection)
- [ ] Load balancing (distribute children based on capacity)
- [ ] Sink feedback loop (optimize aggregation period)
- [ ] Multi-path routing (redundant backbone links)

---

## Quick Reference: Message Routing

| Message Type | Direction | Radio | Handler |
|--------------|-----------|-------|---------|
| Type 0 (HELLO) | RX | Access | handleHelloReception |
| Type 2 (PANIC) | RX/TX | Access | processPanicQueue |
| Type 5.2 (AGG) | RX | Access | handleSensorAgg |
| Type 5.3 (ACK) | TX | Access | createAggACK |
| Type 6 (CH_CMD) | RX/TX | Access | handleCHCMD |
| Type 7 (CMD) | RX/TX | Backbone | [FSM handler in Radio] |
| Type 8 (TOKEN) | RX/TX | Backbone | [Token handler in Radio] |
| Type 9 (HB) | TX | Both | broadcastHeartbeat |
| Type 11 (CENSUS) | RX/TX | Both | handleCensusMessage |
| Type 12 (SHUTDOWN) | RX/TX | Both | handleShutdownMessage |

---

## Documentation Maintainers
- **Dual-Radio Architecture**: [Your name]
- **Reporting-Silence Detector**: [Your name]
- **CH_HELLO Buffer Fix**: [Your name]
- **Last Review**: 2026-06-21

---

## Quick Links
- **Base class**: WSN_Node.m
- **Behavior delegate**: WSN_Gateway_Behavior.m
- **Messaging delegate**: WSN_Gateway_Messaging.m
- **Registry delegate**: GWN/Registry/WSN_Gateway_Registry.m (local-key derivation)
- **Enforcement delegate**: GWN/Enforcement/WSN_Gateway_Enforcement.m (trust scoring, census/shutdown)
- **FeatureExport delegate**: GWN/FeatureExport/WSN_Gateway_FeatureExport.m (children-count metrics, dormant trust snapshot)
- **Backbone radio**: WSN_Radio.m (FSM protocol)
- **Access radio**: WSN_RadioStack.m (HC12 stack)
- **Encryption**: WSN_Crypto.m
- **Feature export**: WSN_FeatureExport.m

---

## Modularization Notes (2026-06-21)

`WSN_Gateway.m` already had a real Behavior/Messaging delegation (FSM vs.
protocol materialization) that predates this pass and was left untouched.
On top of that, the trust/census/key-derivation logic that lived directly
in the main classdef (lines 341-603 in the pre-split file) was extracted
into thin-delegate Registry/Enforcement/FeatureExport submodules, mirroring
the pattern already used for `WSN_Sink.m` and `WSN_ClusterHead.m`:

- **Registry**: `deriveLocalKey`
- **Enforcement**: `getNeighborTrust`, `updateNeighborTrust`,
  `checkCensusTriggers`, `handleCensusMessage`, `handlePollComplete`,
  `handleShutdownMessage`, plus dormant `evaluateTrustDecision` /
  `buildTrustMatrix`
- **FeatureExport**: new `getActiveChildrenCount` / `getSilencedChildrenCount`
  real accessors, plus dormant `getTrustFeatureSnapshot`

`WSN_Gateway.m` itself keeps `step`/`receive`/`updatePhysics`/
`checkChDiscoveryDVS` and the dual-radio logging helpers
(`addLogBackbone`/`addLogAccess`/`addLogBoth`/`logTxBackbone`/
`logTxAccess`) — those are cross-cutting and called by the extracted
methods, so they were not moved. All extracted methods are called via
`obj.method(...)` thin wrappers on the main class, never directly between
static helper classes, to preserve `WSN_Sink < WSN_Gateway` inheritance
correctness (`WSN_Sink` overrides `handlePollComplete`'s ancestor-jurisdiction
checks via its own `globalTrustRegistry`, while `WSN_Gateway_Enforcement`
provides the shared base behavior other GWNs use).

Added dormant trust-decision-matrix properties (`trustDecisionMatrix`,
`trustDecisionPolicy`, `trustDecisionWeights`) to `WSN_Gateway`'s properties
block. **Important**: `WSN_Sink < WSN_Gateway` inherits these — the
previously-separate copy of the same 3 properties was removed from
`WSN_Sink.m` to avoid a MATLAB subclass property-redeclaration error.

Verified: all GWN-tier classes parse via `meta.class.fromName`; a 600-step
headless run (`ActivateAttacks=false`) completes without error and confirms
sensor data still reaches the Sink's `sensorRegistry` end-to-end.

### Bug found and fixed: CH->GWN direct 5.2 merge silently corrupted data
**Severity**: Real correctness bug, pre-existing (not introduced by this
session's split — `mergeSensorAgg`'s body was moved verbatim and lives in
`WSN_Gateway_Messaging.m`, which predates the Registry/Enforcement/
FeatureExport split and was deliberately left untouched by it).

**Symptom**: When a CH sends its periodic 5.2 SENSOR_AGG directly to its GWN
parent (`handle_CH_HELLO` -> `handle_SENSOR_AGG` -> `mergeSensorAgg`, all in
`WSN_Gateway_Messaging.m`), the merge silently produced garbage entries in
`gw.sensorTable` instead of the CH's real sensor readings. No runtime error
was thrown (bounds-checked loop just produced wrong values), so it would not
have surfaced in a clean-exit headless run.

**Root cause** (two compounding issues in the old `mergeSensorAgg`):
1. **Missing decryption**: a CH always encrypts its 5.2 payload with the
   `localKey` its GWN parent issued during handshake
   (`CH/FeatureExport/WSN_ClusterHead_FeatureExport.m`'s `createSensorAgg`:
   `if ~isempty(obj.localKey), msg.payload = WSN_Crypto.encrypt(...)`). The
   old `mergeSensorAgg` never decrypted - it read raw ciphertext bytes as if
   they were the plaintext header/sensor fields. (Confirmed this is not the
   "UNIVERSAL RELAY" path: that branch keys off `gw.children`, which only
   holds backbone *GWN* children, not CH children - so a direct CH child's
   5.2 always falls through to `handle_SENSOR_AGG`, not the relay.)
2. **Wrong header offset**: CH's actual payload layout is
   `[TotalFrags(1), FragIdx(1), NumSensors(1), {SensorData(8 bytes)} x N]`
   (3-byte fragment header, confirmed identical in CH's own CH<->CH merge at
   `CH/Registry/WSN_ClusterHead_Registry.m:196-242`, which gets this right).
   The old GWN-side `mergeSensorAgg` assumed a 1-byte header
   (`numSensors = msg.payload(1); offset = 2;`), off by 2 bytes against the
   real layout.

**Fix** (`GWN/WSN_Gateway_Messaging.m`, `mergeSensorAgg`): decrypt via
`obj.getLocalKeyForCH(msg.src)` (the same key map populated during CH
handshake, `gw.chLocalKeys`) when `msg.isEncrypted()`, then parse with the
correct 3-byte header (`numSensors = payload(3); offset = 4;`), matching
CH's actual format exactly.

**Verification**: deterministic unit-style check (constructed a `WSN_Gateway`,
registered a fake CH's local key in `chLocalKeys`, built an encrypted
CH-formatted 5.2 payload by hand, called `gw.messaging.mergeSensorAgg(msg,t)`
directly) - confirmed sensor ID/value/battery/RSSI round-trip exactly through
encrypt -> decrypt -> parse after the fix. Also re-ran the 300-step headless
regression (`ActivateAttacks=false`) post-fix: `SIM_OK`, no errors.

**In-vivo confirmation**: a 600-step/100-node `ActivateAttacks=true` run did
reach live CH->GWN aggregation (e.g. `AA02 [5.2_FRAG] ... 2 sensors` at
t=359, `FF01 [5.3_TX] ACK -> ...` shortly after), exercising the fixed path
for real.

### Separate, NOT-yet-fixed issue found while investigating: subtype 5.2 is overloaded for two different encryption shapes
While confirming the above fix in a full run, the Sink's exported
`sink_sensorRegistry` showed a cluster of ~40 "sensor" entries with IDs in
the 0xFE2C-0xFEFC range (e.g. `65177,FE99`) that don't correspond to any
real node in the simulation (confirmed: zero matches for those hex IDs as a
`NodeID` anywhere in the combined log). Ruled out Sybil (the only attack
types active in that run were code 1 and 5; `ATTACK_SYBIL=3` never fired).

**Root cause (architectural, not a typo)**: `handle_SENSOR_AGG` (`GWN/
WSN_Gateway_Messaging.m`) is the single dispatch point for *every* inbound
subtype-5.2 message, but two structurally different message shapes both use
subtype 5.2:
1. **CH->GWN** (what this session's fix targets): single XOR-encrypted with
   the per-CH `localKey` from `chLocalKeys`, real bytes live in `msg.payload`.
2. **GWN->GWN backbone relay** (`processSensorAggregation`'s output, e.g.
   `FF05 -> FF01` in the evidence above): built via
   `aggMsg.applyLayeredEncryption(...)`, which sets `doubleEncryptedPayload`/
   `globalEncryptedPayload` but does **not** overwrite `aggMsg.payload`
   (confirmed by reading `WSN_Message.applyLayeredEncryption`, lines
   114-148) - so `msg.payload` arriving at the next hop is stale/plaintext,
   and the real (decryptable-only-by-Sink-style `decryptLayered`+
   `deriveRemoteLocalKey`) bytes are in `doubleEncryptedPayload`.

`handle_SENSOR_AGG` calls `obj.mergeSensorAgg(msg, t)` unconditionally for
both shapes. This session's fix correctly handles shape (1) and, for shape
(2), now safely **drops** the message at the `mergeSensorAgg` step
(`getLocalKeyForCH` returns empty for a GWN sender, hits the new
`if isempty(localKey): return` guard) rather than parsing garbage like the
pre-fix code did - an improvement at that specific call site (drop beats
corrupt). **However**: the 0xFE2C-0xFEFC entries were observed in the
`sink_sensorRegistry` export from a run made *after* this fix was applied,
so shape-(2) corruption is evidently still reaching the Sink through some
other path - most likely `handle_SENSOR_AGG`'s unconditional
`createSensorAggForBackbone(msg, t)` call (which re-wraps whatever is
currently in `msg.payload` - stale/plaintext for shape (2) - with a single
fresh `gw.encryptionKey` layer and forwards it), which this session's fix
does not touch, ultimately reaching the Sink's `decryptLayered`/
`deriveRemoteLocalKey` with mismatched framing. This last link is not fully
traced/confirmed - flagging as unresolved rather than asserting a fix.

**Not fixed this session** - this needs a design decision, not a quick
patch: should an intermediate GWN (a) decrypt+merge shape (2) into its own
`sensorTable` (requiring it to derive the sending GWN's local key the same
way `WSN_Sink_Registry.deriveRemoteLocalKey` does), or (b) skip merge
entirely and pure-relay shape (2) messages onward (closer to what the
"UNIVERSAL BACKBONE RELAY" comment block earlier in this file seems to
intend for encrypted-from-`gw.children` traffic, but that branch's
`ismember(msg.src, gw.children)` check only matches direct backbone GWN
children, not transitively-relayed traffic from further down the chain).
Flagging for follow-up; `handle_SENSOR_AGG` likely needs to branch on
whether `msg.src` is a known CH (`chLocalKeys` has it) vs. a GWN before
deciding how to decrypt/route.
