# 🚀 START HERE — WSN7_MODULAR Complete Refactoring

**Status**: ✅ **COMPLETE & READY TO USE**

---

## ✅ COMPLETE — All Files Moved and Organized

The entire WSN7 simulator has been **reorganized into a hierarchical, self-contained folder structure** with comprehensive documentation. All 30+ MATLAB files are now organized by function, with clear paths for access and modification. **The refactoring is COMPLETE as of 2026-06-21.**

### Current Structure (58 files organized across 8 modules)

```
WSN7_MODULAR/
├── SN/           (Sensor Node — Tier 1)           7 files  ✅ DONE
│   ├── WSN_Sensor.m ✅ MOVED
│   ├── SN_Behavior.m, SN_Messaging.m
│   └── Documentation: SN_*.md files
│
├── CH/           (Cluster Head — Tier 2)          7 files  ✅ DONE
│   ├── WSN_ClusterHead.m ✅ MOVED
│   ├── CH_Behavior.m, CH_Messaging.m
│   └── Documentation: CH_*.md files
│
├── GWN/          (Gateway — Tier 3)               5 files  ✅ DONE
│   ├── WSN_Gateway.m ✅ MOVED
│   ├── WSN_Gateway_Behavior.m, WSN_Gateway_Messaging.m ✅ MOVED
│   └── Documentation: GWN_*.md files
│
├── SINK/         (Base Station — Tier 4)          8 files  ✅ DONE
│   ├── WSN_Sink.m ✅ MOVED
│   ├── WSN_FeatureExport.m, WSN_SinkFeatureExport.m ✅ MOVED
│   ├── Registry/         Node registries
│   ├── Enforcement/      Verdict enforcement
│   ├── FeatureExport/    ML-IDS features
│   └── Documentation: SINK_*.md files
│
├── GUI/          (Visualization)                  8 files  ✅ DONE
│   ├── WSN_GUI.m ✅ MOVED
│   ├── WSN_GUI_*.m (7 components) ✅ MOVED
│   └── Documentation: GUI_README.md
│
├── Utils/        (Shared infrastructure)         13 files  ✅ DONE
│   ├── WSN_Config.m ✅ MOVED
│   ├── WSN_Node.m, WSN_Message.m, WSN_Physics.m ✅ MOVED
│   ├── WSN_Radio.m, WSN_RadioStack.m ✅ MOVED
│   ├── WSN_Protocol.m, WSN_ProtocolFrames.m ✅ MOVED
│   ├── WSN_Crypto.m, WSN_TopologyGenerator.m ✅ MOVED
│   └── Documentation: UTILS_README.md
│
├── Simulator/    (Core simulation)                6 files  ✅ DONE
│   ├── WSN_Main.m ✅ MOVED
│   ├── WSN_Attack.m, WSN_Attack_Demo.m ✅ MOVED
│   ├── VERIFICATION_PHASE2.m, test_hello_diagnostic.m ✅ MOVED
│   └── Documentation: SIMULATOR_README.md
│
└── Root/         (Project docs)                   4 files  ✅
    ├── addpath_setup.m
    ├── START_HERE.md (you are here)
    ├── README_MODULARIZATION.md
    └── CODEBASE_ORGANIZATION.md
```

### Key Features

✅ **Tier-Based Organization**: Each node type (SN, CH, GWN, Sink) self-contained in its folder  
✅ **Behavior/Messaging Separation**: Pure logic separate from protocol (SN & CH, testable)  
✅ **Comprehensive Documentation**: 68+ KB across all modules  
✅ **Path Management**: Automatic setup via `addpath_setup.m`  
✅ **Function Indices**: Every function mapped to source with line numbers  
✅ **Working Notes**: Issues, test scenarios, decision matrices in Shell files  
✅ **Quick Start Guides**: README files for each module  

---

## Quick Start (3 Steps)

### Step 1: Initialize MATLAB Path
```matlab
cd /path/to/WSN7_MODULAR
addpath_setup  % Run this FIRST (one-time per session)
```

### Step 2: Run Simulation (Choose One)

**Interactive (with GUI)**:
```matlab
WSN_Main()  % GUI visible, runs to SimSteps (10000 ticks)
```

**Headless (batch)**:
```matlab
WSN_Main(1e9, 50, [], 5000)  % No GUI, 5000 ticks, fast
```

**With Attacks**:
```matlab
WSN_Attack_Demo  % Run all attack scenarios
```

### Step 3: Check Logs
```matlab
% All outputs in logs/ folder
open logs/
% See: combined_*.csv, sink_nodeRegistry_*.csv, etc.
```

---

## Navigation by Role

