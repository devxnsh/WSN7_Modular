# Sink / Base Station (Tier 4) Documentation

## Overview
The Sink is the network root that:
- Collects aggregated sensor data from all GWNs
- Maintains global node registry (position, tier, battery, children)
- Maintains sensor registry (historical data per SN)
- Executes ML-IDS census verdicts (enforcement decisions)
- Aggregates network-wide statistics for analysis

## Core Responsibilities

### 1. Data Collection & Aggregation
- **Node Registry**: Tracks all nodes (ID, tier, parent, children, local key, battery)
- **Sensor Registry**: Historical timeseries per sensor (value, timestamp, parent CH)
- **Route Tracking**: Upstream path from each node to Sink
- **Battery Monitoring**: Detect critical/dying nodes for proactive replacement

### 2. Census Verdict Enforcement (Tier 4 Follow-up)
- **Receives**: CENSUS_POLL_COMPLETE messages from parent GWNs
- **Enforcement**: If no ancestor successfully enforced, Sink issues final SHUTDOWN
- **Escalation**: Tracks reset history per node (SOFT → HARD → BLACKLIST)
- **Blacklist**: Permanently quarantine confirmed malicious nodes

### 3. Network Diagnostics
- **Link Quality**: Track success rates per neighbor pair
- **Topology Changes**: Detect parent switches, recruitment events
- **Offline Nodes**: Alert when node silent for N periods
- **Energy Forecast**: Predict battery depletion based on consumption trends

### 4. ML-IDS Feature Aggregation (Phase 1-2)
- **Receives**: WSN_SinkFeatureExport data from all nodes
- **Correlates**: Time-align features across network for training
- **Exports**: Unified CSV for offline ML model training

## Message Types Handled

| Type | Subtype | Direction | Purpose |
|------|---------|-----------|---------|
| 1 | - | RX | SENSOR data (terminal collection point) |
| 2 | 0-3 | RX | PANIC messages (terminal collection) |
| 5 | 2 | RX | 5.2 SENSOR_AGG from GWN children (final hop) |
| 11 | 3 | RX | CENSUS_POLL_COMPLETE (verdicts from GWNs) |
| 12 | 0-2 | TX | SHUTDOWN (final enforcement) |

## Data Structures

### Node Registry Entry
```
struct NodeRegistry {
  hexID: string              % e.g., "1A2B"
  parent: string             % parent's hexID
  route: string              % path to Sink (e.g., "1A2B->3C4D->SINK")
  localKey: bytes            % encryption key if GWN-anchored
  tierName: string           % "SENSOR", "CH", "GWN"
  lastUpdate: uint32         % last time heard from
  chCount: uint32            % children count
  snCount: uint32            % direct SN children
  gwChildren: array          % GWN child IDs (if GWN parent)
  chChildren: array          % CH child IDs (if parent is GWN)
  secondaryChildren: array   % learned via relay (if GWN)
  battery: double            % last known %
}
```

### Sensor Registry Entry
```
struct SensorRegistry {
  id: uint32                 % global sensor ID
  hexID: string              % hex representation
  parentCH: string           % direct parent CH
  timeseries: array          % {value, time} entries
  lastValue: double          % most recent sensor reading
  lastTimestamp: uint32      % most recent reading time
}
```

## Key Configuration Parameters (WSN_Config)
- `TIER_SINK = 4` (designation)
- `SILENCE_GRACE_MULTIPLIER = 3` (offline detection threshold)
- `RESET_ESCALATION_COUNT = 3` (soft/hard/blacklist steps)
- `BATTERY_CRITICAL = 10%` (warning threshold)
- `BATTERY_DEAD = 5%` (replacement alert threshold)

## No Inheritance
- Sink is standalone (doesn't inherit from WSN_Node)
- Acts as root of tree (no parent, all others point toward it)
- Special case in WSN_Main: handled separately from regular nodes

## Integration Points
- **Input**: All GWN RX (aggregation, census, diagnostics)
- **Output**: Sink-to-all TX (SHUTDOWN enforcement, heartbeat ACKs)
- **Logging**: Network-wide statistics CSV export
- **Feature Export**: ML-IDS unified training data

## Expected Role in Simulation
1. Initialization: Create as root of topology tree
2. Per-timestep: Receive aggregated data from GWNs
3. Verdict Execution: Process census verdicts, issue SHUTDOWN if needed
4. Data Export: Periodic CSV export of node registry, sensor data, feature vectors
5. Diagnostics: Maintain uptime/availability statistics
