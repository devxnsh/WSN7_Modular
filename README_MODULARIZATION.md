# WSN7_MODULAR Tier Refactoring — Complete

## Project Structure Overview

This directory contains the WSN7 Modular Simulator organized by **node tier** for readability and maintainability. Each tier folder contains 5 files following a consistent pattern:

### Tier Organization

```
WSN7_MODULAR/
├── SN/                          # Sensor Node (Tier 1)
│   ├── SN_Documentation.md      # Exact functionality, message types, state machine
│   ├── SN_Index.m               # Function index with line numbers
│   ├── SN_Shell.md              # Working notes, issues, test scenarios
│   ├── SN_Behavior.m            # High-level logic (trust, orphan, census)
│   └── SN_Messaging.m           # Message creation/parsing (low-level protocol)
│
├── CH/                          # Cluster Head (Tier 2)
│   ├── CH_Documentation.md      # FSM, aggregation, handshake protocol
│   ├── CH_Index.m               # Function index with line numbers
│   ├── CH_Shell.md              # Working notes, reporting-silence detection
│   ├── CH_Behavior.m            # FSM logic, aggregation scheduling, census
│   └── CH_Messaging.m           # Handshake messages (6.x), aggregation (5.x)
│
├── GWN/                         # Gateway (Tier 3)
│   ├── GWN_Documentation.md     # Dual-radio, backbone FSM, CH recruitment
│   ├── GWN_Index.m              # (IN PROGRESS - see WSN_Gateway.m for reference)
│   ├── GWN_Shell.md             # (IN PROGRESS)
│   ├── GWN_Behavior.m           # (IN PROGRESS - delegates to WSN_Gateway_Behavior.m)
│   └── GWN_Messaging.m          # (IN PROGRESS - delegates to WSN_Gateway_Messaging.m)
│
├── SINK/                        # Sink / Base Station (Tier 4)
│   ├── SINK_Documentation.md    # Aggregation, route building, ML-IDS enforcement
│   ├── SINK_Index.m             # (IN PROGRESS - see WSN_Sink.m for reference)
│   ├── SINK_Shell.md            # (IN PROGRESS)
│   ├── SINK_Behavior.m          # (IN PROGRESS)
│   └── SINK_Messaging.m         # (IN PROGRESS)
│
├── WSN_Main.m                   # Main simulation loop
├── WSN_Config.m                 # Global configuration constants
├── WSN_Message.m                # Message serialization/deserialization
├── WSN_Sensor.m                 # Tier 1 node implementation
├── WSN_ClusterHead.m            # Tier 2 node implementation
├── WSN_Gateway.m                # Tier 3 node implementation
├── WSN_Sink.m                   # Tier 4 node implementation
└── README_MODULARIZATION.md     # This file
```

## File Purpose Guide

### Documentation (*.md)
**Goal**: Exact functionality specification for humans and code-generating models

**Contents**:
- Node tier responsibilities (power management, message types, state machines)
- Message protocol specification (Types, subtypes, payload formats)
- Trust scoring decision matrix
- Attack vectors and mitigations
- Configuration parameter reference
- Inheritance and dependencies

**Usage**: Read before implementing; reference during integration testing
**Audience**: Developers, code reviewers, future maintainers

### Index (*.m)
**Goal**: Location map of all functions, behaviors, and data structures

**Contents**:
- Property list with line numbers and state/constant designation
- Function list with line numbers, signatures, return types, and brief descriptions
- Message type handler mapping
- Attack integration points
- Feature export hook points

**Format**: Plain MATLAB comments with structured index entries
**Usage**: Jump to specific implementation; verify function coverage
**Audience**: Developers, code navigators, refactoring scripts

### Shell (*.md)
**Goal**: Working scratchpad for issues, test scenarios, and performance notes

**Contents**:
- Current status and implementation phase
- Known issues with severity and workarounds
- Test scenarios with expected results
- Performance metrics (CPU, memory, network traffic)
- Integration points with other tiers
- TODO items (priority 1-3)
- Decision matrices and thresholds

**Format**: Markdown with sections for quick scanning
**Usage**: During debugging; when adding features; performance tuning
**Audience**: Active developers, debugging sessions

### Behavior (*.m)
**Goal**: High-level decision and control logic (independent of message format)

**Contents**:
- State machine transitions
- Trust scoring algorithms
- Census protocol logic
- Aggregation scheduling
- Priority calculations
- Attack detection thresholds

**Functions**: Pure logic, no message serialization
**Returns**: Computed decisions (next state, trust delta, verdict)
**Usage**: Reusable logic across message format changes
**Audience**: Logic-focused developers, behavior testing

### Messaging (*.m)
**Goal**: Message creation, parsing, and low-level protocol handling

**Contents**:
- Message creation functions (with payload encoding)
- Payload parsing functions (with byte extraction)
- Message dispatch/routing
- Encryption/decryption helpers
- Checksum and frame validation

**Functions**: Protocol-specific, format-aware
**Returns**: Serialized messages or parsed data structures
**Usage**: Message generation in step(); inbound message processing
**Audience**: Protocol developers, message format specialists

---

## How to Use This Structure

### For Implementing New Features

