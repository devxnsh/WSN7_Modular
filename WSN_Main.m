function WSN_Main()
% 1. INITIALIZATION
close all; rng('shuffle');
clear classes;
clc;
% Generate Topology
nodes = WSN_TopologyGenerator.generateTopology(WSN_Config.NodeCount, WSN_Config.FieldSize);

% Initialize GUI
gui = WSN_GUI(nodes, WSN_Config.FieldSize);

% Initialize Queues & Visuals
queue = {};
visualLines = [];

% Initial Physical Connectivity Calculation (Get both Phys and Stable matrices)
[physAdj, stblAdj, distMat] = WSN_Physics.updateConnectivity(nodes);
% --- ID TRANSLATION HELPERS ---
id2idx = @(hid) find(arrayfun(@(n) hex2dec(n.hexID) == hid, nodes), 1);
idx2id = @(idx) hex2dec(nodes(idx).hexID);

% 2. SIMULATION LOOP
try
    for t = 1:WSN_Config.SimSteps
        % Stop if GUI is closed
        if ~ishandle(gui.fig), break; end

        % --- A. GUI REFRESH (Throttled) ---
        if mod(t, WSN_Config.ActiveRefresh) == 0
            % Re-calculate topology (in case of mobility or power changes)
            [physAdj, stblAdj, distMat] = WSN_Physics.updateConnectivity(nodes);

            % Update Tables and Inspector
            gui.updateNetworkTable(nodes,t);
            gui.updateInspector(nodes, t);

            % Update Sink Graphs
            gui.updateSinkAnalytics(nodes, t);
        end

        % --- B. UPDATE PHYSICS & BATTERY ---
        for i = 1:numel(nodes)
            nodes(i).updatePhysics(t);
        end

        % --- C. MESSAGE GENERATION (Step) ---
        newMsgs = {};
        for i = 1:numel(nodes)
            % Polymorphic Step: Sink needs 'allNodes' for adaptive logic
            if isa(nodes(i), 'WSN_Sink')
                generated = nodes(i).step(t, physAdj, nodes);
            else
                generated = nodes(i).step(t, physAdj);
            end

            if ~isempty(generated)
                for g = generated
                    hex = g.serialize();                 % HARD TX BOUNDARY
                    WSN_GUI_GlobalEventBus.emit(t, hex); % TX sees real frame
                    newMsgs{end+1} = hex;
                end
            end

        end

        % --- D. MESSAGE DELIVERY (Processing) ---
        currentBatch = [queue, newMsgs];
        queue = {}; % Clear for next frame
        for k = 1:numel(currentBatch)
            hex = currentBatch{k};
        
            [msg, ok] = WSN_Message.deserialize(hex);
            if ~ok
                % DROP: corrupted, truncated, legacy, or bad checksum
                continue;
            end
            m = msg;
        
            srcIdx = id2idx(m.src);
            if isempty(srcIdx), continue; end
            if isempty(srcIdx), continue; end

            % 1. Determine Destinations (Safe Multicast Check)
            destinations = [];
            logDst = 'UNK';

            % Check for Broadcast (Empty or Scalar 0)
            isBroadcast = isempty(m.dst) || (isscalar(m.dst) && m.dst == 0);

            if isBroadcast
                % srcIdx = id2idx(m.src);
                % if isempty(srcIdx), continue; end
                destinations = find(physAdj(srcIdx, :));
                logDst = 'BCAST';

            elseif isscalar(m.dst)
                dstIdx = id2idx(m.dst);
                if isempty(dstIdx), continue; end
                destinations = dstIdx;
                logDst = nodes(dstIdx).hexID;

            else
                % Multicast: m.dst is vector of hex-dec IDs
                destinations = [];
                for hid = m.dst
                    di = id2idx(hid);
                    if ~isempty(di)
                        destinations(end+1) = di; %#ok<AGROW>
                    end
                end
                logDst = 'MULTI';
            end


            % 2. Attempt Delivery
            for dID = destinations
                % Safety check for invalid IDs
                if dID < 1 || dID > numel(nodes), continue; end

                % Protocol Filter: Heartbeats (Type 9) usually only matter between GWNs (Tier 3)
                if m.type == 9 && nodes(dID).tier ~= 3
                    continue;
                end

                % --- RELIABLE CHANNEL LOGIC ---
                canDeliver = false;

                % srcIdx = id2idx(m.src);
                % if isempty(srcIdx), continue; end

                if m.type == 7
                    if stblAdj(srcIdx, dID), canDeliver = true; end
                else
                    if physAdj(srcIdx, dID), canDeliver = true; end
                end

                if canDeliver
                    % Calculate RSSI based on Sender's Power
                    % srcIdx = id2idx(m.src);
                    % if isempty(srcIdx), continue; end

                    dist = distMat(srcIdx, dID);
                    % % ---- GLOBAL EVENT FEED (RX) ----
                    % WSN_GUI_GlobalEventBus.emit(t, m);


                    if nodes(srcIdx).tier == 3 && nodes(dID).tier == 3
                        if isprop(nodes(srcIdx), 'controlPower')
                            pwr = nodes(srcIdx).controlPower;
                        else
                            pwr = nodes(srcIdx).txPower;
                        end
                    else
                        pwr = nodes(srcIdx).txPower;
                    end

                    rssi = pwr * (1/(max(0.1, dist)^WSN_Config.PathLossExp)) * 100;

                    % DELIVER PACKET
                    response = nodes(dID).receive(m, t, rssi);
                    % ---- GLOBAL EVENT FEED (RX) ----
                    WSN_GUI_GlobalEventBus.emit(t, m);


                    % Handle Response
                    if ~isempty(response)
                        for r = response
                            hexR = r.serialize();
                            queue{end+1} = hexR;
                        end

                        % Log Receipt
                        tag = m.getTypeStr();
                        if isprop(m, 'isEncrypted') && m.isEncrypted, tag = ['[ENC] ' tag]; end

                    end

                    % VISUALIZATION
                    % srcIdx = id2idx(m.src);
                    % if isempty(srcIdx), continue; end
                    [col, lw, ls] = classifyPacket(m);
                    
                    vl = struct( ...
                        'srcPos', nodes(srcIdx).pos, ...
                        'dstPos', nodes(dID).pos, ...
                        'color',  col, ...
                        'style',  ls, ...
                        'width',  lw, ...
                        'expiry', t+5 );
                    
                    visualLines = [visualLines, vl];
                end
            end
        end

        % --- E. RENDER UPDATE ---
        if ~isempty(visualLines)
            visualLines = visualLines([visualLines.expiry] >= t);
        end

        gui.updateNetwork(nodes, physAdj, t);
        gui.drawPackets(visualLines, t);
        drawnow limitrate;
    end

