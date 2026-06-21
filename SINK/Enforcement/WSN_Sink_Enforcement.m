classdef WSN_Sink_Enforcement
    % =========================================================
    % SINK ENFORCEMENT MODULE
    % =========================================================
    % Global trust registry (scoring nodes network-wide from the Sink's
    % vantage point) and the verdict/enforcement surface that consumes it.
    % Extracted from WSN_Sink.m; operates on the Sink instance (obj)
    % passed in by the caller. Stateless itself - all state lives on obj.
    %
    % DORMANT TRUST-DECISION-MATRIX HOOKS:
    % evaluateTrustDecision/buildTrustMatrix below are NOT wired into any
    % active call path yet. They exist so a future trust-based admission/
    % exclusion policy can be layered on top of globalTrustRegistry without
    % touching the FSM or message-dispatch code in WSN_Sink.m. Placeholder
    % policy is identity/no-op (always ALLOW) until real rules are added.
    % =========================================================

    methods (Static)
        function updateGlobalTrust(obj, nodeID, hexID, nodeType, t, isSuccess)
            % Update or create entry in globalTrustRegistry
            % isSuccess: true = increase trust, false = record anomaly

            idx = find([obj.globalTrustRegistry.id] == nodeID, 1);

            if isempty(idx)
                % New node - create entry with default trust
                newEntry = struct( ...
                    'id', nodeID, ...
                    'hexID', hexID, ...
                    'nodeType', nodeType, ...
                    'TrustScore', 50, ...
                    'lastUpdate', t, ...
                    'packetsReceived', 1, ...
                    'anomalyCount', 0);
                if isempty(obj.globalTrustRegistry)
                    obj.globalTrustRegistry = newEntry;
                else
                    obj.globalTrustRegistry(end+1) = newEntry;
                end
            else
                % Update existing entry
                obj.globalTrustRegistry(idx).lastUpdate = t;
                obj.globalTrustRegistry(idx).packetsReceived = obj.globalTrustRegistry(idx).packetsReceived + 1;

                if isSuccess
                    % Increase trust (max 100), slower increase at higher trust
                    currentTrust = obj.globalTrustRegistry(idx).TrustScore;
                    increment = max(0.5, 2 - currentTrust / 50);  % 2 at trust=0, 0.5 at trust=100
                    obj.globalTrustRegistry(idx).TrustScore = min(100, currentTrust + increment);
                else
                    % Record anomaly and decrease trust
                    obj.globalTrustRegistry(idx).anomalyCount = obj.globalTrustRegistry(idx).anomalyCount + 1;
                    decrement = 5;  % Anomalies hurt more than good behavior helps
                    obj.globalTrustRegistry(idx).TrustScore = max(0, ...
                        obj.globalTrustRegistry(idx).TrustScore - decrement);
                end
            end
        end

        function trust = getGlobalTrust(obj, nodeID)
            % Get trust score for a node from global registry
            % Returns default 50 if node not found
            trust = 50;
            if isempty(obj.globalTrustRegistry)
                return;
            end
            idx = find([obj.globalTrustRegistry.id] == nodeID, 1);
            if ~isempty(idx)
                trust = obj.globalTrustRegistry(idx).TrustScore;
            end
        end

        function summary = getGlobalTrustSummary(obj)
            % Get summary statistics for all tracked nodes
            summary = struct();
            summary.totalNodes = 0;
            summary.avgTrust = 50;
            summary.lowTrustNodes = {};
            summary.highTrustNodes = {};

            if isempty(obj.globalTrustRegistry)
                return;
            end

            summary.totalNodes = numel(obj.globalTrustRegistry);
            summary.avgTrust = mean([obj.globalTrustRegistry.TrustScore]);

            % Find low trust nodes (below 30)
            lowIdx = [obj.globalTrustRegistry.TrustScore] < 30;
            if any(lowIdx)
                summary.lowTrustNodes = {obj.globalTrustRegistry(lowIdx).hexID};
            end

            % Find high trust nodes (above 80)
            highIdx = [obj.globalTrustRegistry.TrustScore] > 80;
            if any(highIdx)
                summary.highTrustNodes = {obj.globalTrustRegistry(highIdx).hexID};
            end
        end

        % ----------------------------------------------------------
        % DORMANT: trust-based decision matrix (not yet wired in)
        % ----------------------------------------------------------
        function verdict = evaluateTrustDecision(obj, nodeID)
            % Placeholder single-node enforcement verdict, derived from
            % globalTrustRegistry + obj.trustDecisionMatrix (dormant
            % property; see WSN_Sink.m). Always returns ALLOW today -
            % intended hook point for a future admission/exclusion policy.
            %
            % verdict.action: 'ALLOW' | 'WARN' | 'QUARANTINE' | 'EXCLUDE'
            trust = WSN_Sink_Enforcement.getGlobalTrust(obj, nodeID);
            verdict = struct( ...
                'nodeID', nodeID, ...
                'trustScore', trust, ...
                'action', 'ALLOW', ...
                'reason', 'dormant-policy: trust matrix not yet active');
        end

        function matrix = buildTrustMatrix(obj)
            % Placeholder builder for a network-wide trust decision matrix
            % (rows = tracked nodes, columns = decision factors). Returns
            % a struct array mirroring globalTrustRegistry today; intended
            % to later fold in per-tier weighting, census votes, and
            % neighbor-trust cross-checks (see getNeighborTrust on
            % WSN_Gateway/WSN_ClusterHead) into a single composite score.
            matrix = obj.globalTrustRegistry;
        end
    end
end
