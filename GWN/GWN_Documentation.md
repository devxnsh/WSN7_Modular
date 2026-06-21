# Gateway (GWN) — Tier 3 Documentation

## Overview
Gateways (Tier 3) are high-tier backbone nodes that:
- Bridge network segments via dual-radio LoRa backbone and HC12 access network
- Recruit Cluster Heads and maintain network topology
- Aggregate child sensor data and forward to Sink
- Participate in backbone FSM (Finite State Machine) for parent coordination
- Support mesh routing via Token-based collision avoidance
- Implement reporting-silence detection for Blackhole/Grayhole attacks

## Core Responsibilities

### 1. Dual-Radio Architecture
- **Backbone Radio (LoRa)**: GWN-to-GWN communication, stable links, no fading
- **Access Radio (HC12)**: CH/SN discovery and handshake, subject to Rayleigh fading
- **Separate Locks**: Each radio can be locked independently during handshakes
- **Routing Decision**: Message type determines which radio is used

### 2. GWN-GWN Backbone Protocol (FSM)
- **States**: BOOT → DISCOVERY → HANDSHAKE → SECURE → VERIFIED
- **Parent Selection**: Token-based collision avoidance prevents routing loops
- **Parent Confirmation**: Heartbeat (Type 9) exchange with parent and children
- **Token Passing**: CMD messages (Type 7) coordinate token flow up-tree

### 3. CH/SN Recruitment & Access Radio
- **CH Recruitment**: Accept CH_REQ, send local key + 5-bit passkey, track
  CH children. `chChildren` is an unbounded array, not a single slot — a GWN
  recruits **every** CH whose (possibly relayed) CH_REQ it accepts, so
  multiple CHs can pair with the same GWN if multiple appropriate pairing
  requests arrive (unlike the GWN-GWN backbone, which is capped at one
  child, see `WSN_Gateway_Behavior.m:547-550`).
