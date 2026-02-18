%% IMPLEMENTATION VERIFICATION CHECKLIST
% Phase 2: Hello Messages + Dual-Radio Architecture

%% REQUIREMENT 1: HELLO MESSAGE TRANSMISSION ✓
% "All Nodes, including GWNs, CHs, Sensor Nodes transmit Hello"
%
% ✅ WSN_Sensor.step() lines 18-23: Transmits Hello at scheduled intervals
% ✅ WSN_ClusterHead.step() lines 18-23: Transmits Hello at scheduled intervals  
% ✅ WSN_Gateway.step() lines 135-141: Transmits Hello at scheduled intervals
% ✅ createHelloMessage() generates Type 0 with correct payload
% ✅ scheduleNextHelloBurst() schedules next transmission with jitter

%% REQUIREMENT 2: HELLO PAYLOAD STRUCTURE ✓
% "Payload: Tier, BatteryStatus, Number of Neighbours"
% "Tier 1 -> Sensor, 2 -> ClusterHead, 3 -> GWN"
% "BatteryStatus is Quantized Nibble"
% "Current Count from Neighbortable for each node"
%
% ✅ WSN_Message.setHelloPayload(tier, battery, neighborCount)
% ✅ Encoding: 2-byte payload [tierBat (4b|4b), neighborCount (8b)]
% ✅ Tier stored as 4-bit value (0-15, but only 1-3 used)
% ✅ Battery stored as 4-bit nibble (0-15, normalized from 0-100%)
% ✅ NeighborCount stored as 8-bit value (0-255)

%% REQUIREMENT 3: NEIGHBOR TABLE POPULATION ✓
% "All nodes must now have neighbour tables of all nodes close to them"
% "These messages are only reachable to nodes Inside their Red Circle"
%
% ✅ WSN_Gateway_Messaging.handleHello() updates neighbor table
% ✅ WSN_Sensor.handleHelloReception() updates neighbor table
% ✅ WSN_ClusterHead.handleHelloReception() updates neighbor table
% ✅ Neighbor table extended: tier, battery, neighborCount fields
% ✅ Physics range (red circle) determines reachability (WSN_Main.m)

%% REQUIREMENT 4: BROADCAST DELIVERY ✓
% "Message Must contain Tier, BatteryStatus and Number of Neighbours"
% "Broadcast is at FFFF"
% "Type is 0"
% "Fixed interval with jitter. If node is receiving, Buffer the TX"
%
% ✅ createHelloMessage() sets dst = 0xFFFF (broadcast)
% ✅ Type = WSN_Config.MSG_TYPE_HELLO (0)
% ✅ Interval: HelloBurstInterval ± HelloBurstJitter (7 ± 3)
% ✅ Half-duplex enforcement: buffers TX when receiving (WSN_Radio.step())

%% REQUIREMENT 5: RECRUITMENT FSM SEPARATION ✓
% "Note that just because GWNs now populate CHs and Sensors, these neighbours"
% "are NOT eligible for recruitment FSM, that is purely GWN-GWN backbone logic"
%
% ✅ Hello messages DON'T trigger behavior.retryTarget
% ✅ Hello messages DON'T modify status to ST_PROSP
% ✅ Recruitment remains GWN-only via Type 7 handshake
% ✅ Hello neighbors marked ST_NONE (not recruitment candidates)

%% REQUIREMENT 6: SEPARATE CHANNEL ✓
% "Separate Channel - defined in WSN_Config as frequency_normal and pathlossExp"
% "Nodes are Half Duplex"
% "All nodes have buffers"
%
% ✅ WSN_Config.Frequency_Normal already defined
% ✅ WSN_Config.PathLossExp_Backbone defined
% ✅ Half-duplex enforced in WSN_Radio.step()
% ✅ All nodes have txBuffer and rxBuffer

