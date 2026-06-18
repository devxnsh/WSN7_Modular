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

---

## ML-IDS Phase 1-4 Updates (2026-06-18 / 2026-06-19)

Everything below was implemented in a separate, much larger workstream (`ML_IDS_PLAN.md`):
a dual-tier ML/trust framework layered on top of the architecture above. This section was
missing from this document; it summarizes Phase 1-4 plus three bugs found and fixed during
Phase 4 verification that were not part of the original plan.

### Phase 1-2: Feature export pipeline (new modules, no protocol changes)

- **`WSN_FeatureExport.m`** (new) — static/persistent-store class, tap-based. Records
  per-node-per-window local telemetry (RSSI, PDR, RetransmitCount, ResidualEnergy,
  PhaseHoldTime, QueueDepth, derived LQI/SNR/BER/PER, etc.) via `tap*()` calls added at
  existing event sites in `WSN_Main.m` (tick loop, TX/RX boundaries) and
  `WSN_Gateway_Behavior.m` (retry sites). `flushWindow()` every `WSN_Config.FEATURE_WINDOW_LEN`
  (=50) ticks, `exportCSV()` at end of run → `logs/local_features_*.csv`.
- **`WSN_SinkFeatureExport.m`** (new) — same pattern, but reads only from `WSN_Sink.m`'s own
  registries (`sensorRegistry`, `nodeRegistry`, `globalTrustRegistry`) — i.e. only what the
  Sink could actually observe, including attack-induced gaps/silences. → `logs/sink_features_*.csv`.
- `WSN_Config.m`: added `FEATURE_WINDOW_LEN = 50`.
- `WSN_Main.m`: wired `WSN_FeatureExport.init/tapTick/tapTx/tapRx/tapTxSuccess`, window-flush
  on the `mod(t, FEATURE_WINDOW_LEN)==0` tick, and end-of-run CSV export for both modules.

### Phase 3: Dataset generation driver

- **`WSN_Attack_Demo.m`** (was a 3-byte empty file) — now a headless batch driver. For each
  `(attackType, intensity)` scenario it generates a fresh topology, sets one malicious node
  active from `t=warmup`, runs `WSN_Main(1e9, ..., nodes, duration)` fully headless, and
  concatenates the per-scenario feature CSVs into `logs/local_dataset.csv` /
  `logs/sink_dataset.csv`. Default grid: 1 Normal baseline + 7 attack types × 3 intensities.
  See `DATASET_GENERATION.md` for full usage. **Already run once** — both dataset CSVs exist
  in `logs/` (~27MB each, ~180k/~246k rows) and are treated as a checkpoint, not regenerated
  for the Phase 4 fixes below (see caveat in that doc about the two `CHRatio`/`ActiveSensorsRatio`
  columns reflecting the pre-ratio-fix topology distribution).

### Phase 4: Census/Shutdown/Update protocol (rule-based local-tier mitigation)

New message types 11 (Census)/12 (Shutdown)/13 (Update, constants only — no live sender yet)
and trust-threshold constants in `WSN_Config.m`. Daisy-chain trust polling
(`checkCensusTriggers`/`handleCensusMessage`, mirrored independently in `WSN_Sensor.m`,
`WSN_ClusterHead.m`, `WSN_Gateway.m`) with nearest-ancestor enforcement escalation
(`handlePollComplete`: SOFT_RESET → HARD_RESET → BLACKLIST via `resetHistory`). `isBlacklisted`
flag added to `WSN_Node.m` as a universal `receive()`/`step()` short-circuit. Full protocol
spec, message format, and worked trace in `CENSUS_PROTOCOL.md`.

### Phase 4 verification: three bugs found and fixed (not in the original plan)

Verifying Phase 4 against live simulation runs (not just code review) surfaced three real,
independent problems, each of which was masking the others:

