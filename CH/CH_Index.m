% CLUSTER HEAD (CH/TIER 2) — FUNCTION INDEX
% Maps each behavior/handler to its location in WSN_ClusterHead.m
%
% LEGEND:
%   Line numbers reference WSN_ClusterHead.m
%   Format: FunctionName | Line | Description | Status

% =====================================================
% PROPERTIES & INITIALIZATION
% =====================================================
% Property: state | Line 6 | FSM state (BOOT, DISCOVERY, SECURE, HANDSHAKE)
% Property: isVerified | Line 7 | Verified after KEY_ACK exchange
% Property: localKey | Line 8 | Local key from parent GWN (empty if CH parent)
% Property: retryTarget | Line 11 | Current GWN/CH being recruited
% Property: retryCount | Line 12 | Attempts for current target
% Property: rejectedGWNs | Line 13 | List of rejected GWNs (cleared periodically)
% Property: rejectedCHs | Line 14 | List of rejected CHs
% Property: handshakePartner | Line 14 | Current handshake lock
% Property: isQualifiedToRecruit | Line 15 | True if GWN-anchored (can recruit CHs)
% Property: sensorTable | Line 21 | Aggregated sensor data from children
% Property: aggPeriod | Line 22 | Fixed random 7-10 TFs (set after verification)
% Property: nextAggTX | Line 23 | Next scheduled 5.2 TX time
% Property: pendingAgg | Line 24 | Pending 5.2 message awaiting ACK
% Property: seenPanicUIDs | Line 32 | Dedup list (circular, max 100)
% Property: neighborTrust | Line 35 | Trust scores per neighbor
% Property: censusActivePolls | Line 38 | Active consensus polls
% Property: chLastAggSeen | Line 89 | Last 5.2 aggregation time per CH child
% Property: chAggSilenceFlagged | Line 90 | CH IDs with reporting silence
% Property: pendingChildren | Line 93 | CHs awaiting ENC_HELLO (timeout 15 TF)
% Property: chDvsLastCheckTime | Line 80 | Last DVS power adjustment check
% Property: chDvsLastChildCount | Line 81 | Child count at last DVS check

% Constructor
% WSN_ClusterHead() | Line 44 | Default constructor, sets tier=2, state=BOOT

% =====================================================
% MAIN LOOP (step)
% =====================================================
% FUNCTION: step(t, physAdj, ~) | Line 59 | Main decision loop each timestep
%   Returns: array of generated messages
%
%   - Checks census triggers & finalizes timed-out polls
%   - Handles attacks: FLOODING, PANIC_FLOOD, DENIAL_SLEEP
%   - Phase 2 HELLO burst transmission
%   - Handshake timeout check & recovery
%   - Sensor aggregation (5.2) processing
%   - CH recruitment FSM (DISCOVERY, SECURE, HANDSHAKE states)

% FUNCTION: updatePhysics(t) | Line 52 | Power management
%   Returns: (void, updates obj.battery)
%
%   - CHs do NOT sleep - always awake
%   - Applies idle cost (0.5 units/TF)

% =====================================================
% RECRUITMENT FSM (State Machine)
% =====================================================
% FUNCTION: [FSM Decision Logic] | Lines 149-261 | Recruitment state machine
%   Returns: (messages to TX, state transitions)
%
%   STATE: BOOT
%     → Transition to DISCOVERY
%
%   STATE: DISCOVERY
%     → Find verified GWN
%     → Start recruitment with first target
%
%   STATE: SECURE (no active recruitment)
%     → Find best verified GWN or CH
%     → Enter HANDSHAKE state
%     → Check retries & rejection cooloff
%
%   STATE: HANDSHAKE (waiting for ACK/REJECT)
%     → Monitor lock timer (20 TF timeout)
%     → Wait for response message

% FUNCTION: findBestVerifiedGWN() | Line 547 | Find closest verified GWN
%   Returns: uint16 (node ID) or empty
%
%   - Filters verified neighbors by tier (3=GWN)
%   - Excludes rejected GWNs
%   - Sorts by RSSI (descending, closest first)

% FUNCTION: findBestVerifiedCH() | Line 569 | Find closest verified CH
%   Returns: uint16 (node ID) or empty
%
%   - Filters verified neighbors by tier (2=CH)
%   - Excludes rejected CHs
%   - Sorts by RSSI (descending, closest first)

