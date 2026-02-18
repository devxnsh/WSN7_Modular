# WSN Multi-Hop Architecture - Consolidated Specification

## Protocol Timeline (CORRECTED)

- **t=0-20**: GWN boot/discovery phase
- **t=21-200**: GWN FSM recruitment phase (BootSteps + SetupTime)
  - Phase 2: Hello collection (SetupTime=200)
  - GWN FSM continues recruiting other GWNs during this window
  - **Not t=0-21 as previously stated** - FSM STARTS at t=21, ENDS around t=200
- **t=200+**: CH/Sensor recruitment opens
- **t=300+**: Stable topology

## Message Types

| Type | Name | Purpose | Subtypes |
|------|------|---------|----------|
| 0 | HELLO | Neighbor discovery (verified GWNs only) | Verified/Unverified Via Flag |
| 1 | SENSOR_DATA | Sensor data transmission | 0=SENSOR_REPORT |
| 2 | Relayed Sensor Data | 1 | 1 |
| 3 | Panic | 1 | 1 |
| 4 | Critical | 1 | 1 |
| 5 | DATA_AGG | Aggregated data routing |1 = CH_HELLO, 2=CH_DATA, 3=DATA_ACK |
| 6 | CH_Comm | CH-GWN/CH-CH communication | 0=CH_REQ, 1=CH_ACK, 2=KEY_ACK, 3=CH_REJECT, 4=CH_JOINOK, 5=CH_INFO, 6=CH_DOWN, 7=CH_UP |
| 7 | CMD | GWN-GWN handshake & routing | 0=PARENT_INIT, 1=REQ_JOIN, 2=ACK_JOIN, 3=PARENT_REJECT, 4=GLOBAL_KEY, 5=ENC_HELLO, 9=CMD_DOWN, 10=CMD_UP |
| 8 | TOKEN | Backbone transmission control | 0=TOKEN_DOWN, 1=TOKEN_REQ, 2=PATH_COMPLETE |
| 9 | HEARTBEAT |Neighbour Awake Discovery| 0 - HB_BOOT, 1=HB_DISC, 2 =ENC_HB|
| 10 | Alert | 1 | 1 | 
| 11 | Census | Polling Amongst Nodes to Find Attacker | 0 = POLL_INITIATE, 1=POLL_YES, 2= POLL_NO, 3 = POLL_COMPLETE(Reset Sent Uplink)| 
| 12 | Shutdown | Reset/Kill/Blacklist Any Node. | 0= SOFT RESET, 1=HARD RESET, 2=BLACKLIST | 
| 13 | Update | Update Weights/Balances Of Trust Scores of Nodes | 1 | 
| 14 | Resv | 1 | 1 | 
| 15 | Resv | 1 | 1 | 
| 16 | Resv | 1 | 1 | 

## Key Architectural Components

### Dual-Radio Stack
- **Backbone (LoRa)**: Type 7 (CMD), Type 8 (TOKEN), Type 9 (HB), Type 10 (CH_HELLO) - GWN-GWN FSM and routing
- **Access (HC12)**: Type 0 (Hello), Type 1 (SENSOR_DATA) - Broadcast to CH/Sensors, only if verified
Type 5,6,
### Sink Identity Anonymity
- The Sink's identity must remain unknown to most nodes (e.g., via tier abstraction: all GWNs are tier 3, Sink identified only by `isSink` property).
- This prevents targeted attacks and maintains hierarchical opacity.

### CMD Routing Extensions (Type 7)
- **CMD_DOWN (Subtype 9)**: Downlink messages from Sink/GWN to specific GWN's CH children.
  - Payload encrypted with GlobalKey + LocalKey; intended GWN decrypts and identifies target CH.
  - Triggers Type 6 CH_DOWN to the identified CH.
- **CMD_UP (Subtype 10)**: Uplink routing from CHs.
  - CH_UP (Type 6 Subtype 7) from CHs is rewritten as CMD_UP and transmitted uplink.
