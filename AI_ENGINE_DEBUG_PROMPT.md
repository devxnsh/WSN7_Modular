# WSN7_MODULAR: Comprehensive AI Debugging & Enhancement Prompt

## SYSTEM OVERVIEW

### Purpose
This is a **Wireless Sensor Network (WSN) Multi-Hop Simulator** built in MATLAB using Object-Oriented Programming. It simulates a hierarchical network topology with cryptographic security, dual-radio architecture, token-based backbone transmission control, and real-time GUI visualization.

### Core Architecture

```
HIERARCHY (Bottom to Top):
┌─────────────────────────────────────────────────────────────────────┐
│  SINK (Tier 3, isSink=true)                                         │
│    └── WSN_Sink extends WSN_Gateway                                 │
│        ├── Terminal node: recruits GWNs, issues tokens              │
│        ├── Maintains nodeRegistry (all recruited nodes)             │
│        ├── Maintains sensorRegistry (timeseries data)               │
│        └── Never has a parent (immune to PARENT_INIT)               │ 
├─────────────────────────────────────────────────────────────────────┤
│  GWN - Gateway Node (Tier 3)                                        │
│    └── WSN_Gateway extends WSN_Node                                 │
│        ├── Dual-radio: radioAccess (HC12), radio (LoRa Backbone)    │
│        ├── FSM: BOOT → DISCOVERY → HANDSHAKE → SECURE               │
│        ├── Recruits other GWNs via 3-step handshake                 │
│        ├── Recruits CHs via Type 6 CH_CMD handshake                 │
│        ├── Token-gated backbone buffer for uplink transmission      │
│        ├── backboneBuffer[] holds msgs awaiting token               │
│        └── Delegates behavior to WSN_Gateway_Behavior               │
├─────────────────────────────────────────────────────────────────────┤
│  CH - Cluster Head (Tier 2)                                         │
│    └── WSN_ClusterHead extends WSN_Node                             │
│        ├── Single radio (Access)                                    │
│        ├── Joins GWN via 6.0→6.1→6.2 handshake (receives localKey)  │
│        ├── OR joins other CH via 6.0→6.4 (no localKey)              │
│        ├── Aggregates sensor data into 5.2 SENSOR_AGG               │
│        ├── Receives 5.3 ACK from parent                             │
│        └── Can recruit other CHs after verification                 │
├─────────────────────────────────────────────────────────────────────┤
│  SENSOR (Tier 1)                                                    │
│    └── WSN_Sensor extends WSN_Node                                  │
│        ├── Single radio (Access)                                    │
│        ├── Transmits Type 1 SENSOR_DATA to closest CH/GWN           │
│        ├── No handshake - instantaneous parent adoption             │
│        ├── Sleep mode between transmissions (low power)             │
│        └── Priority 0-2 based on sensor value change percentage     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## MESSAGE PROTOCOL SPECIFICATION

### Message Types (16 defined, 0-15)

| Type | Name | Radio | Purpose | Subtypes |
|------|------|-------|---------|----------|
| 0    | HELLO | Access | Neighbor discovery (broadcast) | 0=unverified, flag.bit2=verified |
| 1    | SENSOR_DATA | Access | Sensor→CH/GWN raw data | 0-3=priority levels |
| 2    | PANIC | Access | Emergency/Anomaly alert (flood/unicast) | 0=ANOMALY, 1=BATTERY_CRIT, 
2=INTRUSION, 3=LINK_LOSS |
| 5    | CH_HELLO | Both | CH routing updates / Data aggregation | 0=CH_HELLO, 1=FWD, 2=SENSOR_AGG, 3=AGG_ACK |
| 6    | CH_CMD | Access | CH↔GWN handshake | 0=CH_REQ, 1=CH_ACK, 2=KEY_ACK, 3=REJECT, 4=JOINOK, 5=INFO |
| 7    | CMD | Backbone | GWN↔GWN FSM handshake | 0=PARENT_INIT, 1=REQ_JOIN, 2=ACK_JOIN, 3=REJECT, 4=GLOBAL_KEY, 5=ENC_HELLO, 6=DOWN, 7=UP |
| 8    | TOKEN | Backbone | Backbone transmission control | 0=TOKEN_DOWN, 1=TOKEN_REQ, 2=PATH_COMPLETE, 3=TOKEN_KILL |
| 9    | HEARTBEAT | Both | Mesh keepalive | 0=HB_BOOT, 1=HB_DISC, 2=placeholder, 3=ENC_HB |
| 10-16 | RESERVED | - | Future: Alert, Census, Shutdown, Update | - |

### Message Frame Structure (Binary Serialized)

```
Byte 0:      [Type:4][Subtype:4]
Byte 1:      [Prio:2][TTL:4][Seq:2]  (packed)
Bytes 2-3:   Src (uint16 big-endian)
Bytes 4-5:   Dst (uint16 big-endian, 0xFFFF=broadcast, 0xFF00=multicast)
Byte 6:      PayloadLen
Byte 7:      [Flag:4][Checksum:4]
             Flag: bit1=Encrypted, bit2=Verified
