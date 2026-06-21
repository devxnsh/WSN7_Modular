# Cluster Head (CH) — Tier 2 Documentation

## Overview
Cluster Heads (Tier 2) are mid-tier aggregation nodes that:
- Aggregate sensor data from child Sensor Nodes (SNs) into prioritized reports
- Recruit and maintain connectivity to parent Gateway (GWN) or another CH
- Forward aggregated sensor data and panic messages up-tree
- Participate in ML-IDS Census protocol for trust-based threat detection
- Support **unbounded-depth** CH-CH relay chains: every CH that joins ends up
  individually GWN-verified+keyed regardless of how many hops out it is,
  with intermediate CHs acting as transparent "latches" (see §1, §3, §9)

## Core Responsibilities

### 1. Network Topology & Recruitment (transparent relay-latch model)
- **States**: BOOT → DISCOVERY → SECURE → HANDSHAKE
- **Parent Options**: any verified GWN or CH neighbor. A CH neighbor is no
  longer a different *kind* of parent than a GWN -- it's just a relay hop.
  `findBestVerifiedGWN`/`findBestVerifiedCH` pick the strongest candidate;
  the actual target sent a `CH_REQ` to may be several hops short of the GWN.
- **Retries**: `CH_MAX_RETRIES`=5 attempts per target, random backoff 2-5 TFs
  after exhausting retries (`CH_ACCESS_LOCK_TIMER`=16 TFs, widened from the
  old one-hop era's 4 TFs to give multi-hop round trips enough budget)
- **Verified Status**: requires the real, GWN-issued `CH_ACK` (`localKey` +
  5-bit `passkey`) to arrive -- whether direct or relayed back through an
  arbitrary chain of latches. `obj.parent` is always the *immediate*
  physical neighbor (the first hop toward the GWN), never the GWN's own ID
  if relayed -- this is what's physically reachable for ongoing traffic.
- **No more one-hop cap**: the old `isQualifiedToRecruit` flag (true only
  for GWN-anchored CHs) is gone. Any verified CH can recruit/relay further
  CHs at any depth -- see §9.

### 2. Sensor Data Aggregation (Type 5.2 / 5.3)
- **Aggregation Period**: Fixed random 7-10 TFs (set after verification)
- **Fragment Size**: Max sensors per fragment (e.g., 10 sensors/fragment)
- **Payload Format**: [TotalFrags(1), FragIdx(1), NumSensors(1), {SensorData} x N]
- **Sensor Entry**: [ID(2), Time(2), Value(2), RSSI(1), Battery(1)] = 8 bytes each
- **Encryption**: Local key XOR, always (every verified CH now has a
  `localKey` -- there is no more "parent is CH, unencrypted" case). The
  5-bit `passkey` is appended as the last payload byte before encryption.
- **Retry Logic**: Resend pending fragments every `AGG_RETRY_INTERVAL` TFs,
  max `AGG_MAX_RETRIES` retries -- this is this CH's OWN data. A *relayed*
  leaf's data uses the separate, generalized per-hop retry table described
  in §9 (`pendingRelayFragments`), since a latch may have several leaves'
  fragments in flight concurrently.

### 3. Handshake Protocol (Type 6: CH_CMD) -- repurposed for relay (no new types)
- **6.0 CH_REQ** (CH→GWN, or CH→nearby CH as a relay request -- same
  message either way, "not a message of its own"): `originalSrc` = the true
  requester identity, preserved unchanged through every relay hop
- **6.1 CH_ACK** (GWN→CH, reverse-latched back through the chain if
  relayed): local key (16B) + the new 5-bit passkey (1B) appended
- **6.2 KEY_ACK** (CH→GWN, possibly relayed): confirm key+passkey reception
  (encrypted, passkey appended before encryption)
- **6.3 CH_REJECT** (GWN/CH→CH, hop-local OR relayed): reject, triggering
  parent purge at whichever hop it's really about
- **6.4 CH_JOINOK** (adjacent CH→CH, ALWAYS hop-local, never relayed):
  "I'll latch/relay for you" -- NOT end-to-end verification, carries no key,
  just refreshes the requester's handshake-timeout lock while the rest of
  the chain works
- **6.5 CH_INFO** (latch→parent, relayed hop-by-hop, unencrypted): topology
  visibility side-channel -- announces which leaf a latch is now relaying
  for, so GWN/Sink/ML-IDS/GUI keep accurate path info even though the
  6.0-6.2 handshake/data path itself stays transparent/unwrapped

### 4. Panic Message Handling (Type 2)
- **Reception**: Forward to parent (unicast) or broadcast if no parent
- **Deduplication**: Track seen panic UIDs (circular buffer, max 100)
- **TTL Decrement**: Reduce by 1 each hop
- **Priority Forwarding**: HIGH severity → broadcast if orphan

### 5. Trust Management (Rule-Based, ML_IDS Phase 4)
- **Initial Trust**: 50.0 (neutral)
- **Trust Range**: 0.0 - 100.0
- **Trust Factors**: Message delivery, response time, data consistency, anomalous behavior
- **Hard Fail**: MAX_RETRIES on recruitment → trust penalty (-30)
- **Census Trigger**: When neighbor trust < 30.0, initiate polling

### 6. ML-IDS Census Protocol (Phase 4)
- **Poll Initiation**: For each distrusted neighbor, broadcast CENSUS_POLL_INITIATE
- **Voting**: Vote YES if neighbor trust < 30, NO otherwise
- **Poll Timeout**: 10 TFs to collect votes
- **Verdict**: Quorum ≥50% YES = malicious; otherwise = cleared
- **Enforcement**: 
  - For direct children: issue SHUTDOWN (escalates: SOFT → HARD → BLACKLIST)
  - For other nodes: forward verdict up-tree to parent
- **Escalation**: Tracks soft/hard reset counts per child; 3rd hard → blacklist

### 7. Reporting-Silence Detection (Phase 4 follow-up)
- **Tracks**: Last 5.2 aggregation arrival per CH child
- **Trigger**: No aggregation for SILENCE_GRACE_MULTIPLIER × AGG_PERIOD
- **Response**: Initiates census poll on silent child (catches Blackhole/Grayhole)
- **Impact**: Invisible attacks now detectable without explicit retry timeout

### 8. Dynamic Voltage Scaling (DVS) — CH Side

A CH has a single radio (`txPower`), unlike the GWN's dual-radio split
(`txPower` for data, `controlPower` for HC12 discovery). All CH-side DVS
therefore scales the same `txPower` used for HELLO broadcast, CH_REQ, and
every other outbound message — see `WSN_Physics.updateConnectivity`, where
link range is a function of the *sender's* configured power. Both
mechanisms below are strictly "appear in range" boosts: a CH never actively
polls or initiates because of DVS. The judgement to send a CH_REQ always
belongs to the *unverified* side, exactly as in the un-boosted FSM.

**8a. CH Peer-Discovery DVS** (`checkChPeerDiscoveryDVS`, gated on
`isVerified` alone)
- Any **verified** CH runs this now — since the one-hop cap is gone (see
  §9), every verified CH can latch/relay for further CHs, so widening any
  verified CH's footprint can lead somewhere.
- **Monitors**: `relayTable` row count (CHs this latch relays for; SNs are
  tracked separately via `sensorTable`)
- **Check interval**: `CH_PEER_DVS_CHECK_INTERVAL` = 110 TFs — slower than
  even the pre-relay tuning (80), since relay chains now do most of the
  connectivity-propagation work passively (see the comparison below); DVS
  is a backstop, not the primary mechanism
- **If no growth**: `txPower *= CH_PEER_DVS_SCALE_FACTOR` (1.07), capped at
  `MaxCHPeerPower` (1.5× baseline, vs. GWN's 2×), max
  `CH_PEER_DVS_MAX_SCALE_ATTEMPTS` = 2 attempts
- **Rollback**: when `relayTable` grows, `txPower` resets to
  `TxPower_CH` baseline and the attempt budget refreshes
- **Goal**: directly closes the topology gap noted in
  `RECRUITMENT_RACE_CONDITIONS.md` — "a center-of-topology CH ... out of
  direct/DVS-boosted GWN range from any GWN-anchored CH has no path into
  the network." Now the GWN-anchored CH itself also widens its footprint,
  not just the GWN, giving orphaned CHs an additional entry point that sits
  physically closer to them than the GWN often is.

**8b. CH Orphan-Rescue DVS** (`checkChOrphanDVS`, gated on
`t >= CH_ORPHAN_DVS_START_TIME` (600) `&& ~isVerified`)
- Last resort: a CH still unverified by t=600 has had the entire
  `SetupTime`→600 window for the passive FSM (`findBestVerifiedGWN`/
  `findBestVerifiedCH`, `CH_MAX_RETRIES`, `retryBackoff`) to find a
  candidate on its own — if it's still unverified, it is almost certainly
  starved of *visible* candidates rather than being actively rejected, so
  this CH widens its own footprint instead of only waiting on someone
  else's boost.
- **Check interval**: `CH_ORPHAN_DVS_CHECK_INTERVAL` = 40 TFs (more eager
  than peer-DVS — avoiding permanent orphaning outweighs the battery cost
  here)
- **Scale step**: `CH_ORPHAN_DVS_SCALE_FACTOR` = 1.15, capped at
  `MaxCHOrphanPower` (1.8× baseline), max
  `CH_ORPHAN_DVS_MAX_SCALE_ATTEMPTS` = 4 attempts
- Targets **either** a verified GWN or a verified CH — once one appears in
  `neighborTable` (because the *boosted* node's own HELLO now reaches this
  far, courtesy of `GWN_CH_DVS`/`CH_PEER_DVS` above, or because this CH's
  own widened HELLO is now heard and reciprocated), the existing SECURE-state
  FSM drives the CH_REQ / retries exactly as it would for any other
  candidate — DVS does not bypass or shortcut the handshake.
- **Rollback**: on verification (`handleCHACK`/`handleCHJOINOK`),
  `txPower` is unconditionally reset to `TxPower_CH` baseline.
- Deliberately **more conservative than the GWN's CH-discovery DVS** in
  both cadence and relative cap, because `WSN_ClusterHead.updatePhysics`
  has no charging circuit (unlike `WSN_Gateway.updatePhysics`'s
  always-on +1%/TF) — a CH's battery only ever drains, so its DVS budget is
  smaller and its ceiling lower in absolute and relative terms than the
  GWN's.

**Connectivity-propagation comparison vs. the prior system.** Before this
change, CH-side power scaling didn't exist at all (it had been moved
entirely to the GWN, see `GWN_Documentation.md` §3) and a CH's
discoverability was a fixed-radius, one-shot fact decided entirely by GWN
proximity. Three structural blind spots followed directly from that:
1. **CH-CH chains stalled before they could start.** A GWN-anchored relay
   CH had no reason to widen its own footprint, so a center-of-topology CH
   outside the GWN's direct *and* boosted range, but inside what would have
   been the relay CH's range, simply never got the chance — its only
   visibility into the network was the GWN, which may be physically much
   farther away than the nearest GWN-anchored CH. §8a removes this
   asymmetry: connectivity now propagates outward from *every* verified,
   recruiting-eligible node (GWN and CH alike), not just GWNs, so the
   "frontier" of discoverable territory grows from more points
   simultaneously and the GWN-ring's effective coverage radius compounds
   one extra hop further per recruiting CH rather than stopping dead at the
   GWN's own boosted edge.
2. **No fallback for nodes that simply never got line-of-sight.** Without
   any CH-side recourse, a CH stuck outside every boosted radius for the
   life of the run (a genuine occurrence per the topology notes above) was
   permanently orphaned — there was no mechanism to escalate. §8b adds a
   bounded, late-stage escalation specifically for that residual case,
   trading a small, capped amount of extra battery for a real chance at
   eventual connectivity instead of guaranteed permanent isolation.
3. **All scaling was push-only from one side.** Previously only the GWN
   pushed its discovery radius outward; an isolated CH had no symmetric
   ability to push back. Letting the still-unverified CH widen its own
   footprint too (§8b) means coverage now grows from *both* ends of a gap
   simultaneously once t > 600, which closes marginal gaps far faster than
   a single side's linear radius growth (`scaleFactor^attempts`) — the
   combined reach is closer to additive in the gap distance, not just
   incremental from one boosted source.

Net effect: the GWN-ring's connectivity propagates as a graph where every
*verified* node (not just GWNs) widens its own discovery frontier, with the
unverified CH itself joining in as a bounded last resort past t=600, at the
cost of a small, tightly-capped amount of extra CH battery drain — the
intended trade given CHs are the power-constrained tier and GWNs are not.

**Superseded by §9 below.** This DVS system widens *who can be discovered*.
It does not, by itself, change *how far a discovered chain can extend* --
that was still capped at one CH-CH hop until the relay-latch redesign in §9
removed the cap entirely. With that cap gone, a center-of-topology CH no
longer needs to be in DVS-boosted range of a GWN *or* a GWN-anchored CH
specifically -- it just needs to be in range of **any** verified CH, which
then transparently relays it to the GWN at whatever depth that takes. DVS
and relay now work together: DVS widens who's visible, relay extends how
far being visible to *any* verified CH actually gets you.

### 9. Transparent Relay / Latch (replaces the one-hop CH-CH cap)

The old model capped CH-CH chains at exactly one hop
(`isQualifiedToRecruit`, true only for GWN-anchored CHs): an orphan CH could
join through a relay CH, but that relay CH's child got no key, no
encryption, and could not itself recruit further. This is now replaced
entirely by **transparent multi-hop relay**, reusing the existing message
types/subtypes (see §3) instead of adding new ones.

**Core idea**: any verified CH that receives a `CH_REQ` (6.0) from a
neighbor always treats it as a relay request — "is not a message of its
own." It does not become that neighbor's parent. Instead it:
1. Records a `relayTable` row: `leafID -> nextHop` (the true requester
   identity, from `msg.originalSrc`, mapped to the immediate physical
   neighbor to forward toward).
2. Immediately sends `6.4 CH_JOINOK` back — hop-local only, "I'll latch for
   you," refreshing the requester's handshake-timeout lock.
3. Relays the *same* `6.0 CH_REQ` one hop further toward its own parent,
   `originalSrc` unchanged (mirrors `WSN_Gateway_Messaging.createRelayForward`,
   the existing pattern used for GWN-GWN backbone relay).
4. Sends a fresh `6.5 CH_INFO` one hop further too (topology visibility).

This repeats at every hop until the request reaches the GWN. The GWN runs
its **normal, unmodified 3-step verification** (`generateLocalKeyForCH` +
the new `generatePasskeyForCH`) keyed on `msg.originalSrc` — it never knows
or cares how many hops the request crossed. The resulting `6.1 CH_ACK`
(local key + 5-bit passkey) is wire-addressed back to the immediate sender
and reverse-latched hop-by-hop back down the same path
(`relayMessageIfNotMine`, keyed by `relayTable` lookup) until it reaches the
true leaf, which then completes its own verification exactly as a directly-
connected CH would.

**Why `originalSrc`, not `src`/`dst`:** the simulator's message delivery
(`Simulator/WSN_Main.m`) is physical-adjacency-based per tick — a message
addressed all the way to the GWN from a CH that isn't physically in the
GWN's range would simply be dropped. So `src`/`dst` are always rewritten to
the *immediate* physical hop at every relay step (so delivery succeeds),
while `WSN_Message.originalSrc` (already present for exactly this purpose)
carries the true, never-rewritten identity end-to-end. This is "transparent"
in the cryptographic/application sense the spec calls for (no insignia, no
re-encryption, no extra passkey wrapping at intermediate hops) while still
being physically deliverable hop-by-hop.

**Recruitment depth is now unbounded** — any verified CH can relay further
CHs, at any depth, limited only by radio range and the reliability
machinery below (not by an artificial hop cap).

**Multiple concurrent recruits, both directions:**
- A GWN already recruits multiple CHs (unbounded `chChildren` array, no
  change needed there — see `GWN_Documentation.md` §3).
- A latch CH can now also relay for multiple unverified CHs concurrently
  (`relayTable` is a table, not a single slot) — accepting a relay role no
  longer takes an exclusive radio lock the way recruiting used to.

**Direction is inferred, not stored separately**: `relayTable` only stores
one `nextHop` per leaf (the downstream neighbor toward that leaf).
`relayMessageIfNotMine` decides uplink vs. downlink per message by checking
whether the inbound hop's `msg.src` equals that recorded downstream
neighbor — if so, the message arrived from downstream and is forwarded
uplink to `obj.parent`; otherwise it arrived from upstream and is forwarded
back down to the recorded neighbor. This avoids needing two separate routes
per leaf while staying correct in both directions.

**Queuing & per-hop reliability** (`relayQueue`, `pendingRelayFragments`,
`processRelayQueue`):
- Control/recruitment/priority traffic (6.0/6.1/6.2/6.3/6.5, and Type 2
  PANIC, unaffected/unchanged) is **never queued** — sent immediately from
  its own handler, exactly as before.
- Only 5.2/5.3 data/fragment traffic queues. Each latch independently
  ACKs what it directly receives (hop-by-hop, not end-to-end) and
  separately retries what it forwards (`RELAY_FRAG_RETRY_INTERVAL`=3,
  `RELAY_FRAG_MAX_RETRIES`=3 — mirrors `AGG_RETRY_INTERVAL`/
  `AGG_MAX_RETRIES` but generalized into a table keyed by leaf+fragment, so
  one latch can have several leaves' fragments in flight at once).
- Fairness: `RELAY_LOCAL_TX_FAIRNESS`=4 guarantees this CH's own local
  sensor-aggregation traffic gets a turn at least once every 4 relay
  transmissions, so a busy latch is never permanently stuck only forwarding.

**Battery note**: relaying costs the latch CH real TX energy
(`BaseTxCost`/`IdleCost` per message, same as any other transmission) — this
is the explicit trade for unbounded depth. `RELAY_QUEUE_MAX`=20 bounds how
much a latch will buffer per hop before dropping oldest, and the per-hop
ACK/retry/fairness machinery above keeps that cost bounded and visible in
logs (`[RELAY_TX]`/`[RELAY_FRAG_DROPPED]`) rather than silently runaway.

**Known scope limit**: the GWN's Access radio still serializes one
handshake (direct or relayed) at a time — a deliberate simplification, not
a correctness bug. A latch can relay data for many already-verified leaves
concurrently; this only throttles brand-new joins reaching the GWN at the
exact same tick.

## Message Types Handled

| Type | Subtype | Direction | Purpose |
|------|---------|-----------|---------|
| 0 | - | RX | HELLO broadcast discovery |
| 1 | - | RX | SENSOR data from child SNs (aggregated) |
| 2 | 0-3 | RX/TX | PANIC messages (forwarded up-tree) |
| 5 | 2, 3 | RX | 5.2 SENSOR_AGG, 5.3 CH_ACK (if parent) |
| 6 | 0-5 | RX/TX | CH_CMD (REQ, ACK, JOINOK, REJECT, KEY_ACK, INFO -- 6.0/6.1/6.2/6.3/6.5 may be transparently relayed via `relayMessageIfNotMine`, see §9; 6.4 is always hop-local) |
| 7 | 0-7 | RX | CMD messages from GWN (FSM) |
| 11 | 0-3 | RX/TX | CENSUS protocol (poll, votes, completion) |
| 12 | 0-2 | RX | SHUTDOWN (soft/hard reset, blacklist) |

## State Transitions

```
BOOT (startup)
  ↓
DISCOVERY (wait for verified GWN)
  ↓ [Found GWN]
SECURE (no recruitment in progress)
  ├─ Try GWN/CH neighbor (CH_REQ may be relayed an arbitrary number of
  │  hops if the target is a CH, not a GWN -- see §9)
  └─ → HANDSHAKE (waiting for hop-local 6.4 JOINOK, then end-to-end 6.1 ACK)
       ↓ [6.4 JOINOK: hop-local only, refreshes lock, NOT verified yet]
       ↓ [6.1 CH_ACK arrives, possibly reverse-latched through several hops]
       ↓                              [6.3 REJECT received, hop-local or relayed]
    [KEY_ACK sent]                    [Clear lock, try next]
       ↓                                    ↓
    VERIFIED (localKey+passkey set,    SECURE (retry with backoff)
    can now relay further CHs at
    any depth -- no more one-hop cap)
```

## Attack Vectors

### Flooding (Hello Flood)
- Malicious CHs broadcast excessive ADV-CH messages
- Detection: Trust scoring on frequency anomalies
- Mitigation: Rate limiting, trust penalties

### Panic Flood (Sinkhole Variant)
- Malicious CHs inject fake emergency alerts
- Detection: Trust scoring + Census consensus
- Mitigation: Voting-based verdict, SN origin tracking

### Blackhole/Grayhole
- Malicious CH drops sensor aggregation (stops forwarding child data)
- Detection: Reporting-silence detector (no 5.2 for N×aggregation period)
- Mitigation: Census poll, hard reset, eventual blacklist

### Denial of Sleep
- Malicious CH floods targets with spurious packets
- Detection: Unusual packet frequency + trust decay
- Mitigation: Trust penalties, census escalation

### Sybil
- Malicious CH spoofs multiple identities
- Detection: ML-IDS feature extraction on identity patterns
- Mitigation: Cryptographic verification via Gateway keys

## Key Configuration Parameters (WSN_Config)
- `TIER_CH = 2`
- `STATE_BOOT = 0`, `STATE_DISCOVERY = 1`, `STATE_HANDSHAKE = 2`, `STATE_SECURE = 3`
- `CH_MAX_RETRIES = 5` (recruitment attempts per target)
- `CH_ACCESS_LOCK_TIMER = 16` TFs (handshake timeout -- widened from 4 to
  give multi-hop relay round trips enough budget; see §9)
- `CH_REJECTED_LIST_RESET_INTERVAL = 60` TFs (forgive old rejections --
  loosened from 40 since relay gives an orphaned CH more entry points)
- `CH_PASSKEY_MAX = 31` (5-bit per-child verification passkey range)
- `RELAY_QUEUE_MAX = 20`, `RELAY_FRAG_RETRY_INTERVAL = 3`,
  `RELAY_FRAG_MAX_RETRIES = 3`, `RELAY_LOCAL_TX_FAIRNESS = 4` (relay/latch
  queuing and per-hop reliability, see §9)
- `CH_PEER_DVS_ENABLED = true`, `CH_PEER_DVS_CHECK_INTERVAL = 110` TFs,
  `CH_PEER_DVS_SCALE_FACTOR = 1.07`, `CH_PEER_DVS_MAX_SCALE_ATTEMPTS = 2`,
  `MaxCHPeerPower = 3.0` (any verified CH widens footprint; slowed down now
  that relay does more of the connectivity-propagation work)
- `CH_ORPHAN_DVS_ENABLED = true`, `CH_ORPHAN_DVS_START_TIME = 600`,
  `CH_ORPHAN_DVS_CHECK_INTERVAL = 55`, `CH_ORPHAN_DVS_SCALE_FACTOR = 1.1`,
  `CH_ORPHAN_DVS_MAX_SCALE_ATTEMPTS = 3`, `MaxCHOrphanPower = 3.6`
  (last-resort unverified-CH widening past t=600)
- `AGG_PERIOD_MIN = 7`, `AGG_PERIOD_MAX = 10` TFs
- `MAX_SENSORS_PER_FRAGMENT = 10` sensors
- `AGG_RETRY_INTERVAL = 5` TFs
- `AGG_MAX_RETRIES = 3` (pending aggregation retries)
- `MSG_TYPE_SENSOR = 1`, `MSG_TYPE_PANIC = 2`, `MSG_TYPE_CH_HELLO = 5`, `MSG_TYPE_CH_CMD = 6`
- `SENSOR_SUB_AGG = 2`, `SENSOR_SUB_ACK = 3` (5.2, 5.3)
- `TRUST_INITIAL = 50.0`
- `TRUST_DELTA_FAIL_HARD = -30` (MAX_RETRIES failure)
- `TRUST_CENSUS_TRIGGER = 30.0`
- `CENSUS_POLL_TIMEOUT = 10` TFs
- `SILENCE_GRACE_MULTIPLIER = 3` (report-silence trigger = 3 × AGG_PERIOD)
- `RESET_ESCALATION_COUNT = 3` (soft/hard escalation to blacklist)

## Inheritance
- Extends: `WSN_Node` (base class)
- Properties: All properties of WSN_Node plus CH-specific ones
- Methods: Overrides `updatePhysics()`, `step()`, `receive()`

## Dependencies
- `WSN_Config`: Configuration constants
- `WSN_Message`: Message serialization/deserialization
- `WSN_Crypto`: Encryption (XOR with local key)
- `WSN_Attack`: Attack system integration
- `WSN_FeatureExport`: ML-IDS feature extraction (Phase 1-2)