### 👨‍💻 **Developer** (modifying code)
1. `addpath_setup` — Initialize path
2. `CODEBASE_ORGANIZATION.md` — Understand structure
3. `{TIER}/{TIER}_Documentation.md` — Understand tier
4. `{TIER}/{TIER}_Index.m` — Find functions
5. Edit appropriate file (Behavior/Messaging or main class)
6. Test with scenarios from `{TIER}/{TIER}_Shell.md`

### 🔬 **Researcher** (running experiments)
1. `addpath_setup` — Initialize path
2. `Simulator/SIMULATOR_README.md` — Learn command options
3. `Utils/WSN_Config.m` — Adjust simulation parameters
4. Run `WSN_Main()` with desired arguments
5. Analyze logs in `logs/` folder
6. `SINK/SINK_Documentation.md` — Understand data output

### 📚 **Learner** (understanding the system)
1. `README_MODULARIZATION.md` — Overview of structure
2. `CODEBASE_ORGANIZATION.md` — File organization guide
3. `SN/SN_Documentation.md` → `CH/CH_Documentation.md` → `GWN/GWN_Documentation.md` — Read tier specs
4. `Simulator/SIMULATOR_README.md` — See how it all runs together
5. Run simulations: `WSN_Main(0, 1, [], 500)` to watch with GUI

### 🐛 **Debugger** (fixing issues)
1. `{TIER}/{TIER}_Shell.md` — Check "Known Issues" section
2. `{TIER}/{TIER}_Index.m` — Locate the function
3. `{TIER}/WSN_{TierName}.m` — View implementation
4. `{TIER}/{TIER}_Behavior.m` — Review decision logic
5. Check decision matrices in `{TIER}/{TIER}_Shell.md`

---

## Key Files & What They Do

### 🔧 Setup
- **addpath_setup.m** — Sets up MATLAB path for all modules (RUN THIS FIRST)

### 📋 Documentation
- **README_MODULARIZATION.md** — Project structure overview
- **MODULARIZATION_COMPLETE.md** — Completion report with statistics
- **CODEBASE_ORGANIZATION.md** — File-by-file organization guide
- **{TIER}/{TIER}_Documentation.md** — Exact specification per tier
- **{MODULE}/{MODULE}_README.md** — Quick start per module

### 🗂️ Navigation
- **{TIER}/{TIER}_Index.m** — Function map with line numbers
- **{TIER}/{TIER}_Shell.md** — Known issues and test scenarios

### ⚙️ Implementation
- **{TIER}/WSN_{TierName}.m** — Core class implementation
- **{TIER}/{TIER}_Behavior.m** — Decision logic (if separate)
- **{TIER}/{TIER}_Messaging.m** — Protocol handling (if separate)
- **Utils/{module}.m** — Shared utilities (config, base classes, physics, etc.)

### 🎮 Running
- **WSN_Launcher.m** — Root entry point (GUI/headless, decoupled attack config)
- **Simulator/WSN_Main.m** — Core simulation loop
- **Simulator/SIMULATOR_README.md** — How to run with options
- **Attacks/WSN_Attack.m** — Attack injection (+ per-type files:
  WSN_Attack_Blackhole.m, _Grayhole.m, _Flooding.m, _Sybil.m, _Wormhole.m,
  _DenialOfSleep.m, _PanicFlood.m)
- **Attacks/WSN_Attack_Demo.m** — Run all attacks

### 🖥️ Visualization
- **GUI/WSN_GUI.m** — Main GUI window
- **GUI/WSN_GUI_*.m** — Component modules

---

## File Organization Summary

| Tier | Files | Purpose |
|------|-------|---------|
| **SN** | WSN_Sensor.m + 6 docs | Sensor nodes (low-power, sleep cycles) |
| **CH** | WSN_ClusterHead.m + 6 docs | Cluster heads (aggregation, FSM) |
| **GWN** | WSN_Gateway.m + 4 docs | Gateways (dual-radio, backbone FSM) |
| **SINK** | WSN_Sink.m + 3 sub-modules + 3 docs | Base station (data collection, enforcement) |
| **GUI** | 7 WSN_GUI_*.m + 1 README | Visualization & user interface |
| **Utils** | 13 files | Config, messages, physics, radio, crypto |
| **Simulator** | WSN_Main.m + attacks + tests | Core simulation loop |
| **Root** | 4 setup/doc files | Project documentation |

---

## What Happens When You Run `addpath_setup`