% FUNCTION: getNeighborTier(id) | Line 591 | Get tier of neighbor
%   Returns: uint8 (0=unknown, 2=CH, 3=GWN)

% =====================================================
% HANDSHAKE MESSAGES (Type 6: CH_CMD)
% =====================================================
% FUNCTION: createCHREQ(dst, t) | Line 601 | Create 6.0 CH_REQ message
%   Returns: WSN_Message object
%   - Sent to potential parent (GWN or CH)
%   - TTL: 1 (unicast)
%   - No payload

% FUNCTION: createCHACK(sender, t) [RECEIVE] | Line 433 | Process 6.1 CH_ACK from GWN
%   Returns: (void, updates localKey, state, parent)
%   - Extract local key from payload (16 bytes)
%   - Refresh lock
%   - Send 6.2 KEY_ACK encrypted with local key
%   - Mark verified, qualified to recruit
%
% FUNCTION: createKEY_ACK(dst, t) | Line 616 | Create 6.2 KEY_ACK message
%   Returns: WSN_Message object
%   - Response to CH_ACK
%   - Payload: echo of local key
%   - Flag: encrypted (bit 0 = 1)
%   - TTL: 1

% FUNCTION: handleCHREJECT(msg, t) | Line 480 | Process 6.3 CH_REJECT
%   Returns: (void, updates parent, state, rejectedList)
%   - Purge parent if sender was parent
%   - Remove sender from children if was child
%   - Add to rejected list (GWN or CH)
%   - Transition back to SECURE

% FUNCTION: createCHREJECT(dst, t) | Line 632 | Create 6.3 CH_REJECT message
%   Returns: WSN_Message object
%   - Sent to CH trying to join (if not qualified or locked)
%   - TTL: 1

% FUNCTION: handleCHREQ(msg, t) | Line 343 | Process 6.0 CH_REQ (as parent)
%   Returns: WSN_Message (6.4 JOINOK or 6.3 REJECT)
%   - Check if qualified to recruit (GWN-anchored only)
%   - Check lock (single active handshake only)
%   - If accept: send JOINOK, add to children
%   - If accept: send 6.5 CH_INFO to own parent

% FUNCTION: handleCHJOINOK(msg, t) | Line 389 | Process 6.4 CH_JOINOK (as child)
%   Returns: (void, updates parent, state, isQualifiedToRecruit)
%   - Mark verified
%   - Set parent
%   - Clear lock
%   - Set isQualifiedToRecruit = false (CH-anchored, cannot recruit others)

% FUNCTION: createCHJOINOK(dst, t) | Line 647 | Create 6.4 CH_JOINOK message
%   Returns: WSN_Message object
%   - Sent by parent CH to joining CH
%   - TTL: 1
%   - No payload

% FUNCTION: createCHINFO(recruitedID, t) | Line 662 | Create 6.5 CH_INFO message
%   Returns: WSN_Message object
%   - Sent to parent GWN when recruiting a child CH
%   - Payload: [RecruitedID(2), ParentID(2)]
%   - Flag: encrypted if localKey available
%   - TTL: 1

% FUNCTION: handle_CH_INFO(msg, t) | Line 417 | Process 6.5 CH_INFO (as parent)
%   Returns: (void, forwards to parent)
%   - Forward CH_INFO up-tree to own parent

% FUNCTION: handleTimeout(t) | Line 518 | Handshake timeout recovery
%   Returns: WSN_Message (6.3 CH_REJECT to partner)
%   - Send rejection to timed-out partner (orphan guard)
%   - Clear lock
%   - Set backoff timer (2-5 TF)

% =====================================================
% SENSOR AGGREGATION (Type 5: CH_HELLO)
% =====================================================
% FUNCTION: processSensorAggregation(t) | Line 969 | Main aggregation loop
%   Returns: array of WSN_Message objects
%
%   - Check pending 5.2 retry logic (5 TF intervals, max 3 retries)
%   - Create new 5.2 message if period triggered
%   - Handle attacks (BLACKHOLE/GRAYHOLE drops)

