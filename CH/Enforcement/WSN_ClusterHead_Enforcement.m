classdef WSN_ClusterHead_Enforcement
    % =========================================================
    % CH ENFORCEMENT MODULE
    % =========================================================
    % Per-neighbor trust scoring and the ML-IDS Census/Shutdown verdict
    % protocol. Extracted from WSN_ClusterHead.m; operates on the CH
    % instance (obj) passed in by the caller. Stateless itself - all
    % state lives on obj. Mirrors WSN_Gateway's equivalent census logic
    % (see GWN/WSN_Gateway.m) and WSN_Sink_Enforcement's trust registry.
    %
    % DORMANT TRUST-DECISION-MATRIX HOOKS:
    % evaluateTrustDecision/buildTrustMatrix below are NOT wired into any
    % active call path yet - placeholder ALLOW policy, see
    % WSN_Sink_Enforcement for the SINK-tier counterpart.
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
            msgs = [];

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
                msgs = [msgs, pollMsg]; %#ok<AGROW>

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
                    msgs = [msgs, completeMsg]; %#ok<AGROW>
                end

                obj.addLog(sprintf('t=%d [CENSUS_COMPLETE] suspect=%s verdict=%d (%d/%d votes)', ...
                    t, dec2hex(uint16(poll.suspectID), 4), verdict, poll.yesCount, poll.totalVoters));
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
            % Nearest-ancestor enforcement: if the suspect is our own direct
            % child, decide and issue a Shutdown; otherwise relay the verdict
            % further uplink toward our own parent (eventually reaching an
            % ancestor that does have the suspect as a child, or the Sink).
            response = [];
            [suspectID, verdict, yesCount, totalVoters] = msg.getCensusCompletePayload();
            if verdict ~= 1, return; end % only confirmed-malicious verdicts drive enforcement

            if ismember(suspectID, obj.children)
                idx = find([obj.resetHistory.id] == suspectID, 1);
                if isempty(idx)
                    obj.resetHistory(end+1) = struct('id', suspectID, 'softCount', 0, 'hardCount', 0);
                    idx = numel(obj.resetHistory);
                end

                if obj.resetHistory(idx).hardCount >= WSN_Config.RESET_ESCALATION_COUNT
                    level = WSN_Config.SHUTDOWN_BLACKLIST;
                    obj.children(obj.children == suspectID) = [];
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
                obj.addLog(sprintf('t=%d [ENFORCE] child %s confirmed malicious (%d/%d votes) -> SHUTDOWN.%d', ...
                    t, dec2hex(uint16(suspectID), 4), yesCount, totalVoters, level));
            elseif ~isempty(obj.parent)
                fwd = WSN_Message(WSN_Config.MSG_TYPE_CENSUS, hex2dec(obj.hexID), obj.parent, []);
                fwd.subtype = WSN_Config.CENSUS_POLL_COMPLETE;
                fwd.ttl = 5;
                fwd.setCensusCompletePayload(suspectID, verdict, yesCount, totalVoters);
                fwd.addChecksum();
                response = fwd;
            end
        end

        function handleShutdownMessage(obj, msg, t)
            switch msg.subtype
                case WSN_Config.SHUTDOWN_SOFT_RESET
                    obj.neighborTrust = struct('id',{}, 'score',{});
                    obj.censusActivePolls = struct('pollUID',{}, 'suspectID',{}, 'startTick',{}, 'yesCount',{}, 'totalVoters',{}, 'voterIDs',{});
                    obj.addLog(sprintf('t=%d [SHUTDOWN] SOFT_RESET - trust/poll state cleared', t));
                case WSN_Config.SHUTDOWN_HARD_RESET
                    obj.parent = [];
                    obj.isVerified = false;
                    obj.localKey = [];
                    obj.passkey = [];
                    obj.relayTable = struct('leafID',{}, 'nextHop',{}, 'lastActive',{});
                    obj.relayQueue = {};
                    obj.pendingRelayFragments = struct('leafID',{}, 'nextHop',{}, 'seq',{}, 'fragIdx',{}, 'totalFrags',{}, 'msg',{}, 'retryCount',{}, 'lastRetryTime',{});
                    obj.state = WSN_Config.STATE_BOOT;
                    obj.neighborTrust = struct('id',{}, 'score',{});
                    obj.addLog(sprintf('t=%d [SHUTDOWN] HARD_RESET - forced re-handshake', t));
                case WSN_Config.SHUTDOWN_BLACKLIST
                    obj.isBlacklisted = true;
                    obj.addLog(sprintf('t=%d [SHUTDOWN] BLACKLIST - node permanently silenced', t));
            end
        end

        % ----------------------------------------------------------
        % DORMANT: trust-based decision matrix (not yet wired in)
        % ----------------------------------------------------------
        function verdict = evaluateTrustDecision(obj, neighborID)
            % Placeholder single-neighbor enforcement verdict, derived from
            % neighborTrust + obj.trustDecisionMatrix (dormant property; see
            % WSN_ClusterHead.m). Always returns ALLOW today - intended hook
            % point for a future admission/exclusion policy.
            trust = WSN_ClusterHead_Enforcement.getNeighborTrust(obj, neighborID);
            verdict = struct( ...
                'neighborID', neighborID, ...
                'trustScore', trust, ...
                'action', 'ALLOW', ...
                'reason', 'dormant-policy: trust matrix not yet active');
        end

        function matrix = buildTrustMatrix(obj)
            % Placeholder builder for a per-CH trust decision matrix; returns
            % obj.neighborTrust today, intended to later fold in census
            % outcomes and sensor-relay reliability into a composite score.
            matrix = obj.neighborTrust;
        end
    end
end
