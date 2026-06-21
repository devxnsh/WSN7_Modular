% SENSOR NODE (SN/TIER 1) — FUNCTION INDEX
% Maps each behavior/handler to its location in WSN_Sensor.m and SN_Behavior.m
%
% LEGEND:
%   Line numbers reference WSN_Sensor.m unless noted as [BEHAVIOR]
%   Format: FunctionName | Line | Description | Status

% =====================================================
% PROPERTIES & INITIALIZATION
% =====================================================
% Property: sensorPeriod | Line 4 | Fixed random 3-7 TFs per sensor (constant)
% Property: nextSensorTX | Line 5 | Next scheduled sensor TX time (state)
% Property: sensorValue | Line 6 | Current sensor reading 0-100 (state)
% Property: prevSensorValue | Line 7 | Previous sensor value for drift (state)
% Property: isOrphaned | Line 10 | Orphan mode flag (state)
% Property: orphanCheckCount | Line 11 | Consecutive failed targets (counter)
% Property: orphanThreshold | Line 12 | Orphan entry threshold (5 failures)
% Property: radioState | Line 15 | 'RX'/'TX'/'SLEEP' (state)
% Property: lastPanicTime | Line 18 | Last panic TX time (timestamp)
% Property: panicCooldown | Line 19 | Min TFs between panics (500)
% Property: seenPanicUIDs | Line 20 | Dedup list (circular, max 50)
% Property: neighborTrust | Line 23 | Trust scores per neighbor (struct array)
% Property: censusActivePolls | Line 26 | Active consensus polls (struct array)
% Property: censusSeenPolls | Line 27 | Seen poll UIDs (dedup, max 50)

% Constructor
% WSN_Sensor() | Line 31 | Default constructor, sets tier=1, period random

% =====================================================
% MAIN LOOP (step)
% =====================================================
% FUNCTION: step(t, physAdj, ~) | Line 69 | Main decision loop each timestep
%   Returns: array of generated messages
%
%   - Checks census triggers & finalizes timed-out polls
%   - Handles attacks: FLOODING, PANIC_FLOOD, DENIAL_SLEEP
%   - Phase 2 HELLO burst transmission
%   - Sensor data TX with target selection & priority
%   - Anomaly detection & panic generation
%   - Orphan mode management
%   - Battery critical detection

% FUNCTION: updatePhysics(t) | Line 41 | Sleep/wake cycling
%   Returns: (void, updates obj.isAwake, obj.radioState, obj.battery)
%
%   - Determines wake window based on orphan state
%   - Normal cycle: 3 TFs awake per 20-TF cycle (15% duty)
%   - Orphan cycle: 2 TFs awake per 35-TF cycle (~6% duty, 75% longer rest)
%   - Applies idle cost when awake, sleep cost when sleeping

% =====================================================
% SENSOR TARGET SELECTION & TRANSMISSION
% =====================================================
% FUNCTION: findBestSensorTarget() | Line 266 | Find closest verified CH/GWN
%   Returns: uint16 (node ID) or empty
%
%   - Filters verified neighbors by tier (2=CH, 3=GWN)
%   - Prefers GWN if RSSI better by ≥4.8 dB (distance factor 0.8)
%   - Falls back to CH if GWN not available
%   - Returns closest neighbor by RSSI

% FUNCTION: createSensorMessage(t, target, priority) | Line 331 | Create Type 1 message
%   Returns: WSN_Message object
%
%   - Payload: [SensorValue(2), Battery(1)]
%   - Priority encoded in subtype (2-bit field)
%   - TTL = 1 (single hop)
%   - Includes checksum

% =====================================================
% PANIC HANDLING (HIGH PRIORITY)
% =====================================================
% FUNCTION: createPanicMessage(t, target, type, severity, value) | Line 484 | Create Type 2 PANIC
%   Returns: WSN_Message object
%
%   - Subtype: panic type (ANOMALY, BATTERY_CRIT, INTRUSION, LINK_LOSS)
%   - Priority: severity level (LOW=0, MEDIUM=1, HIGH=2, CRIT=3)
%   - Payload: [OrigSrc(2), SensorValue(2), Battery(1), Timestamp(2)] = 7 bytes
%   - TTL: 5 if HIGH/CRIT, else 1
%   - Target: unicast to parent or broadcast if orphan

% FUNCTION: handlePanicReception(msg, t, rssi) | Line 415 | Process inbound PANIC
%   Returns: WSN_Message (forward) or empty
%
%   - Deduplicates by UID (keeps last 50)
%   - Checks TTL (drops if ≤0)
%   - Trust-based filtering: drops if sender trust < 10
%   - Forwards to parent (unicast) or broadcasts if orphan
%   - Preserves UID for deduplication chain

% FUNCTION: createPanicForward(msg, dst) | Line 464 | Forward PANIC with TTL decrement
%   Returns: WSN_Message object
%
%   - Decrements TTL
%   - Preserves UID and payload
%   - Changes source to forwarder (this node)
%   - Destination: parent or broadcast