Bytes 8+:    Payload (0-64 bytes)
```

### Special Addresses
- `0x0000` or `0xFFFF`: Broadcast (all in range)
- `0xFF00`: GWN multicast group (verified GWNs only)
- `0x0001-0xFFFE`: Unicast to specific node hexID

---

## TIMING & PHASES

### Simulation Timeline

```
t=0-21:    BOOT Phase
           - All nodes send HB_BOOT heartbeats
           - GWNs build neighbor tables via Hello/HB
           - Power scaling at 33%/66% boot progress if <3 neighbors

t=21-200:  DISCOVERY + RECRUITMENT Phase (SetupTime=200)
           - Sink enters SECURE immediately
           - GWNs transition BOOT→DISCO→HANDSHAKE→SECURE
           - 3-step handshake: PARENT_INIT → REQ_JOIN → ACK_JOIN → GLOBAL_KEY → ENC_HELLO
           - Verified GWNs join FF00 multicast group
           - Verified GWNs begin Hello broadcasts on Access radio

t=200+:    CH/SENSOR RECRUITMENT Phase
           - CHs initiate 3-step handshake with GWNs (6.0→6.1→6.2)
           - CHs can also join verified CHs (6.0→6.4)
           - Sensors start transmitting at t=350 (SENSOR_START_TIME)
           - Token system begins at t=200 (TOKEN_START_TIME)

t=300+:    STABLE TOPOLOGY
           - Network fully formed
           - Continuous sensor data flow
           - Token rotation for backbone transmission
```

### Key Timing Parameters (WSN_Config.m)

BootSteps = 21              % GWN boot duration (3*AggressiveInterval)
SetupTime = 200             % Hello discovery window
HelloInterval = 500         % Heartbeat interval (stable)
AggressiveInterval = 7      % Heartbeat interval (during boot/crazy)
HandshakeTimeout = 6        % Lock timeout for handshake
SENSOR_START_TIME = 350     % When sensors begin TX
TOKEN_START_TIME = 200      % When Sink starts issuing tokens
TOKEN_HOLD_TIME = 10        % TFs to hold token before passing
TOKEN_DEPRECATION_TIME = 100 % Max token validity
```

---

## DUAL-RADIO ARCHITECTURE (GWN Only)

### Radio Stack

```
GWN Node:
├── radio (WSN_Radio, type='BACKBONE')
│   └── LoRa radio for GWN↔GWN communication
│   └── Carries: Type 7 (CMD), Type 8 (TOKEN), Type 9 (ENC_HB), Type 5 (CH_HELLO relay)
│
└── radioAccess (WSN_Radio, type='ACCESS')
    └── HC12 radio for broadcast/CH communication
    └── Carries: Type 0 (Hello), Type 6 (CH_CMD), Type 9 (HB_BOOT/DISC)
    
CH/Sensor Nodes:
└── radio (WSN_Radio, type='BACKBONE' but functionally Access)
    └── Single radio for all communication
```

### Radio Locking
- Each radio has independent lock state (`handshakePartner`, `lockTimer`)
- During handshake, radio only accepts RX from `handshakePartner`
- Exceptions: ENC_HELLO (7.5), CH_HELLO (5.x) bypass lock
- Lock timeout triggers `radio.timeout()` → sends REJECT to orphaned partner

### Half-Duplex Enforcement
- `txScheduledThisTick`: If TX scheduled, RX blocked for that tick
- `lastActiveTime`: Prevents multiple actions per timestep
- Single `pendingRX` slot with priority arbitration

---

## TOKEN SYSTEM (Backbone Transmission Control)

### Purpose
Controls when GWNs can transmit buffered messages (CH_HELLO, SENSOR_AGG, etc.) on backbone radio. Prevents collision and ensures ordered uplink.

### Token Flow

```
SINK issues TOKEN_DOWN (8.0) to each child branch
    ↓
GWN receives token → enters STATE_TOKEN
    ↓
GWN holds token for TOKEN_HOLD_TIME (10 TFs)
    ├── Each tick: flush up to TOKEN_MAX_BUFFER_TX (3) msgs from backboneBuffer
    └── If buffer empty early: immediate pass
    ↓
GWN passes TOKEN_DOWN to children (round-robin)
    OR (if leaf): broadcasts PATH_COMPLETE (8.2)
    ↓
PATH_COMPLETE reaches SINK → SINK re-issues token on that path
```

### Buffer Management

```matlab
backboneBuffer = {}              % Cell array of {msg, bufferedAt}
BACKBONE_BUFFER_MAX = 20         % Max buffer size
BUFFER_TOKEN_REQ_THRESHOLD = 15  % Trigger TOKEN_REQ at 15+ msgs
BUFFER_PURGE_THRESHOLD = 19      % Purge oldest 5 at 19+ msgs
```