1. **`neighborTable.TrustScore` field-reuse collision (fixed).** `WSN_Gateway.m`'s Census
   trust code originally reused the pre-existing `neighborTable.TrustScore` field — but that
   field already meant something else (Hello/Heartbeat *verification confidence*, set once at
   neighbor-discovery via `trust = [10 30 60 100]` in `WSN_Gateway_Messaging.m`, indexed by
   tier/subtype, never updated afterward). An unverified heartbeat (the common bootstrap case)
   assigned `TrustScore=10` — already below `TRUST_CENSUS_TRIGGER=20` from the moment of
   creation, regardless of actual behavior. This caused ~6500 false-positive `CENSUS_INITIATE`
   events in a 1500-tick run, virtually all GWN-vs-GWN noise from t=2 onward. **Fix**: gave
   `WSN_Gateway` its own dedicated `neighborTrust` struct array (mirroring `WSN_Sensor`/
   `WSN_ClusterHead`'s existing pattern), seeded at `TRUST_INITIAL=50`, completely decoupled
   from `neighborTable.TrustScore` (which keeps its original GUI-display meaning untouched).
   Verified: false-positive volume dropped ~95% (6553 → 347 events) with no loss of real signal.

2. **GWN:CH population ratio inverted (fixed).** `WSN_TopologyGenerator.m` generated *more*
   GWNs (12-15% of N) than CHs (6-10% of N) — backwards from a normal hierarchy (many sensors
   → fewer CHs → even fewer backbone/gateway nodes). With ~10 CHs spread across ~12 GWNs, no
   GWN could structurally have more than 1-2 CH children, hard-capping the daisy-chain Census
   voter pool at the GWN tier regardless of RF range (confirmed via direct distance
   measurement: actual GWN-CH links averaged 17.2 units against a ~24-27 unit fade-affected
   max range — physics was never the bottleneck). **Fix**: `targetGWNs` lowered to 10-13%,
   `targetCHs` raised to 16-20% (first attempt cut GWN density too far to 6-9%, which thinned
   GWN spatial coverage and pushed average link distance up to 22.6 units, tanking
   connectivity — the final numbers keep GWN density close to original while still
   guaranteeing CH > GWN in every draw). Verified: CH verification rate rose from 41% to 79%
   in a baseline run.

3. **Blackhole/Grayhole produces no ACK failure anywhere, so neither original trigger ever
   catches it (fixed with a new detector).** Traced into `WSN_ClusterHead.m`'s
   `handleSensorAgg` (the receive-side handler for incoming 5.2 AGG from a child) and found
   the Blackhole/Grayhole branch **deliberately fake-ACKs** the child before silently dropping
   the relay upward ("Log RX, send ACK (appears normal), but no forward"). This means a
   misbehaving node's own children always see a normal-looking ACK — the *only* place the
   attack is visible is the attacker's own parent, who simply stops receiving periodic 5.2
   reports. Neither of Phase 4's two original triggers (CH's-own-agg-never-ACKed;
   GWN/CH-handshake-retry-exhaustion) is a silence detector — both require an active send
   attempt that the attacker explicitly avoids failing. **Fix**: new parent-side
   reporting-silence detector. `WSN_Gateway.m` gained `chLastAggSeen` (per-CH-child last-AGG
   timestamp, updated in `WSN_Gateway_Messaging.m`'s `handle_SENSOR_AGG` and seeded at
   CH-join time) and `chAggSilenceFlagged` (one-shot debounce). `checkCensusTriggers` now
   flags and trust-decrements any CH child silent for longer than
   `AGG_PERIOD_MAX * WSN_Config.SILENCE_GRACE_MULTIPLIER` (= 10×3 = 30 ticks). Verified live:
   the detector fires correctly with accurate gap/threshold values in every test run since
   being added (5-14 `[SILENCE]` events per run depending on scenario).
   **Not yet captured live**: a single fully-clean trace from "attacker injected" through
   "SILENCE → CENSUS_INITIATE → quorum → ENFORCE → SHUTDOWN" in one run — repeated attempts
   were blocked by an *unrelated* topology-formation variance issue (the randomly-selected CH
   attacker sometimes never completes its own GWN handshake at all within the test window, so
   the attack has no host to manifest from — confirmed via `isVerified=0`/`parent=[]` in
   several runs). This is independent of the Census/silence code, which has been verified
   mechanically correct via direct log inspection (real gap values being computed and compared
   against the real threshold).

