# Sensor Node (SN/Tier 1) — Self-Contained Module

## Overview
This folder contains all Sensor Node implementation and documentation. Sensor Nodes are the leaf nodes in the WSN hierarchy, responsible for sensing and reporting data while consuming minimal energy.

## Files in This Folder

### Implementation
- **WSN_Sensor.m** — Sensor Node class implementation
  - Main class with properties and methods
  - Inherits from WSN_Node (base class in Utils/)
  - Implements step(), receive(), updatePhysics()

### Documentation
- **SN_Documentation.md** — Exact functionality specification
  - Power management (sleep cycles, orphan mode)
  - Sensor data transmission
  - Panic detection and generation
  - Trust management (rule-based, Phase 4)
  - ML-IDS Census protocol
  - Attack vectors and mitigations

- **SN_Index.m** — Function index with line numbers
  - Maps all behaviors to WSN_Sensor.m
  - Property list with designations
  - Message handler mappings

- **SN_Shell.md** — Working notes and development guide
  - Status and implementation phase
  - Known issues with workarounds
  - Test scenarios for validation
  - Performance metrics and baselines
  - Decision matrices and thresholds

### Logic & Protocol Separation
- **SN_Behavior.m** — High-level decision logic (pure functions, testable)
  - Sleep/wake cycle computation
  - Sensor target selection
  - Anomaly detection
  - Trust scoring and updates
  - Census verdict computation
  - Orphan mode management

- **SN_Messaging.m** — Low-level protocol (message serialization)
  - Message creation functions (Type 0, 1, 2, 11, 12)
  - Payload parsing and extraction
  - Message filtering and validation

## Quick Start

### 1. View Node Behavior
```matlab
% Read documentation first
open('SN/SN_Documentation.md')

% Review working notes and issues
open('SN/SN_Shell.md')

% Find specific function
grep('createSensorMessage', 'SN/SN_Index.m')
```

### 2. Create Sensor Node
```matlab
node = WSN_Sensor(nodeID, position);
% Properties auto-initialized:
% - sensorPeriod: 3-7 TF (random)
% - nextSensorTX: computed
% - battery: 100%
% - radioState: 'RX'
% - neighborTable: empty
```

### 3. Run Single Timestep
```matlab
msgs = node.step(t, physAdj);  % Generate messages for TX
for rxMsg = receivedMessages
    response = node.receive(rxMsg, t, rssi);  % Process RX
    if ~isempty(response)
        % Handle response
    end
end
```

### 4. Review Issues & Test Scenarios
```matlab
% Read through SN_Shell.md for:
% - Known issues (orphan oscillation, trust decay)
% - Test scenarios (normal, flooding, census voting)
% - Performance baselines
% - Performance notes (CPU, memory, network)
```

## Module Dependencies

### Requires (from Utils/):
- `WSN_Node.m` — Base class (extends)
- `WSN_Config.m` — Configuration constants
- `WSN_Message.m` — Message class
- `WSN_Crypto.m` — Encryption (placeholder)
- `WSN_Attack.m` — Attack system integration
- `WSN_FeatureExport.m` — ML-IDS feature extraction

### Used by:
- `WSN_Main.m` — Main simulation loop
- Network topology (parent: CH or GWN)
- `WSN_Attack.m` — Attack injection (flooding, panic flood)

## Key Properties

### State
- `sensorPeriod` — TX period (3-7 TF, fixed per node)
- `nextSensorTX` — Next TX time
- `sensorValue` — Current reading (0-100)
- `isOrphaned` — Orphan mode flag
- `radioState` — 'RX'/'TX'/'SLEEP'

### Neighbor Management
- `neighborTable` — Discovered CH/GWN nodes
- `parent` — Selected CH/GWN target

### Trust & Consensus
- `neighborTrust` — Per-neighbor trust scores (0-100)
- `censusActivePolls` — Active voting polls
- `censusSeenPolls` — Dedup list (max 50 UIDs)

### Panic Handling
- `lastPanicTime` — Cooldown tracking
- `seenPanicUIDs` — Dedup list (max 50 UIDs)

## Key Methods