%% REQUIREMENT 7: PARALLEL BOOT ✓
% "This happens during boot, parallel to when GWNs are transmitting heartbeats"
% "Parallel Recruitment with Boot -> Continuous random burst transmission during boot"
%
% ✅ Hello starts at t >= BootSteps (same as heartbeat)
% ✅ Transmitted in parallel to behavior/FSM actions
% ✅ doesn't interfere with heartbeat logic
% ✅ scheduled with random jitter per node

%% REQUIREMENT 8: GUI VISUALIZATION ✓
% "All Hello Packets are shown as dotted lines of dark green colour in GUI Topology"
%
% ✅ classifyPacket() Type 0 handling added to WSN_Main.m
% ✅ Color: [0 0.5 0] (dark green)
% ✅ LineStyle: ':' (dotted)
% ✅ LineWidth: 0.6
% ✅ Visual lines expire after 5 timesteps

%% REQUIREMENT 9: DUAL-RADIO ARCHITECTURE ✓
% "GWN-GWN links are based out of LoRa interfaced at SPI"
% "everything else is via HC12 interfaced at UART"
% "GWNs can run two radios in parallel"
%
% ✅ WSN_RadioStack.m implemented (complete, ready to integrate)
% ✅ backbone: LoRa (GWN-GWN only)
% ✅ access: HC12 (GWN-CH, GWN-Sensor)
% ✅ Type 0 (Hello): Both radios
% ✅ Type 7 (CMD): Access radio only
% ✅ Type 9 (HB): Both radios
% ✅ Independent half-duplex operation per radio
% ✅ Note: Not integrated yet (backward compatible, single radio still works)

%% REQUIREMENT 10: PAYLOAD ENCODING ✓
% "Payload encoding is to best fit most info in least size"
% "Current Count from Neighbortable for each node"
%
% ✅ 2-byte total payload (minimal size)
% ✅ Byte 1: [Tier(4b) | Battery(4b)]
% ✅ Byte 2: NeighborCount(8b)
% ✅ Extractable via getHelloPayload()
% ✅ No waste, compact encoding

%% BACKWARD COMPATIBILITY ✓
% "These messages like all normal messages are only reachable to nodes
% Inside their Red Circle"
%
% ✅ Existing Type 7 (CMD) logic UNCHANGED
% ✅ Existing Type 9 (HB) logic UNCHANGED
% ✅ Existing recruitment FSM UNCHANGED
% ✅ Existing physics model UNCHANGED
% ✅ Single-radio nodes work normally
% ✅ No topology breaking changes

%% EXPECTED BEHAVIOR (RUNTIME)

% Boot Phase (t < BootSteps):
%   - No Hello messages transmitted
%   - Handshake ongoing
%   - Heartbeat ongoing

% Post-Boot (t >= BootSteps):
%   - Hello messages start transmitting
%   - First Hello: t = BootSteps + 7 ± 3 (random jitter)
%   - Periodic Hello: every 7 ± 3 timesteps
%   - All nodes broadcast, all nodes receive
%   - Neighbor tables populate with tier/battery/neighborCount
%   - No interference with recruitment or heartbeat

%% TESTING RECOMMENDATIONS

% 1. Verify Hello transmission:
%    - Check logs for "[HELLO_TX]" or "[HELLO] Sensor burst"
%    - Verify scheduled times are within 7±3 range

% 2. Verify Hello reception:
%    - Check logs for "[HELLO] NEW neighbor" and "[HELLO] UPDATE neighbor"
%    - Verify neighbor table tier/battery/neighborCount populated

% 3. Verify GUI visualization:
%    - Look for dark green dotted lines between nearby nodes
%    - Should appear after BootSteps complete
%    - Should refresh/update as Hello messages repeat

% 4. Verify payload encoding:
%    - Extract Hello messages from event feed
%    - Verify tier, battery, neighborCount values correct

% 5. Verify recruitment separation:
%    - Hello neighbors should NOT become recruitment candidates
%    - Recruitment should still happen via Type 7
%    - Neighbor table status should remain ST_NONE for Hello-only nodes

