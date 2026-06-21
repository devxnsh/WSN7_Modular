% GATEWAY (GWN/TIER 3) — FUNCTION INDEX
% Maps functions to WSN_Gateway.m, WSN_Gateway_Behavior.m, WSN_Gateway_Messaging.m
%
% LEGEND: Line numbers reference WSN_Gateway.m unless noted [BEHAVIOR] or [MESSAGING]
%
% =====================================================
% DUAL-RADIO MANAGEMENT
% =====================================================
% Property: radio | WSN_Radio (LoRa, backbone FSM)
% Property: radioAccess | WSN_RadioStack (HC12, access network)
% Property: logBackbone | cell (LoRa radio logs)
% Property: logAccess | cell (HC12 radio logs)
%
% Backbone Radio: GWN-to-GWN communication (STABLE, no fading)
%   - FSM protocol (PARENT_INIT, REQ_JOIN, ACK_JOIN, etc.)
%   - Token-based collision avoidance (Type 8)
%   - Heartbeat (Type 9) unicast to parent
%
% Access Radio: CH/SN recruitment (FADING subject)
%   - Broadcasts HELLO (discovery, Type 0)
%   - Handshake (Type 6: CH_CMD)
%   - Aggregation (Type 5.2 RX / 5.3 TX)

% =====================================================
% CH CHILDREN MANAGEMENT
% =====================================================
% Property: chChildren | array of CH IDs (direct recruited children)
% Property: secondaryChChildren | array of CH IDs (learned via CH_INFO relay)
% Property: chLocalKeys | containers.Map (hexID -> key mapping)
% Property: chLastAggSeen | struct array (id, lastTime for silence detection)
% Property: chAggSilenceFlagged | array of silent CH IDs (for census)
% Property: pendingChildren | struct array (awaiting ENC_HELLO, timeout 15 TF)
% Property: chChildrenAnnouncedToParent | array (last announced set)
% Property: pendingChHelloForward | cell (buffered CH_HELLO relays if parent unavailable)
% Property: chDvsLastCheckTime | uint32 (last DVS power adjustment)

% =====================================================
% MAIN LOOP (step)
% =====================================================
% FUNCTION: step(t, physAdj, allNodes) | See WSN_Gateway.m
%   Returns: array of generated messages
%
%   - Backbone FSM step (parent recruitment)
%   - Access radio step (CH/SN discovery & handshake)
%   - Sensor aggregation processing (5.2 from children)
%   - Panic queue processing
%   - Census triggers & finalizations
%   - Heartbeat transmission (backbone & access)
%   - Token passing (backbone collision avoidance)

% =====================================================
% RECEIVE (Protocol Dispatcher)
% =====================================================
% FUNCTION: receive(msg, t, rssi) | See WSN_Gateway.m, line ~[TBD]
%   Returns: WSN_Message (response) or empty
%
%   - Type 0 (HELLO): Access radio, discover CH/SN
%   - Type 2 (PANIC): High priority, forward to parent
%   - Type 5 (5.2/5.3): Aggregation, merge & forward
%   - Type 6 (CH_CMD): Handshake (recruitment)
%   - Type 7 (CMD): Backbone FSM messages
%   - Type 8 (TOKEN): Token passing (collision avoidance)
%   - Type 9 (HEARTBEAT): Parent/child connection keepalive
%   - Type 11 (CENSUS): Voting & enforcement
%   - Type 12 (SHUTDOWN): Escalation enforcement

% =====================================================
% BACKBONE FSM (GWN-to-GWN)
% =====================================================
% FUNCTION: [FSM Step Logic] | See WSN_Gateway_Behavior.m
%   State Machine:
%     BOOT → DISCOVERY (await verified GWN parent)
%     DISCOVERY → HANDSHAKE (upon GWN found)
%     HANDSHAKE → SECURE (REQ_JOIN → ACK_JOIN)
%     SECURE → VERIFIED (maintain parent, forward data)
%     VERIFIED → SECURE (monitor parent loss, re-parent)
%
%   Messages: Type 7 CMD (PARENT_INIT, REQ_JOIN, ACK_JOIN, etc.)
%   Heartbeat: Type 9 ENC_HB (encrypted, to parent)
%   Token: Type 8 (collision avoidance on backbone)

% =====================================================
% CH RECRUITMENT & HANDSHAKE (Access Radio)
% =====================================================
% CH_REQ (6.0): CH → GWN (wants to join)
% CH_ACK (6.1): GWN → CH (accept, include local key)
% KEY_ACK (6.2): CH → GWN (confirm key, encrypted)
% CH_REJECT (6.3): GWN → CH (reject recruit)
% CH_INFO (6.5): CH → GWN (announce recruited child)
%
% See WSN_Gateway_Behavior.m for recruitment FSM
% See WSN_Gateway_Messaging.m for message creation/parsing

% =====================================================
% SENSOR AGGREGATION (Type 5)
% =====================================================
% FUNCTION: processSensorAggregation(t) | See WSN_Gateway_Behavior.m
%   - Receive 5.2 SENSOR_AGG from CH children (encrypted with localKey)
%   - Merge into GWN-level sensorTable
%   - Send 5.3 ACK to acknowledge
%   - Aggregate & forward to parent GWN
%   - Retry logic: 5 TF intervals, max 3 retries