1. **Read Documentation** → Understand tier responsibilities and protocols
2. **Check Index** → Find existing implementation locations
3. **Review Shell** → See known issues and test scenarios
4. **Modify Behavior** → If decision logic needs change
5. **Modify Messaging** → If message format or handler logic needs change
6. **Test with Shell Scenarios** → Verify correctness

### For Debugging an Issue

1. **Grep Index files** → Find function locations
2. **Read Shell scenarios** → Check if known issue
3. **Review Shell decision matrix** → Verify threshold values
4. **Trace through Behavior logic** → Understand decision flow
5. **Check Messaging handlers** → Verify message processing order

### For Integration Testing

1. **Review Documentation** → Understand tier contracts
2. **Check Shell performance notes** → Set baselines
3. **Run Shell test scenarios** → Verify normal operation
4. **Verify Trust/Census** → Run multi-hop scenarios
5. **Test Attacks** → Run attack integration scenarios

### For Refactoring / Optimization

1. **Read Index** → Get function locations
2. **Check Shell TODO** → See optimization opportunities
3. **Profile Performance** → Compare to Shell baselines
4. **Implement in Behavior/Messaging** → Separate logic from protocol
5. **Update Documentation & Shell** → Record changes and new metrics

---

## Completion Status

| Tier | Doc | Index | Shell | Behavior | Messaging | Status |
|------|-----|-------|-------|----------|-----------|--------|
| **SN** (Sensor) | ✅ | ✅ | ✅ | ✅ | ✅ | **Complete** |
| **CH** (Cluster Head) | ✅ | ✅ | ✅ | ✅ | ✅ | **Complete** |
| **GWN** (Gateway) | ✅ | ⏳ | ⏳ | 📝 | 📝 | **In Progress** |
| **SINK** (Base Station) | ⏳ | ⏳ | ⏳ | 📝 | 📝 | **Planned** |

**Legend**: ✅ Complete | ⏳ In Progress | 📝 Delegated to existing files | ❌ Not Started

### Notes
- **SN & CH**: Fully modularized with dedicated Behavior/Messaging files
- **GWN**: Documentation complete; delegates to existing `WSN_Gateway_Behavior.m` and `WSN_Gateway_Messaging.m`
  - Create `GWN_Index.m` by reading `WSN_Gateway.m` and `WSN_Gateway_Behavior/Messaging.m`
  - Create `GWN_Shell.md` with dual-radio notes and CH recruitment issues
- **SINK**: Documentation in progress; delegates to `WSN_Sink.m`
  - Will follow same pattern as GWN (documentation + index + shell, Behavior/Messaging are delegated)

---

## Key Design Patterns

### Behavior/Messaging Separation
- **Behavior**: Pure logic (decisions, calculations, state transitions)
- **Messaging**: Protocol implementation (serialization, parsing, handlers)
- **Benefit**: Logic is testable independent of message format; message changes don't break logic

### Trust Scoring Matrices
- Each tier has documented trust deltas for specific events
- Thresholds trigger census polls (trust < 30)
- Escalation levels (SOFT → HARD → BLACKLIST) track repeat offenders
- Verdict computation uses quorum voting (≥50% YES = malicious)

### Reporting-Silence Detection
- Tracks "last seen" time for child aggregations
- Triggers when silence > 3 × aggregation period
- Automatically initiates census poll (catches Blackhole/Grayhole)
- More robust than explicit timeout retry logic

### Dual-Radio (GWN Only)
- **Backbone (LoRa)**: GWN-to-GWN, stable links, FSM protocol
- **Access (HC12)**: CH/SN discovery, subject to fading
- **Routing Decision**: Message type determines which radio
- **Lock Management**: Each radio can be locked independently

---

## Testing Strategy

### Unit Testing (by tier)
- Behavior functions independently (pure logic tests)
- Messaging parsing/creation round-trips (format validation)

### Integration Testing (by scenario)
- See Shell files for test scenarios
- Normal operation: HELLO discovery → parent selection → data flow
- Attack scenarios: Flooding, Blackhole, Grayhole, Sybil
- Failure scenarios: Network partition, parent loss, link flapping

### System Testing
- Run full WSN_Main with all tiers active
- Verify trust/census consensus across network
- Measure latency, throughput, energy consumption

---

## Next Steps

1. ✅ **Complete SN & CH** (fully modularized)
2. ⏳ **Complete GWN** (create Index & Shell, document Behavior/Messaging delegation)
3. ⏳ **Complete SINK** (similar to GWN pattern)
4. 📋 **Refactor actual implementation** (separate WSN_Sensor into SN_Behavior/SN_Messaging classes)
5. 📋 **Create test harness** (unit + integration tests for each tier)
6. 📋 **Update WSN_Main** (adjust for new class structure if needed)

---

## For Future Developers

When extending this modular structure:

1. **Add new behavior** → Modify Behavior_*.m, update Behavior_Shell.md with decision logic
2. **Change message format** → Modify Messaging_*.m, update Messaging_Behavior.md with payload spec
3. **Add new attack** → Update Shell decision matrix, create test scenario
4. **Optimize performance** → Profile with Shell baselines, implement in Behavior layer
5. **Add new feature** → Document in Documentation_*.md first, then implement Behavior → Messaging

All changes should maintain the clear separation between **what the node decides** (Behavior) and **how it communicates** (Messaging).

---

**Last Updated**: 2026-06-21
**Maintainers**: [Your team here]
**Status**: Active Development — Ready for integration & testing