### Token-Exempt Messages
- Type 7 (CMD): FSM handshake
- Type 8 (TOKEN): Token protocol itself
- Type 9 (HB): Heartbeats
- Relay messages from child GWNs: Already encrypted, heading uplink

---

## CRYPTOGRAPHIC SECURITY

### Key Hierarchy

```
GLOBAL_AES_KEY (256-bit hex string in WSN_Message.GLOBAL_AES_KEY_HEX)
    └── Used for: GWN↔Sink, ENC_HELLO, ENC_HB, TOKEN messages
    └── Distributed via: 7.4 GLOBAL_KEY after ACK_JOIN

LOCAL_KEY (derived per GWN-CH pair)
    └── derivedLocalKey = XOR(globalKey[0:8], hexID bytes, parent bytes)
    └── Used for: CH→GWN communication (5.2 SENSOR_AGG)
    └── Distributed via: 6.1 CH_ACK payload
```

### Encryption Markers in GUI

```
[] = Global key only (ENC_HELLO, TOKEN_DOWN, ENC_HB)
{} = Local key only (Type 5 CH→GWN after handshake)
[{}] = Both (5.2 SENSOR_AGG from GWN to Sink)
```

---

## FSM STATE MACHINE (GWN)

### States (WSN_Config.m)

```matlab
STATE_BOOT = 0       % Initial boot, building neighbor table
STATE_DISCOVERY = 1  % Searching for parent
STATE_HANDSHAKE = 2  % Locked in handshake exchange
STATE_SECURE = 3     % Verified, can recruit
STATE_DORMANT = 4    % Low power (unused currently)
STATE_TOKEN = 5      % Holding token, flushing buffer
```

### GWN State Transitions

```
BOOT ────────────────────────────────────────────────────────────────────┐
  │ (t >= BootSteps && neighbors >= MinBootNeighbors)                    │
  ↓                                                                      │
DISCOVERY ───────────────────────────────────────────────────────────────┤
  │ (found parent candidate)                                             │
  │ SEND: PARENT_INIT (7.0)                                             │
  ↓                                                                      │
HANDSHAKE ───────────────────────────────────────────────────────────────┤
  │ RX: REQ_JOIN (7.1) → SEND: ACK_JOIN (7.2)                           │
  │ RX: GLOBAL_KEY (7.4) → derive localKey, SEND: ENC_HELLO (7.5)       │
  ↓                                                                      │
SECURE ──────────────────────────────────────────────────────────────────┤
  │ (token received)                                                     │
  ↓                                                                      │
TOKEN ───────────────────────────────────────────────────────────────────┘
  │ (buffer flushed, token passed)
  └→ SECURE
```

---

## DATA FLOW PATHS

### Sensor Data Path

```
SENSOR (Type 1) ────────────────────────────────────────────────────────┐
  │ Raw sensor value + battery + priority                               │
  ↓                                                                      │
CH (aggregates into sensorTable[]) ──────────────────────────────────────┤
  │ Periodically creates 5.2 SENSOR_AGG (7-10 TF period)               │
  │ Encrypted with localKey (if has one)                                │
  ↓                                                                      │
GWN (receives on Access radio) ──────────────────────────────────────────┤
  │ Decrypts, aggregates, re-encrypts with globalKey                   │
  │ Buffers in backboneBuffer (awaits token)                           │
  ↓                                                                      │
GWN (with token) → Parent GWN → ... → SINK ──────────────────────────────┤
  │ Terminates into sensorRegistry timeseries                          │
  └ Sends 5.3 AGG_ACK back down the chain                              │
```

### CH_HELLO Routing Path

```
CH (verified) ───────────────────────────────────────────────────────────┐
  │ Creates 5.0 CH_HELLO (encrypted with localKey)                     │
  ↓                                                                      │
Parent GWN ──────────────────────────────────────────────────────────────┤
  │ Receives, decrypts, extracts CH info                               │
  │ Creates 5.1 CH_HELLO_FWD (encrypted with globalKey)                │
  │ Buffers → awaits token                                             │
  ↓                                                                      │
SINK ────────────────────────────────────────────────────────────────────┘
  │ Terminates, updates nodeRegistry with CH info                      │
```

---

## GUI COMPONENTS

### Main Structure (WSN_GUI.m)

```
WSN_GUI
├── tabGroup
│   ├── tabTopo (Topology & Operations)
│   │   ├── WSN_GUI_Topology (node visualization, links, hull)
│   │   ├── WSN_GUI_GlobalEventFeed (packet log table)
│   │   ├── WSN_GUI_ControlDeck (inspector, commands)
│   │   └── WSN_GUI_NetworkState (network table)
│   │
│   └── tabSink (Sink Analytics)
│       └── WSN_GUI_SinkAnalytics (graphs, registry table)
```

### Control Deck (WSN_GUI_ControlDeck.m)