- **Propagation**: CH_DOWN can propagate to second-degree children or be upsent as CH_UP → CMD_UP.
- **CMD_UP Termination**: Sink terminates CMD_UP and verifies routing using payload information.

### CH Recruitment and Routing
- **Recruitment Clearance**: All CHs are cleared for further recruitment, even without local key, to prevent orphan CHs.
- **Two-Step Handshake**: CH performs handshake with closest CH using CH_REQ + CH_JOINOK.
  - After sending CH_JOINOK, parent CH sends CH_INFO to its parent.
  - CH_INFO forwarded: If parent is CH, forwards directly; if parent is GWN, encrypted in local key. GWN encrypts in GlobalKey before sending uplink.
- **CH_HELLO Generation**: At GWN, CH_HELLO (Type 10) generated for newly recruited CH.

### GWN Status Tiers
- GWNs maintain status tiers for all recruited nodes (GWN ring: parent-child forwarding):
  - 0: Self
  - 1: Parent
  - 2: Child
  - 3: 2nd-degree child
  - 4+: Further degrees
- Status displayed by number of [ ] brackets in GUI only (e.g., [[node]] for 2nd-degree).

### 3-Step CH-GWN Handshake (Type 7 Subtypes 6-8)
1. **CH_REQ** (subtype 6): CH→GWN on normal radio
2. **CH_JOIN** (subtype 7): GWN→CH with local key
3. **KEY_ACK** (subtype 8): CH→GWN encrypted confirmation

### Verified-Only Broadcasting
- GWN broadcasts Type 0 (Hello) on HC12 ONLY if `isVerified=true`
- SetupTime=200 provides discovery window
- FSM lock (Backbone) does NOT block HC12 broadcasts

### Backbone Radio Buffer Specifications
- Immediate transmission of buffered messages is forbidden.
- Without a token, GWNs can only forward messages from child to parent.
- Token-required transmissions: All except Type 7 (CMD), Type 8 (TOKEN), Type 9 (HEARTBEAT).

### TOKEN Specifications (Type 8)
- **8.0 TOKEN_DOWN**: Initiated by Sink to children (priority=0 default, 1 for high-priority requests).
  - Upon receipt: Hold for 10 timeframes, transmit all buffered messages uplink to parent.
  - After 10 TFs or if buffer empties: Forward 8.0 TOKEN_DOWN to children.
  - If no more children after transmission: Broadcast 8.2 PATH_COMPLETE on FF00 (GWN Backbone multicast).
  - Sink can issue new TOKEN_DOWN on completed paths.
- **8.1 TOKEN_REQ**: Broadcast by GWN on Backbone if buffer >90% full (intended for Sink).
  - Sink responds with 8.0 TOKEN_DOWN (priority=1) on the requester's chain.
  - Upon 8.1 broadcast, any existing 8.0 TOKEN_DOWN in the branch (not the whole network) is deprecated; node which has it must not pass it down. Spamming 8.1 without appropriate data delivery to sink results in flagging.
- **8.2 PATH_COMPLETE** All GWNs can ignore this broadcast except Sink, which must now resend another 8.0 ON THE PATH. Sink must verify that PATH_COMPLETE actually comes from a really terminal GWN (refer to registry) + actually contains transmission. PATH_COMPLETE will be received at sink earlier than the rest of the messages since rest messages undergo forwarding. If the actual messages are not received, the 8.2 is flagged.
- **High-Priority Handling**: Nodes with buffer >85% full can uptransmit on high-priority 8.0; others must pass it down.
- **Exempt Messages**: Type 7 (CMD), Type 8 (TOKEN), Type 9 (HEARTBEAT) transmit without token.

