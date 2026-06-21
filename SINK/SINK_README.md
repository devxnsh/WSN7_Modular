# Sink / Base Station (SINK/Tier 4) — Self-Contained Module

## Overview
This folder contains all Sink/Base Station implementation and documentation. The Sink is the central collection point in the WSN hierarchy, responsible for data aggregation, enforcing consensus verdicts, maintaining node registries, and exporting ML-IDS features for anomaly detection.

## Files in This Folder

### Implementation
- **WSN_Sink.m** — Sink class implementation
  - Main class with properties and methods
  - Inherits from WSN_Node (base class in Utils/)
  - Implements step(), receive(), updatePhysics()
  - Coordinates with sub-modules for registries, enforcement, and features

### Sub-Modules (Separated Concerns)
- **Registry/WSN_Sink_Registry.m** — Node & sensor data tracking
  - Node registry (ID, tier, parent, battery, status)
  - Sensor registry (sensor ID, values, timeseries)
  - Route tracking (parent tree, hop counts)
  - Offline detection and recovery

- **Enforcement/WSN_Sink_Enforcement.m** — Consensus verdict execution
  - Implements verdicts from census voting
  - Tracks escalation levels
  - Manages exclusion lists
  - Coordinates with nodes for enforcement

- **FeatureExport/WSN_Sink_FeatureExport.m** — ML-IDS feature export
  - Extracts anomaly features from network behavior
  - Phases 1-5 feature computation
  - CSV export for ML training
  - Real-time feature stream

### Documentation
- **SINK_Documentation.md** — Exact functionality specification
  - Data collection and aggregation
  - Census verdict enforcement (Tier 4 follow-up)
  - Network diagnostics and route tracking
  - ML-IDS feature aggregation (Phase 1-2)
  - Node and sensor registries

- **SINK_Index.m** — Function index with line numbers
  - 30+ function references
  - Message handlers (Type 1, 2, 5, 11, 12)
  - Registry update logic
  - Enforcement escalation
  - Export functions

- **SINK_Shell.md** — Working notes and development guide
  - Status and implementation phase
  - Known issues with workarounds
  - Test scenarios for validation
  - Performance metrics and baselines

## Quick Start

### 1. View Sink Behavior
```matlab
% Read documentation first
open('SINK/SINK_Documentation.md')

% Review working notes and issues
open('SINK/SINK_Shell.md')

% Find specific function
grep('updateNodeRegistry', 'SINK/SINK_Index.m')
```

### 2. Create Sink
```matlab
sink = WSN_Sink(nodeID, position);
% Properties auto-initialized:
% - nodeRegistry: empty
% - sensorRegistry: empty
% - enforceVerdicts: {}
% - mlExporter: active
% - battery: infinite (mains powered)
```

### 3. Receive Node Data
```matlab
% In WSN_Main simulation loop:
msgs = sink.step(t, physAdj);  % Generate control messages
for rxMsg = receivedMessages
    response = sink.receive(rxMsg, t, rssi);  % Process RX
    % Sinks typically don't respond, but log everything
end
```

### 4. Review Issues & Test Scenarios
```matlab
% Read through SINK_Shell.md for:
% - Known issues (registry bloat, route computation)
% - Test scenarios (normal collection, verdict enforcement)
% - Performance baselines (mostly listen-only)
% - Feature export validation
```

## Module Dependencies

### Requires (from Utils/):
- `WSN_Node.m` — Base class (extends)
- `WSN_Config.m` — Configuration constants
- `WSN_Message.m` — Message class

### Sub-Modules (internal):
- `SINK/Registry/WSN_Sink_Registry.m` — Node/sensor tracking
- `SINK/Enforcement/WSN_Sink_Enforcement.m` — Verdict execution
- `SINK/FeatureExport/WSN_Sink_FeatureExport.m` — ML-IDS export

### Used by:
- `WSN_Main.m` — Main simulation loop (listens all timesteps)
- Network hierarchy (receives from all tiers via relays)
- ML-IDS pipeline (exports features to training)

## Folder Organization

```
SINK/
├── SINK_README.md                     ← This file
├── SINK_Documentation.md              ← Functionality spec
├── SINK_Index.m                       ← Function index
├── SINK_Shell.md                      ← Issues & tests
├── WSN_Sink.m                         ← Main implementation
│
├── Registry/                          ← Node & sensor registries
│   └── WSN_Sink_Registry.m
│
├── Enforcement/                       ← Verdict enforcement
│   └── WSN_Sink_Enforcement.m
│
└── FeatureExport/                     ← ML-IDS feature export
    └── WSN_Sink_FeatureExport.m
```

## Key Properties

### Registries
- `nodeRegistry` — All nodes (structure array)
  - Fields: id, tier, parent, battery, status, lastSeen
- `sensorRegistry` — All sensors (structure array)
  - Fields: id, nodeID, value, timeseries, lastUpdate

### Routes & Topology
- `parentTree` — Parent-child relationships
- `routeCache` — Hop counts from Sink to each node
- `offlineNodes` — Detected offline/dead nodes

### Enforcement
- `verdictStatus` — Active censuses and outcomes
- `exclusionList` — Nodes excluded by consensus
- `enforceLevel` — Escalation level (0-3)

### ML-IDS Features
- `featureBuffer` — Recent features (for real-time export)
- `trainingExport` — CSV export path
- `mlExporter` — Active feature extraction object

## Key Methods

### Main Loop
- `step(t, physAdj)` — Called every timestep
  - Returns: empty (sink mostly listen-only)
  - Exports features to CSV