```
┌─────────────────────────────────────────────────────────────────────┐
│ TARGET: [Dropdown]                                                   │
├──────────────┬──────────────┬──────────────┬────────────────────────┤
│ INSPECTOR    │ BACKBONE     │ ACCESS       │ COMMANDS               │
│ (node info)  │ (LoRa log)   │ (HC12 log)   │ X: [___] Y: [___]     │
│              │              │              │ TxPwr: [___]           │
│              │              │              │ TTL: [___]             │
│              │              │              │ [TRIGGER FLOOD]        │
│              │              │              │ INTENSITY: [slider]    │
│              │              │              │ ATTACK MODE: [dropdown]│
│              │              │              │ [EXPORT CSV]           │
└──────────────┴──────────────┴──────────────┴────────────────────────┘
```

### Global Event Feed Columns

```
T | Frame | Inference | Type | Sub | Src | Dst | Len | Enc | Ver | CHK | Payload
```

---

## LOGGING ARCHITECTURE

### Log Levels

```
Global Event Feed (WSN_GUI_GlobalEventFeed)
└── Emitted via WSN_GUI_GlobalEventBus.emit(t, msg)
└── Shows serialized wire frames
└── Excludes: Type 0 (Hello), Type 9 (Heartbeat)

Node-Local Logs (node.log{})
└── All nodes maintain local log array
└── Format: "t=%d [EVENT] details..."

GWN Dual-Radio Logs
├── logBackbone{} - LoRa backbone events
└── logAccess{} - HC12 access events
```

### Log Entry Format

```
t=%d [EVENT_TYPE] [Direction] Type.Subtype Src→Dst details
Examples:
  t=50 [TX] PARENT_INIT -> 0A2B
  t=51 [RX] REQ_JOIN <- 0A2B RSSI=45.2
  t=52 [STATE] DISCO->SHAKE
  t=53 [TOKEN] Holding #42, flush 3 msgs
  t=54 [BUF] CH_HELLO 5.0 -> parent (awaiting token)
```

---

## PHYSICS MODEL (WSN_Physics.m)

### RSSI Calculation

```matlab
rxMean = txPower * (1 / (max(0.1, distance)^PathLossExp)) * 100
rxPhys = rxMean * exprnd(RayleighScale)  % Rayleigh fading

PathLossExp = 2.4          % Normal links (HC12)
PathLossExp_Backbone = 1.5 % GWN-GWN links (LoRa)
Sensitivity = 0.15         % Decode threshold
RayleighScale = 0.5        % Fading variance
```

### Adjacency Matrices

```
physAdj (NxN boolean) - Physical connectivity with Rayleigh fading
                        Links may appear/disappear each timestep
                        Used for: CH/Sensor links

stblAdj (NxN boolean) - Stable connectivity without fading
                        Consistent link state
                        Used for: GWN-GWN backbone links
```

---

## KNOWN ISSUES & DEBUG HINTS

### Issue Categories

1. **Timing Issues**
   - FSM timeline mismatch (comments say 0-21, reality is 21-200)
   - Race conditions in handshake timeout vs response arrival
   - Token deprecation timing drift

2. **State Machine Issues**
   - Orphaned nodes (handshake partner timeout without rejection)
   - Re-recruitment of already-recruited children
   - Retry count exceeding MAX_RETRIES

3. **Buffer Issues**
   - backboneBuffer overflow causing message loss
   - TOKEN_REQ spam when buffer stays full
   - Stale messages in buffer after token pass

4. **Radio Issues**
   - Half-duplex violation (TX+RX in same tick)
   - Lock leakage (lock not cleared on timeout)
   - Wrong radio used for message type

5. **Routing Issues**
   - CH_HELLO not reaching Sink (relay chain broken)
   - SENSOR_AGG ACK not returning (5.3 dropped)
   - PATH_COMPLETE not processed (token not reissued)

### Debug Checklist

```
□ Check node.state transitions in log
□ Verify handshakePartner cleared after handshake
□ Confirm radio.lockTimer decrement each tick
□ Validate message checksum before processing
□ Ensure buffer operations log properly
□ Check token issuedAt vs deprecationTime
□ Verify encryption flag matches message type
□ Confirm multicast group membership for FF00
□ Validate attack module initialization (if enabled)
□ Check malicious node behavior matches intensity
□ Verify ghost links and attack visualization
□ Confirm ground truth logging for security tests
```

---

## FILE STRUCTURE REFERENCE

