# Simulator Module — Core Simulation Engine

## Purpose
Contains the main simulation loop (`WSN_Main.m`). As of the 2026-06-21
reorganization, this is the ONLY file in this folder - the attack system and
the verification/diagnostic scripts that used to live here have moved out
(see "Related Folders" below), since neither is really part of the
simulation engine itself.

## Files in This Folder

### Main Simulation
- **WSN_Main.m** — Entry point for the simulator
  - Main simulation loop (for t = 1:simSteps)
  - Physics refresh, message delivery, protocol execution
  - GUI integration (optional visibility, including partial-headless: GUI
    starts hidden and is revealed mid-run at `startGUIAt` - see
    `WSN_Launcher.m`'s `HeadlessSteps`/`StartGUIAt` parameters)
  - Headless mode support (batch runs)
  - Autolog every 250 ticks
  - Attack system integration (via `Attacks/WSN_Attack.m`)
  - Feature export (ML-IDS)

  **Signature**: `WSN_Main(varargin)`
  
  **Arguments**:
  - `WSN_Main()` — GUI visible from t=0, runs to SimSteps
  - `WSN_Main(100)` — GUI visible at t=100
  - `WSN_Main(1e9, 50, nodes)` — Headless, pre-created nodes
  - `WSN_Main(1e9, 50, nodes, 500)` — Headless, 500 ticks, batch mode

## Related Folders (moved out of Simulator/)
- **Attacks/WSN_Attack.m** + **Attacks/WSN_Attack_<Type>.m** (Blackhole,
  Grayhole, Flooding, Sybil, Wormhole, DenialOfSleep, PanicFlood) + 
  **Attacks/WSN_Attack_Demo.m** — the full attack injection system. Attacks
  are conceptually independent of the simulation engine (the engine just
  calls into `WSN_Attack.*` the same way it calls into any other utility),
  so they get their own top-level folder rather than living under Simulator/.
- **Utils/WSN_Node.m** — base node class (abstract interface); always lived
  conceptually with the other shared utility/base classes.
- **Utils/VERIFICATION_PHASE2.m**, **Utils/test_hello_diagnostic.m** —
  protocol verification/diagnostic scripts; these are tooling, not part of
  the simulation engine, so they live alongside the other Utils/ helpers.

## Quick Start

### 1. Initialize Path (REQUIRED FIRST)
```matlab
cd /path/to/WSN7_MODULAR
addpath_setup  % Sets up all folders
```

### 2. Run Default Simulation
```matlab
% Interactive GUI mode (starts with visualization)
WSN_Main()

% Headless batch mode (no GUI, faster)
WSN_Main(1e9, 50, [], 5000)  % 5000 ticks, no GUI
```

### 3. Run with Attacks
```matlab
% Create attack configuration
WSN_Attack.init(100);  % 100 nodes in simulation
WSN_Attack.setMalicious(5, WSN_Attack.ATTACK_BLACKHOLE);  % Node 5 is blackhole
WSN_Attack.setMalicious(10, WSN_Attack.ATTACK_FLOODING);  % Node 10 floods

% Run simulation
WSN_Main(1e9, 50, [], 2000);
```

### 4. Batch Attack Demo
```matlab
% Runs all attack types sequentially with metrics
WSN_Attack_Demo
```

### 5. Verification Tests
```matlab
% Test protocol correctness
VERIFICATION_PHASE2

% Diagnostic for HELLO messages
test_hello_diagnostic
```

## Output Files

### Logs (in `logs/` folder)
- **combined_t0-N_TIMESTAMP.csv** — Unified node logs at tick N
- **sink_nodeRegistry_t0-N_TIMESTAMP.csv** — Node status at tick N
- **sink_sensorRegistry_t0-N_TIMESTAMP.csv** — Sensor data at tick N
- **global_t0-N_TIMESTAMP.csv** — Global event feed at tick N
- **attack_log_TIMESTAMP.csv** — Ground truth for malicious nodes
- **local_features_TIMESTAMP.csv** — ML-IDS local feature vectors
- **sink_features_TIMESTAMP.csv** — ML-IDS aggregated feature vectors

### Export Locations
- Autolog: Every 250 ticks during simulation
- Final export: End of simulation (CSV format)

## Usage Patterns

### Interactive Development
```matlab
% Start with small network, GUI visible
nodes = WSN_TopologyGenerator.generateTopology(20, 1000);
WSN_Main(0, 1, nodes, 500);  % 500 ticks, GUI from t=0, 1 TF print interval
```

### Headless Batch Processing
```matlab
% Run many scenarios in parallel (no GUI overhead)
for numMalicious = 0:5:20
    WSN_Attack.init(100);
    for i = 1:numMalicious
        WSN_Attack.setMalicious(i, WSN_Attack.ATTACK_FLOODING);
    end
    nodes = WSN_TopologyGenerator.generateTopology(100, 1000);
    WSN_Main(1e9, 50, nodes, 2000);  % Run quietly
    fprintf('Completed with %d malicious nodes\n', numMalicious);
end
```

### Debug Mode with Logs
```matlab
% Frequent console output, save all logs
WSN_Main(100, 1, [], 200);  % Print every 1 TF, GUI at t=100
% Check logs/ folder for detailed output
```

### Performance Profiling
```matlab
% Time large simulation
tic;
WSN_Main(1e9, 50, [], 5000);  % 5000 ticks, no GUI
elapsed = toc;
fprintf('Simulation rate: %.0f ticks/second\n', 5000/elapsed);
```

## Main Loop Structure (from WSN_Main.m)

```
FOR each timestep t = 1:SimSteps
    1. PHYSICS REFRESH
       - Update adjacency matrices (Rayleigh fading)
       - Recompute distances and RSSI
    
    2. UPDATE ALL NODES
       - updatePhysics() — battery drain, wake/sleep cycles
       - Feature extraction tap
    
    3. MESSAGE GENERATION
       - Call step() on each node
       - Collect generated messages
       - Apply attack injection (Sybil Hello, panic flood)
    
    4. MESSAGE DELIVERY
       - Deserialize and validate
       - Determine destinations (broadcast, multicast, unicast)
       - Apply Wormhole relay if needed
       - Deliver to physical adjacency
       - Calculate RSSI based on distance
       - Route to backbone or access radio
    
    5. PROTOCOL EXECUTION
       - Call radio.step() on each node
       - Process received messages (receive())
       - Defer responses for next timestep
    
    6. FEATURE WINDOW FLUSH
       - Every FEATURE_WINDOW_LEN ticks (e.g., 100)
       - Export feature vectors for ML-IDS
    
    7. GUI REFRESH
       - Update network visualization
       - Draw packet animations
       - Refresh tables and graphs
       - Check if GUI closed (break if so)
    
    8. AUTOLOG
       - Every 250 ticks, export current logs to CSV
END

AFTER simulation:
- Export attack ground truth
- Export final feature dataset
- Print summary statistics
```

## Key Parameters (from WSN_Config)

### Timing
- `SimSteps` = 10000 (default total simulation time)
- `FEATURE_WINDOW_LEN` = 100 (ticks between feature export)
- `SENSOR_START_TIME` = 100 (when sensors begin TX)
- `SetupTime` = 50 (mesh setup period)

### Network
- `NodeCount` = 100 (total nodes, varies)
- `FieldSize` = 1000 (1000×1000 meters)
- `HelloRange` = 300 (Hello broadcast range)

### Energy
- `IdleCost` = 0.5 (units/TF when awake)
- `SleepCost` = 0.05 (units/TF when sleeping)
- `BaseTxCost` = 1.0 (units per TX)

## Troubleshooting

### "Function not found" Error
**Problem**: WSN_Config, WSN_Message, etc. not in path
**Solution**: Run `addpath_setup` from WSN7_MODULAR root first

### GUI Doesn't Appear
**Problem**: `startGUIAt > SimSteps` so GUI never becomes visible
**Solution**: Use `WSN_Main(100, 1, [])` to make GUI visible at t=100

### Slow Simulation
**Problem**: GUI refresh bottleneck (drawnow every timestep)
**Solution**: Use `WSN_Main(1e9, 50, [], 5000)` to run headless

### Attack Not Injecting
**Problem**: `WSN_Attack.init()` not called or node IDs out of range
**Solution**: Call `WSN_Attack.init(numel(nodes))` before WSN_Main, use valid IDs

### Feature Export Empty
**Problem**: Feature window never reaches FEATURE_WINDOW_LEN
**Solution**: Run longer: `WSN_Main(1e9, 50, [], 200)` at minimum

## Files Generated During Run

```
WSN7_MODULAR/
├── logs/
│   ├── combined_t0-10000_20260621_153000.csv
│   ├── sink_nodeRegistry_t0-10000_20260621_153000.csv
│   ├── sink_sensorRegistry_t0-10000_20260621_153000.csv
│   ├── attack_log_20260621_153000.csv
│   ├── local_features_20260621_153000.csv
│   └── sink_features_20260621_153000.csv
└── [simulation running...]
```

## See Also
- [README_MODULARIZATION](../README_MODULARIZATION.md) — Project overview
- [Utils README](../Utils/UTILS_README.md) — Configuration and base classes
- [GUI README](../GUI/GUI_README.md) — Visualization components
- [SN Documentation](../SN/SN_Documentation.md) — Sensor node tier
- [CH Documentation](../CH/CH_Documentation.md) — Cluster head tier
- [GWN Documentation](../GWN/GWN_Documentation.md) — Gateway tier
- [SINK Documentation](../SINK/SINK_Documentation.md) — Base station tier
