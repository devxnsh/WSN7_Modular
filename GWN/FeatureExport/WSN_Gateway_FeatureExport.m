classdef WSN_Gateway_FeatureExport
    % =========================================================
    % GWN FEATURE-EXPORT MODULE
    % =========================================================
    % Lightweight metric accessors describing this GWN's child
    % population (access-tier children + CH children on the backbone).
    % Extracted/added alongside the Registry/Enforcement split of
    % WSN_Gateway.m; operates on the GWN instance (obj) passed in by the
    % caller. Stateless itself - all state lives on obj. Mirrors
    % WSN_Sink_FeatureExport.getActiveSensorsCount.
    % =========================================================

    methods (Static)
        function n = getActiveChildrenCount(obj)
            % Count direct children not currently silence-flagged
            % (chAggSilenceFlagged) - a real, currently-unused metric
            % mirroring WSN_Sink_FeatureExport.getActiveSensorsCount.
            if isempty(obj.children)
                n = 0;
            else
                n = numel(setdiff(obj.children, obj.chAggSilenceFlagged));
            end
        end

        function n = getSilencedChildrenCount(obj)
            % Count CH children currently flagged silent on 5.2 AGG
            % (see WSN_Gateway_Enforcement.checkCensusTriggers).
            n = numel(obj.chAggSilenceFlagged);
        end

        % ----------------------------------------------------------
        % DORMANT: trust-aware feature snapshot (not yet wired in)
        % ----------------------------------------------------------
        function row = getTrustFeatureSnapshot(obj, neighborID)
            % Placeholder per-neighbor feature row combining child-census
            % stats with neighbor trust, intended as a future input column
            % set for ML-IDS feature export once the trust decision matrix
            % (see WSN_Gateway_Enforcement.buildTrustMatrix) is active.
            row = struct( ...
                'neighborID', neighborID, ...
                'neighborTrust', obj.getNeighborTrust(neighborID), ...
                'isSilenced', ismember(neighborID, obj.chAggSilenceFlagged));
        end
    end
end
