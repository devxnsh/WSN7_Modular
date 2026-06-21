# GUI Module — Visualization & User Interface

## Purpose
Contains all visualization components for the WSN7 simulator. Users interact with the network state through these GUI components during simulation.

## Files in This Folder

### Main GUI Framework
- **WSN_GUI.m** — Main GUI window, network visualization, coordinates all sub-components
  - Creates figure window, axes, UI controls
  - Updates network topology display each timestep
  - Integrates with control deck, event bus, analytics

### Sub-Components (Modular)
- **WSN_GUI_Topology.m** — Renders network topology on map
  - Node positions (colored by tier)
  - Link visualization
  - Attack indicators (ghost links, Sybil nodes, DoS)

- **WSN_GUI_NetworkState.m** — Network state table
  - Node list (ID, tier, parent, battery, status)
  - Neighbor count, verified status
  - Real-time sorting/filtering

- **WSN_GUI_GlobalEventBus.m** — Central event dispatcher
  - Collects TX/RX events from network
  - Broadcasts to all subscribers (visualizer, feed, etc.)
  - Filters by message type

- **WSN_GUI_GlobalEventFeed.m** — Message log table
  - Displays all TX/RX events chronologically
  - Packet inspector (drill down into payload)
  - Filter by type, source, destination
  - CSV export for offline analysis

- **WSN_GUI_SinkAnalytics.m** — Sink-side analytics dashboard
  - Node registry (route tree, battery levels)
  - Sensor timeseries graphs
  - Aggregation statistics
  - Offline node alerts

- **WSN_GUI_ControlDeck.m** — Control panel for simulation
  - Start/pause/resume buttons
  - Speed adjustment
  - Attack injection controls
  - Reset network

## Usage

### From WSN_Main.m
```matlab
% Create GUI at startup
gui = WSN_GUI(nodes, WSN_Config.FieldSize);

% Make visible at specified timestep
if startGUIAt > 0
    set(gui.fig, 'Visible', 'off');  % Start hidden
else
    set(gui.fig, 'Visible', 'on');   % Start visible
end

% Update each timestep
gui.updateNetwork(nodes, physAdj, t);
gui.drawPackets(visualLines, t);
gui.drawAttackVisuals(nodes, t);
drawnow limitrate;

% If GUI closed, break simulation
if ~ishandle(gui.fig)
    break;
end
```

### From Test Scripts
```matlab
% Create standalone GUI (no simulation)
nodes = WSN_TopologyGenerator.generateTopology(100, 1000);
gui = WSN_GUI(nodes, 1000);
gui.updateNetworkTable(nodes, 0);
gui.updateInspector(nodes, 0);
```

## Performance Notes

### Refresh Rates
- **Network Map**: Updated every `WSN_Config.ActiveRefresh` ticks (default 10)
- **Tables/Graphs**: Throttled to prevent slowdown
- **Message Feed**: Real-time updates (can buffer if too fast)

### Optimization Tips
- Use `drawnow limitrate` to cap refresh rate (~30 fps)
- Disable `drawAttackVisuals()` if not debugging attacks
- Use headless mode (`startGUIAt = 1e9`) for large networks
- Export logs to CSV instead of keeping GUI open for long runs

## Dependencies

### Requires:
- `WSN_Message.m` — Message type constants
- `WSN_Config.m` — Configuration (field size, colors, refresh rates)
- `WSN_Attack.m` — Attack visualization data

### Used by:
- `WSN_Main.m` — Main simulation loop
- Test scripts (VERIFICATION_PHASE2.m, etc.)

## Extension Points

### Adding New Visualization Component
1. Create `WSN_GUI_YourComponent.m` in this folder
2. Inherit from `handle` class
3. Implement `update()` method for refresh
4. Register with `WSN_GUI` main component
5. Call `addpath('GUI')` to make accessible

### Example: Custom Thermal Map
```matlab
% In GUI/ folder, create WSN_GUI_ThermalMap.m
classdef WSN_GUI_ThermalMap < handle
    properties
        parent       % Reference to main WSN_GUI
        axes         % Thermal map axes
    end
    
    methods
        function obj = WSN_GUI_ThermalMap(parent)
            obj.parent = parent;
            obj.axes = axes(parent.fig);
        end
        
        function update(obj, nodes, t)
            % Recompute and display thermal data
        end
    end
end

% In WSN_GUI.m:
thermalMap = WSN_GUI_ThermalMap(obj);
```

## Folder Organization

```
GUI/
├── GUI_README.md                      ← This file
├── WSN_GUI.m                          ← Main framework
├── WSN_GUI_Topology.m                 ← Network map
├── WSN_GUI_NetworkState.m             ← Node table
├── WSN_GUI_GlobalEventBus.m           ← Event dispatcher
├── WSN_GUI_GlobalEventFeed.m          ← Message log
├── WSN_GUI_SinkAnalytics.m            ← Analytics dashboard
└── WSN_GUI_ControlDeck.m              ← Control panel
```

## See Also
- [Simulator README](../Simulator/SIMULATOR_README.md) — How to run WSN_Main
- [README_MODULARIZATION](../README_MODULARIZATION.md) — Project structure overview
