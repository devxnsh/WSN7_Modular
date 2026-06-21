# Cluster Head (CH/Tier 2) — Self-Contained Module

## Overview
This folder contains all Cluster Head implementation and documentation. Cluster Heads are intermediate aggregators in the WSN hierarchy, responsible for collecting sensor data, managing child nodes, and reporting to Gateways.

## Files in This Folder

### Implementation
- **WSN_ClusterHead.m** — Cluster Head class implementation
  - Main class with properties and methods
  - Inherits from WSN_Node (base class in Utils/)
  - Implements step(), receive(), updatePhysics()
  - Finite State Machine (FSM) for recruitment and verification

### Documentation
- **CH_Documentation.md** — Exact functionality specification
  - Network topology and recruitment FSM
  - Sensor data aggregation (5.2/5.3 protocol)
  - Handshake protocol (6.0-6.5 messages)
  - Panic message handling
  - Reporting-silence detection (catches Blackhole/Grayhole)
  - ML-IDS Census protocol with escalation

- **CH_Index.m** — Function index with line numbers
  - Maps all behaviors to WSN_ClusterHead.m
  - FSM state transitions
  - Aggregation scheduling and retry logic
  - Handshake protocol handlers
  - Census message types and enforcement

- **CH_Shell.md** — Working notes and development guide
  - Status and implementation phase
  - Known issues with workarounds
  - Test scenarios for validation
  - Performance metrics and baselines
  - Decision matrices and thresholds

### Logic & Protocol Separation
- **CH_Behavior.m** — High-level decision logic (pure functions, testable)
  - FSM state machine logic
  - Aggregation scheduling and fragmentation
  - Trust scoring and escalation
  - Reporting-silence detection algorithm
  - Census verdict computation

- **CH_Messaging.m** — Low-level protocol (message serialization)
  - Handshake message creation (Type 6: CH_CMD subtypes 0-5)
  - Aggregation messages (Type 5.2/5.3)
  - Panic and census message handling
  - Payload parsing with encryption support

## Quick Start

### 1. View Node Behavior
```matlab
% Read documentation first
open('CH/CH_Documentation.md')

% Review working notes and issues
open('CH/CH_Shell.md')

% Find specific function
grep('handleHandshake', 'CH/CH_Index.m')
```

### 2. Create Cluster Head
```matlab
node = WSN_ClusterHead(nodeID, position);
% Properties auto-initialized:
% - parentGateway: empty
% - sensorChildren: []
% - aggregationQueue: []
% - fsm_state: 'STATE_BOOT'
% - battery: 100%
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
% Read through CH_Shell.md for:
% - Known issues (CH-CH loop, aggregation loss)
% - Test scenarios (recruitment, aggregation, silence detection)
% - Performance baselines
% - FSM state transitions
```

## Module Dependencies

### Requires (from Utils/):
- `WSN_Node.m` — Base class (extends)
- `WSN_Config.m` — Configuration constants
- `WSN_Message.m` — Message class
- `WSN_Crypto.m` — Encryption (placeholder)
- `WSN_Attack.m` — Attack system integration

### Used by:
- `WSN_Main.m` — Main simulation loop
- Network topology (parent: GWN, children: SNs)
- `WSN_Attack.m` — Attack injection (blackhole, grayhole)

## Key Properties

### Hierarchy
- `parentGateway` — Connected Gateway (GWN)
- `sensorChildren` — Array of child Sensor Node IDs

### Aggregation State
- `aggregationQueue` — Pending sensor reports
- `aggregationSchedule` — Next aggregation time
- `lastAggregationTime` — Previous aggregation time

### FSM State
- `fsm_state` — 'STATE_BOOT', 'STATE_ADVERTISE', 'STATE_VERIFY', etc.
- `parentVerificationAttempts` — Handshake retry counter

### Trust & Consensus
- `neighborTrust` — Per-neighbor trust scores
- `censusActivePolls` — Active voting polls
- `lastReportingTime` — Reporting-silence detection

## Key Methods