```
WSN7_MODULAR/
├── WSN_Main.m                    # Simulation loop, message delivery
├── WSN_Config.m                  # All constants and parameters
│
├── WSN_Node.m                    # Base class (id, pos, battery, radio)
├── WSN_Gateway.m                 # GWN facade (delegates to Behavior/Messaging)
├── WSN_Gateway_Behavior.m        # FSM, recruitment, timing decisions
├── WSN_Gateway_Messaging.m       # Protocol handlers, packet creation
├── WSN_Sink.m                    # Terminal node (extends Gateway)
├── WSN_ClusterHead.m             # CH FSM and aggregation
├── WSN_Sensor.m                  # Sensor data transmission
│
├── WSN_Radio.m                   # Radio abstraction (TX/RX, locking)
├── WSN_RadioStack.m              # (Placeholder for multi-radio)
├── WSN_Message.m                 # Frame serialization/deserialization
├── WSN_Physics.m                 # RSSI, adjacency, distance
├── WSN_TopologyGenerator.m       # Initial node placement
├── WSN_Crypto.m                  # AES encrypt/decrypt
├── WSN_Protocol.m                # (Placeholder for protocol logic)
├── WSN_ProtocolFrames.m          # (Placeholder for frame types)
│
├── WSN_Attack.m                  # Attack simulation module
├── WSN_Attack_Demo.m             # Attack demonstration script
│
├── WSN_GUI.m                     # Main GUI coordinator
├── WSN_GUI_Topology.m            # Node circles, links, hull
├── WSN_GUI_GlobalEventFeed.m     # Packet log table
├── WSN_GUI_GlobalEventBus.m      # Event bus singleton
├── WSN_GUI_ControlDeck.m         # Inspector, commands, logs
├── WSN_GUI_NetworkState.m        # Network table
├── WSN_GUI_SinkAnalytics.m       # Sink-specific graphs
│
├── test_hello_diagnostic.m       # Diagnostic test for Hello messages
├── SPECIFICATION.md              # Protocol specification document
└── VERIFICATION_PHASE2.m         # Test/verification script
```

---

## ATTACK SIMULATION MODULE (WSN_Attack.m)

### Overview
The WSN_Attack module provides comprehensive network security testing capabilities by simulating various attack scenarios within the WSN simulation environment. This module enables controlled testing of network resilience and intrusion detection systems.

### Attack Types (8 categories, intensity 1-10)

| ID | Attack Type | Description | Behavior |
|----|-------------|-------------|----------|
| 0 | NONE | Normal operation | No malicious behavior |
| 1 | FLOODING | Hello Flood | Broadcasts excessive Hello messages to drain resources |
| 2 | PANIC_FLOOD | Fake emergency alerts | Injects false panic messages to cause network congestion |
| 3 | SYBIL | Multiple identity impersonation | Node claims multiple false identities |
| 4 | BLACKHOLE | Drop all data packets | Silently discards all received data messages |
| 5 | WORMHOLE | False tunnel | Creates deceptive low-latency path between distant nodes |
| 6 | GRAYHOLE | Selective forwarding | Drops packets selectively to avoid detection |
| 7 | DENIAL_SLEEP | Vampire attack | Prevents sensors from sleeping to drain battery |

### Intensity Scale

```
Intensity 1 (EASILY DETECTABLE):
├── Aggressive, constant behavior
├── Affects both Access and Backbone radios (GWN)
├── High packet rates, obvious attack patterns
└── Immediate detection by monitoring systems

Intensity 10 (HARD TO DETECT):
├── Subtle, intermittent behavior
├── Affects only one radio randomly (GWN)
├── Low attack rates mixed with normal behavior
└── Hard to distinguish from network issues
```

### Attack Architecture

```matlab
WSN_Attack (Static Class)
├── Data Storage (Persistent)
│   ├── isMalicious[N] - Boolean array of malicious nodes
│   ├── attackType[N] - Attack type per node (0-7)
│   ├── intensity[N] - Intensity level per node (1-10)
│   └── attackStartTime[N] - When attack begins
│
├── Attack State Tracking
│   ├── floodingBurstRemaining[N] - Packets left in flood burst
│   ├── sybilIdentities{N} - Multiple identities per node
│   ├── wormholeEndpoints[] - Paired wormhole nodes
│   └── denialLastWakeTick[N] - DoS cooldown tracking
│
├── Visual Tracking
│   ├── ghostLinks[] - Dropped message visualization
│   ├── dosTargets[] - DoS attack visualization
│   └── Color coding for each attack type
│
└── Ground Truth Logging
    └── Records all attack actions for IDS evaluation
```

### Key Methods

#### Configuration
```matlab
WSN_Attack.init(numNodes)                          % Initialize attack system
WSN_Attack.setMalicious(nodeIdx, type, intensity)  % Configure node as attacker
WSN_Attack.clearMalicious(nodeIdx)                 % Remove attack configuration
WSN_Attack.setWormholeEndpoints(nodeA, nodeB)      % Configure wormhole pair
```

#### Attack Decision Logic
```matlab
WSN_Attack.shouldDropBlackhole(nodeIdx, t)         % Blackhole drop decision
WSN_Attack.shouldDropGrayhole(nodeIdx, t)          % Selective drop decision
WSN_Attack.shouldSybilAdvertiseHello(nodeIdx, t)   % Sybil identity broadcast
WSN_Attack.shouldPanicFlood(nodeIdx, t)            % Emergency flood decision
WSN_Attack.shouldWormholeRelay(nodeIdx, t)         % Tunnel relay decision
```