% FUNCTION: createSensorAgg(t) | Line 1052 | Create 5.2 SENSOR_AGG message(s)
%   Returns: array of WSN_Message objects (fragmented)
%
%   - Sort sensors by RSSI (strongest first)
%   - Fragment into max 10 sensors per fragment
%   - Payload: [TotalFrags(1), FragIdx(1), NumSensors(1), {SensorEntry} x N]
%   - Encrypt with localKey if available
%   - Mark first fragment as pending for ACK tracking

% FUNCTION: handleSensorAgg(msg, t, rssi) | Line 1132 | Process 5.2 SENSOR_AGG (as parent)
%   Returns: WSN_Message (5.3 ACK)
%
%   - Handle attacks (BLACKHOLE/GRAYHOLE fake-ACK stealth)
%   - Send 5.3 ACK with fragment info
%   - Merge sensor data into parent's sensorTable
%   - Forward to parent on next aggregation cycle

% FUNCTION: mergeSensorAgg(msg, t, rssi) | Line 1197 | Merge 5.2 data into table
%   Returns: (void, updates sensorTable)
%
%   - Parse fragmented sensor entries
%   - Update or add to sensorTable
%   - Use timestamp to prefer newer values

% FUNCTION: handleAggACK(msg, t) | Line 1245 | Process 5.3 CH_ACK (pending ACK)
%   Returns: (void, clears pending, updates retry state)
%
%   - Extract acked fragment from payload
%   - Remove from pendingFragments list
%   - Clear pendingAgg if all fragments ACKed

% FUNCTION: createAggACK(dst, seq, t, fragIdx, totalFrags) | Line 1274 | Create 5.3 ACK
%   Returns: WSN_Message object
%
%   - Payload: [TotalFrags(1), AckedFragIdx(1)]
%   - TTL: 1
%   - Echo back sequence number

% FUNCTION: handleSensorData(msg, t, rssi) | Line 938 | Process Type 1 SENSOR (from SN)
%   Returns: (void, updates sensorTable)
%
%   - Parse sensor payload [Value(2), Battery(1)]
%   - Update or add entry to sensorTable
%   - Log new sensors, silent update for existing

% =====================================================
% PANIC HANDLING (HIGH PRIORITY, Type 2)
% =====================================================
% FUNCTION: handlePanicMessage(msg, t, rssi) | Line 1304 | Process inbound PANIC
%   Returns: WSN_Message (forward) or empty
%
%   - Deduplicates by UID (keeps last 100)
%   - Checks TTL (drops if ≤0)
%   - Extracts panic type, severity, original source
%   - Forwards to parent (unicast) or broadcasts if no parent
%   - High severity broadcasts if orphan

% FUNCTION: createPanicForward(origMsg) | Line 1360 | Forward PANIC with TTL decrement
%   Returns: WSN_Message object
%
%   - Decrements TTL
%   - Preserves UID and payload
%   - Changes source to forwarder
%   - Destination: parent or broadcast

% FUNCTION: getPanicTypeStr(panicType) | Line 1380 | Convert panic type to string
%   Returns: string (e.g., 'ANOMALY', 'LINK_LOSS')

% =====================================================
% HELLO RECEPTION & NEIGHBOR TABLE
% =====================================================
% FUNCTION: handleHelloReception(msg, t, rssi) | Line 689 | Process HELLO broadcast
%   Returns: (void, updates neighborTable)
%
%   - Extracts tier, battery, neighborCount from payload
%   - Creates or updates neighbor table entry
%   - Logs new neighbors, silent update for existing

% =====================================================
% TRUST MANAGEMENT (Rule-Based, Phase 4)
% =====================================================
% FUNCTION: getNeighborTrust(neighborID) | Line 741 | Query trust for neighbor
%   Returns: double (0.0-100.0, default 50.0)

% FUNCTION: updateNeighborTrust(neighborID, delta) | Line 750 | Update trust delta
%   Returns: (void, updates neighborTrust)

% =====================================================
% ML-IDS CENSUS PROTOCOL (Phase 4)
% =====================================================
% FUNCTION: checkCensusTriggers(t) | Line 763 | Initiate/finalize polls
%   Returns: array of WSN_Message objects
%
%   - For each distrusted neighbor (trust < 30):
%     * Create CENSUS_POLL_INITIATE (Type 11)
%     * Track in censusActivePolls
%
%   - Finalize timed-out polls (age ≥ 10 TF)
%   - Compute verdict (quorum ≥50% YES = malicious)
%   - Forward to parent or enforce if direct child