- **Transparent relay, unbounded depth**: a GWN's handshake handlers
  (`handle_CH_REQ`/`handle_CH_KEY_ACK` in `WSN_Gateway_Messaging.m`) key
  every operation on `msg.originalSrc` (the TRUE requesting CH's identity),
  not `msg.src` (just the immediate physical neighbor that delivered this
  hop, which may be a relaying latch several hops out). The GWN runs the
  exact same 3-step verification regardless of depth and is oblivious to
  the relay — see `CH_Documentation.md` §9 for the full relay-latch design
  (this replaces the old one-hop CH-CH cap entirely).
- **CH_INFO Relay**: hop-by-hop topology-visibility side-channel
  (unencrypted by design — see `CH_Documentation.md` §3/§9) forwarded to
  Sink; tracks the real relay path even though the handshake/data path
  itself is transparent
- **Pending CH List**: Track CHs awaiting ENC_HELLO confirmation
- **Pending CH_HELLO Buffer**: Queue CH_HELLO relays if parent unavailable
- **CH Discovery DVS**: Once this GWN is itself verified (`isVerified`),
  boost HC12 `controlPower` if no new CH recruits detected, so it appears
  in range of unverified CHs ("passive" — the GWN never initiates the
  pairing itself; see `checkChDiscoveryDVS` in `WSN_Gateway.m` and the
  matching, more-conservative CH-side mechanisms in `CH_Documentation.md`
  §8, which extend this same widen-the-footprint strategy one hop further
  via GWN-anchored CHs, plus a last-resort unverified-CH-side boost past
  t=600)

### 4. Sensor Data Aggregation (Type 5)
- **Receives**: 5.2 SENSOR_AGG from CH children (encrypted with local key)
- **Merges**: Combines child aggregations into GWN-level sensorTable
- **Sends ACK**: 5.3 CH_ACK to acknowledge receipt
- **Forwards**: Aggregates further up-tree to parent GWN or Sink
- **Encryption**: Uses own localKey when forwarding to parent

### 5. Panic Message Handling (Type 2)
- **Priority Path**: Separate high-priority queue for panic messages
- **Forwarding**: Forward to parent (unicast) or broadcast if orphan
- **Deduplication**: Track seen panic UIDs (circular buffer, max 200)

### 6. Trust Management & Census (Phase 4)
- **Neighbor Trust**: Per-neighbor scores (0-100, initial 50)
- **Hard Fail on Recruitment**: MAX_RETRIES → -30 trust penalty
- **Reporting-Silence**: Detect CHs not sending aggregations (3×AGG_PERIOD)
- **Census Initiation**: For neighbors with trust < 30
- **Enforcement**: Issue SHUTDOWN (SOFT → HARD → BLACKLIST) to direct children

### 7. Backbone Heartbeat (Type 9)
- **Discovery Heartbeat**: Broadcast to announce GWN presence
- **Encrypted Heartbeat**: Unicast to parent (ENC_HB, subtype 3)
- **Child Heartbeat**: Multicast (FF00) to verified CH children
- **Function**: Keeps parent->child link alive, triggers re-parent on loss

## Message Types Handled

| Type | Subtype | Direction | Purpose |
|------|---------|-----------|---------|
| 0 | - | RX | HELLO from CH/SN (access radio) |
| 2 | 0-3 | RX/TX | PANIC (high priority, forwarded) |
| 5 | 2, 3 | RX | 5.2 SENSOR_AGG, 5.3 CH_ACK |
| 6 | 0-5 | RX | CH_CMD (recruitment handshake) |
| 7 | 0-7 | RX/TX | CMD messages (FSM, token passing) |
| 8 | 0-2 | RX/TX | TOKEN frames (backbone collision avoidance) |
| 9 | 0, 3 | RX/TX | HEARTBEAT (discovery, encrypted) |
| 11 | 0-3 | RX/TX | CENSUS protocol (voting, enforcement) |
| 12 | 0-2 | RX/TX | SHUTDOWN (escalated enforcement) |

## State Machine (Backbone FSM)

```
BOOT (startup)
  ↓ [Discovery timeout]
DISCOVERY (wait for verified parent GWN)
  ├─ HELLO: collect neighbor table
  ├─ HB: check if verified
  └─ Find parent → HANDSHAKE
       ↓
   HANDSHAKE (await FSM response from parent)
     ├─ PARENT_INIT received → send REQ_JOIN
     └─ ACK_JOIN → transition to SECURE
       ↓
   SECURE (no handshake in progress)
     └─ Monitor heartbeats
       ↓
   VERIFIED (parent confirmed)
     ├─ Forward sensor data
     ├─ Receive child heartbeats
     └─ Monitor parent loss (timeout → re-parent)
```

## CH Topology Management
- **Pending CH List**: CHs waiting for ENC_HELLO (timeout 15 TF)
- **Direct CH Children**: CHs that completed CH_JOINOK/KEY_ACK
- **Secondary CH Children**: CHs learned about via CH_INFO from parent
- **Announced to Parent**: Track which CH set was last announced (re-announce on change)

## Attack Vectors

### Flooding (Hello Flood)
- Malicious GWNs broadcast excessive HELLO messages
- Detection: Rate limiting, unusual frequency
- Mitigation: Trust decay, census escalation

### Blackhole (Aggregation Drop)
- Malicious GWN accepts CH children but drops their 5.2 aggregations
- Detection: Reporting-silence detector (no agg for 3×period)
- Mitigation: Census poll on silent child, hard reset, blacklist

### Wormhole
- Malicious GWN relays messages out-of-band to distant node
- Detection: ML-IDS topology analysis
- Mitigation: Key exchange prevents spoofing

### Sybil
- Malicious node spoofs multiple GWN identities
- Detection: ML-IDS feature extraction on routing behavior
- Mitigation: Cryptographic verification via backbone heartbeat

## Key Configuration Parameters (WSN_Config)
- `TIER_GWN = 3`
- `TxPower_GWN_Control = 6.0` (access radio, HC12)
- `GWN_CH_DVS_ENABLED = true`, `GWN_CH_DVS_CHECK_INTERVAL = 50` TFs,
  `GWN_CH_DVS_SCALE_FACTOR = 1.2`, `GWN_CH_DVS_MAX_SCALE_ATTEMPTS = 5`,
  `MaxGWNPower = 12.0` (gated on this GWN's own `isVerified`; see CH-side
  counterparts `CH_PEER_DVS_*` / `CH_ORPHAN_DVS_*` in `CH_Documentation.md`
  §8, which are intentionally more conservative since CHs are
  battery-limited and GWNs are not)
- `CH_ACCESS_LOCK_TIMER = 20` TFs
- `PENDING_CHILD_TIMEOUT = 15` TFs
- `PENDING_CH_HELLO_MAX = 30` messages
- `AGG_PERIOD_MIN = 7`, `AGG_PERIOD_MAX = 10` TFs
- `AGG_RETRY_INTERVAL = 5` TFs, `AGG_MAX_RETRIES = 3`
- `SILENCE_GRACE_MULTIPLIER = 3` (agg silence detection)
- `GWN_MAX_RETRIES = 3` (backbone recruitment)
- `MSG_TYPE_SENSOR = 1`, `MSG_TYPE_PANIC = 2`, `MSG_TYPE_CH_HELLO = 5`
- `MSG_TYPE_CH_CMD = 6`, `MSG_TYPE_CMD = 7`, `MSG_TYPE_TOKEN = 8`
- `MSG_TYPE_HB = 9`, `MSG_TYPE_CENSUS = 11`, `MSG_TYPE_SHUTDOWN = 12`

## Inheritance
- Extends: `WSN_Node` (base class)
- Properties: All properties of WSN_Node plus GWN-specific ones
- Methods: Overrides `updatePhysics()`, `step()`, `receive()`
- Delegates: `WSN_Gateway_Behavior`, `WSN_Gateway_Messaging`

## Dependencies
- `WSN_Config`: Configuration constants
- `WSN_Message`: Message serialization/deserialization
- `WSN_Crypto`: Encryption (XOR with local key, AES stub)
- `WSN_Attack`: Attack system integration (Wormhole, Sybil)
- `WSN_FeatureExport`: ML-IDS feature extraction (Phase 1-2)
- `WSN_Radio`: Backbone radio (LoRa FSM)
- `WSN_RadioStack`: Access radio (HC12)
