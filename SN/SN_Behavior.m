% =====================================================
% SENSOR NODE (SN) BEHAVIOR MODULE
% =====================================================
% This module contains high-level behavioral logic for Sensor Nodes:
% - Power & sleep management (orphan mode)
% - Sensor data acquisition & target selection
% - Trust scoring & neighbor evaluation
% - ML-IDS Census protocol (distributed voting)
% - Panic detection & severity determination
%
% Intended to be delegated from WSN_Sensor main class.
% See SN_Messaging.m for message parsing/creation.
%
% Status: Documented behavior reference (not yet separated into dedicated class)
% =====================================================

% =====================================================
% SLEEP/WAKE CYCLE MANAGEMENT
% =====================================================

% updatePhysics_Orphan(t, wakeWindow, cycleLength)
% Determine if node should be awake during this timestep
% Returns: boolean (true = awake, false = sleeping)
function isAwake = computeWakeState(t, offset, wakeWindow, cycleLength)
    mod_val = mod(t + offset, cycleLength);
    isAwake = (mod_val < wakeWindow);
end

% applyCycleCost(battery, isAwake)
% Apply energy cost for current state
% Returns: updated battery level
function battery = applyCycleCost(battery, isAwake, idleCost, sleepCost)
    if isAwake
        battery = max(0, battery - idleCost);
    else
        battery = max(0, battery - sleepCost);
    end
end

% =====================================================
% SENSOR TARGET SELECTION
% =====================================================

% scoreTarget(neighbor, preferGwn, distanceFactor)
% Evaluate a target (CH or GWN) for sensor transmission
% Returns: double (higher = better), or -Inf if invalid
%
% Factors:
%  - RSSI (signal strength): higher is better
%  - Tier: GWN preferred if RSSI advantage > threshold
%  - Verification: only verified targets valid
function score = computeTargetScore(neighbor, preferGwn, distanceFactor)
    if ~neighbor.isVerified
        score = -Inf;
        return;
    end

    % Base score is RSSI (higher = closer)
    score = neighbor.rssi;

    % Bonus for GWN if preferGwn flag set
    if preferGwn && neighbor.tier == 3  % TIER_GWN
        score = score + 1.0;  % Small bonus
    end
end

% =====================================================
% ANOMALY DETECTION & PANIC SEVERITY
% =====================================================

% detectAnomaly(newValue, prevValue, threshold)
% Detect significant sensor value change
% Returns: boolean
%
% Logic: pctChange >= threshold → anomaly
function anomaly = hasAnomalousChange(newValue, prevValue, threshold)
    if prevValue <= 0
        anomaly = false;
        return;
    end
    pctChange = abs(newValue - prevValue) / prevValue * 100;
    anomaly = (pctChange >= threshold);
end

% computePanicSeverity(anomalous, batteryCritical)
% Determine panic type and severity
% Returns: struct with (panicType, severity)
%
% Decision matrix:
%  Anomaly + Battery → ANOMALY, CRITICAL (highest)
%  Battery only      → BATTERY_CRIT, MEDIUM
%  Anomaly only      → ANOMALY, MEDIUM
function panic = computePanicSeverity(anomalous, batteryCrit, numMissingTargets)
    if anomalous && batteryCrit
        panic.type = 0;      % PANIC_SUB_ANOMALY
        panic.severity = 3;  % PANIC_SEV_CRITICAL
    elseif batteryCrit
        panic.type = 1;      % PANIC_SUB_BATTERY_CRIT
        panic.severity = 2;  % PANIC_SEV_MEDIUM
    elseif anomalous
        panic.type = 0;      % PANIC_SUB_ANOMALY
        panic.severity = 2;  % PANIC_SEV_MEDIUM
    elseif numMissingTargets >= 5
        panic.type = 3;      % PANIC_SUB_LINK_LOSS
        panic.severity = 2;  % PANIC_SEV_MEDIUM
    else
        panic.type = -1;
        panic.severity = -1;
    end
end

% =====================================================
% TRUST MANAGEMENT
% =====================================================

