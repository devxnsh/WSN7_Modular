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
├── WSN_GUI.m                     # Main GUI coordinator
├── WSN_GUI_Topology.m            # Node circles, links, hull
├── WSN_GUI_GlobalEventFeed.m     # Packet log table
├── WSN_GUI_GlobalEventBus.m      # Event bus singleton
├── WSN_GUI_ControlDeck.m         # Inspector, commands, logs
├── WSN_GUI_NetworkState.m        # Network table
├── WSN_GUI_SinkAnalytics.m       # Sink-specific graphs
│
├── SPECIFICATION.md              # Protocol specification document
└── VERIFICATION_PHASE2.m         # Test/verification script
```

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

*Document Version: 1.0*
*Generated: 2026-02-19*
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