#### Visual Support
```matlab
WSN_Attack.addGhostLink(src, dst, expiry, type)    % Track dropped messages
WSN_Attack.getGhostLinks(t)                        % Get active ghost links
WSN_Attack.addDoSTarget(src, dst, expiry)          % Track DoS targets
```

### Attack Color Coding (GUI Visualization)

```
Attack Message Colors:
├── Flooding:     Hot Pink [1.0, 0.0, 0.5]
├── Panic Flood:  Bright Red [1.0, 0.0, 0.0]
├── Sybil:        Orange [1.0, 0.5, 0.0]
├── Blackhole:    Dark Gray [0.2, 0.2, 0.2]
├── Wormhole:     Purple [0.6, 0.0, 1.0]
├── Grayhole:     Olive [0.7, 0.7, 0.3]
└── Denial Sleep: Bright Yellow [1.0, 1.0, 0.0]

Node Status Colors:
├── Malicious nodes: Bright attack-specific colors
├── Ghost links: Dashed red lines (dropped messages)
└── DoS targets: Double lines (vampire attacks)
```

### Attack Implementation Details

#### Hello Flood (Type 1)
- Generates excessive Hello broadcasts
- Configurable burst sizes based on intensity
- Tracks collision counts and timing
- Depletes neighbor resources

#### Panic Flood (Type 2)
- Injects false emergency messages (Type 2 PANIC)
- Uses all panic subtypes (ANOMALY, BATTERY_CRIT, INTRUSION, LINK_LOSS)
- Rate-limited by cooldown periods
- Causes network-wide flooding

#### Sybil Attack (Type 3)
- Creates multiple fake identities per node
- Staggered identity injection over time
- Single radio constraint (one identity active)
- Different tier types for each identity

#### Blackhole (Type 4)
- Silently drops all data packets
- Maintains normal routing advertisements
- Tracks drop statistics for analysis
- Perfect packet elimination

#### Wormhole (Type 5)
- Creates false low-latency tunnel between nodes
- Bandwidth and latency constraints
- Delayed packet queue simulation
- Deceptive routing optimization

#### Grayhole (Type 6)
- Selective packet dropping based on:
  - Message type priority
  - Source reputation
  - Random selection (intensity-based)
- Maintains plausible forwarding ratio

#### Denial of Sleep (Type 7)
- Prevents sensors from entering sleep mode
- Sends wake packets during sleep windows
- Cooldown management to avoid detection
- Battery drain acceleration

### Security Testing Integration

The attack module integrates with the WSN simulation to enable:

- **Ground Truth Recording**: All attack actions logged for IDS evaluation
- **Real-time Visualization**: Attack messages and affected nodes highlighted
- **Performance Impact**: Realistic resource consumption and timing effects
- **Detection Evasion**: Intensity-based stealth capabilities

### Attack Configuration via GUI

```
Control Deck → Attack Configuration:
├── Target Node Selection (dropdown)
├── Attack Mode Selection (8 types)
├── Intensity Slider (1-10 scale)
├── Wormhole Endpoint Pairing
└── Attack Activation Controls
```

### Attack Demo Environment (WSN_Attack_Demo.m)

#### Overview
Self-contained attack pattern training environment with **warmup-then-attack** design:
- **Warmup Phase**: 600 ticks of normal behavior (headless) establishes baseline
- **Attack Phase**: GUI appears at t=0, one node turns malicious
- **Standard GUI**: Same layout as WSN_GUI (stable, throttled updates)

#### Simulation Timeline

```
┌────────────────────────────────────────────────────────────────────┐
│                     WARMUP PHASE (Headless)                        │
│   t = 1 to 600: All nodes behave normally                          │
│   - Builds neighbor tables                                         │
│   - Establishes baseline traffic patterns                          │
│   - Logs observations for ML training (Phase=0)                    │
├────────────────────────────────────────────────────────────────────┤
│                     ATTACK PHASE (GUI Visible)                     │
│   t = 0 (displayed): Attack starts, GUI appears                    │
│   - Center node (AAAA) turns malicious                            │
│   - Neighbors observe attack patterns                              │
│   - Logs observations with IsAnomalous=1 (Phase=1)                │
└────────────────────────────────────────────────────────────────────┘
```

#### Demo Topology (Star Pattern)

```
                    ┌───────┐
                    │  0002 │ (Observer T2)
                    └───┬───┘
        ┌───────┐       │       ┌───────┐
        │  0001 │───────┼───────│  0003 │
        │  T1   │       │       │  T3   │
        └───────┘  ┌────┴────┐  └───────┘
                   │  AAAA   │ ← ATTACKER (center)
                   │   T3    │
        ┌───────┐  └────┬────┘  ┌───────┐
        │  0006 │───────┼───────│  0004 │
        │  T1   │       │       │  T2   │
        └───────┘       │       └───────┘
                    ┌───┴───┐
                    │  0005 │
                    │  T3   │
                    └───────┘
```

#### Standard GUI Layout