catch ME
    % --- ERROR TRAPPING ---
    fprintf('CRASH AT t=%d: %s\n', t, ME.message);
    for k=1:length(ME.stack)
        fprintf('  File: %s, Line: %d\n', ME.stack(k).name, ME.stack(k).line);
    end
    errordlg(sprintf('Simulation Crashed at t=%d\n%s', t, ME.message), 'WSN Error');
end
function [col, lw, ls] = classifyPacket(m)
    % ---------- DEFAULT ----------
    col = [1 0.4 0.7];   % pink
    lw  = 0.5;
    ls  = '-';

    % ---------- HEARTBEATS ----------
    if m.type == 9
        if m.subtype == 3   % ENC_HB
            col = [0.6 0 0.8];   % purple
            lw  = 0.8;
        else
            ls = '--';           % discovery / hello
        end
        return;
    end

    % ---------- CMD FRAMES ----------
    if m.type ~= 7
        return;
    end

    switch m.subtype
        case 0  % PARENT_INIT
            col = [0 1 0];
            lw  = 1.0;

        case 1  % REQ_JOIN
            col = [0 1 1];       % cyan
            lw  = 1.2;

        case 2  % ACK_JOIN
            col = [0 0.8 0];
            lw  = 2.0;
            ls  = '--';

        case 3  % PARENT_REJECT
            col = [1 0 0];
            lw  = 0.8;

        case 4  % GLOBAL_KEY
            col = [0.9 0.6 0];   % amber
            lw  = 1.2;

        case 5  % ENC_HELLO
            col = [0.4 0.4 1];   % blue
            lw  = 1.0;
    end
end

end