% FUNCTION: handleCensusMessage(msg, t) | Line 821 | Process CENSUS variants
%   Returns: WSN_Message (vote, complete, or enforcement action)
%
%   - CENSUS_POLL_INITIATE: Extract suspect, vote based on local trust
%   - CENSUS_POLL_YES/NO: Aggregate votes to poll
%   - CENSUS_POLL_COMPLETE: Forward or enforce (if suspect is child)

% FUNCTION: handlePollComplete(msg, t) | Line 869 | Enforce census verdict
%   Returns: WSN_Message (SHUTDOWN) or forward
%
%   - Extract suspect, verdict, votes
%   - If suspect is direct child:
%     * Issue SHUTDOWN with escalation (SOFT → HARD → BLACKLIST)
%     * Track resetHistory for escalation levels
%   - Else: Forward verdict to parent

% FUNCTION: handleShutdownMessage(msg, t) | Line 914 | Process enforcement
%   Returns: (void)
%
%   - SHUTDOWN_SOFT_RESET: Clear trust/polls, keep tree structure
%   - SHUTDOWN_HARD_RESET: Reset state, force re-handshake
%   - SHUTDOWN_BLACKLIST: Set isBlacklisted, cease operations

% =====================================================
% RECEIVE (Protocol Dispatcher)
% =====================================================
% FUNCTION: receive(msg, t, rssi) | Line 263 | Process inbound message
%   Returns: WSN_Message (response) or empty
%
%   - Drops if blacklisted
%   - Type 0 (HELLO): Broadcast, populate neighborTable
%   - Type 1 (SENSOR): From children, aggregate
%   - Type 2 (PANIC): High priority, forward up-tree
%   - Type 5 (5.2/5.3): Aggregation messages
%   - Type 6 (CH_CMD): Handshake protocol
%   - Type 11 (CENSUS): Distributed polling
%   - Type 12 (SHUTDOWN): Enforcement
%
%   - All RX requires valid checksum

% FUNCTION: handleCHCMD(msg, t, rssi) | Line 322 | Dispatch CH_CMD (Type 6)
%   Returns: WSN_Message (response) or empty
%
%   - Route by subtype:
%     * 6.0 CH_REQ: handleCHREQ
%     * 6.1 CH_ACK: handleCHACK
%     * 6.3 CH_REJECT: handleCHREJECT
%     * 6.4 CH_JOINOK: handleCHJOINOK
%     * 6.5 CH_INFO: handle_CH_INFO

% =====================================================
% HELPER: Encryption
% =====================================================
% FUNCTION: encryptPayload(payload, key) | Line 729 | Simple XOR encryption
%   Returns: encrypted payload
%
%   - XOR each byte with repeating key
%   - Used for 6.2 KEY_ACK and 5.2 SENSOR_AGG

% =====================================================
% ATTACK INTEGRATION
% =====================================================
% - WSN_Attack.isMaliciousNode(id) : boolean
% - WSN_Attack.getAttackType(id) : int (FLOODING, PANIC_FLOOD, BLACKHOLE, etc.)
% - WSN_Attack.getFloodingBurstCount(id, t) : int
% - WSN_Attack.createFakePanicBeacon(id, hexID, t) : WSN_Message
% - WSN_Attack.getDenialOfSleepTargets(id, neighborTable, t) : array of IDs
% - WSN_Attack.createSpuriousPacket(srcID, dstID, t) : WSN_Message
% - WSN_Attack.shouldDropBlackhole(id, t) : boolean
% - WSN_Attack.shouldDropGrayhole(id, t) : boolean

% =====================================================
% FEATURE EXPORT (ML-IDS Phase 1-2)
% =====================================================
% - WSN_FeatureExport.tapTick(nodeIdx, node, t) : collect time-series features
% - WSN_FeatureExport.tapTx(nodeIdx, msg, t) : log TX event
% - WSN_FeatureExport.tapRx(nodeIdx, rssi, msg, t) : log RX event