### Main Loop
- `step(t, physAdj)` — Called every timestep
  - Returns: array of messages to TX
  - Handles: recruitment, aggregation, census

- `receive(msg, t, rssi)` — Inbound message processing
  - Returns: response message or empty
  - Handles: HELLO, HANDSHAKE, SENSOR_DATA, PANIC, CENSUS

- `updatePhysics(t)` — Battery management
  - Updates: battery level

### Recruitment & Verification
- `handleHandshakeMessage(msg, t)` — Handshake protocol
- `verifyWithGateway(t)` — Initiate verification
- `processVerificationResponse(msg, t)` — Handle response

### Aggregation
- `scheduleAggregation(t)` — Plan next aggregation
- `performAggregation(t)` — Collect and fragment sensor data
- `createAggregationMessage(t, fragment)` — Type 5.2/5.3 MSG

### Trust & Consensus
- `detectReportingSilence(t)` — Identify unresponsive nodes
- `checkCensusTriggers(t)` — Initiate/finalize polls
- `handleCensusMessage(msg, t)` — Process voting

## Configuration (WSN_Config)

### Energy
- `IdleCost` = 0.5 (awake, RX mode)
- `SleepCost` = 0.05 (sleeping)
- `BaseTxCost` = 1.0 (message TX)
- `AggregationCost` = 2.0 (computation)

### Aggregation
- `AGGREGATION_PERIOD` = 20 TF (collect sensor reports)
- `AGGREGATION_FRAGMENT_SIZE` = 10 (reports per message)
- `AGGREGATION_RETRY_MAX` = 3

### Trust & Consensus
- `TRUST_INITIAL` = 50.0
- `REPORTING_SILENCE_TIMEOUT` = 30 TF
- `CENSUS_POLL_TIMEOUT` = 10 TF
- `CENSUS_QUORUM_YES_RATIO` = 0.5

## Testing & Validation

### Manual Test (Single Cluster)
```matlab
% Create Cluster Head and Sensor
ch = WSN_ClusterHead(200, [500, 500]);
sn = WSN_Sensor(101, [510, 510]);

% Establish hierarchy
ch.sensorChildren = [101];
sn.parentNode = 200;

% Step both nodes
chMsgs = ch.step(100, eye(10));
snMsgs = sn.step(100, eye(10));
```

### Scenario Test (from CH_Shell.md)
```matlab
% Run Scenario: Aggregation with Silence Detection
% - t=100: CH boots, advertises to GWN
% - t=102: SN joins as child
% - t=120: CH aggregates first batch
% - t=150: SN goes silent, CH detects
% Results: CH escalates to Sink, initiates census
```

## Extension Points

### Adding New Behavior
1. Add function to `CH_Behavior.m` (pure logic)
2. Call from `step()` at appropriate point
3. Document in `CH_Documentation.md`
4. Add test scenario to `CH_Shell.md`

### Adding New Message Type
1. Create handler in `CH_Messaging.m`
2. Add case to `receive()` dispatcher
3. Update `CH_Index.m` with new line number
4. Document message format in `CH_Documentation.md`

### Custom Attack Response
1. Add check in `step()` or `receive()`
2. Implement response logic in `CH_Behavior.m`
3. Create test scenario in `CH_Shell.md`

## Folder Organization

```
CH/
├── CH_README.md                       ← This file
├── CH_Documentation.md                ← Functionality spec
├── CH_Index.m                         ← Function index
├── CH_Shell.md                        ← Issues & tests
├── CH_Behavior.m                      ← Pure logic
├── CH_Messaging.m                     ← Protocol
└── WSN_ClusterHead.m                  ← Implementation
```

## Related Documentation
- [README_MODULARIZATION](../README_MODULARIZATION.md) — Project overview
- [CH_Documentation.md](CH_Documentation.md) — Detailed spec
- [CH_Shell.md](CH_Shell.md) — Known issues and test scenarios
- [Utils/WSN_Node.m](../Utils/) — Base class
- [Simulator/SIMULATOR_README.md](../Simulator/) — How to run