% =====================================================
% REPORTING-SILENCE DETECTION (Phase 4 follow-up)
% =====================================================
% FUNCTION: checkReportingSilence(t) | See WSN_Gateway_Behavior.m
%   - Track chLastAggSeen (last 5.2 arrival per CH)
%   - Detect silence > 3 × AGG_PERIOD
%   - Automatically initiate CENSUS_POLL on silent child
%   - Catches Blackhole/Grayhole attacks (invisible to retry logic)

% =====================================================
% PANIC QUEUE (HIGH PRIORITY)
% =====================================================
% FUNCTION: processPanicQueue(t) | See WSN_Gateway_Behavior.m
%   - Separate high-priority queue for PANIC messages (Type 2)
%   - Forward to parent (unicast) or broadcast if orphan
%   - Deduplication: keep last 200 UIDs
%   - TTL decrement, preserve UID for dedup chain

% =====================================================
% TRUST MANAGEMENT & CENSUS (Phase 4)
% =====================================================
% FUNCTION: checkCensusTriggers(t) | See WSN_Gateway_Behavior.m
%   - For each distrusted neighbor (trust < 30):
%     * Create CENSUS_POLL_INITIATE
%     * Track in censusActivePolls
%   - Finalize timed-out polls (10 TF)
%   - Compute verdict (quorum ≥50% YES = malicious)
%   - Enforce: issue SHUTDOWN to direct children

% =====================================================
% CH DISCOVERY DYNAMIC VOLTAGE SCALING (DVS)
% =====================================================
% FUNCTION: adjustAccessPower(t) | See WSN_Gateway_Behavior.m
%   - Monitor chChildren count
%   - Check every DVS_CHECK_INTERVAL TFs
%   - If no growth: boost controlPower (HC12 access radio)
%   - Goal: Extend HELLO/CH_ACK range to attract recruits

% =====================================================
% HEARTBEAT MANAGEMENT
% =====================================================
% Type 9 (MSG_TYPE_HB)
%   - DISCOVERY HEARTBEAT: Broadcast to announce GWN presence
%   - ENCRYPTED HEARTBEAT (9.3): Unicast to parent, encrypted
%   - CHILD HEARTBEAT: Multicast (FF00) to verified CH children
%
% Frequency: Every ~10-20 TFs (configurable)
% Purpose: Keep parent->child link alive, trigger re-parent on loss

% =====================================================
% TOKEN PASSING (Backbone Collision Avoidance)
% =====================================================
% Type 8 (MSG_TYPE_TOKEN)
%   - TOKEN_DOWN (8.0): Parent sends token down to child
%   - TOKEN_REQ (8.1): Child requests token
%   - PATH_COMPLETE (8.2): Acknowledgement of token receipt
%
% Purpose: Prevent routing loops, coordinate transmission order
% See WSN_Token module (if separated) or Radio module

% =====================================================
% HELLO RECEPTION & NEIGHBOR TABLE (Access Radio)
% =====================================================
% FUNCTION: handleHelloReception(msg, t, rssi) | WSN_Gateway.m
%   Returns: (void, updates neighborTable)
%
%   - Extracts tier, battery, neighborCount from HELLO payload
%   - Creates or updates neighbor table entry
%   - Logs new neighbors, silent update for existing
%   - Verifies sender authenticity

% =====================================================
% PENDING CH_HELLO BUFFER (Relay Fix)
% =====================================================
% Issue: CH_HELLO relay drops if GWN lacks parent
% Solution: Queue in pendingChHelloForward, flush when parent acquired
%
% FUNCTION: flushPendingChHelloForward(t) | See WSN_Gateway_Messaging.m
%   - Called when parent acquired or parent changed
%   - Replay queued CH_HELLO messages to parent
%   - Clear buffer on successful send
%   - Cap size (PENDING_CH_HELLO_MAX = 30) to prevent unbounded growth

% =====================================================
% LOGGING & FEATURE EXPORT
% =====================================================
% Dual-radio logging:
%   - logBackbone: LoRa radio events (FSM, token, heartbeat)
%   - logAccess: HC12 radio events (discovery, handshake, aggregation)
%
% Feature export (ML-IDS Phase 1-2):
%   - WSN_FeatureExport.tapTick(nodeIdx, node, t)
%   - WSN_FeatureExport.tapTx(nodeIdx, msg, t)
%   - WSN_FeatureExport.tapRx(nodeIdx, rssi, msg, t)

% =====================================================
% PROPERTY SUMMARY (Quick Reference)
% =====================================================
% Backbone FSM State:
%   state, targetParent, lastParent, bootTime, handshakePartner
%
% CH Recruitment:
%   chChildren, secondaryChChildren, chLocalKeys
%   chLastAggSeen, chAggSilenceFlagged, pendingChildren
%   chChildrenAnnouncedToParent, pendingChHelloForward
%
% Trust & Census:
%   neighborTrust, censusActivePolls, censusSeenPolls, resetHistory
%
% DVS:
%   controlPower, chDvsLastCheckTime, chDvsLastChildCount, chDvsScaleCount
%
% Aggregation:
%   sensorTable, nextAggTX, pendingAgg, aggRetryCount
%
% Panic Queue:
%   panicQueue, seenPanicUIDs
%
% Radios:
%   radio (backbone), radioAccess (access)
%   logBackbone, logAccess

% =====================================================
% END OF GWN_INDEX
% =====================================================
