% =====================================================
% CLUSTER HEAD (CH) BEHAVIOR MODULE
% =====================================================
% This module contains high-level behavioral logic for Cluster Heads:
% - FSM recruitment state machine (BOOT → DISCOVERY → SECURE → HANDSHAKE)
% - Sensor aggregation scheduling & retry logic
% - Trust scoring & neighbor evaluation
% - ML-IDS Census protocol (distributed voting)
% - Panic detection & forwarding
%
% Intended to be delegated from WSN_ClusterHead main class.
% See CH_Messaging.m for message parsing/creation.
%
% Status: Documented behavior reference (not yet separated into dedicated class)
% =====================================================

% =====================================================
% RECRUITMENT FSM
% =====================================================

% computeNextFsmState(currentState, foundGwn, foundCh, isVerified, maxRetriesExceeded)
% Determine next recruitment state
% Returns: new state (BOOT, DISCOVERY, SECURE, HANDSHAKE)
function nextState = computeNextFsmState(currentState, foundGwn, foundCh, isVerified, maxRetries)
    switch currentState
        case 0  % BOOT
            nextState = 1;  % DISCOVERY
        case 1  % DISCOVERY
            if foundGwn
                nextState = 2;  % SECURE (start recruiting)
            else
                nextState = 1;  % Stay in DISCOVERY
            end
        case 2  % SECURE
            if isVerified
                nextState = 2;  % Stay SECURE (normal operation)
            else
                nextState = 3;  % HANDSHAKE (recruitment in progress)
            end
        case 3  % HANDSHAKE
            if maxRetries
                nextState = 2;  % Back to SECURE (try next target)
            else
                nextState = 3;  % Stay in HANDSHAKE
            end
        otherwise
            nextState = currentState;
    end
end

% =====================================================
% AGGREGATION SCHEDULING
% =====================================================

% shouldTransmitAggregation(nextAggTx, currentTime, pendingAgg)
% Determine if aggregation window triggered
% Returns: boolean
function should = shouldTransmitAggregation(nextAggTx, currentTime, pendingAgg)
    should = (currentTime >= nextAggTx && isempty(pendingAgg));
end

% computeNextAggTime(lastAggTime, aggPeriod)
% Schedule next aggregation time
% Returns: uint32 (timeframe)
function nextTime = computeNextAggTime(lastAggTime, aggPeriod)
    nextTime = lastAggTime + aggPeriod;
end

% shouldRetryPendingAgg(lastRetryTime, retryInterval, retryCount, maxRetries)
% Determine if pending aggregation needs retry
% Returns: boolean
function should = shouldRetryPending(lastRetryTime, currentTime, retryInterval, retryCount, maxRetries)
    if retryCount >= maxRetries
        should = false;  % Max retries exceeded
    else
        should = ((currentTime - lastRetryTime) >= retryInterval);
    end
end

% =====================================================
% SENSOR AGGREGATION FRAGMENTATION
% =====================================================

% fragmentSensors(sensorArray, maxPerFragment)
% Split sensor array into fragments
% Returns: cell array of fragment structs, each with [sensors, fragIdx, totalFrags]
function fragments = fragmentSensorArray(sensors, maxPerFragment)
    numSensors = numel(sensors);
    numFragments = ceil(numSensors / maxPerFragment);
    if numFragments == 0
        numFragments = 1;
    end

    fragments = {};
    for i = 1:numFragments
        startIdx = (i - 1) * maxPerFragment + 1;
        endIdx = min(i * maxPerFragment, numSensors);
        fragSensors = sensors(startIdx:endIdx);

        frag = struct(...
            'sensors', fragSensors, ...
            'fragIdx', i, ...
            'totalFrags', numFragments);
        fragments{end+1} = frag;
    end
end

% =====================================================
% TRUST MANAGEMENT
% =====================================================

% updateTrustOnEvent(currentScore, eventType)
% Adjust trust based on behavior observation
% Returns: updated trust score (clamped [0, 100])
function newScore = updateTrustScore(currentScore, eventType, trustMin, trustMax)
    delta = 0;

    switch eventType
        case 'agg_ack_received'
            delta = 2;
        case 'handshake_success'
            delta = 5;
        case 'agg_timeout'
            delta = -5;
        case 'max_retries_fail'
            delta = -30;
        case 'checksum_fail'
            delta = -10;
        case 'malicious_verdict'
            delta = -50;
        case 'census_silence'
            delta = -20;  % Reporting-silence detection
        case 'census_vote_yes'
            delta = 1;
        case 'census_silence_poll'
            delta = -3;
    end

    newScore = max(trustMin, min(trustMax, currentScore + delta));