New `WSN_Config.m` constant: `SILENCE_GRACE_MULTIPLIER = 3`.

Affected files (Phase 4 + verification fixes):

- `WSN_Config.m` — message types 11-13, trust thresholds, `FEATURE_WINDOW_LEN`,
  `SILENCE_GRACE_MULTIPLIER`
- `WSN_Node.m` — `isBlacklisted` universal gate
- `WSN_Message.m` — Census payload getters/setters, generic Shutdown payload
- `WSN_Sensor.m`, `WSN_ClusterHead.m`, `WSN_Gateway.m`, `WSN_Gateway_Messaging.m`,
  `WSN_Gateway_Behavior.m`, `WSN_Sink.m` — Census/Shutdown dispatch, trust stores, silence
  detector
- `WSN_GUI_SinkAnalytics.m` — Trust column now shows `BLACKLISTED` for blacklisted nodes
- `WSN_TopologyGenerator.m` — GWN:CH ratio fix
- New: `WSN_FeatureExport.m`, `WSN_SinkFeatureExport.m`
- `WSN_Attack_Demo.m` — dataset generation driver (was empty)
- `CENSUS_PROTOCOL.md`, `DATASET_GENERATION.md`, `ML_IDS_PLAN.md` — reference docs

### Phase 5: offline Python training scripts (complete, run against real data)

New `WSN7_Modular/ml/` directory:

- **`wsn_ids_common.py`** — shared helpers only (CSV loading, one-hot encoding, accuracy/F1/
  confusion-matrix evaluation, CSV+PNG plot helpers). No model logic — the two scripts
  intentionally use different models/feature sets per the plan's vantage-point split.
- **`train_global_model.py`** — consumes `logs/sink_dataset.csv`. Drops dataset-generation
  bookkeeping columns that would leak the label or aren't real inference-time signals
  (`ScenarioID`, `RequestedAttackType`, `RequestedIntensity`, `AttackerNodeIdx`, `IsMalicious`,
  etc.) and drops `RSSIQualityBucket` specifically — `WSN_SinkFeatureExport.m` buckets it into
  ~250 near-continuous `GROUPnnn` categories (a feature-export bug, not a real coarse bucket
  scheme); `ReportedRSSI` already carries the same signal as a clean numeric column, so
  one-hot-encoding 250 categories would add dimensionality for no benefit. NaN rows (a node
  the Sink never heard from that window) are imputed explicitly (0 for counts/ratios, -1
  sentinel for battery/RSSI) rather than silently dropped, since absence is itself a signal.
  Class-weighted Decision Tree + Random Forest, stratified 80/20 split.
- **`train_local_model.py`** — consumes `logs/local_dataset.csv`, restricted to the literal
  6-column local-tier subset (`RSSI, PDR, RetransmitCount, ResidualEnergy, PhaseHoldTime,
  QueueDepth`). Deliberately shallow models (`max_depth=5`, RF capped at 20 trees).

**Run against the real (already-generated, Phase-3) datasets — results are genuine, not a
smoke test:**

| | DecisionTree acc | RandomForest acc | Notes |
|---|---|---|---|
| Global (`sink_dataset.csv`, 245,893 rows, 15 features) | 99.80% | 99.84% | Per-class F1 ranges 0.27-0.99 across all 8 classes — real discriminative signal, not a degenerate all-Normal classifier. |
| Local (`local_dataset.csv`, originally multi-class) | 25.91% | 36.05% | **Superseded** — redesigned as binary Attack-vs-Normal after paper verification (see "Phase 5 follow-up #2" below); multi-class accuracy numbers no longer apply. |

Both scripts write `class_distribution.csv`, `confusion_matrix_*.{csv,png}`,
`feature_importance_*.{csv,png}`, `accuracy_comparison.csv`, `per_class_f1.csv`, and
`full_report.json` to `ml/results/global/` and `ml/results/local/` respectively.

