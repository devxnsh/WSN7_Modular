# Sensor Node (SN) — Tier 1 Documentation

## Overview
Sensor Nodes (Tier 1) are the leaf nodes in the WSN hierarchy. They are low-power devices that:
- Sleep 75-80% of the time to conserve battery
- Wake periodically to sense environment and transmit data to Cluster Heads (CHs) or Gateways (GWNs)
- Detect local anomalies and generate panic messages
- Participate in ML-IDS Census protocol for distributed trust-based malicious node detection
- Support emergency broadcasts when network connectivity is lost (orphan mode)

## Core Responsibilities

### 1. Power Management
- **Sleep Cycles**: 20-35 TFs (normal) or 35+ TFs (orphan mode, 75% longer)
- **Idle Cost**: 0.5 units/TF when awake
- **Sleep Cost**: 0.05 units/TF when sleeping
- **TX Cost**: Proportional to message type and power level

### 2. Data Acquisition & Transmission
- **Sensor Period**: Fixed random 3-7 TFs (set at initialization)
- **Sensor Values**: Random 0-100, with gradual drift (±5) and rare spikes (0.5% chance)
- **Priority Levels**: 0 (default), 1 (≥20% change), 2 (≥45% change)
- **Jitter**: 0-3 TFs added to scheduled TX time

### 3. Target Selection
- Finds best verified CH or GWN based on RSSI
- Prefers GWN if significantly closer than CH (distance factor: 0.8)
- Falls back to broadcast if no verified targets available

### 4. Panic Detection & Generation
- **Anomaly Detection**: Triggers on ≥50% sensor value change
- **Battery Critical**: Triggers on ≤10% battery remaining
- **Deduplication**: Tracks seen panic UIDs (keep last 50)
- **Forwarding**: Routes to parent (unicast) or broadcasts if no parent
- **TTL Management**: High severity (≥2) = TTL 5; low/medium = TTL 1

### 5. Trust Management (Rule-Based, ML_IDS Phase 4)
- **Initial Trust**: 50.0 (neutral)
- **Trust Range**: 0.0 - 100.0
- **Trust Factors**: Message delivery success, response time, anomalous behavior
- **Census Trigger**: When neighbor trust < 30.0, initiate polling

### 6. ML-IDS Census Protocol (Phase 4)
- **Poll Initiation**: Broadcast CENSUS_POLL_INITIATE to network
- **Voting**: Respond YES if suspect trust < 30, NO otherwise
- **Poll Timeout**: 10 TFs to collect votes
- **Verdict**: Quorum ≥50% YES = malicious; otherwise = cleared
- **Actions**: 
  - Verdicts propagate up-tree to Sink for enforcement
  - Soft/Hard resets escalate on repeated violations
  - Final blacklist (permanent silence) after 3 escalations

### 7. Orphan Mode (Extended Sleep)
- **Entry Condition**: No verified CH/GWN found for 5 consecutive TX periods
- **Behavior**: 
  - 75% longer sleep cycles (extended rest)
  - Broadcast link-loss panic
  - Re-enter normal mode when CH/GWN rediscovered
- **Exit Condition**: Successfully deliver sensor data to verified target

## Message Types Handled

| Type | Subtype | Direction | Purpose |
|------|---------|-----------|---------|
| 0 | - | RX | HELLO broadcast discovery |
| 2 | 0-3 | RX/TX | PANIC messages (anomaly, battery, intrusion, link-loss) |
| 11 | 0-3 | RX/TX | CENSUS protocol (poll, votes, completion) |
| 12 | 0-2 | RX | SHUTDOWN (soft/hard reset, blacklist) |

## State Transitions

```
Initial
  ↓
Receive HELLO (populate neighbor table)
  ↓
Find verified target (CH or GWN)
  ↓ [Found]              ↓ [Not Found]
Transmit Sensor Data    Orphan Mode (extended sleep)
  ↓                       ↓ [Re-discovered]
Normal Operation         ↓ [Lost for 5+ periods]
  ↓                      (broadcast link-loss panic)
[Repeat]                [Return to Normal]
```

## Attack Vectors

### Flooding (Hello Flood)
- Malicious SNs broadcast excessive HELLO messages
- Detection: Unusual message frequency or TX power
- Mitigation: Rate limiting, trust decay

### Panic Flood (Sinkhole Variant)
- Malicious SNs send fake emergency alerts
- Detection: Trust scoring + Census consensus
- Mitigation: Voting-based verdict system

### Blackhole/Grayhole
- Malicious node drops inbound messages
- Detection: Trust scoring on response/delivery failures
- Mitigation: Neighbor trust penalties, census escalation

### Sybil
- Malicious node spoofs multiple identities
- Detection: ML-IDS feature extraction tracks identity patterns
- Mitigation: Cryptographic verification via Gateway keys

## Key Configuration Parameters (WSN_Config)
- `TIER_SENSOR = 1`
- `SENSOR_PERIOD_MIN = 3`, `SENSOR_PERIOD_MAX = 7`
- `SENSOR_START_TIME = 100` (TF)
- `SENSOR_JITTER_MIN = 0`, `SENSOR_JITTER_MAX = 3`
- `SENSOR_NORMAL_WAKE_WINDOW = 3` TFs per 20-TF cycle
- `SENSOR_ORPHAN_WAKE_WINDOW = 2` TFs per extended cycle
- `SENSOR_ORPHAN_SLEEP_FACTOR = 0.75` (75% longer cycles)
- `PANIC_ANOMALY_THRESHOLD = 50%` (pct change)
- `PANIC_BATTERY_CRIT_LEVEL = 10%` (pct)
- `PANIC_COOLDOWN = 500` TFs (min between panics)
- `PANIC_DEFAULT_TTL = 5` (for high severity)
- `TRUST_INITIAL = 50.0`
- `TRUST_MIN = 0.0`, `TRUST_MAX = 100.0`
- `TRUST_CENSUS_TRIGGER = 30.0` (distrust threshold)
- `CENSUS_POLL_TIMEOUT = 10` TFs
- `CENSUS_MIN_VOTERS = 3`
- `CENSUS_QUORUM_YES_RATIO = 0.5`

## Inheritance
- Extends: `WSN_Node` (base class)
- Properties: All properties of WSN_Node plus SN-specific ones
- Methods: Overrides `updatePhysics()`, `step()`, `receive()`

## Dependencies
- `WSN_Config`: Configuration constants
- `WSN_Message`: Message serialization/deserialization
- `WSN_Crypto`: Encryption (placeholder)
- `WSN_Attack`: Attack system integration
- `WSN_FeatureExport`: ML-IDS feature extraction (Phase 1-2)
