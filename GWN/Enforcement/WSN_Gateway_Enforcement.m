classdef WSN_Gateway_Enforcement
    % =========================================================
    % GWN ENFORCEMENT MODULE
    % =========================================================
    % Per-neighbor trust scoring and the ML-IDS Census/Shutdown verdict
    % protocol. Extracted from WSN_Gateway.m; operates on the GWN
    % instance (obj) passed in by the caller. Stateless itself - all
    % state lives on obj. Mirrors WSN_ClusterHead_Enforcement and
    % WSN_Sink_Enforcement's trust registry (WSN_Sink < WSN_Gateway, so
    % the Sink inherits these methods and may override via its own
    % globalTrustRegistry where appropriate).
    %
    % DORMANT TRUST-DECISION-MATRIX HOOKS:
    % evaluateTrustDecision/buildTrustMatrix below are NOT wired into any
    % active call path yet - placeholder ALLOW policy.
    % =========================================================

    methods (Static)
        function score = getNeighborTrust(obj, neighborID)
            idx = find([obj.neighborTrust.id] == neighborID, 1);
            if isempty(idx)
                score = WSN_Config.TRUST_INITIAL;
            else
                score = obj.neighborTrust(idx).score;
            end
        end

        function updateNeighborTrust(obj, neighborID, delta)
            idx = find([obj.neighborTrust.id] == neighborID, 1);
            if isempty(idx)
                obj.neighborTrust(end+1) = struct('id', neighborID, 'score', WSN_Config.TRUST_INITIAL + delta);
            else
                newScore = max(WSN_Config.TRUST_MIN, min(WSN_Config.TRUST_MAX, obj.neighborTrust(idx).score + delta));
                obj.neighborTrust(idx).score = newScore;
            end
        end

        function msgs = checkCensusTriggers(obj, t)
            msgs = WSN_Message.empty;

            % --- ML-IDS: flag CH children who've gone silent on 5.2 AGG ---
            % (catches Blackhole/Grayhole, which fake-ACKs its children and
            % is invisible to the retry-based triggers below -- see
            % WSN_Config.SILENCE_GRACE_MULTIPLIER)
            silenceThreshold = WSN_Config.AGG_PERIOD_MAX * WSN_Config.SILENCE_GRACE_MULTIPLIER;
            for c = 1:numel(obj.chChildren)
                childID = obj.chChildren(c);
                idx = find([obj.chLastAggSeen.id] == childID, 1);
                if isempty(idx) || ismember(childID, obj.chAggSilenceFlagged)
                    continue;
                end
                gap = t - obj.chLastAggSeen(idx).lastTime;
                if gap > silenceThreshold
                    obj.updateNeighborTrust(childID, -WSN_Config.TRUST_DELTA_FAIL_HARD);
                    obj.chAggSilenceFlagged = [obj.chAggSilenceFlagged, childID];
                    obj.addLog(sprintf('t=%d [SILENCE] CH %s has not sent 5.2 AGG in %d ticks (threshold=%d) -- distrust', ...
                        t, dec2hex(uint16(childID), 4), gap, silenceThreshold));
                end
            end

            for i = 1:numel(obj.neighborTrust)
                suspectID = obj.neighborTrust(i).id;
                if obj.neighborTrust(i).score >= WSN_Config.TRUST_CENSUS_TRIGGER
                    continue;
                end
                already = ~isempty(obj.censusActivePolls) && any([obj.censusActivePolls.suspectID] == suspectID);
                if already, continue; end

                pollUID = randi(65535);
                pollMsg = WSN_Message(WSN_Config.MSG_TYPE_CENSUS, hex2dec(obj.hexID), hex2dec('FFFF'), []);
                pollMsg.subtype = WSN_Config.CENSUS_POLL_INITIATE;
                pollMsg.ttl = 1;
                pollMsg.setCensusPollPayload(suspectID, pollUID, 1);
                pollMsg.addChecksum();
                msgs = [msgs, pollMsg];

                obj.censusActivePolls(end+1) = struct('pollUID', pollUID, 'suspectID', suspectID, ...
                    'startTick', t, 'yesCount', 0, 'totalVoters', 0, 'voterIDs', []);
                obj.addLog(sprintf('t=%d [CENSUS_INITIATE] suspect=%s trust=%.1f pollUID=%d', ...
                    t, dec2hex(uint16(suspectID), 4), obj.neighborTrust(i).score, pollUID));
            end

            if isempty(obj.censusActivePolls), return; end
            ages = t - [obj.censusActivePolls.startTick];
            doneIdx = find(ages >= WSN_Config.CENSUS_POLL_TIMEOUT);
            for k = fliplr(doneIdx)
                poll = obj.censusActivePolls(k);
                if poll.totalVoters < WSN_Config.CENSUS_MIN_VOTERS
                    verdict = 2;
                elseif poll.yesCount / poll.totalVoters >= WSN_Config.CENSUS_QUORUM_YES_RATIO
                    verdict = 1;
                    obj.updateNeighborTrust(poll.suspectID, WSN_Config.TRUST_MIN - WSN_Config.TRUST_INITIAL);
                else
                    verdict = 0;
                    idx = find([obj.neighborTrust.id] == poll.suspectID, 1);
                    if ~isempty(idx)
                        obj.neighborTrust(idx).score = WSN_Config.TRUST_INITIAL;
                    end
                end

                if ~isempty(obj.parent)
                    completeMsg = WSN_Message(WSN_Config.MSG_TYPE_CENSUS, hex2dec(obj.hexID), obj.parent, []);
                    completeMsg.subtype = WSN_Config.CENSUS_POLL_COMPLETE;
                    completeMsg.ttl = 5;
                    completeMsg.setCensusCompletePayload(poll.suspectID, verdict, poll.yesCount, poll.totalVoters);
                    completeMsg.addChecksum();
                    msgs = [msgs, completeMsg];
                end

                obj.addLogBackbone(sprintf('t=%d [CENSUS_COMPLETE] suspect=%s verdict=%d (%d/%d votes)', ...
                    t, dec2hex(uint16(poll.suspectID), 4), verdict, poll.yesCount, poll.totalVoters), [], t);
                obj.censusActivePolls(k) = [];
            end
        end

        function response = handleCensusMessage(obj, msg, t)
            response = [];
            sender = msg.src;

            if msg.subtype == WSN_Config.CENSUS_POLL_INITIATE
                if ismember(msg.uid, obj.censusSeenPolls), return; end
                obj.censusSeenPolls = [obj.censusSeenPolls, msg.uid];
                if numel(obj.censusSeenPolls) > 50
                    obj.censusSeenPolls = obj.censusSeenPolls(end-49:end);
                end

                [suspectID, pollUID, ~] = msg.getCensusPollPayload();
                idx = find([obj.neighborTrust.id] == suspectID, 1);
                if isempty(idx), return; end

                voteMsg = WSN_Message(WSN_Config.MSG_TYPE_CENSUS, hex2dec(obj.hexID), sender, []);
                if obj.neighborTrust(idx).score < WSN_Config.TRUST_CENSUS_TRIGGER
                    voteMsg.subtype = WSN_Config.CENSUS_POLL_YES;
                else
                    voteMsg.subtype = WSN_Config.CENSUS_POLL_NO;
                end
                voteMsg.ttl = 1;
                voteMsg.setCensusPollPayload(suspectID, pollUID, 0);
                voteMsg.addChecksum();
                response = voteMsg;
                return;
            end

            if msg.subtype == WSN_Config.CENSUS_POLL_YES || msg.subtype == WSN_Config.CENSUS_POLL_NO
                [suspectID, pollUID, ~] = msg.getCensusPollPayload();
                pIdx = find([obj.censusActivePolls.pollUID] == pollUID & [obj.censusActivePolls.suspectID] == suspectID, 1);
                if isempty(pIdx), return; end
                if ismember(sender, obj.censusActivePolls(pIdx).voterIDs), return; end

                obj.censusActivePolls(pIdx).voterIDs = [obj.censusActivePolls(pIdx).voterIDs, sender];
                obj.censusActivePolls(pIdx).totalVoters = obj.censusActivePolls(pIdx).totalVoters + 1;
                if msg.subtype == WSN_Config.CENSUS_POLL_YES
                    obj.censusActivePolls(pIdx).yesCount = obj.censusActivePolls(pIdx).yesCount + 1;
                end
                return;
            end

            if msg.subtype == WSN_Config.CENSUS_POLL_COMPLETE
                response = obj.handlePollComplete(msg, t);
                return;
            end
        end

        function response = handlePollComplete(obj, msg, t)
            % Nearest-ancestor enforcement (see WSN_ClusterHead.handlePollComplete
            % for the same pattern): if the suspect is our own direct child or
            % CH child, issue Shutdown; otherwise relay further uplink.
            response = [];
            [suspectID, verdict, yesCount, totalVoters] = msg.getCensusCompletePayload();
            if verdict ~= 1, return; end

            isOwnChild = ismember(suspectID, obj.children) || ...
                (isprop(obj, 'chChildren') && ismember(suspectID, obj.chChildren));
            if isOwnChild
                idx = find([obj.resetHistory.id] == suspectID, 1);
                if isempty(idx)
                    obj.resetHistory(end+1) = struct('id', suspectID, 'softCount', 0, 'hardCount', 0);
                    idx = numel(obj.resetHistory);
                end

                if obj.resetHistory(idx).hardCount >= WSN_Config.RESET_ESCALATION_COUNT
                    level = WSN_Config.SHUTDOWN_BLACKLIST;
                    obj.children(obj.children == suspectID) = [];
                    if isprop(obj, 'chChildren')
                        obj.chChildren(obj.chChildren == suspectID) = [];
                    end
                elseif obj.resetHistory(idx).softCount >= WSN_Config.RESET_ESCALATION_COUNT
                    level = WSN_Config.SHUTDOWN_HARD_RESET;
                    obj.resetHistory(idx).hardCount = obj.resetHistory(idx).hardCount + 1;
                else
                    level = WSN_Config.SHUTDOWN_SOFT_RESET;
                    obj.resetHistory(idx).softCount = obj.resetHistory(idx).softCount + 1;
                end

                shutdownMsg = WSN_Message(WSN_Config.MSG_TYPE_SHUTDOWN, hex2dec(obj.hexID), suspectID, []);
                shutdownMsg.subtype = level;
                shutdownMsg.ttl = 1;
                shutdownMsg.setDownPayload(suspectID, 0);
                shutdownMsg.addChecksum();
                response = shutdownMsg;
                obj.addLogBackbone(sprintf('t=%d [ENFORCE] child %s confirmed malicious (%d/%d votes) -> SHUTDOWN.%d', ...
                    t, dec2hex(uint16(suspectID), 4), yesCount, totalVoters, level), [], t);

                % GUI visibility: flag blacklisted nodes in the Sink's global registry, if present
                if level == WSN_Config.SHUTDOWN_BLACKLIST && isprop(obj, 'globalTrustRegistry')
                    gIdx = find([obj.globalTrustRegistry.id] == suspectID, 1);
                    if ~isempty(gIdx)
                        if ~isfield(obj.globalTrustRegistry, 'isBlacklisted')
                            [obj.globalTrustRegistry.isBlacklisted] = deal(false);
                        end
                        obj.globalTrustRegistry(gIdx).isBlacklisted = true;
                    end
                end
            elseif ~isempty(obj.parent)
                fwd = WSN_Message(WSN_Config.MSG_TYPE_CENSUS, hex2dec(obj.hexID), obj.parent, []);
                fwd.subtype = WSN_Config.CENSUS_POLL_COMPLETE;
                fwd.ttl = 5;
                fwd.setCensusCompletePayload(suspectID, verdict, yesCount, totalVoters);
                fwd.addChecksum();
                response = fwd;
            else
                % Sink with no parent and suspect not its own child/CH-child:
                % record for visibility via the global trust registry (if present)
                if isprop(obj, 'globalTrustRegistry')
                    obj.updateGlobalTrust(suspectID, dec2hex(uint16(suspectID), 4), 'UNKNOWN', t, false);
                end
            end
        end

        function handleShutdownMessage(obj, msg, t)
            switch msg.subtype
                case WSN_Config.SHUTDOWN_SOFT_RESET
                    obj.neighborTrust = struct('id',{}, 'score',{});
                    obj.censusActivePolls = struct('pollUID',{}, 'suspectID',{}, 'startTick',{}, 'yesCount',{}, 'totalVoters',{}, 'voterIDs',{});
                    obj.Q_fwd = {};
                    obj.Q_local = {};
                    obj.addLogBackbone(sprintf('t=%d [SHUTDOWN] SOFT_RESET - trust/poll/queue state cleared', t), [], t);
                case WSN_Config.SHUTDOWN_HARD_RESET
                    obj.parent = [];
                    obj.isVerified = false;
                    obj.hasKey = false;
                    obj.state = WSN_Config.STATE_BOOT;
                    obj.addLogBackbone(sprintf('t=%d [SHUTDOWN] HARD_RESET - forced re-handshake', t), [], t);
                case WSN_Config.SHUTDOWN_BLACKLIST
                    obj.isBlacklisted = true;
                    obj.addLogBackbone(sprintf('t=%d [SHUTDOWN] BLACKLIST - node permanently silenced', t), [], t);
            end
        end

        % ----------------------------------------------------------
        % DORMANT: trust-based decision matrix (not yet wired in)
        % ----------------------------------------------------------
        function verdict = evaluateTrustDecision(obj, neighborID)
            % Placeholder single-neighbor enforcement verdict, derived from
            % neighborTrust + obj.trustDecisionMatrix (dormant property; see
            % WSN_Gateway.m). Always returns ALLOW today - intended hook
            % point for a future admission/exclusion policy. Note: WSN_Sink
            % (< WSN_Gateway) layers its own richer globalTrustRegistry-based
            % evaluateTrustDecision via WSN_Sink_Enforcement on top of this.
            trust = WSN_Gateway_Enforcement.getNeighborTrust(obj, neighborID);
            verdict = struct( ...
                'neighborID', neighborID, ...
                'trustScore', trust, ...
                'action', 'ALLOW', ...
                'reason', 'dormant-policy: trust matrix not yet active');
        end

        function matrix = buildTrustMatrix(obj)
            % Placeholder builder for a per-GWN trust decision matrix;
            % returns obj.neighborTrust today, intended to later fold in
            % census outcomes and CH-relay reliability (chAggSilenceFlagged)
            % into a composite score.
            matrix = obj.neighborTrust;
        end
    end
end