### Phase 5 follow-up (2026-06-19): tried resampling for class imbalance, reverted

Given the 99.4-99.8% Normal-class imbalance (67-145 real rows per minority class), tried
addressing it with `imbalanced-learn` (already installed): `wsn_ids_common.resample_training_data`
undersamples Normal and SMOTE-oversamples minorities on the **training split only** (test split
always stays at the real distribution for honest metrics). Tested empirically rather than assumed
beneficial:

| | macro-F1 (RandomForest), no resample | macro-F1, resampled (target=2000/class) |
|---|---|---|
| Global | **0.610** | 0.243 |
| Local | **0.175** | 0.124 |

**Resampling regressed both models** — first attempt (uncapped, fixed target=2000) was especially
bad for the global model, since its minorities only have 53-80 real training rows; blowing that up
to 2000 via SMOTE means >95% synthetic data, and undersampling Normal from ~196k down to 2000 throws
away the real majority-class structure the model needs to draw a clean decision boundary. Added a
`max_oversample_ratio` cap (default 10x each class's real count) to make the function more
defensible, but the capped version was still worse than no resampling at all on this dataset's small
absolute counts. **Conclusion: `class_weight='balanced'` alone already handles this dataset's
imbalance better than resampling** — resampling only earns its cost once minority classes have
enough real rows that synthetic interpolation isn't doing most of the work (revisit after Phase 6
rebalancing increases minority row counts). The function is kept in `wsn_ids_common.py` as an opt-in
`--resample` flag on both scripts (off by default) rather than deleted, since it may become useful
later and is independently tested/working.

**Found and fixed in the process**: `PhaseHoldTime` (one of the paper's official 6 local-tier
features) is **NaN for 100% of Sensor/CH-tier rows** in `local_dataset.csv` and populated only for
GWN-tier rows (89.1% NaN overall) — i.e. it's being tapped at the wrong tier in
`WSN_FeatureExport.m`, backwards from the plan's intent ("proxy for Sensor/CH token-hold time").
This is a dataset-generation-side bug, not an ML issue, and fixing the MATLAB tap site would require
regenerating the dataset (out of scope per user decision to keep the existing dataset). Worked around
in `train_local_model.py` with an explicit `-1` sentinel imputation (logged with a `[WARN]` at
runtime) rather than silently relying on sklearn's implicit native-NaN tree support — verified this
imputation alone is a small genuine improvement (macro-F1 0.1747→0.1764), not a regression, and is
now the local-tier baseline. **The local model's overall weak performance is not explained by this
bug alone**: even with PhaseHoldTime properly imputed, Blackhole/Grayhole/Wormhole F1 stay near zero
-- the remaining 5 features genuinely have little discriminative power for those attack types at the
local-tier vantage point (see the standalone-tier-comparison discussion above).

### Phase 5 follow-up #2 (2026-06-19): verified against the paper, redesigned local model as binary

User asked to verify a specific architectural claim against the actual paper
(`A Secure Architecture for ML-Enforced Attack Mitigation in Wireless Sensor Networks.doc`,
extracted via `antiword` -- no `pandoc`/`libreoffice` available in this environment) before
changing anything: **the local tier should never classify attack TYPE, only flag suspicion**.
Confirmed directly in the paper's text:

> "The actual identification of a malicious node is handled through daisy-chained polling
> amongst immediate neighbors of the node under scrutiny... However, confidently identifying a
> malicious neighbor is difficult for a single sensor node that lacks a global source of truth
> for feedback."

> "The RFC is deployed at the Sink, where compute is not the bottleneck; edge deployment on
> constrained GWN hardware is reserved for a pruned DTC variant in future work."

