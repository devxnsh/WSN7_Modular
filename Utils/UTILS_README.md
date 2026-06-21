# Utilities Module — Common Functions & Infrastructure

## Purpose
Contains shared infrastructure, configuration, and utilities used across all tiers and components.

## Files in This Folder

### Core Infrastructure
- **WSN_Config.m** — Global configuration constants
  - Network parameters (field size, node count, tier definitions)
  - Message type constants (Type 0-12, subtypes)
  - Power & energy parameters (TX cost, idle cost, sleep cost)
  - Trust thresholds (TRUST_INITIAL, TRUST_MIN, TRUST_MAX, TRUST_CENSUS_TRIGGER)
  - Timing constants (aggregation period, handshake timeout, etc.)
  - Feature names for ML-IDS

- **WSN_Message.m** — Message serialization/deserialization
  - Message class definition (properties: type, src, dst, payload, etc.)
  - Serialization to hex frames
  - Deserialization from hex frames
  - Checksum computation and verification
  - Payload encoding/decoding helpers

- **WSN_Node.m** — Base node class
  - Common properties (ID, position, battery, tier, neighbor table)
  - Common methods (addLog, createHelloMessage, scheduleNextHelloBurst)
  - Abstract interface for step(), receive()
  - Battery management
  - Neighbor table management

### Physics & Propagation
- **WSN_Physics.m** — Physical layer simulation
  - Adjacency matrix computation (which nodes can reach which)
  - Rayleigh fading simulation (stochastic link changes)
  - Path loss model (RSSI calculation)
  - Distance matrix computation

- **WSN_TopologyGenerator.m** — Network initialization
  - Random node placement in field
  - Initial neighbor discovery
  - Topology statistics (density, connectivity)

### Protocol & Messaging
- **WSN_Protocol.m** — Protocol state machines (if needed)
  - May contain shared FSM logic for GWN backbone

- **WSN_ProtocolFrames.m** — Frame format definitions
  - Bit-level frame structure
  - Serialization helpers

### Radio & MAC
- **WSN_Radio.m** — Backbone radio (LoRa)
  - FSM protocol (PARENT_INIT, REQ_JOIN, ACK_JOIN, etc.)
  - Transmit/receive buffering
  - Token passing collision avoidance
  - Lock mechanism for handshakes

- **WSN_RadioStack.m** — Access radio (HC12)
  - Separate TX/RX buffers from backbone radio
  - HC12-specific parameters
  - Same FSM interface as WSN_Radio

### Security & Encryption
- **WSN_Crypto.m** — Cryptographic functions
  - XOR encryption (simple, placeholder)
  - AES encryption stub (future)
  - Key generation
  - Checksum/hash functions

### Feature Export (ML-IDS)
- **WSN_FeatureExport.m** — Local feature extraction (Phase 1-2)
  - Per-node time-series features (TX count, RX count, etc.)
  - Window-based aggregation
  - CSV export for ML training

## Usage

### In Any Node Implementation
```matlab
% Access configuration
fieldSize = WSN_Config.FieldSize;
msgType = WSN_Config.MSG_TYPE_SENSOR;
trustThreshold = WSN_Config.TRUST_CENSUS_TRIGGER;

% Create/deserialize messages
msg = WSN_Message();
msg.type = WSN_Config.MSG_TYPE_SENSOR;
msg.src = myID;
msg.dst = targetID;
msg.payload = [sensor_value_bytes, battery_byte];
msg.addChecksum();

hexFrame = msg.serialize();  % TX
[msg, ok] = WSN_Message.deserialize(hexFrame);  % RX if ok

% Use physics
[physAdj, stblAdj, distMat] = WSN_Physics.updateConnectivity(nodes);
rssi = WSN_Physics.calculateRSSI(txPower, distance, pathLossExp);

% Extract features
WSN_FeatureExport.tapTx(nodeIdx, msg, t);
WSN_FeatureExport.tapRx(nodeIdx, rssi, msg, t);
WSN_FeatureExport.flushWindow(nodes, t);
```

### From Main Simulation
```matlab
% Initialize
nodes = WSN_TopologyGenerator.generateTopology(WSN_Config.NodeCount, WSN_Config.FieldSize);

% Per-timestep physics
[physAdj, stblAdj, distMat] = WSN_Physics.updateConnectivity(nodes);
for i = 1:numel(nodes)
    nodes(i).updatePhysics(t);
    WSN_FeatureExport.tapTick(i, nodes(i), t);
end
```

## Configuration Management

### Modifying Constants
Edit `WSN_Config.m` to change:
- `FieldSize` — Area of simulation (default 1000×1000)
- `NodeCount` — Initial number of nodes
- `TxPower_*` — Transmission power per tier
- `IdleCost`, `SleepCost` — Battery drain rates
- `TRUST_*` — Trust thresholds
- Message type IDs and subtypes

### Example: Increase Trust Threshold
```matlab
% In WSN_Config.m, change:
TRUST_CENSUS_TRIGGER = 25;  % Was 30, now triggers sooner
```

## Extension Points

### Adding New Message Type
```matlab
% In WSN_Config.m, add:
MSG_TYPE_CUSTOM = 13;
CUSTOM_SUB_TYPE1 = 0;
CUSTOM_SUB_TYPE2 = 1;

% In WSN_Message.m, add case to serialize/deserialize
```

### Adding New Radio Type
```matlab
% Create Radio/WSN_RadioWiFi.m (if Wi-Fi support needed)
classdef WSN_RadioWiFi < WSN_Radio
    % Specific to Wi-Fi (different ranges, power, fading model)
end
```

### Custom Physics Model
```matlab
% Extend WSN_Physics.updateConnectivity() to add:
% - Terrain effects (buildings, obstacles)
% - Weather effects (rain, fog)
% - Directional antennas
```

## Folder Organization

```
Utils/
├── UTILS_README.md                    ← This file
├── WSN_Config.m                       ← Global configuration
├── WSN_Message.m                      ← Message class
├── WSN_Node.m                         ← Base node class
├── WSN_Physics.m                      ← Physical layer
├── WSN_TopologyGenerator.m            ← Network initialization
├── WSN_Protocol.m                     ← Protocol FSM (if needed)
├── WSN_ProtocolFrames.m               ← Frame definitions
├── WSN_Radio.m                        ← LoRa backbone radio
├── WSN_RadioStack.m                   ← HC12 access radio
├── WSN_Crypto.m                       ← Encryption/hashing
├── WSN_FeatureExport.m                ← Local feature extraction
└── WSN_SinkFeatureExport.m            ← Sink-side feature export
```

## Dependencies

### Requires (from Utils):
- Nothing (Utils is self-contained or depends on MATLAB std library)

### Used by (from everywhere):
- All tier implementations (SN, CH, GWN, SINK)
- Main simulator (WSN_Main)
- GUI components
- Attack system (WSN_Attack)

## Performance Considerations

### Expensive Operations (optimize if needed)
- `WSN_Physics.updateConnectivity()` — O(n²) distance calculations
  - Called every timestep, consider caching if static
- `WSN_FeatureExport.flushWindow()` — O(f·n) where f = features, n = nodes
  - Called every feature window (e.g., every 100 TFs)

### Memory Usage
- `WSN_Config` — ~1 KB (constants)
- `WSN_Message` — ~100 bytes per message object
- Feature export buffers — ~10 KB per node (scales with window size)

## See Also
- [README_MODULARIZATION](../README_MODULARIZATION.md) — Project structure
- [Simulator README](../Simulator/SIMULATOR_README.md) — How to run
- [WSN_Config.m](WSN_Config.m) — Configuration details (inline comments)
