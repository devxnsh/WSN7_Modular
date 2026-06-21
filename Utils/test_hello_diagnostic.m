%% HELLO MESSAGE DIAGNOSTIC TEST
% Verify broadcast delivery, Hello handling, and visualization

clear all; close all; clc;

% Setup
nodes = WSN_TopologyGenerator.generateRandomTopology(10, [0 100 0 100]);
sink = nodes(1);

fprintf('=== DIAGNOSTIC TEST ===\n');
fprintf('Nodes: %d\n', numel(nodes));
fprintf('Sink: %s (tier %d)\n\n', sink.hexID, sink.tier);

% Check broadcast constants
fprintf('Broadcast checks:\n');
fprintf('  DST=0: isBroadcast = %d\n', (0 == 0));
fprintf('  DST=0xFFFF: isBroadcast = %d\n', (hex2dec('FFFF') == hex2dec('FFFF')));

% Create a test Hello message
helloMsg = nodes(2).createHelloMessage(100);
fprintf('\nTest Hello message:\n');
fprintf('  Type: %d (expected 0)\n', helloMsg.type);
fprintf('  Subtype: %d (expected 0)\n', helloMsg.subtype);
fprintf('  Src: %04X (node 2)\n', helloMsg.src);
fprintf('  Dst: %04X (expected FFFF)\n', helloMsg.dst);
fprintf('  Payload length: %d bytes\n', helloMsg.payloadLen);

% Decode payload
[tier, battery, neighborCount] = helloMsg.getHelloPayload();
fprintf('  Payload decoded:\n');
fprintf('    Tier: %d\n', tier);
fprintf('    Battery: %d/15\n', battery);
fprintf('    NeighborCount: %d\n', neighborCount);

% Check destination filtering
fprintf('\nDestination filtering in Node.receive():\n');
isBcast = isempty(helloMsg.dst) || helloMsg.dst == 0 || helloMsg.dst == hex2dec('FFFF');
fprintf('  isBroadcast for dst=0xFFFF: %d (expected 1)\n', isBcast);

% Verify Hello is not type 7 (won't be filtered as recruitment)
fprintf('\nMessage type checks:\n');
fprintf('  Is Type 0? %d\n', helloMsg.type == WSN_Config.MSG_TYPE_HELLO);
fprintf('  Is Type 7? %d\n', helloMsg.type == 7);
fprintf('  Is Type 9? %d\n', helloMsg.type == 9);

% Test neighbor table update
fprintf('\nNeighbor table operations:\n');
testNode = nodes(3);
fprintf('  Before: %d neighbors\n', numel(testNode.neighborTable));
testNode.handleHelloReception(helloMsg, 100, 50.0);
fprintf('  After handling Hello: %d neighbors\n', numel(testNode.neighborTable));

if ~isempty(testNode.neighborTable)
    ne = testNode.neighborTable(end);
    fprintf('    Last neighbor ID: %04X\n', ne.id);
    fprintf('    Tier: %d\n', ne.tier);
    fprintf('    Battery: %d\n', ne.battery);
    fprintf('    NeighborCount: %d\n', ne.neighborCount);
end

% Test visualization classification
fprintf('\nVisualization classification:\n');
[col, lw, ls] = classifyPacketTest(helloMsg);
fprintf('  Color RGB: [%.2f, %.2f, %.2f]\n', col(1), col(2), col(3));
fprintf('  LineStyle: %s\n', ls);
fprintf('  LineWidth: %.2f\n', lw);

fprintf('\n=== CHECKS COMPLETE ===\n');

% Local copy of classifyPacket for testing
function [col, lw, ls] = classifyPacketTest(m)
    col = [1 0.4 0.7];
    lw  = 0.5;
    ls  = '-';
    
    if m.type == WSN_Config.MSG_TYPE_HELLO
        col = [0 0.5 0];
        lw  = 0.6;
        ls  = ':';
        return;
    end
    
    if m.type == 9
        if m.subtype == 3
            col = [0.6 0 0.8];
            lw  = 0.8;
        else
            ls = '--';
        end
        return;
    end
    
    if m.type ~= 7
        return;
    end
    
    switch m.subtype
        case 0
            col = [0 1 0];
            lw  = 1.0;
        case 1
            col = [0 1 1];
            lw  = 1.2;
        case 2
            col = [0 0.8 0];
            lw  = 2.0;
            ls  = '--';
        case 3
            col = [1 0 0];
            lw  = 0.8;
        case 4
            col = [0.9 0.6 0];
            lw  = 1.2;
        case 5
            col = [0.4 0.4 1];
            lw  = 1.0;
    end
end