### Security Considerations for TOKEN System
- **Encryption & Authentication**: All Type 8 messages must be encrypted with GlobalKey and include HMAC for integrity. Only verified GWNs can decrypt/process; compromised nodes cannot forge valid tokens.
- **Token Theft (8.0)**: Include token ID and sequence number in payload. Sink tracks active tokens; invalid or duplicate IDs are ignored. Compromised GWN stealing 8.0 triggers Sink to invalidate the token and issue a new one, preventing autoprompt of 8.1.
- **8.1 Spam**: Rate-limit 8.1 broadcasts (e.g., max 1 per 50 timeframes per node). Sink verifies requester's buffer status via encrypted query before responding. Spamming deprecates tokens but doesn't cause failure if Sink ignores invalid requests.
- **8.2 Spam**: PATH_COMPLETE broadcasts include path hash and token ID. Sink verifies against active tokens; invalid spams are logged and ignored. Only Sink processes 8.2, minimizing disruption.
- **General Mitigations**: Node revocation via Sink broadcast; periodic key rotation; anomaly detection for unusual token patterns.

### Multi-Hop Topology Emergence
- CHs join GWN (parent) via 3-step handshake
- CHs broadcast HELLO_VERIFIED (Type 0.2) to nearby Sensors
- Sensors discover and join CH (tier 2) preferred over GWN (tier 3)
- Result: Sensor→CH→GWN→Sink multi-hop chains

### Recruitment Filtering
- **Sink**: Recruits only GWN (tier 3)
- **GWN**: Recruits only GWN (tier 3)
- **CH**: Recruits only GWN (tier 3)
- **Sensor**: Prefers CH (tier 2), falls back to GWN (tier 3)

## Config Parameters

```matlab
% Timing
BootSteps = 21              % GWN boot duration
SetupTime = 200             % Hello discovery window (after verification)
HelloInterval = 500         % Heartbeat interval

% Thresholds
CH_GWN_RSSI_Threshold = 0.5
Sensor_CH_RSSI_Threshold = 0.5
Sensor_GWN_RSSI_Threshold = 0.4

% Tiers (No Sink tier - identified by isSink property)
TIER_SENSOR = 1
TIER_CH = 2
TIER_GWN = 3
```

## Identified Issues (Code NOT Modified Per User Request)

### Issue 1: Message Type 8 Not Defined
- **Current**: CH_HELLO being sent as Type 7 (CMD subtype)
- **Required**: Separate Type 8 for CH_HELLO messages
- **Impact**: GWN→Sink routing updates need distinct message type
- **Fix Location**: WSN_Config.m - Add `MSG_TYPE_CH_HELLO = 8;`

### Issue 2: Recruitment Filters - FIXED ✓
- ~~GWN SECURE state was filtering tier==1 (Sensors)~~
- **Status**: Fixed - now filters tier==3 (GWNs)
- File: WSN_Gateway_Behavior.m line 223

### Issue 3: Re-recruitment of Children - FIXED ✓
- ~~GWN could re-recruit already-recruited children~~
- **Status**: Fixed - children filtered from valid candidates
- File: WSN_Gateway_Behavior.m lines 228-230

### Issue 4: Retry Count Exceeded - FIXED ✓
- ~~Retry count could exceed MAX_RETRIES (5/4 observed)~~
- **Status**: Fixed - guard checks retryCount >= MAX_RETRIES before new attempt
- File: WSN_Gateway_Behavior.m lines 254-262

### Issue 5: FSM Timeline Documentation - NEEDS FIX
- **Current**: Comments state FSM "0-21" or "completes at t=21"
- **Correct**: FSM runs t=21 to ~t=200 (SetupTime window)
- **Fix Locations** (search for "21" in behavior/gateway files)
  - WSN_Gateway_Behavior.m: Check phase comments
  - SPECIFICATION comments need timeline correction

### Issue 6: Neighbor Table Formatting - FIXED ✓
- Header/data alignment was mismatched
- **Status**: Fixed with proper %4s|%5.1f|%1d format
- File: WSN_Physics.m lines 144-145, 200-201

## Verification Checkpoints

✅ **Done**:
- Dual-radio architecture operational
- Hello messages working with payload extraction
- Recruitment filtering (tier==3) enforced
- GWN re-recruitment prevention
- Retry count limiting
- Neighbor table display alignment
- Sink tier transparency (tier 3, identified by isSink)

