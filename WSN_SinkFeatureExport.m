classdef WSN_SinkFeatureExport
    % =========================================================
    % SINK-OBSERVED DATASET EXPORTER (Phase 1a/1b of ML_IDS_PLAN.md)
    % Computed PURELY from WSN_Sink.m's own registries
    % (sensorRegistry, nodeRegistry, globalTrustRegistry) at window
    % close -- no peeking at other nodes' internal state. Trains the
    % global-tier model. No per-tick taps needed; only two small
    % deltas (route-history growth, local-key changes) require a
    % cross-window cache, kept here rather than in WSN_Sink.m.
    % =========================================================

    methods (Static)
        function data = pDataStore(newData)
            persistent pData
            if nargin > 0
                pData = newData;
            end
            data = pData;
        end

        function setData(data)
            WSN_SinkFeatureExport.pDataStore(data);
        end

        function data = getData()
            data = WSN_SinkFeatureExport.pDataStore();
        end

        function init()
            d = struct();
            d.prevRouteHistoryCount = containers.Map('KeyType', 'double', 'ValueType', 'double');
            d.prevLocalKey = containers.Map('KeyType', 'char', 'ValueType', 'char');
            d.prevRoute = containers.Map('KeyType', 'char', 'ValueType', 'char');
            d.prevBattery = containers.Map('KeyType', 'double', 'ValueType', 'double');
            d.rows = {};
            WSN_SinkFeatureExport.setData(d);
        end

        function flushWindow(sink, id2idx, t, windowStart)
            d = WSN_SinkFeatureExport.getData();
            if isempty(d), return; end

            windowLen = max(1, t - windowStart + 1);
            expectedSensorPeriod = (WSN_Config.SENSOR_PERIOD_MIN + WSN_Config.SENSOR_PERIOD_MAX) / 2;
            expectedCount = windowLen / expectedSensorPeriod;

            numCH = 0;
            for j = 1:numel(sink.nodeRegistry)
                if startsWith(sink.nodeRegistry(j).hexID, 'AA')
                    numCH = numCH + 1;
                end
            end
            numSensors = numel(sink.sensorRegistry);
            chRatio = numCH / max(1, numSensors);
            activeSensorsRatio = sink.getActiveSensorsCount(t, windowLen) / max(1, numSensors);

            attackNames = {'Normal','Flooding','PanicFlood','Sybil','Blackhole','Wormhole','Grayhole','DenialOfSleep'};

            % ---- SENSOR rows ----
            for j = 1:numel(sink.sensorRegistry)
                s = sink.sensorRegistry(j);

                reportsReceived = 0;
                reportingGap = NaN;
                selfReportedBattery = NaN;
                reportedRSSI = NaN;
                if ~isempty(s.timeseries)
                    times = [s.timeseries.time];
                    reportsReceived = sum(times >= windowStart);
                    reportingGap = t - times(end);
                    selfReportedBattery = s.timeseries(end).battery;
                    reportedRSSI = s.timeseries(end).rssi;
                end
                expectedReportRatio = reportsReceived / max(1e-6, expectedCount);

                % EnergyConsumed: delta vs. last window's self-reported battery
                % (sensor-only -- CH/GWN report no battery telemetry to the sink)
                energyConsumed = NaN;
                if ~isnan(selfReportedBattery)
                    if isKey(d.prevBattery, s.id)
                        energyConsumed = max(0, d.prevBattery(s.id) - selfReportedBattery);
                    end
                    d.prevBattery(s.id) = selfReportedBattery;
                end

                rssiQualityBucket = 'UNKNOWN';
                if isfield(s, 'rssiQuality') && ~isempty(s.rssiQuality)
                    rssiQualityBucket = s.rssiQuality;
                end

                rhCount = 0;
                if isfield(s, 'routeHistory') && ~isempty(s.routeHistory)
                    rhCount = numel(s.routeHistory);
                end
                prevRH = 0;
                if isKey(d.prevRouteHistoryCount, s.id)
                    prevRH = d.prevRouteHistoryCount(s.id);
                end
                rerouteCount = max(0, rhCount - prevRH);
                d.prevRouteHistoryCount(s.id) = rhCount;

                hopCount = WSN_SinkFeatureExport.computeHopCount(sink, s.hexID);

                trustScore = 50;
                if isfield(s, 'TrustScore') && ~isempty(s.TrustScore)
                    trustScore = s.TrustScore;
                end
                anomalyCount = 0;
                if ~isempty(sink.globalTrustRegistry)
                    gIdx = find([sink.globalTrustRegistry.id] == s.id, 1);
                    if ~isempty(gIdx)
                        anomalyCount = sink.globalTrustRegistry(gIdx).anomalyCount;
                    end
                end

                nodeIdx = id2idx(s.id);
                isMal = false; attackType = 0;
                if ~isempty(nodeIdx)
                    isMal = WSN_Attack.isMaliciousNode(nodeIdx, t);
                    if isMal
                        attackType = WSN_Attack.getAttackType(nodeIdx);
                    end
                end
                attackTypeName = attackNames{attackType + 1};

                row = sprintf(['%d,%d,%d,%s,SENSOR,' ...
                    '%d,%g,%g,%g,%g,%s,' ...
                    '%d,%d,%d,' ...
                    '%g,%d,%g,%g,' ...
                    '%g,' ...
                    '%d,%s,%d'], ...
                    windowStart, t, s.id, s.hexID, ...
                    reportsReceived, reportingGap, expectedReportRatio, selfReportedBattery, reportedRSSI, rssiQualityBucket, ...
                    rerouteCount, hopCount, 0, ...
                    trustScore, anomalyCount, chRatio, activeSensorsRatio, ...
                    energyConsumed, ...
                    attackType, attackTypeName, isMal);
                d.rows{end+1} = row;
            end

            % ---- CH / GWN rows (from nodeRegistry) ----
            for j = 1:numel(sink.nodeRegistry)
                r = sink.nodeRegistry(j);
                id = hex2dec(r.hexID);

                rekeyEvent = 0;
                if isKey(d.prevLocalKey, r.hexID)
                    prevKey = d.prevLocalKey(r.hexID);
                    if ~isempty(prevKey) && ~strcmp(prevKey, r.localKey)
                        rekeyEvent = 1;
                    end
                end
                d.prevLocalKey(r.hexID) = r.localKey;

                rerouteCount = 0;
                if isKey(d.prevRoute, r.hexID)
                    prevRouteStr = d.prevRoute(r.hexID);
                    if ~isempty(prevRouteStr) && ~strcmp(prevRouteStr, r.route)
                        rerouteCount = 1;
                    end
                end
                d.prevRoute(r.hexID) = r.route;

                hopCount = WSN_SinkFeatureExport.computeHopCount(sink, r.hexID);

                trustScore = 50; anomalyCount = 0;
                if ~isempty(sink.globalTrustRegistry)
                    gIdx = find([sink.globalTrustRegistry.id] == id, 1);
                    if ~isempty(gIdx)
                        trustScore = sink.globalTrustRegistry(gIdx).TrustScore;
                        anomalyCount = sink.globalTrustRegistry(gIdx).anomalyCount;
                    end
                end

                nodeIdx = id2idx(id);
                isMal = false; attackType = 0;
                if ~isempty(nodeIdx)
                    isMal = WSN_Attack.isMaliciousNode(nodeIdx, t);
                    if isMal
                        attackType = WSN_Attack.getAttackType(nodeIdx);
                    end
                end
                attackTypeName = attackNames{attackType + 1};

                nodeType = 'GWN';
                if startsWith(r.hexID, 'AA')
                    nodeType = 'CH';
                end

                row = sprintf(['%d,%d,%d,%s,%s,' ...
                    'NaN,NaN,NaN,NaN,NaN,UNKNOWN,' ...
                    '%d,%d,%d,' ...
                    '%g,%d,%g,%g,' ...
                    'NaN,' ...
                    '%d,%s,%d'], ...
                    windowStart, t, id, r.hexID, nodeType, ...
                    rerouteCount, hopCount, rekeyEvent, ...
                    trustScore, anomalyCount, chRatio, activeSensorsRatio, ...
                    attackType, attackTypeName, isMal);
                d.rows{end+1} = row;
            end

            WSN_SinkFeatureExport.setData(d);
        end

        function hopCount = computeHopCount(sink, targetHex)
            routeStr = sink.traceRoute(targetHex);
            if isempty(routeStr)
                hopCount = 0;
                return;
            end
            parts = strsplit(routeStr, ' -> ');
            hopCount = max(0, numel(parts) - 1);
        end

        function exportCSV(filename)
            d = WSN_SinkFeatureExport.getData();
            if isempty(d) || isempty(d.rows)
                return;
            end

            fid = fopen(filename, 'w');
            header = ['WindowStart,WindowEnd,NodeIdx,NodeHexID,NodeType,' ...
                'ReportsReceived,ReportingGap,ExpectedReportRatio,SelfReportedBattery,ReportedRSSI,RSSIQualityBucket,' ...
                'RerouteCount,HopCount,RekeyEvent,' ...
                'TrustScore,AnomalyCount,CHRatio,ActiveSensorsRatio,' ...
                'EnergyConsumed,' ...
                'AttackType,AttackTypeName,IsMalicious'];
            fprintf(fid, '%s\n', header);
            for i = 1:numel(d.rows)
                fprintf(fid, '%s\n', d.rows{i});
            end
            fclose(fid);
        end
    end
end