### Main Loop
- `step(t, physAdj)` — Called every timestep
  - Returns: array of messages to TX
  - Handles: sensor TX, panic detection, census

- `receive(msg, t, rssi)` — Inbound message processing
  - Returns: response message or empty
  - Handles: HELLO, PANIC, CENSUS, SHUTDOWN

- `updatePhysics(t)` — Battery & wake-sleep management
  - Updates: battery level, isAwake flag

### Sensor & Data
- `findBestSensorTarget()` — Closest verified CH/GWN
- `createSensorMessage(t, target, priority)` — Type 1 MSG
- `createPanicMessage(t, target, type, severity, value)` — Type 2 MSG

### Trust & Consensus
- `getNeighborTrust(neighborID)` — Query trust score
- `updateNeighborTrust(neighborID, delta)` — Update trust
- `checkCensusTriggers(t)` — Initiate/finalize polls
- `handleCensusMessage(msg, t)` — Process voting

## Configuration (WSN_Config)

### Energy
- `IdleCost` = 0.5 (awake, RX mode)
- `SleepCost` = 0.05 (sleeping)
- `BaseTxCost` = 1.0 (message TX)

### Sensor
- `SENSOR_PERIOD_MIN` = 3, `SENSOR_PERIOD_MAX` = 7
- `SENSOR_JITTER_MIN` = 0, `SENSOR_JITTER_MAX` = 3
- `SENSOR_START_TIME` = 100 (first TX)

### Sleep Cycles
- `SENSOR_NORMAL_WAKE_WINDOW` = 3 TF (per 20-TF cycle, 15% duty)
- `SENSOR_ORPHAN_WAKE_WINDOW` = 2 TF (per 35-TF cycle, ~6% duty, 75% longer)

### Trust & Consensus
- `TRUST_INITIAL` = 50.0
- `TRUST_CENSUS_TRIGGER` = 30.0 (suspect threshold)
- `CENSUS_POLL_TIMEOUT` = 10 TF
- `CENSUS_QUORUM_YES_RATIO` = 0.5 (≥50% YES = malicious)

## Testing & Validation

### Manual Test (Single Node)
```matlab
% Create standalone SN
sn = WSN_Sensor(101, [500, 500]);
sn.neighborTable(1) = struct('id', 200, 'tier', 2, 'isVerified', true, 'rssi', 0.8);

% Step & receive
msgs = sn.step(100, eye(10));  % physAdj is identity (in range)
fprintf('Generated %d messages\n', numel(msgs));
```

### Scenario Test (from SN_Shell.md)
```matlab
% Run Scenario 1: Normal Operation
% - t=100: SNs wake, send HELLO
% - t=102: SN receives CH HELLO, populates neighbor table
% - t=105: SN sensor period triggers, sends Type 1
% Results: Steady uplink traffic, trust remains neutral
```

## Extension Points

### Adding New Behavior
1. Add function to `SN_Behavior.m` (pure logic)
2. Call from `step()` at appropriate point
3. Document in `SN_Documentation.md`
4. Add test scenario to `SN_Shell.md`

### Adding New Message Type
1. Create handler in `SN_Messaging.m`
2. Add case to `receive()` dispatcher
3. Update `SN_Index.m` with new line number
4. Document message format in `SN_Documentation.md`

### Custom Attack Response
1. Add check in `step()` or `receive()`
2. Implement response logic in `SN_Behavior.m`
3. Create test scenario in `SN_Shell.md`

## Folder Organization

```
SN/
├── SN_README.md                       ← This file
├── SN_Documentation.md                ← Functionality spec
├── SN_Index.m                         ← Function index
├── SN_Shell.md                        ← Issues & tests
├── SN_Behavior.m                      ← Pure logic
├── SN_Messaging.m                     ← Protocol
└── WSN_Sensor.m                       ← Implementation
```

## Related Documentation
- [README_MODULARIZATION](../README_MODULARIZATION.md) — Project overview
- [SN_Documentation.md](SN_Documentation.md) — Detailed spec
- [SN_Shell.md](SN_Shell.md) — Known issues and test scenarios
- [Utils/WSN_Node.m](../Utils/) — Base class
- [Simulator/SIMULATOR_README.md](../Simulator/) — How to run