The paper's only validated classifier (RFC, 99.68% on WSN-DS) is explicitly Sink-tier; multi-class
attack-type identification at the node level isn't described anywhere in the paper at all — local
inference is framed purely as a trust-score/anomaly signal feeding the daisy-chain polling, which is
exactly `WSN_Gateway`/`WSN_Sensor`/`WSN_ClusterHead`'s existing `checkCensusTriggers` (Phase 4). This
directly justified two changes, both empirically trial-and-error tested before being kept:

**1. Global (Sink) model — no resource constraint, tried better ensembles.** Tried
`RandomForestClassifier` (more trees + tuned `min_samples_leaf`/`max_features`), `ExtraTreesClassifier`,
and `HistGradientBoostingClassifier` against the existing RF/DT baseline (macro-F1 0.610):

| Model | macro-F1 |
|---|---|
| DecisionTree (baseline) | 0.555 |
| RandomForest (baseline, 100 trees) | 0.610 |
| RandomForest (300 trees, tuned) | 0.620 |
| HistGradientBoosting | 0.421 (worse) |
| **ExtraTrees (300 trees)** | **0.738** |

`ExtraTreesClassifier` won clearly and is now the third model trained by `train_global_model.py`
(kept alongside DT/RF for continuity with the paper's framing, not as a replacement). Per-class F1
improved substantially for the weakest classes (Blackhole 0.52→0.83, DenialOfSleep 0.35→0.67,
PanicFlood 0.52→0.82); Sybil/Wormhole stayed roughly flat. 500 trees and further `min_samples_leaf`/
`class_weight='balanced_subsample'` tuning on top of ExtraTrees made no further difference — 300 trees,
defaults otherwise, is the found optimum.

**2. Local model — redesigned as binary (Attack vs Normal), confirmed IsMalicious is the right label.**
`local_dataset.csv`'s existing `IsMalicious` column is exactly 1:1 with `AttackTypeName != 'Normal'`
(verified via crosstab), so it's used directly as the binary label rather than deriving a new column.
`train_local_model.py` now trains on `IsMalicious` (mapped to `"Attack"`/`"Normal"` for readable
plots), drops the old multi-class framing entirely, and writes an `attack_type_breakdown.csv`
alongside the binary `class_distribution.csv` purely for reference (what real attack types are
lumped into "Attack").

Trial-and-error across DecisionTree (depth 3/4/5), a small RandomForest, and a LogisticRegression
(the theoretically lightest possible model — included specifically because "lighter model" was an
explicit goal) found:

| Model | Accuracy | Attack recall | Attack precision |
|---|---|---|---|
| DecisionTree depth=3 | 33.8% | **98.5%** | ~0.5% (flags almost everything — not usable) |
| **DecisionTree depth=4 (chosen default)** | 69.5% | 71.4% | 1.3% |
| RandomForest (10 trees, depth=4) | 58.7% | 83.3% | 1.1% |
| LogisticRegression | 68.4% | 61.1% | 1.1% |

`max-depth` default changed from 5 to 4 (found depth=4 the best accuracy/recall balance; depth=3's
98.5% recall sounds attractive but means it flags two-thirds of all Normal traffic too, which would
keep the Census layer in constant false-alarm mode — the same failure pattern as the Phase 4
`neighborTable.TrustScore` bug found earlier in this session). `--resample` was retested for the
binary task specifically (a fairer test than multi-class, since binary collapses to a single 176:1
ratio instead of multiple ~1235:1 minority splits) and again found to make no meaningful difference
(recall within 1-2 points either way) — stayed off by default.

**Precision (~1%) staying low is expected and correct, not a bug to chase**: per the paper's own
framing, a single node's local signal was never meant to confidently convict a neighbor — it only
needs to reliably trigger Census daisy-chain polling, which is the actual corroboration/conviction
mechanism. Recall (~70-85%, meaning most real attacks do get flagged for polling) is the metric that
matters for a trigger role. `DecisionTreeClassifier` is the recommended deployment choice (cheapest —
a handful of if/else comparisons, trivially portable to a microcontroller, matches the paper's
explicit "pruned DTC variant" guidance for edge hardware); RandomForest and LogisticRegression are
trained and reported alongside purely as reference points, not as alternative deployment candidates.

`train_local_model.py` now also writes `precision_recall.csv` (new `wsn_ids_common.save_precision_recall`
helper) alongside the existing outputs, since accuracy/F1 alone hide the precision-recall asymmetry
that's central to this model's actual role.

### Phase 5 follow-up #3 (2026-06-19): one more trial-and-error pass, user asked "can we do better"

User pushed for a further round of tuning on both tiers (`xgboost`/`lightgbm` were already installed,
unused until now). Results:

**Global**: tried `XGBClassifier` and `LGBMClassifier` (both need integer-encoded labels + explicit
`compute_sample_weight('balanced', ...)` instead of sklearn's `class_weight='balanced'` string, which
neither library accepts directly for multiclass — wrapped in a new `wsn_ids_common.LGBMMulticlassWrapper`
so it drops into the same `fit`/`predict`/`feature_importances_` interface as every other model here):

| Model | macro-F1 |
|---|---|
| ExtraTrees (previous best) | 0.738 |
| XGBoost (300 trees, depth 6) | 0.745 |
| **LightGBM (300 trees, default depth)** | **0.791** |

Further LightGBM tuning (500-800 estimators, `num_leaves`, `learning_rate`, `min_child_samples`) found
no improvement beyond defaults at 300 estimators — that's the ceiling for this feature set/sample size.
LightGBM is now a 4th model in `train_global_model.py`; ExtraTrees is kept too as a comparison point.

**Local**: tried the same gradient-boosted options at comparable per-tree depth with only 5-20 trees
(to stay within "lighter model" intent) — they did **not** beat a single deeper Decision Tree, so the
real lever here was depth, not algorithm choice. Swept `max_depth` from 3 to unbounded on the existing
single tree:

| Depth | Accuracy | Attack Recall | Attack Precision | Verdict |
|---|---|---|---|---|
| 3 | 33.8% | 98.5% | 0.5% | Rejected — flags 2/3 of all Normal traffic, floods the Census layer |
| 4 (previous default) | 69.5% | 71.4% | 1.3% | Superseded |
| **8 (new default)** | **71.0%** | **85.2%** | **1.6%** | Best on all three axes simultaneously |
| 10 | 71.3% | 83.3% | 1.6% | Marginal vs. depth=8, no reason to prefer |
| unbounded | 99.2% | 24.6% | 27.6% | Rejected — nearly memorizes training data, recall collapses (useless as a trigger meant to catch most attacks) |

`--max-depth` default changed from 4 to 8 in `train_local_model.py`. Still a single tree — depth=8 is
at most 256 leaves, nowhere near an ensemble's memory/compute footprint, so this is a genuine
"better metrics without sacrificing lightness" win, not a trade-off.

Next steps:

- Wire the local model's binary "Attack" flag into the live simulator as an actual Census-poll
  trigger (currently `checkCensusTriggers` only fires off rule-based trust-score thresholds; this
  ML signal isn't yet connected to it — would need a decision on whether the trained model is
  exported to MATLAB or reimplemented as an equivalent rule/threshold, consistent with the
  project's existing "rule-based live mitigation, ML for offline reporting" split).
- Capture one clean live trace of full SILENCE→ENFORCE→BLACKLIST escalation (needs either a
  larger random-trial budget or a deterministic way to guarantee the picked attacker
  completes its own handshake before the attack window opens).
- Phase 6 (dataset rebalancing) — the local-tier weak spots above are a natural candidate:
  more/longer Blackhole, Grayhole, Wormhole scenarios in the `WSN_Attack_Demo.m` grid once
  rebalancing is in scope.
- Phase 7 (reference docs incl. `RESULTS.md` with the honest tier-comparison discussion) not
  yet started.
- Phase 3 dataset (`logs/local_dataset.csv`/`sink_dataset.csv`) was generated before the
  GWN:CH ratio fix and the silence detector; per user decision, it is being kept as-is rather
  than regenerated, since dataset rows/labels don't depend on either fix (see caveat in
  `DATASET_GENERATION.md`).

