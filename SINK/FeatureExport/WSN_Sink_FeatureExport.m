classdef WSN_Sink_FeatureExport
    % =========================================================
    % SINK FEATURE-EXPORT MODULE
    % =========================================================
    % Sink-local metric/feature accessors. Extracted from WSN_Sink.m;
    % operates on the Sink instance (obj) passed in by the caller.
    % Stateless itself - all state lives on obj.
    %
    % Network-wide ML-IDS feature export (per-tier CSV/feature rows) is
    % handled separately by the generic WSN_FeatureExport utility and by
    % WSN_SinkFeatureExport (global aggregation), both driven from
    % WSN_Main.m. This module covers metrics computed FROM the Sink's own
    % registries (sensorRegistry / globalTrustRegistry) for status
    % reporting and as future inputs to those exporters.
    % =========================================================

    methods (Static)
        function count = getActiveSensorsCount(obj, t, windowSize)
            % Get count of sensors that have reported within the specified time window
            % This gives a better "sensors tracked" metric than total sensors
            if nargin < 3
                windowSize = 50;  % Default: sensors active in last 50 ticks
            end

            count = 0;
            if isempty(obj.sensorRegistry)
                return;
            end

            for i = 1:numel(obj.sensorRegistry)
                s = obj.sensorRegistry(i);
                if ~isempty(s.timeseries)
                    latestTime = s.timeseries(end).time;
                    if (t - latestTime) <= windowSize
                        count = count + 1;
                    end
                end
            end
        end

        % ----------------------------------------------------------
        % DORMANT: trust-aware feature snapshot (not yet wired in)
        % ----------------------------------------------------------
        function row = getTrustFeatureSnapshot(obj, nodeID, t)
            % Placeholder per-node feature row combining registry stats
            % with global trust, intended as a future input column set
            % for WSN_SinkFeatureExport / ML-IDS once the trust decision
            % matrix (see WSN_Sink_Enforcement.buildTrustMatrix) is active.
            row = struct( ...
                'nodeID', nodeID, ...
                'globalTrust', obj.getGlobalTrust(nodeID), ...
                'activeSensors', WSN_Sink_FeatureExport.getActiveSensorsCount(obj, t));
        end
    end
end