```
✓ Added tier folder: SN/
✓ Added tier folder: CH/
✓ Added tier folder: GWN/
✓ Added tier folder: SINK/
✓ Added SINK subfolder: SINK/Registry/
✓ Added SINK subfolder: SINK/Enforcement/
✓ Added SINK subfolder: SINK/FeatureExport/
✓ Added utilities: Utils/
✓ Added GUI components: GUI/
✓ Added simulator: Simulator/
✓ Added root directory for documentation

[VALIDATION] Checking key files...
✓ Found: WSN_Main.m
✓ Found: WSN_Config.m
✓ Found: WSN_Sensor.m
✓ Found: WSN_ClusterHead.m
✓ Found: WSN_Gateway.m
✓ Found: WSN_Sink.m
✓ Found: WSN_GUI.m

[SUCCESS] All key files found. System ready.
Ready to run: WSN_Main()
```

---

## Common Tasks

### Run GUI Simulation
```matlab
addpath_setup
WSN_Main()  % 10000 ticks, interactive visualization
```

### Run Batch Simulation (No GUI)
```matlab
addpath_setup
WSN_Main(1e9, 50, [], 5000)  % 5000 ticks, headless
```

### Change Simulation Parameters
```matlab
addpath_setup
WSN_Config.NodeCount = 50;  % Modify before running
nodes = WSN_TopologyGenerator.generateTopology(50, 1000);
WSN_Main(1e9, 50, nodes, 1000);
```

### Run Protocol Tests
```matlab
addpath_setup
VERIFICATION_PHASE2  % Test FSM, aggregation, etc.
```

### Run Attack Scenarios
```matlab
addpath_setup
WSN_Attack_Demo  % Runs all 7 attack types with metrics
```

### Examine Output Logs
```matlab
% After simulation completes, check:
open logs/combined_*.csv         % All node logs
open logs/sink_nodeRegistry_*.csv  % Node status
open logs/sink_sensorRegistry_*.csv  % Sensor data
open logs/attack_log_*.csv       % Ground truth for ML-IDS
```

---

## Module Quick Reference

### SN/ — Sensor Nodes (Tier 1)
- **Read First**: `SN/SN_Documentation.md`
- **Main Class**: `SN/WSN_Sensor.m`
- **Key Methods**: `step()`, `receive()`, `findBestSensorTarget()`
- **Decision Logic**: `SN/SN_Behavior.m`
- **Protocol**: `SN/SN_Messaging.m`
- **Issues & Tests**: `SN/SN_Shell.md`

### CH/ — Cluster Heads (Tier 2)
- **Read First**: `CH/CH_Documentation.md`
- **Main Class**: `CH/WSN_ClusterHead.m`
- **Key Methods**: FSM (`STATE_BOOT` → `STATE_VERIFIED`), `processSensorAggregation()`
- **Decision Logic**: `CH/CH_Behavior.m`
- **Protocol**: `CH/CH_Messaging.m` (handshake, aggregation)
- **Issues & Tests**: `CH/CH_Shell.md`

### GWN/ — Gateways (Tier 3)
- **Read First**: `GWN/GWN_Documentation.md`
- **Main Class**: `GWN/WSN_Gateway.m`
- **Key Features**: Dual-radio (LoRa backbone + HC12 access), FSM, CH recruitment
- **Behavior**: Delegates to `WSN_Gateway_Behavior.m`
- **Messaging**: Delegates to `WSN_Gateway_Messaging.m`
- **Issues & Tests**: `GWN/GWN_Shell.md`

### SINK/ — Sink / Base Station (Tier 4)
- **Read First**: `SINK/SINK_Documentation.md`
- **Main Class**: `SINK/WSN_Sink.m`
- **Registry**: `SINK/Registry/WSN_Sink_Registry.m` (node & sensor data)
- **Enforcement**: `SINK/Enforcement/WSN_Sink_Enforcement.m` (verdict execution)
- **Features**: `SINK/FeatureExport/WSN_Sink_FeatureExport.m` (ML-IDS export)
- **Issues & Tests**: `SINK/SINK_Shell.md`

### GUI/ — Visualization
- **Read First**: `GUI/GUI_README.md`
- **Main**: `GUI/WSN_GUI.m` (coordinates all components)
- **Components**: Topology, NetworkState, EventBus, EventFeed, Analytics, ControlDeck
- **Start**: Created automatically by `WSN_Main.m` if `startGUIAt <= SimSteps`

### Utils/ — Utilities
- **Read First**: `Utils/UTILS_README.md`
- **Config**: `Utils/WSN_Config.m` (ALL constants here)
- **Base Class**: `Utils/WSN_Node.m` (parent for SN, CH, GWN, Sink)
- **Messages**: `Utils/WSN_Message.m` (Type 0-12, serialization)
- **Physics**: `Utils/WSN_Physics.m` (RSSI, adjacency, fading)
- **Radios**: `Utils/WSN_Radio.m`, `Utils/WSN_RadioStack.m`

