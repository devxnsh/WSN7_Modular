classdef WSN_FeatureExport
    % =========================================================
    % LOCAL TELEMETRY DATASET EXPORTER (Phase 1a/1b of ML_IDS_PLAN.md)
    % Per-node, tapped-at-source feature accumulator -> trains the
    % local-tier model. Mirrors WSN_Attack.m's persistent pDataStore
    % pattern. Counters are bolted onto THIS class, not onto
    % WSN_Node/WSN_Sensor/WSN_Gateway/WSN_ClusterHead.
    % =========================================================

    methods (Static)
        % ---------------- PERSISTENT STORE ----------------
        function data = pDataStore(newData)
            persistent pData
            if nargin > 0
                pData = newData;
            end
            data = pData;
        end

        function setData(data)
            WSN_FeatureExport.pDataStore(data);
        end

        function data = getData()
            data = WSN_FeatureExport.pDataStore();
        end

        % ---------------- INIT ----------------
        function init(nodes)
            numNodes = numel(nodes);
            d = struct();
            d.numNodes = numNodes;
            d.windowStart = 1;

            % id (decimal hexID) -> array index, for tap sites that only
            % have the node object/hexID, not its array index (e.g. the
            % Behavior delegate in WSN_Gateway_Behavior.m).
            d.idMap = containers.Map('KeyType', 'double', 'ValueType', 'double');
            for i = 1:numNodes
                d.idMap(hex2dec(nodes(i).hexID)) = i;
            end

            % ---- per-window counters (reset on flush) ----
            d.txAttempts          = zeros(1, numNodes);
            d.txDelivered         = zeros(1, numNodes);
            d.rxCount              = zeros(1, numNodes);
            d.rssiSum              = zeros(1, numNodes);
            d.rssiCount            = zeros(1, numNodes);
            d.payloadLenSum        = zeros(1, numNodes);
            d.payloadLenCount      = zeros(1, numNodes);
            d.awakeTicks           = zeros(1, numNodes);
            d.windowTicks          = zeros(1, numNodes);
            d.retransmitCount      = zeros(1, numNodes);
            d.reElectionCount      = zeros(1, numNodes);
            d.encryptedCount       = zeros(1, numNodes);
            d.rekeyCount            = zeros(1, numNodes);
            d.intrusionCount       = zeros(1, numNodes);
            d.packetInjectionCount = zeros(1, numNodes);
            d.latencySum           = zeros(1, numNodes);
            d.latencyCount         = zeros(1, numNodes);
            d.phaseRunSum          = zeros(1, numNodes);
            d.phaseRunCount        = zeros(1, numNodes);

            % ---- cross-window state (NOT reset on flush) ----
            d.prevParent       = cell(1, numNodes);
            d.lastAggSentTime  = zeros(1, numNodes);
            d.prevPhase        = -ones(1, numNodes);
            d.phaseRunLen      = zeros(1, numNodes);

            d.rows = {};

            WSN_FeatureExport.setData(d);
        end

        % ---------------- TAPS ----------------

        function tapTx(nodeIdx, msg, t)
            % Called once per generated message (WSN_Main.m step-generation loop)
            d = WSN_FeatureExport.getData();
            if isempty(d) || nodeIdx < 1 || nodeIdx > d.numNodes, return; end

            d.txAttempts(nodeIdx) = d.txAttempts(nodeIdx) + 1;

            if msg.isEncrypted()
                d.encryptedCount(nodeIdx) = d.encryptedCount(nodeIdx) + 1;
            end

            isRekey = (msg.type == WSN_Config.MSG_TYPE_CH_CMD && msg.subtype == WSN_Config.CH_SUB_ACK) || ...
                      (msg.type == WSN_Config.MSG_TYPE_CMD && msg.subtype == 4); % 7.4 GLOBAL_KEY
            if isRekey
                d.rekeyCount(nodeIdx) = d.rekeyCount(nodeIdx) + 1;
            end

            if msg.type == WSN_Config.MSG_TYPE_PANIC && msg.subtype == WSN_Config.PANIC_SUB_INTRUSION
                d.intrusionCount(nodeIdx) = d.intrusionCount(nodeIdx) + 1;
            end

            if WSN_Attack.isMaliciousNode(nodeIdx, t)
                d.packetInjectionCount(nodeIdx) = d.packetInjectionCount(nodeIdx) + 1;
            end

            % 5.2 SENSOR_AGG: remember send time for latency pairing against the 5.3 ACK
            if msg.type == WSN_Config.MSG_TYPE_CH_HELLO && msg.subtype == WSN_Config.SENSOR_SUB_AGG
                d.lastAggSentTime(nodeIdx) = t;
            end

            WSN_FeatureExport.setData(d);
        end

        function tapTxSuccess(srcIdx)
            % Called once per generated message that reached at least one
            % destination (WSN_Main.m, after the per-destination delivery
            % loop). Kept separate from tapRx so broadcast messages with
            % many recipients don't inflate PDR past 1.0 -- PDR measures
            % "did this send succeed", not "how many copies arrived".
            d = WSN_FeatureExport.getData();
            if isempty(d) || srcIdx < 1 || srcIdx > d.numNodes, return; end
            d.txDelivered(srcIdx) = d.txDelivered(srcIdx) + 1;
            WSN_FeatureExport.setData(d);
        end

        function tapRx(dstIdx, rssi, msg, t)
            % Called at every successful pushRX() in WSN_Main.m's delivery loop
            d = WSN_FeatureExport.getData();
            if isempty(d), return; end

            if dstIdx >= 1 && dstIdx <= d.numNodes
                d.rxCount(dstIdx) = d.rxCount(dstIdx) + 1;
                d.rssiSum(dstIdx) = d.rssiSum(dstIdx) + rssi;
                d.rssiCount(dstIdx) = d.rssiCount(dstIdx) + 1;
                d.payloadLenSum(dstIdx) = d.payloadLenSum(dstIdx) + double(msg.payloadLen);
                d.payloadLenCount(dstIdx) = d.payloadLenCount(dstIdx) + 1;

                % 5.3 AGG_ACK received: close out latency measurement for this node
                if msg.type == WSN_Config.MSG_TYPE_CH_HELLO && msg.subtype == WSN_Config.SENSOR_SUB_ACK
                    if d.lastAggSentTime(dstIdx) > 0
                        latency = t - d.lastAggSentTime(dstIdx);
                        d.latencySum(dstIdx) = d.latencySum(dstIdx) + latency;
                        d.latencyCount(dstIdx) = d.latencyCount(dstIdx) + 1;
                        d.lastAggSentTime(dstIdx) = 0;
                    end
                end
            end

            WSN_FeatureExport.setData(d);
        end

        function tapRetransmitByHex(hexID)
            % Called from WSN_Gateway_Behavior.m where only the node object
            % (and thus its hexID), not its array index, is available.
            d = WSN_FeatureExport.getData();
            if isempty(d), return; end
            id = hex2dec(hexID);
            if ~isKey(d.idMap, id), return; end
            nodeIdx = d.idMap(id);
            d.retransmitCount(nodeIdx) = d.retransmitCount(nodeIdx) + 1;
            WSN_FeatureExport.setData(d);
        end

        function tapTick(nodeIdx, nodeObj, t)
            % Called once per node per tick (WSN_Main.m physics-update loop)
            d = WSN_FeatureExport.getData();
            if isempty(d) || nodeIdx < 1 || nodeIdx > d.numNodes, return; end

            d.windowTicks(nodeIdx) = d.windowTicks(nodeIdx) + 1;
            if nodeObj.isAwake
                d.awakeTicks(nodeIdx) = d.awakeTicks(nodeIdx) + 1;
            end

            % --- Re-election / parent-change detection (generic, all tiers) ---
            curParent = nodeObj.parent;
            prev = d.prevParent{nodeIdx};
            if ~isempty(prev) && ~isempty(curParent) && ~isequal(prev, curParent)
                d.reElectionCount(nodeIdx) = d.reElectionCount(nodeIdx) + 1;
            end
            d.prevParent{nodeIdx} = curParent;

            % --- Phase hold-time tracking (GWN/Sink only) ---
            if isprop(nodeObj, 'currentPhase')
                curPhase = nodeObj.currentPhase;
                if curPhase == WSN_Config.PHASE_TX
                    if d.prevPhase(nodeIdx) == WSN_Config.PHASE_TX
                        d.phaseRunLen(nodeIdx) = d.phaseRunLen(nodeIdx) + 1;
                    else
                        d.phaseRunLen(nodeIdx) = 1;
                    end
                else
                    if d.prevPhase(nodeIdx) == WSN_Config.PHASE_TX && d.phaseRunLen(nodeIdx) > 0
                        d.phaseRunSum(nodeIdx) = d.phaseRunSum(nodeIdx) + d.phaseRunLen(nodeIdx);
                        d.phaseRunCount(nodeIdx) = d.phaseRunCount(nodeIdx) + 1;
                    end
                    d.phaseRunLen(nodeIdx) = 0;
                end
                d.prevPhase(nodeIdx) = curPhase;
            end

            WSN_FeatureExport.setData(d);
        end

        % ---------------- WINDOW FLUSH ----------------

        function flushWindow(nodes, t)
            d = WSN_FeatureExport.getData();
            if isempty(d), return; end

            % Empirical RSSI calibration constants (see FEATURE_MAPPING.md, Phase 7).
            % RSSI here uses the same units as WSN_Main.m:324 / WSN_Physics.m:68
            % (rxMean = txPower * (1/dist^PathLossExp) * 100), NOT dBm.
            noiseFloor = WSN_Config.Sensitivity;   % decode threshold, same scale as RSSI
            rssiCeiling = 50;                      % empirical "strong link" ceiling, documented proxy

            numCH = 0; numSensor = 0;
            for i = 1:d.numNodes
                if nodes(i).tier == WSN_Config.TIER_CH
                    numCH = numCH + 1;
                elseif nodes(i).tier == WSN_Config.TIER_SENSOR
                    numSensor = numSensor + 1;
                end
            end
            chRatio = numCH / max(1, numSensor);

            attackNames = {'Normal','Flooding','PanicFlood','Sybil','Blackhole','Wormhole','Grayhole','DenialOfSleep'};

            for idx = 1:d.numNodes
                n = nodes(idx);

                pdr = 0;
                if d.txAttempts(idx) > 0
                    pdr = d.txDelivered(idx) / d.txAttempts(idx);
                end

                meanRSSI = 0;
                if d.rssiCount(idx) > 0
                    meanRSSI = d.rssiSum(idx) / d.rssiCount(idx);
                end

                lqi = 0; snrDB = 0; ber = 0.5; per = 1;
                if meanRSSI > 0
                    lqi = round(min(100, max(0, (meanRSSI - noiseFloor) / (rssiCeiling - noiseFloor) * 100)));
                    snrLinear = max(1e-6, meanRSSI / noiseFloor);
                    snrDB = 10 * log10(snrLinear);
                    ber = 0.5 * erfc(sqrt(snrLinear));
                    meanPayloadBits = 32;
                    if d.payloadLenCount(idx) > 0
                        meanPayloadBits = (d.payloadLenSum(idx) / d.payloadLenCount(idx)) * 8;
                    end
                    per = 1 - (1 - ber) ^ max(1, meanPayloadBits);
                end

                dutyCycle = 1.0;
                if d.windowTicks(idx) > 0
                    dutyCycle = d.awakeTicks(idx) / d.windowTicks(idx);
                end

                latency = NaN;
                if d.latencyCount(idx) > 0
                    latency = d.latencySum(idx) / d.latencyCount(idx);
                end

                phaseHoldTime = NaN;
                if isprop(n, 'currentPhase')
                    if d.phaseRunCount(idx) > 0
                        phaseHoldTime = d.phaseRunSum(idx) / d.phaseRunCount(idx);
                    else
                        phaseHoldTime = 0;
                    end
                end

                queueDepth = 0;
                if isprop(n, 'Q_fwd') && isprop(n, 'Q_local')
                    queueDepth = numel(n.Q_fwd) + numel(n.Q_local);
                end

                txPowerControl = NaN;
                if isprop(n, 'controlPower')
                    txPowerControl = n.controlPower;
                end

                txGain = double(n.txPower) / WSN_Config.NormalPower;

                hopCount = WSN_FeatureExport.computeHopCount(idx, nodes, d.idMap);

                keyOverhead = d.encryptedCount(idx) * 24; % 16B AES + 8B local key, see ML_IDS_PLAN.md 1a

                isMal = WSN_Attack.isMaliciousNode(idx, t);
                attackType = 0;
                if isMal
                    attackType = WSN_Attack.getAttackType(idx);
                end
                attackTypeName = attackNames{attackType + 1};

                row = sprintf(['%d,%d,%d,%s,%d,' ...
                    '%g,%d,%g,%g,%g,%g,%g,%g,' ...
                    '%g,%g,%d,%g,%g,' ...
                    '%d,%d,%g,%g,%d,%d,' ...
                    '%g,%d,%d,%d,' ...
                    '%d,%s,%d'], ...
                    d.windowStart, t, idx, n.hexID, n.tier, ...
                    meanRSSI, lqi, snrDB, ber, per, n.txPower, txPowerControl, txGain, ...
                    pdr, latency, queueDepth, dutyCycle, phaseHoldTime, ...
                    hopCount, numel(n.neighborTable), n.battery, chRatio, d.reElectionCount(idx), d.retransmitCount(idx), ...
                    keyOverhead, d.rekeyCount(idx), d.intrusionCount(idx), d.packetInjectionCount(idx), ...
                    attackType, attackTypeName, isMal);

                d.rows{end+1} = row;
            end

            % ---- reset per-window counters, keep cross-window state ----
            nz = zeros(1, d.numNodes);
            d.txAttempts = nz; d.txDelivered = nz; d.rxCount = nz;
            d.rssiSum = nz; d.rssiCount = nz;
            d.payloadLenSum = nz; d.payloadLenCount = nz;
            d.awakeTicks = nz; d.windowTicks = nz;
            d.retransmitCount = nz; d.reElectionCount = nz;
            d.encryptedCount = nz; d.rekeyCount = nz;
            d.intrusionCount = nz; d.packetInjectionCount = nz;
            d.latencySum = nz; d.latencyCount = nz;
            d.phaseRunSum = nz; d.phaseRunCount = nz;
            d.windowStart = t + 1;

            WSN_FeatureExport.setData(d);
        end

        function hops = computeHopCount(nodeIdx, nodes, idMap)
            % Real hop count to the node's current root (GWN/Sink), walked
            % via the parent chain (numeric IDs, same convention as idMap).
            % Previously this column was a copy-paste bug (n.tier); see
            % ML_IDS_PLAN.md 1a, which calls for a "real hop count".
            hops = 0;
            cur = nodeIdx;
            visited = false(1, numel(nodes));
            while hops < 15
                pid = nodes(cur).parent;
                if isempty(pid) || pid == 0 || ~isKey(idMap, pid)
                    break;
                end
                nextIdx = idMap(pid);
                if visited(nextIdx)
                    break;  % defensive: avoid infinite loop on a parent cycle
                end
                visited(nextIdx) = true;
                cur = nextIdx;
                hops = hops + 1;
            end
        end

        % ---------------- EXPORT ----------------

        function exportCSV(filename)
            d = WSN_FeatureExport.getData();
            if isempty(d) || isempty(d.rows)
                return;
            end

            fid = fopen(filename, 'w');
            header = ['WindowStart,WindowEnd,NodeIdx,NodeHexID,Tier,' ...
                'RSSI,LQI,SNR_dB,BER,PER,TxPower,TxPowerControl,TxGain,' ...
                'PDR,Latency,QueueDepth,DutyCycle,PhaseHoldTime,' ...
                'HopCount,NeighborCount,ResidualEnergy,CHRatio,ReElectionFreq,RetransmitCount,' ...
                'KeyOverhead,RekeyFreq,IntrusionRate,PacketInjectionCount,' ...
                'AttackType,AttackTypeName,IsMalicious'];
            fprintf(fid, '%s\n', header);
            for i = 1:numel(d.rows)
                fprintf(fid, '%s\n', d.rows{i});
            end
            fclose(fid);
        end
    end
end