```
┌─────────────────────────────┬───────────────────────────────────────┐
│                             │          NETWORK STATE TABLE          │
│      NETWORK TOPOLOGY       │  ID | Tier | Batt | TX | RX | Status  │
│   (stable node positions,   │  ─────────────────────────────────────│
│    attack links animate)    │  AAAA  T3   95%    42   12  ATTACK    │
│                             │  0001  T1   87%     8   15  NORMAL    │
│                             │  ...                                  │
├─────────────────────────────┼───────────────────┬───────────────────┤
│                             │   NODE INSPECTOR  │   ATTACKER LOG    │
│    SIMULATION STATUS        │   [Dropdown: ID]  │   t=5 [ATTACK]... │
│                             │   Battery: 95%    │   t=10 [ATTACK]...│
│  Time: t=50                 │   TX Count: 42    │   t=15 [ATTACK]...│
│  Attack: FLOODING I=5       │   Neighbors: 6    │                   │
│  Attacker Batt: 95%         │                   │                   │
│  Avg Neighbor Batt: 85%     │   >>> ATTACKER    │                   │
└─────────────────────────────┴───────────────────┴───────────────────┘
```

#### Usage Examples

```matlab
% Interactive menu
WSN_Attack_Demo()

% Hello Flood, intensity 5
WSN_Attack_Demo(1, 5)

% Blackhole with 8 neighbors, export CSV
WSN_Attack_Demo(4, 7, 'neighbors', 8, 'export', true)

% Custom warmup and attack duration
WSN_Attack_Demo(3, 5, 'warmup', 800, 'duration', 500)
```

#### Node State (Inspectable)

Each node tracks:
- `battery`, `txPower` - Resource state
- `txCount`, `rxCount` - Traffic counters
- `lastTxTime`, `lastRxTime` - Timing
- `neighborTable` - Known neighbors with RSSI
- `log{}` - Full event log
- `msgTypeHist[16]` - Message type histogram

#### Training Data Export

```matlab
WSN_Attack_Demo(1, 5, 'export', true)
% Generates: attack_data_flooding_I5_YYYYMMDD_HHMMSS.csv
```

CSV columns:
| Column | Description |
|--------|-------------|
| Time | Simulation tick |
| Phase | 0=warmup, 1=attack |
| NeighborIdx | Observer node index |
| RxFromAttacker | Messages from attacker |
| RxTotal | Total messages received |
| AvgRSSI | Average signal strength |
| Battery | Current battery % |
| NeighborCount | Known neighbors |
| SpoofedIDs | Fake identities seen |
| IsAnomalous | Ground truth label |

---

## DIAGNOSTIC UTILITIES

### Test Scripts

#### test_hello_diagnostic.m
Comprehensive diagnostic utility for Hello message handling:

```matlab
% Purpose: Verify Hello broadcast delivery and processing
Features:
├── Message Creation Testing
│   ├── Hello frame structure validation
│   ├── Payload encoding/decoding verification
│   └── Destination address handling
│
├── Reception Logic Testing
│   ├── Broadcast filtering verification
│   ├── Neighbor table update testing
│   └── RSSI handling validation
│
├── Visualization Testing
│   ├── Message classification verification
│   ├── Color/line style assignment
│   └── GUI integration testing
│
└── Output Analysis
    ├── Detailed logging of all operations
    ├── Before/after state comparison
    └── Expected vs actual result validation
```

**Usage**: Run standalone to diagnose Hello message issues
**Output**: Formatted test results with pass/fail indicators

---

## ENHANCEMENT OPPORTUNITIES

### Performance
- Parallel message delivery (parfor in delivery loop)
- Lazy GUI updates (skip frames when not visible)
- Pre-allocated arrays instead of cell growth

### Protocol
- Implement Types 10-16 (Alert, Census, Shutdown, Update)
- Add message fragmentation for large payloads
- Implement proper ACK chains for reliability

### Security
- Token theft detection and recovery
- Node revocation broadcast
- Periodic key rotation

### GUI
- Real-time throughput graphs
- Packet trace visualization
- Export/import topology

### Logging
- Structured log format (JSON/CSV)
- Log filtering by type/node/time
- Log replay for debugging

---

## DEBUGGING QUERIES

When debugging, consider asking:

1. **State**: "What is node X's state at time T?"
2. **Parent**: "Who is node X's parent? Is it in children list of parent?"
3. **Lock**: "Is node X's radio locked? With whom? Timer value?"
4. **Buffer**: "How many messages in X's backboneBuffer? Types?"
5. **Token**: "Does X have a token? ID? Deprecation time?"
6. **Neighbor**: "What does X's neighborTable look like? Verified?"
7. **Message**: "What was the last message X sent/received? Checksum OK?"
8. **Attack**: "Is node X malicious? What attack type and intensity?"
9. **Security**: "Are there ghost links from X? DoS targets?"
10. **Behavior**: "Does X's packet drop rate match expected attack behavior?"

---

## PROMPT USAGE INSTRUCTIONS

When using this prompt with an AI debugging engine:

