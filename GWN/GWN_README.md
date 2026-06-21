# Gateway (GWN/Tier 3) — Self-Contained Module

## Overview
This folder contains all Gateway implementation and documentation. Gateways form the backbone of the WSN hierarchy, using dual-radio architecture (LoRa backbone + HC12 access) to bridge Cluster Heads and relay data to the Sink.

## Files in This Folder

### Implementation
- **WSN_Gateway.m** — Gateway class implementation
  - Main class with properties and methods
  - Inherits from WSN_Node (base class in Utils/)
  - Implements step(), receive(), updatePhysics()
  - Dual-radio management (LoRa backbone + HC12 access)
  - Finite State Machine (FSM) for backbone topology

### Documentation
- **GWN_Documentation.md** — Exact functionality specification
  - Dual-radio architecture (Backbone LoRa + Access HC12)
  - GWN-GWN backbone protocol (FSM)
  - CH/SN recruitment and access radio
  - Sensor aggregation and panic handling
  - Trust management and Census protocol
  - Reporting-silence detection
  - CH Discovery Dynamic Voltage Scaling (DVS)

- **GWN_Index.m** — Function index with line numbers
  - 60+ function/property references
  - Dual-radio management details
  - CH children tracking and aggregation
  - FSM state machine references
  - Token passing and heartbeat logic

- **GWN_Shell.md** — Working notes and development guide
  - Status and implementation phase
  - Known issues with workarounds
  - Test scenarios for validation
  - Performance metrics and baselines
  - Decision matrices and thresholds

### Messaging & Behavior
- **WSN_Gateway_Behavior.m** (delegated) — Decision logic
  - Backbone token passing FSM
  - CH recruitment scheduling
  - Aggregation synchronization
  - Trust scoring and escalation
  - Census verdict computation

- **WSN_Gateway_Messaging.m** (delegated) — Protocol handling
  - Backbone topology messages
  - CH recruitment protocol
  - Aggregation forwarding
  - Panic escalation
  - Census message handling

## Quick Start

### 1. View Node Behavior
```matlab
% Read documentation first
open('GWN/GWN_Documentation.md')

% Review working notes and issues
open('GWN/GWN_Shell.md')

% Find specific function
grep('tokenPass', 'GWN/GWN_Index.m')
```

### 2. Create Gateway
```matlab
node = WSN_Gateway(nodeID, position);
% Properties auto-initialized:
% - parentGateway: empty (backbone connection)
% - childGateways: []
% - clusterHeads: []
% - backboneRadio: enabled
% - accessRadio: enabled
% - battery: 100% (or external power)
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
% Read through GWN_Shell.md for:
% - Known issues (CH_HELLO relay buffer, token loss)
% - Test scenarios (backbone formation, CH recruitment)
% - Performance baselines (dual-radio traffic)
% - Token passing FSM details
```

## Module Dependencies

### Requires (from Utils/):
- `WSN_Node.m` — Base class (extends)
- `WSN_Config.m` — Configuration constants
- `WSN_Message.m` — Message class
- `WSN_Crypto.m` — Encryption (placeholder)
- `WSN_Attack.m` — Attack system integration

### Behavior/Messaging (delegated):
- `WSN_Gateway_Behavior.m` — Decision logic
- `WSN_Gateway_Messaging.m` — Protocol implementation

### Used by:
- `WSN_Main.m` — Main simulation loop
- Network topology (parent: Sink, children: CHs and GWNs)
- `WSN_Attack.m` — Attack injection (sinkhole, jamming)

## Key Properties

### Backbone Hierarchy
- `parentGateway` — Connected parent Gateway (forms backbone tree)
- `childGateways` — Array of child Gateway IDs
- `sinkConnection` — Direct Sink link

### Access Network
- `clusterHeads` — Array of recruited CH IDs
- `sensors` — Sensor nodes heard from access radio

### Dual Radio
- `backboneRadio` — LoRa (long-range backbone)
  - State: 'RX'/'TX'/'SLEEP'
  - Power: high (backbone sync always active)
- `accessRadio` — HC12 (short-range access)
  - State: 'RX'/'TX'/'SLEEP'
  - Power: high (dual-radio = higher consumption)

### FSM State
- `fsm_state` — Backbone topology state
- `lastTokenTime` — Token pass timing

### Trust & Consensus
- `neighborTrust` — Per-neighbor trust scores
- `censusActivePolls` — Active voting polls
- `chReportingStatus` — Per-CH reporting health

