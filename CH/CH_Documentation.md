# Cluster Head (CH) — Tier 2 Documentation

## Overview
Cluster Heads (Tier 2) are mid-tier aggregation nodes that:
- Aggregate sensor data from child Sensor Nodes (SNs) into prioritized reports
- Recruit and maintain connectivity to parent Gateway (GWN) or another CH
- Forward aggregated sensor data and panic messages up-tree
- Participate in ML-IDS Census protocol for trust-based threat detection
- Support hierarchical network topology (one-hop CH-CH chains only)

## Core Responsibilities

### 1. Network Topology & Recruitment
- **States**: BOOT → DISCOVERY → SECURE → HANDSHAKE
- **Parent Options**: Verify GWN first, then CH (single CH-CH hop max)
- **Retries**: Max 3 attempts per target, random backoff 2-5 TFs after MAX_RETRIES
- **Verified Status**: Requires KEY_ACK exchange with GWN (local key received)
- **Qualification**: GWN-anchored CHs can recruit other CHs; CH-anchored CHs cannot

### 2. Sensor Data Aggregation (Type 5.2 / 5.3)
- **Aggregation Period**: Fixed random 7-10 TFs (set after verification)
- **Fragment Size**: Max sensors per fragment (e.g., 10 sensors/fragment)
- **Payload Format**: [TotalFrags(1), FragIdx(1), NumSensors(1), {SensorData} x N]
- **Sensor Entry**: [ID(2), Time(2), Value(2), RSSI(1), Battery(1)] = 8 bytes each
- **Encryption**: Local key XOR if parent is GWN, no encryption if parent is CH
- **Retry Logic**: Resend pending fragments every 5 TFs, max 3 retries

### 3. Handshake Protocol (Type 6: CH_CMD)
- **6.0 CH_REQ** (CH→GWN/CH): Request to join parent
- **6.1 CH_ACK** (GWN→CH): Accept with local key in payload
- **6.2 KEY_ACK** (CH→GWN): Confirm key reception (encrypted)
- **6.3 CH_REJECT** (GWN/CH→CH): Reject, triggering parent purge
- **6.4 CH_JOINOK** (CH→CH): Accept CH-CH join (no key exchange)
- **6.5 CH_INFO** (CH→GWN): Announce recruited CH child to parent

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

### 8. CH-Discovery Dynamic Voltage Scaling (DVS)
- **Monitors**: chChildren count
- **Check Interval**: Every DVS_CHECK_INTERVAL TFs
- **If No Growth**: Incrementally boost controlPower (HC12 access radio)
- **Goal**: Extend HELLO/CH_ACK range to attract more recruits
- **Rollback**: When chChildren grows, reduce power back to normal

## Message Types Handled

| Type | Subtype | Direction | Purpose |
|------|---------|-----------|---------|
| 0 | - | RX | HELLO broadcast discovery |
| 1 | - | RX | SENSOR data from child SNs (aggregated) |
| 2 | 0-3 | RX/TX | PANIC messages (forwarded up-tree) |
| 5 | 2, 3 | RX | 5.2 SENSOR_AGG, 5.3 CH_ACK (if parent) |
| 6 | 0-5 | RX/TX | CH_CMD (REQ, ACK, JOINOK, REJECT, KEY_ACK, INFO) |
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
  ├─ Try GWN → [Accepted] → VERIFIED (GWN-anchored, can recruit CHs)
  ├─ Try CH  → [Accepted] → VERIFIED (CH-anchored, cannot recruit)
  └─ Try next → HANDSHAKE (waiting for ACK/REJECT)
       ↓ [ACK received] [REJECT received]
   [Refresh lock]         [Clear lock, try next]
       ↓                        ↓
    [KEY_ACK]               SECURE (retry with backoff)
       ↓
    VERIFIED ←──────────────┘
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
- `STATE_BOOT = 0`, `STATE_DISCOVERY = 1`, `STATE_SECURE = 2`, `STATE_HANDSHAKE = 3`
- `CH_MAX_RETRIES = 3` (recruitment attempts per target)
- `CH_ACCESS_LOCK_TIMER = 20` TFs (handshake timeout)
- `CH_REJECTED_LIST_RESET_INTERVAL = 100` TFs (forgive old rejections)
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