❌ **TODO (Code Changes Required)**:
1. Add MSG_TYPE_TOKEN = 8, MSG_TYPE_CH_HELLO = 10 to WSN_Config.m
2. Update message routing for Types 8, 10 in WSN_Main.m
3. Add Type 10 handler to WSN_Sink.m for CH_HELLO reception
4. Update FSM timeline comments (t=21-200, not 0-21)
5. Update CH join handlers to use Type 10 instead of Type 7.6-8
6. Implement TOKEN system for Backbone radio buffering

## Expected Log Output (Proof of Correctness)

```
t=21 [GWN] BOOT→DISCO (BootSteps complete)
t=50 GWN_A [DISCO] PARENT_INIT → Sink
t=100 GWN_A [RX] ACK_JOIN from Sink → isVerified=true
t=102 GWN_A [BCAST] Hello on HC12 (verified)
t=150 GWN_B [RX] Hello from GWN_A, added to neighbors
t=200 [END SetupTime] GWN FSM recruitment complete
t=221 CH_X [INIT] CH_REQ → GWN_A (type 7.6)
t=222 CH_X [RX] CH_JOIN (type 7.7) from GWN_A
t=223 CH_X [SECURE] parent=GWN_A
t=227 CH_X [BCAST] HELLO_VERIFIED
t=250 Sensor_Y [RX] HELLO_VERIFIED, join CH_X
```

## Data Transmission and Aggregation System (Ideation)

### Sensor Data Reporting
- **Periodicity**: Sensors transmit data every 3-7 timeframes (randomized at startup) over Access Radio (unencrypted).
- **Target Selection**: Prefer verified CHs; fallback to GWNs if no CH available or GWN signal >> CH signal.
- **Message**: Type 1, Subtype 0.
  - Fields: TTL, TX_DROP, Payload: {Sensor Value, Battery Value}.
  - Priority: 0 (default), 1 (>15% value change), 2 (>25% change). 3-4 reserved.
- **Reception Limit**: CH/GWN accepts only one Type 1 message per timeframe (priority-based arbitration).
- **Parent Adoption**: Instantaneous (no handshake); can change per transmission.

### Aggregation and Routing
- **CH Aggregation**:
  - Collects sensor data, groups by RSSI.
  - Sends aggregated data as Type 5, Subtype 2 (CH_DATA) encrypted in LocalKey to parent GWN.
- **GWN Aggregation**:
  - Receives CH_DATA, aggregates further, re-encrypts in GlobalKey, sends uplink as Type 5.2.
- **Forwarding**:
  - GWNs blindly forward Type 5 messages to parent.
  - Sink terminates Type 5, maintains routing table + time series data (sensor values, battery levels).
- **ACK Mechanism**:
  - CH→GWN 5.2 transmission acknowledged by GWN→CH 5.3 (ACK).
  - Payload: Fragment ID (for fragmented 5.2 messages; each fragment ACKed separately).
  - Ensures reliable data delivery.
  - If ACK is not received for any fragment of 5.2 it is retransmitted with higher priority status.
- **Second-Degree CH Forwarding**:
  - Verified second-degree CHs (grandchildren) can forward 5.2 to their parent CH.
  - Parent CH responds with 5.3 ACK, encapsulates in LocalKey, and sends to GWN.
  - Enhances multi-hop data reliability.

### Power Management
- **Sensors**: Sleep mode (low drain), transmit only periodically.
- **CHs**: Efficient battery draining, aggregate/send data.
- **GWNs**: Frequent recharging to prevent depletion.


This system enables scalable sensor data collection with aggregation, ACKs for reliability, and multi-hop forwarding.

**Key Invariants**:
- No node learns Sink identity via tier (all tier 3, identified by `isSink`).
- Sink anonymity maintained for security.
- CMD routing supports targeted CH communication via decryption and rewriting.