## Key Methods

### Main Loop
- `step(t, physAdj)` — Called every timestep
  - Returns: array of messages to TX
  - Handles: backbone sync, CH recruitment, census

- `receive(msg, t, rssi)` — Inbound message processing
  - Returns: response message or empty
  - Handles: BACKBONE_TOKEN, CH_HELLO, AGGREGATION, CENSUS

- `updatePhysics(t)` — Dual-radio battery management
  - Updates: battery level (high drain from dual radios)

### Backbone Management
- `passBackboneToken(t)` — Backbone FSM coordination
- `verifyBackboneLink(t)` — Test parent connectivity
- `recruiteClusterHead(t, chID)` — Initiate CH recruitment

### Access Network
- `handleCHHello(msg, t)` — Process CH discovery
- `scheduleAggregationSync(t)` — Sync with CH children
- `forwardAggregation(msg, t)` — Relay uplink data

### Trust & Consensus
- `detectCHSilence(t)` — Identify unresponsive CHs
- `checkCensusTriggers(t)` — Initiate/finalize polls
- `handleCensusMessage(msg, t)` — Process voting

## Configuration (WSN_Config)

### Energy
- `IdleCost` = 0.5 (single radio, RX mode)
- `DualRadioCost` = 1.5 (both radios active, GWN only)
- `BaseTxCost` = 1.0 (message TX)

### Dual Radio
- `BACKBONE_RADIO_POWER` = "LoRa" (long-range, always on)
- `ACCESS_RADIO_POWER` = "HC12" (short-range, dynamic)

### Backbone
- `BACKBONE_TOKEN_INTERVAL` = 100 TF
- `BACKBONE_SYNC_PERIOD` = 30 TF

### CH Recruitment
- `CH_DISCOVERY_INTERVAL` = 50 TF
- `CH_RECRUITMENT_RETRY_MAX` = 3

### Trust & Consensus
- `TRUST_INITIAL` = 50.0
- `CH_SILENCE_TIMEOUT` = 50 TF
- `CENSUS_POLL_TIMEOUT` = 10 TF

## Testing & Validation

### Manual Test (Backbone Pair)
```matlab
% Create two Gateways
gwn1 = WSN_Gateway(300, [300, 300]);
gwn2 = WSN_Gateway(301, [350, 300]);

% Establish backbone
gwn1.childGateways = [301];
gwn2.parentGateway = 300;

% Step both
gwnMsgs1 = gwn1.step(100, eye(10));
gwnMsgs2 = gwn2.step(100, eye(10));
```

### Scenario Test (from GWN_Shell.md)
```matlab
% Run Scenario: Backbone Formation + CH Recruitment
% - t=100: GWNs boot, form backbone chain
% - t=120: CHs hello on access radio
% - t=130: GWNs recruit CHs, establish access links
% Results: Dual-radio traffic pattern, token passes down backbone
```

## Extension Points

### Adding New Behavior
1. Add function to `WSN_Gateway_Behavior.m` (pure logic)
2. Call from `step()` at appropriate point
3. Document in `GWN_Documentation.md`
4. Add test scenario to `GWN_Shell.md`

### Modifying Backbone Protocol
1. Update FSM states/transitions in `WSN_Gateway_Behavior.m`
2. Update message types in `WSN_Gateway_Messaging.m`
3. Update `GWN_Index.m` with modified line numbers
4. Document protocol in `GWN_Documentation.md`

### Custom Attack Response
1. Add check in `step()` or `receive()`
2. Implement response logic in `WSN_Gateway_Behavior.m`
3. Create test scenario in `GWN_Shell.md`

## Folder Organization

```
GWN/
├── GWN_README.md                      ← This file
├── GWN_Documentation.md               ← Functionality spec
├── GWN_Index.m                        ← Function index
├── GWN_Shell.md                       ← Issues & tests
├── WSN_Gateway.m                      ← Main implementation
├── WSN_Gateway_Behavior.m             ← Decision logic (delegated)
└── WSN_Gateway_Messaging.m            ← Protocol (delegated)
```

## Related Documentation
- [README_MODULARIZATION](../README_MODULARIZATION.md) — Project overview
- [GWN_Documentation.md](GWN_Documentation.md) — Detailed spec
- [GWN_Shell.md](GWN_Shell.md) — Known issues and test scenarios
- [Utils/WSN_Node.m](../Utils/) — Base class
- [Simulator/SIMULATOR_README.md](../Simulator/) — How to run