% =====================================================
% HELLO RECEPTION & NEIGHBOR TABLE
% =====================================================
% FUNCTION: handleHelloReception(msg, t, rssi) | Line 684 | Process HELLO broadcast
%   Returns: (void, updates obj.neighborTable)
%
%   - Extracts tier, battery, neighborCount from payload
%   - Creates or updates neighbor table entry
%   - Logs new neighbors, silent update for existing
%   - Preserves verified status from message flag

% =====================================================
% TRUST MANAGEMENT (Rule-Based, Phase 4)
% =====================================================
% FUNCTION: getNeighborTrust(neighborID) | Line 524 | Query trust for neighbor
%   Returns: double (0.0-100.0, default 50.0)
%
%   - Lookup in neighborTrust struct array by ID
%   - Returns TRUST_INITIAL (50) if unknown

% FUNCTION: updateNeighborTrust(neighborID, delta) | Line 544 | Update trust delta
%   Returns: (void, updates obj.neighborTrust)
%
%   - Clamps to [TRUST_MIN, TRUST_MAX] = [0, 100]
%   - Creates new entry if neighbor unknown
%   - Modifies existing entry if found

% =====================================================
% ML-IDS CENSUS PROTOCOL (Phase 4)
% =====================================================
% FUNCTION: checkCensusTriggers(t) | Line 562 | Initiate/finalize polls
%   Returns: array of WSN_Message objects
%
%   - Iterate through neighborTrust
%   - For each neighbor with trust < TRUST_CENSUS_TRIGGER (30.0):
%     * If not already polled: create CENSUS_POLL_INITIATE (Type 11)
%     * Broadcast to network (dst=0xFFFF)
%     * Add to censusActivePolls tracking struct
%
%   - Check timeout for all active polls (age ≥ CENSUS_POLL_TIMEOUT = 10 TFs)
%   - Finalize: compute verdict (quorum ≥50% YES = malicious, else cleared)
%   - If verdict=MALICIOUS: update trust to TRUST_MIN
%   - Forward verdict to parent (CENSUS_POLL_COMPLETE, Type 11)

% FUNCTION: handleCensusMessage(msg, t) | Line 622 | Process CENSUS variants
%   Returns: WSN_Message (vote or empty)
%   Dispatches on msg.subtype:
%
%   - CENSUS_POLL_INITIATE (0): Extract suspect ID, vote YES if trust < 30, NO otherwise
%   - CENSUS_POLL_YES (1) / CENSUS_POLL_NO (2): Aggregate votes to matching poll (by pollUID)
%   - (Note: other subtypes handled by parent/child CH/GWN)

% FUNCTION: handleShutdownMessage(msg, t) | Line 665 | Process enforcement
%   Returns: (void)
%   Dispatches on msg.subtype:
%
%   - SHUTDOWN_SOFT_RESET (0): Clear neighborTrust & censusActivePolls, keep tree structure
%   - SHUTDOWN_HARD_RESET (1): Clear parent, reset state, force re-discovery
%   - SHUTDOWN_BLACKLIST (2): Set isBlacklisted=true, cease all operations

% =====================================================
% RECEIVE (Protocol Dispatcher)
% =====================================================
% FUNCTION: receive(msg, t, rssi) | Line 354 | Process inbound message
%   Returns: WSN_Message (response) or empty
%
%   - Silently ignores if blacklisted
%   - Returns immediately if not awake or SLEEP state
%
%   - Checks attacks: BLACKHOLE/GRAYHOLE drop logic
%   - Type 0 (HELLO): Broadcast only, populates neighborTable
%   - Type 2 (PANIC): High priority, forwards up-tree
%   - Type 11 (CENSUS): Distributed polling, voting
%   - Type 12 (SHUTDOWN): Enforcement, state reset
%
%   - All RX requires valid checksum

% =====================================================
% ORPHAN MODE
% =====================================================
% Condition Entry: orphanCheckCount ≥ orphanThreshold (5 failed TX attempts)
% Condition Exit: Successfully TX sensor data to verified target
% Behavior:
%   - Extended sleep cycles (75% longer, ~6% duty cycle)
%   - Broadcast link-loss panic (Type 2, subtype LINK_LOSS)
%   - Log state transitions

% =====================================================
% ATTACK INTEGRATION
% =====================================================
% - WSN_Attack.isMaliciousNode(id) : boolean
% - WSN_Attack.getAttackType(id) : int (FLOODING=1, PANIC_FLOOD=2, etc.)
% - WSN_Attack.getFloodingBurstCount(id, t) : int
% - WSN_Attack.getFloodingTxPower(id) : double
% - WSN_Attack.shouldPanicFlood(id, t) : boolean
% - WSN_Attack.createFakePanicBeacon(id, hexID, t) : WSN_Message
% - WSN_Attack.shouldDropBlackhole(id, t) : boolean
% - WSN_Attack.shouldDropGrayhole(id, t) : boolean

% =====================================================
% FEATURE EXPORT (ML-IDS Phase 1-2)
% =====================================================
% - WSN_FeatureExport.tapTick(nodeIdx, node, t) : collect time-series features
% - WSN_FeatureExport.tapTx(nodeIdx, msg, t) : log TX event
% - WSN_FeatureExport.tapRx(nodeIdx, rssi, msg, t) : log RX event