end

% =====================================================
% REPORTING-SILENCE DETECTOR
% =====================================================

% checkReportingSilence(chLastAggSeen, currentTime, aggPeriod, graceMult)
% Detect CH children that stopped sending aggregations
% Returns: array of child IDs with silence violation
function silentChildren = detectReportingSilence(chLastAggSeen, currentTime, aggPeriod, graceMult)
    silentChildren = [];
    threshold = aggPeriod * graceMult;

    for i = 1:numel(chLastAggSeen)
        childID = chLastAggSeen(i).id;
        lastTime = chLastAggSeen(i).lastTime;
        age = currentTime - lastTime;

        if age > threshold
            silentChildren = [silentChildren, childID];
        end
    end
end

% =====================================================
% ML-IDS CENSUS PROTOCOL (Phase 4)
% =====================================================

% shouldInitiateCensus(trustScore, censusThreshold)
% Determine if neighbor is suspicious enough to poll
% Returns: boolean
function should = shouldPoll(trustScore, threshold)
    should = (trustScore < threshold);
end

% computeCensusVerdict(yesVotes, totalVotes, minVoters, quorumRatio)
% Aggregate votes and determine malicious verdict
% Returns: verdict (0=cleared, 1=malicious, 2=inconclusive)
function verdict = computeVerdictFromVotes(yesVotes, totalVotes, minVoters, quorum)
    if totalVotes < minVoters
        verdict = 2;  % INCONCLUSIVE
    elseif (yesVotes / totalVotes) >= quorum
        verdict = 1;  % MALICIOUS
    else
        verdict = 0;  % CLEARED
    end
end

% =====================================================
% ESCALATION TRACKING
% =====================================================

% computeEscalationLevel(resetHistory, escalationCount)
% Determine SHUTDOWN level based on prior violations
% Returns: shutdown level (0=SOFT, 1=HARD, 2=BLACKLIST)
function level = computeShutdownLevel(softCount, hardCount, escalationCount)
    if hardCount >= escalationCount
        level = 2;  % BLACKLIST
    elseif softCount >= escalationCount
        level = 1;  % HARD_RESET
    else
        level = 0;  % SOFT_RESET
    end
end

% =====================================================
% PRIORITY AGGREGATION
% =====================================================

% sortSensorsByPriority(sensorTable)
% Reorder sensor table by priority (highest first)
% Returns: sorted struct array
function sorted = sortByRssi(sensorTable)
    if isempty(sensorTable)
        sorted = [];
        return;
    end

    rssis = [sensorTable.rssi];
    [~, ord] = sort(rssis, 'descend');
    sorted = sensorTable(ord);
end

% =====================================================
% HELPER: Deduplication
% =====================================================

% addSeenUID(uidList, newUID, maxSize)
% Add to circular dedup buffer
% Returns: updated list (max last 'maxSize' entries)
function uidList = addSeenUID(uidList, newUID, maxSize)
    uidList = [uidList, newUID];
    if numel(uidList) > maxSize
        uidList = uidList(end - maxSize + 1:end);
    end
end

% =====================================================
% HELPER: Neighbor Filtering
% =====================================================

% getVerifiedNeighbors(neighborTable)
% Return only verified neighbors
% Returns: filtered struct array
function verified = getVerifiedNeighbors(neighborTable)
    if isempty(neighborTable)
        verified = [];
        return;
    end
    mask = [neighborTable.isVerified];
    verified = neighborTable(mask);
end

% getNeighborsByTier(neighborTable, tier)
% Filter neighbors by tier
% Returns: filtered struct array
function filtered = getNeighborsByTier(neighborTable, tier)
    if isempty(neighborTable)
        filtered = [];
        return;
    end
    mask = ([neighborTable.tier] == tier);
    filtered = neighborTable(mask);
end

% =====================================================
% END OF CH_BEHAVIOR
% =====================================================