1. **Describe the symptom**: "Node 0A2B never becomes verified"
2. **Provide timeline**: "At t=50, it sent PARENT_INIT. At t=56, timeout."
3. **Include log snippets**: Paste relevant log entries
4. **State your hypothesis**: "I think the ACK_JOIN was lost due to fading"
5. **Ask specific questions**: "What could cause radio.lockTimer to not decrement?"

The AI will use this specification to:
- Map symptoms to likely causes
- Suggest log entries to check
- Propose code locations to inspect
- Recommend configuration changes
- Identify protocol violations

---

*Document Version: 1.1*
*Generated: 2026-02-19*
*Last Updated: 2026-03-18*
*Codebase: WSN7_MODULAR*

---

## Recent AI Engine Updates (2026-02-19)

Summary of changes applied by the AI assistant during the recent debugging session.

- **Clusterhead Topology**: `WSN_TopologyGenerator` now uses a grid+Poisson-like sampler with controlled perturbation to evenly distribute clusterheads inside the GWN hull while retaining a degree of randomness.
- **Clusterhead Dynamic Voltage Scaling (DVS)**: `WSN_ClusterHead` implements DVS when all verified neighbors are exhausted: it scales TX power by `CH_DVS_SCALE_FACTOR` (bounded by `CH_DVS_MAX_POWER`), clears rejected neighbor lists and retries recruitment. After `CH_DVS_MAX_SCALE_ATTEMPTS` the CH may enter `STATE_DORMANT`.
- **Sensor Orphan Mode & Extended Sleep**: `WSN_Sensor` now tracks consecutive failed recruitment attempts, enters an orphan extended-sleep mode (75% longer sleep, narrower wake window) when thresholds are exceeded, and broadcasts a LINK_LOSS panic when entering orphan mode.
- **Panic Messages (Type 2)**: Introduced `MSG_TYPE_PANIC` with subtypes (ANOMALY, BATTERY_CRIT, INTRUSION, LINK_LOSS) and severity levels. Panic messages include TTL, priority and a payload [originalSrc, sensorValue, battery, timestamp]. Sensors and CHs perform UID-based deduplication and TTL-aware forwarding. CHs prioritize and forward panics toward parent/sink.
- **Sensor RX Mode & Panic Handling**: Sensors default to `RX` while awake, can receive and forward panic messages, and use a trust-score stub (`getNeighborTrust`) to decide whether to forward.
- **Configuration Constants**: Added relevant constants to `WSN_Config.m` (panic types, DVS parameters, orphan sleep factors, etc.).
- **Trust Model Stub & Ideation**: Added a simple trust-score stub in sensors to be replaced by a full reputation model later; ideation on trust factors and Hello-encoded sleep scheduling documented separately in the debug notes.

Affected files (implemented):

- `WSN_TopologyGenerator.m` — Poisson/grid distribution + perturbation
- `WSN_ClusterHead.m` — DVS logic, panic handling queue
- `WSN_Sensor.m` — Orphan sleep mode, panic generation/forwarding, RX state
- `WSN_Config.m` — New constants for DVS, panic, orphan behavior

Notes & next steps:

- The changes are conservative and limited to CH/Sensor behavior and topology generation; they do not alter GWN backbone token logic.
- The trust model, Hello-based sleep scheduling hints, and any formal security policy for panic handling are documented as design notes and remain to be implemented.
- Recommend running a short topology + smoke simulation (low node count) to visually validate CH placement, sensor clustering, orphan behavior, and panic floods.

---

## Recent AI Engine Updates (2026-03-18)

Summary of changes applied during the attack system documentation and demo development session.

- **Attack Module Documentation**: Comprehensive documentation of `WSN_Attack.m` added, covering all 8 attack types (NONE, FLOODING, PANIC_FLOOD, SYBIL, BLACKHOLE, WORMHOLE, GRAYHOLE, DENIAL_SLEEP), intensity scaling, ground truth logging, and visual tracking features.

- **WSN_Attack_Demo Script**: Redesigned as lightweight, self-contained training environment:
  - **Independent of WSN_Main**: Own simulation loop and GUI
  - **Star topology**: Attacker at center, observers in ring
  - **Mixed tiers**: Neighbors can be any tier (Sensor, CH, GWN)
  - **No hierarchy/chaining**: Direct message exchange, simplified physics
  - **Training data export**: CSV with observation features per neighbor per tick
  - **Features logged**: RxFromAttacker, RSSI, Battery, MsgRate, SpoofedIDs, etc.
  - **Ground truth labels**: IsAnomalous flag for ML training

- **File Structure Updates**: Documentation updated to reflect new attack-related files

- **Debug Checklist Expansion**: Added security-specific debug items

Usage:

```matlab
% Interactive selection
WSN_Attack_Demo()

% Flooding attack with training export
WSN_Attack_Demo(1, 5, 'export', true)

% Batch data generation (headless)
WSN_Attack_Demo(4, 8, 'headless', true, 'neighbors', 10, 'duration', 500)
```