% updateTrustOnEvent(currentScore, eventType)
% Adjust trust based on behavior observation
% Returns: updated trust score (clamped [0, 100])
%
% Events:
%  - 'ack_received': +3
%  - 'forward_success': +2
%  - 'msg_timeout': -5
%  - 'checksum_fail': -10
%  - 'malicious_verdict': -50
function newScore = updateTrustScore(currentScore, eventType, trustMin, trustMax)
    delta = 0;

    switch eventType
        case 'ack_received'
            delta = 3;
        case 'forward_success'
            delta = 2;
        case 'msg_timeout'
            delta = -5;
        case 'checksum_fail'
            delta = -10;
        case 'malicious_verdict'
            delta = -50;
        case 'census_vote_yes'
            delta = 1;   % Cooperative response
        case 'census_silence'
            delta = -3;  % Non-responsive
    end

    newScore = max(trustMin, min(trustMax, currentScore + delta));
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

% computeCensusVerdict(yesVotes, totalVotes, quorumRatio)
% Aggregate votes and determine malicious verdict
% Returns: verdict (0=cleared, 1=malicious, 2=inconclusive)
%
% Verdict logic:
%  totalVotes < MIN_VOTERS        → inconclusive (2)
%  yesVotes/total >= quorumRatio  → malicious (1)
%  otherwise                      → cleared (0)
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
% ORPHAN MODE MANAGEMENT
% =====================================================

% updateOrphanState(failureCount, threshold, prevOrphaned)
% Transition in/out of orphan mode
% Returns: (newOrphanFlag, updatedFailureCount)
%
% Logic:
%  failureCount >= threshold AND ~orphaned → enter (log transition)
%  orphaned AND targetFound                 → exit (log recovery)
%  otherwise                               → maintain state
function [isOrphaned, failCount] = updateOrphanState(failureCount, threshold, prevOrphaned, targetFound)
    if ~prevOrphaned && failureCount >= threshold
        % Enter orphan mode
        isOrphaned = true;
        failCount = 0;  % Reset counter once in mode
    elseif prevOrphaned && targetFound
        % Exit orphan mode
        isOrphaned = false;
        failCount = 0;
    else
        isOrphaned = prevOrphaned;
        failCount = failureCount;
    end
end

% =====================================================
% PRIORITY CALCULATION
% =====================================================

% computeSensorPriority(pctChange)
% Convert sensor value change into message priority (2-bit)
% Returns: uint8 (0-3)
%
% Priority scale:
%  0: default (< 20% change)
%  1: moderate (20-45% change)
%  2: high (>= 45% change)
%  3: reserved
function priority = computePriority(prevValue, newValue)
    if prevValue <= 0
        priority = 0;
        return;
    end
    pctChange = abs(newValue - prevValue) / prevValue * 100;

    if pctChange >= 45
        priority = 2;
    elseif pctChange >= 20
        priority = 1;
    else
        priority = 0;
    end
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
% Filter neighbors by tier (e.g., 2=CH, 3=GWN)
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
% STATISTICS / REPORTING
% =====================================================

% getSummaryStats(neighborTable, neighborTrust)
% Compute network statistics for diagnostics
% Returns: struct with counts, avg trust, etc.
function stats = computeNetworkStats(neighborTable, neighborTrust)
    stats.totalNeighbors = numel(neighborTable);
    stats.verifiedNeighbors = sum([neighborTable.isVerified]);
    stats.chNeighbors = sum([neighborTable.tier] == 2);
    stats.gwnNeighbors = sum([neighborTable.tier] == 3);

    if isempty(neighborTrust)
        stats.avgTrust = 50;
        stats.minTrust = 50;
        stats.maxTrust = 50;
    else
        scores = [neighborTrust.score];
        stats.avgTrust = mean(scores);
        stats.minTrust = min(scores);
        stats.maxTrust = max(scores);
    end

    stats.activeCensus = 0;  % Would count active polls
end

% =====================================================
% END OF SN_BEHAVIOR
% =====================================================