- `receive(msg, t, rssi)` — Inbound message processing
  - Message types: 1 (sensor), 2 (panic), 5 (aggregation), 11 (census), 12 (status)
  - Updates registries, triggers enforcement, extracts features

- `updatePhysics(t)` — Mains-powered (no battery updates)

### Registry Management
- `updateNodeRegistry(nodeID, tier, parent)` — Add/update node
- `updateSensorRegistry(sensorID, nodeID, value)` — Add sensor reading
- `detectOfflineNodes(t)` — Identify unresponsive nodes
- `clearRegistry()` — Reset on simulation restart

### Verdict Enforcement
- `handleCensusVerdict(verdict, t)` — Execute consensus result
- `enforceMaliciousExclusion(nodeID)` — Remove from network
- `escalateToLevel(level, nodeID)` — Increase enforcement
- `commitEnforcement(t)` — Apply decisions

### ML-IDS Feature Export
- `exportFeatures(t)` — Write feature row to CSV
- `computeAnomalyScore(nodeID, t)` — Real-time scoring
- `appendToExportLog(features)` — Buffer for batch export

## Configuration (WSN_Config)

### Energy (Sink)
- Battery: Infinite (mains powered)
- No power management

### Registries
- `MAX_NODE_REGISTRY_SIZE` = 1000
- `REGISTRY_TIMEOUT` = 500 TF (node offline after this)
- `SENSOR_HISTORY_DEPTH` = 100 (timeseries points)

### Enforcement
- `ENFORCE_LEVEL_WARN` = 0 (alert only)
- `ENFORCE_LEVEL_ISOLATE` = 1 (remove from network)
- `ENFORCE_LEVEL_BLOCK` = 2 (exclude from rejoining)
- `ENFORCE_ESCALATION_RATE` = 0.1 (per timestep)

### ML-IDS Export
- `FEATURE_EXPORT_INTERVAL` = 10 TF (CSV row)
- `FEATURE_EXPORT_PATH` = 'logs/ml_features_*.csv'
- `EXPORT_FIELD_COUNT` = 25+ (features per row)

## Testing & Validation

### Manual Test (Sink Collection)
```matlab
% Create Sink
sink = WSN_Sink(0, [500, 500]);

% Simulate receiving sensor message
msg = WSN_Message.createSensorMessage(...
    101, 200, 42, t, 0.8);
response = sink.receive(msg, t, 0.9);

% Check registry update
fprintf('Registry has %d nodes\n', numel(sink.nodeRegistry));
fprintf('Sensor values: %s\n', mat2str(sink.sensorRegistry.values));
```

### Scenario Test (from SINK_Shell.md)
```matlab
% Run Scenario: Data Collection & Enforcement
% - t=100-200: Normal operation, collect sensor data
% - t=250: Consensus verdict arrives (node 150 = malicious)
% - t=260: Sink enforces exclusion, logs to CSV
% Results: Registry updated, enforcement complete, features exported
```

## Extension Points

### Adding New Registry Type
1. Add property to `WSN_Sink.m` (e.g., `linkRegistry`)
2. Create update method in `SINK/Registry/WSN_Sink_Registry.m`
3. Call from `receive()` when processing relevant message
4. Export from `SINK/FeatureExport/WSN_Sink_FeatureExport.m` if needed
5. Document in `SINK_Documentation.md`

### Adding New Feature Export
1. Compute feature in `SINK/FeatureExport/WSN_Sink_FeatureExport.m`
2. Add column to CSV header
3. Export value in `exportFeatures()` row
4. Document feature meaning in `SINK_Documentation.md`
5. Add to test scenario in `SINK_Shell.md`

### Modifying Enforcement Policy
1. Update escalation logic in `SINK/Enforcement/WSN_Sink_Enforcement.m`
2. Modify enforcement levels in `WSN_Config`
3. Test with scenarios in `SINK_Shell.md`
4. Document policy in `SINK_Documentation.md`

## Sub-Module Reference

### Registry (Node & Sensor Tracking)
**Purpose**: Maintain state of all network nodes and sensor readings
**Key Method**: `updateNodeRegistry(nodeID, tier, parent, battery, status)`
**Key Method**: `updateSensorRegistry(sensorID, nodeID, value)`
**Outputs**: CSV logs of registry state

### Enforcement (Verdict Execution)
**Purpose**: Execute consensus verdicts, manage node exclusion
**Key Method**: `handleCensusVerdict(verdict, t)`
**Key Method**: `enforceMaliciousExclusion(nodeID)`
**Outputs**: Enforcement logs, node status changes

### FeatureExport (ML-IDS Training)
**Purpose**: Extract anomaly features for ML model training
**Key Method**: `exportFeatures(t)`
**Key Method**: `computeAnomalyScore(nodeID, t)`
**Outputs**: ML training CSV files, feature timeseries

## Related Documentation
- [README_MODULARIZATION](../README_MODULARIZATION.md) — Project overview
- [SINK_Documentation.md](SINK_Documentation.md) — Detailed spec
- [SINK_Shell.md](SINK_Shell.md) — Known issues and test scenarios
- [Registry/WSN_Sink_Registry.m](Registry/) — Registry implementation
- [Enforcement/WSN_Sink_Enforcement.m](Enforcement/) — Enforcement implementation
- [FeatureExport/WSN_Sink_FeatureExport.m](FeatureExport/) — Export implementation
- [Utils/WSN_Node.m](../Utils/) — Base class
- [Simulator/SIMULATOR_README.md](../Simulator/) — How to run