### Simulator/ — Core Simulation
- **Read First**: `Simulator/SIMULATOR_README.md`
- **Main Loop**: `Simulator/WSN_Main.m`
- **Entry Point**: `WSN_Main(startGUIAt, printInterval, nodes, simSteps)`

### Attacks/ — Attack Injection System
- **Coordinator**: `Attacks/WSN_Attack.m` (state store, config, dispatch,
  thin wrappers delegating to the per-type files below)
- **Per-type logic**: `Attacks/WSN_Attack_Blackhole.m`, `_Grayhole.m`,
  `_Flooding.m`, `_Sybil.m`, `_Wormhole.m`, `_DenialOfSleep.m`,
  `_PanicFlood.m`
- **Batch driver**: `Attacks/WSN_Attack_Demo.m`
- **Tests**: `Utils/VERIFICATION_PHASE2.m`, `Utils/test_hello_diagnostic.m`

---

## Performance Baseline

From `{TIER}/{TIER}_Shell.md`:

| Metric | SN | CH | GWN | SINK |
|--------|----|----|-----|------|
| **CPU** | O(n) | O(m log m) | O(k) | O(n) |
| **Memory** | ~1 KB | ~2 KB | ~3 KB | ~5 KB |
| **Network** | 18-20 msgs/100TF | 25-30 | 35-45 | 0.5-1.0 in |
| **Battery** | 1000+ TF @ 15% | 150-200 TF | 150-200 TF | N/A |

---

## Troubleshooting

### "Function not found" or "Undefined variable"
**Problem**: Haven't run `addpath_setup`
**Solution**: `addpath_setup` at start of session

### GUI doesn't appear
**Problem**: `startGUIAt > SimSteps` so GUI never visible
**Solution**: `WSN_Main(100, 1)` to show GUI at t=100

### Slow simulation
**Problem**: GUI refresh is bottleneck
**Solution**: Use headless: `WSN_Main(1e9, 50, [], 5000)`

### "Attack not working"
**Problem**: `WSN_Attack.init()` not called
**Solution**: `WSN_Attack.init(numel(nodes))` before `WSN_Main`

### Logs not appearing
**Problem**: Simulation exited without hitting autolog (250 ticks)
**Solution**: Run longer: `WSN_Main(1e9, 50, [], 300)` minimum

---

## Next Steps

### For Development
1. ✅ Run `addpath_setup`
2. ✅ Run `WSN_Main()` to see it work
3. ✅ Read `{TIER}/{TIER}_Documentation.md` for the tier you want to modify
4. ✅ Modify `{TIER}/WSN_{TierName}.m` or `{TIER}/{TIER}_Behavior.m`
5. ✅ Test with scenarios from `{TIER}/{TIER}_Shell.md`

### For Research
1. ✅ Run `addpath_setup`
2. ✅ Modify `Utils/WSN_Config.m` for experiment parameters
3. ✅ Run `WSN_Main()` with desired batch mode
4. ✅ Analyze `logs/*.csv` files

### For Understanding
1. ✅ Run `addpath_setup`
2. ✅ Start with `SN/SN_Documentation.md` (simplest tier)
3. ✅ Then `CH/CH_Documentation.md` (adds aggregation)
4. ✅ Then `GWN/GWN_Documentation.md` (adds dual-radio)
5. ✅ Finally `SINK/SINK_Documentation.md` (final collection)

---

## Key Statistics

- **58 total files** across 8 organized modules
- **68+ KB** of documentation
- **170+ function entries** indexed with line numbers
- **20+ test scenarios** specified
- **7 attack types** implemented and testable
- **4 node tiers** with modular organization
- **100% backward compatible** (no breaking changes)

---

## Support & Documentation

- **Project Overview**: `README_MODULARIZATION.md`
- **Complete Organization**: `CODEBASE_ORGANIZATION.md`
- **This Quick Start**: `START_HERE.md` (you are here)
- **Tier Specifications**: `{TIER}/{TIER}_Documentation.md`
- **Function Maps**: `{TIER}/{TIER}_Index.m`
- **Issues & Solutions**: `{TIER}/{TIER}_Shell.md`
- **Module Guides**: `{MODULE}/{MODULE}_README.md`

---

## 🎯 You're Ready!

```matlab
>> cd /path/to/WSN7_MODULAR
>> addpath_setup
[SUCCESS] All key files found. System ready.
[SETUP] Ready to run: WSN_Main()

>> WSN_Main()
% Simulation starts with GUI...
```

**Happy simulating!** 🚀

For detailed information, see `CODEBASE_ORGANIZATION.md` or `README_MODULARIZATION.md`
