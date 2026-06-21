% =====================================================
% SENSOR NODE (SN) MESSAGING MODULE
% =====================================================
% This module contains message creation, parsing, and handling for Sensor Nodes:
% - Message serialization (Type 0: HELLO, 1: SENSOR, 2: PANIC, 11: CENSUS, 12: SHUTDOWN)
% - Inbound message dispatch
% - Payload encoding/decoding
%
% Intended to be delegated from WSN_Sensor main class.
% See SN_Behavior.m for decision logic.
%
% Status: Documented messaging reference (not yet separated into dedicated class)
% =====================================================

% =====================================================
% MESSAGE CREATION
% =====================================================

% createSensorMessage(srcID, dstID, sensorValue, battery, priority, t)
% Create Type 1 SENSOR message
% Returns: WSN_Message object
%
% Payload format:
%   [SensorValue(2), Battery(1)] = 3 bytes
%
% Subtype encodes priority (2-bit, stored in subtype field)
% TTL: 1 (single hop to parent)
function msg = createSensorMessage(srcID, dstID, sensorValue, battery, priority, t)
    msg = WSN_Message();
    msg.type = 1;  % MSG_TYPE_SENSOR
    msg.subtype = uint8(bitand(priority, 3));  % 2-bit priority
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));

    % Payload: sensor value (2 bytes LE) + battery (1 byte)
    valueBytes = typecast(uint16(sensorValue), 'uint8');
    batteryByte = uint8(round(battery));
    msg.payload = [valueBytes, batteryByte];
    msg.payloadLen = 3;

    msg.addChecksum();
end

% createPanicMessage(srcID, dstID, panicType, severity, sensorValue, battery, t)
% Create Type 2 PANIC message
% Returns: WSN_Message object
%
% Payload format:
%   [OriginalSrc(2), SensorValue(2), Battery(1), Timestamp(2)] = 7 bytes
%
% Subtype: panic type (ANOMALY=0, BATTERY_CRIT=1, INTRUSION=2, LINK_LOSS=3)
% Priority (prio): severity (LOW=0, MEDIUM=1, HIGH=2, CRITICAL=3)
% TTL: 5 if HIGH/CRITICAL, else 1
% UID: Unique message ID for deduplication
function msg = createPanicMessage(srcID, dstID, panicType, severity, sensorValue, battery, t)
    msg = WSN_Message();
    msg.type = 2;  % MSG_TYPE_PANIC
    msg.subtype = uint8(panicType);
    msg.src = srcID;
    msg.dst = dstID;
    msg.prio = uint8(severity);
    msg.seq = uint8(mod(t, 256));
    msg.uid = randi(1e9);  % Unique ID for deduplication

    % Set TTL based on severity
    if severity >= 2  % HIGH or CRITICAL
        msg.ttl = 5;
    else
        msg.ttl = 1;
    end

    % Payload: [OrigSrc(2), SensorValue(2), Battery(1), Timestamp(2)] = 7 bytes
    origSrcBytes = typecast(uint16(srcID), 'uint8');
    valueBytes = typecast(uint16(sensorValue), 'uint8');
    batteryByte = uint8(round(battery));
    timeBytes = typecast(uint16(mod(t, 65536)), 'uint8');
    msg.payload = [origSrcBytes, valueBytes, batteryByte, timeBytes];
    msg.payloadLen = 7;

    msg.addChecksum();
end

% createPanicForward(srcID, origMsg)
% Create forwarded panic message (decremented TTL)
% Returns: WSN_Message object
%
% Copies payload and metadata, decrements TTL, changes source to forwarder
function msg = createPanicForward(srcID, origMsg)
    msg = WSN_Message();
    msg.type = 2;  % MSG_TYPE_PANIC
    msg.subtype = origMsg.subtype;
    msg.src = srcID;  % Forwarder is new source
    msg.dst = origMsg.dst;
    msg.ttl = origMsg.ttl - 1;  % Decrement
    msg.prio = origMsg.prio;
    msg.seq = origMsg.seq;
    msg.uid = origMsg.uid;  % Preserve for dedup chain

    % Copy payload unchanged
    msg.payload = origMsg.payload;
    msg.payloadLen = origMsg.payloadLen;

    msg.addChecksum();
end

% =====================================================
% CENSUS MESSAGE CREATION (Phase 4)
% =====================================================

% createCensusPollInitiate(srcID, suspectID, pollUID, t)
% Create Type 11 CENSUS_POLL_INITIATE message
% Returns: WSN_Message object
%
% Subtype: 0 (CENSUS_POLL_INITIATE)
% Broadcast to network (dst = 0xFFFF)
% Payload: [SuspectID(2), PollUID(2), IsInitiator(1)] = 5 bytes
function msg = createCensusPollInitiate(srcID, suspectID, pollUID, t)
    msg = WSN_Message();
    msg.type = 11;  % MSG_TYPE_CENSUS
    msg.subtype = 0;  % CENSUS_POLL_INITIATE
    msg.src = srcID;
    msg.dst = hex2dec('FFFF');  % Broadcast
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));
    msg.uid = pollUID;  % Store poll UID in msg.uid

    % Payload: [SuspectID(2), PollUID(2), IsInitiator(1)]
    suspectBytes = typecast(uint16(suspectID), 'uint8');
    pollBytes = typecast(uint16(pollUID), 'uint8');
    initiator = uint8(1);
    msg.payload = [suspectBytes, pollBytes, initiator];
    msg.payloadLen = 5;

    msg.addChecksum();
end

% createCensusVote(srcID, dstID, suspectID, pollUID, voteYes, t)
% Create Type 11 CENSUS_POLL_YES/NO message
% Returns: WSN_Message object
%
% Subtype: 1 (CENSUS_POLL_YES) or 2 (CENSUS_POLL_NO)
% Send back to initiator (unicast)
function msg = createCensusVote(srcID, dstID, suspectID, pollUID, voteYes, t)
    msg = WSN_Message();
    msg.type = 11;  % MSG_TYPE_CENSUS
    if voteYes
        msg.subtype = 1;  % CENSUS_POLL_YES
    else
        msg.subtype = 2;  % CENSUS_POLL_NO
    end
    msg.src = srcID;
    msg.dst = dstID;  % Back to initiator
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));
    msg.uid = pollUID;

    % Payload: [SuspectID(2), PollUID(2)]
    suspectBytes = typecast(uint16(suspectID), 'uint8');
    pollBytes = typecast(uint16(pollUID), 'uint8');
    msg.payload = [suspectBytes, pollBytes];
    msg.payloadLen = 4;

    msg.addChecksum();
end

% createCensusPollComplete(srcID, dstID, suspectID, verdict, yesVotes, totalVotes, t)
% Create Type 11 CENSUS_POLL_COMPLETE message
% Returns: WSN_Message object
%
% Subtype: 3 (CENSUS_POLL_COMPLETE)
% Forward verdict up-tree (to parent)
% Payload: [SuspectID(2), Verdict(1), YesVotes(1), TotalVotes(1)] = 5 bytes
function msg = createCensusPollComplete(srcID, dstID, suspectID, verdict, yesVotes, totalVotes, t)
    msg = WSN_Message();
    msg.type = 11;  % MSG_TYPE_CENSUS
    msg.subtype = 3;  % CENSUS_POLL_COMPLETE
    msg.src = srcID;
    msg.dst = dstID;  % Forward to parent
    msg.ttl = 5;
    msg.seq = uint8(mod(t, 256));

    % Payload: [SuspectID(2), Verdict(1), YesVotes(1), TotalVotes(1)]
    suspectBytes = typecast(uint16(suspectID), 'uint8');
    verdictByte = uint8(verdict);
    yesByte = uint8(min(255, yesVotes));  % Cap at 255
    totalByte = uint8(min(255, totalVotes));
    msg.payload = [suspectBytes, verdictByte, yesByte, totalByte];
    msg.payloadLen = 5;

    msg.addChecksum();
end

% =====================================================
% PAYLOAD PARSING
% =====================================================

% parseSensorMessage(msg)
% Extract sensor data from Type 1 message
% Returns: struct with (sensorValue, battery, priority)
function data = parseSensorMessage(msg)
    if msg.payloadLen < 3
        data = struct('sensorValue', 0, 'battery', 0, 'priority', 0);
        return;
    end

    valueBytes = msg.payload(1:2);
    sensorValue = double(typecast(valueBytes, 'uint16'));
    battery = double(msg.payload(3));
    priority = msg.subtype;  % Priority encoded in subtype

    data = struct('sensorValue', sensorValue, 'battery', battery, 'priority', priority);
end

% parsePanicMessage(msg)
% Extract panic data from Type 2 message
% Returns: struct with (panicType, severity, origSrc, sensorValue, battery, timestamp)
function data = parsePanicMessage(msg)
    panicType = msg.subtype;
    severity = msg.prio;

    origSrc = 0;
    sensorValue = 0;
    battery = 0;
    timestamp = 0;

    if msg.payloadLen >= 7
        origSrc = double(typecast(msg.payload(1:2), 'uint16'));
        sensorValue = double(typecast(msg.payload(3:4), 'uint16'));
        battery = double(msg.payload(5));
        timestamp = double(typecast(msg.payload(6:7), 'uint16'));
    end

    data = struct(...
        'panicType', panicType, ...
        'severity', severity, ...
        'origSrc', origSrc, ...
        'sensorValue', sensorValue, ...
        'battery', battery, ...
        'timestamp', timestamp);
end

% parseCensusMessage(msg)
% Extract census data from Type 11 message
% Returns: struct with relevant fields based on subtype
function data = parseCensusMessage(msg)
    subtype = msg.subtype;

    suspectID = 0;
    pollUID = 0;
    verdict = 0;
    yesVotes = 0;
    totalVotes = 0;

    if msg.payloadLen >= 2
        suspectID = double(typecast(msg.payload(1:2), 'uint16'));
    end

    switch subtype
        case 0  % CENSUS_POLL_INITIATE
            if msg.payloadLen >= 4
                pollUID = double(typecast(msg.payload(3:4), 'uint16'));
            end
        case {1, 2}  % CENSUS_POLL_YES / CENSUS_POLL_NO
            if msg.payloadLen >= 4
                pollUID = double(typecast(msg.payload(3:4), 'uint16'));
            end
        case 3  % CENSUS_POLL_COMPLETE
            if msg.payloadLen >= 5
                verdict = double(msg.payload(3));
                yesVotes = double(msg.payload(4));
                totalVotes = double(msg.payload(5));
            end
    end

    data = struct(...
        'subtype', subtype, ...
        'suspectID', suspectID, ...
        'pollUID', pollUID, ...
        'verdict', verdict, ...
        'yesVotes', yesVotes, ...
        'totalVotes', totalVotes);
end

% =====================================================
% MESSAGE DISPATCH
% =====================================================

% dispatchMessage(msg, srcID, dstID)
% Determine message type and return handler name
% Returns: string (handler name) or 'unknown'
function handler = getMessageHandler(msg)
    switch msg.type
        case 0
            handler = 'handle_hello';
        case 1
            handler = 'handle_sensor';  % CHs only; SNs ignore
        case 2
            handler = 'handle_panic';
        case 11
            handler = 'handle_census';
        case 12
            handler = 'handle_shutdown';
        otherwise
            handler = 'unknown';
    end
end

% =====================================================
% HELLO MESSAGE (Discovery)
% =====================================================

% parseHelloMessage(msg)
% Extract hello data from Type 0 broadcast
% Returns: struct with (tier, battery, neighborCount, isVerified)
function data = parseHelloMessage(msg)
    tier = 0;
    battery = 0;
    neighborCount = 0;
    isVerified = false;

    if msg.payloadLen >= 2
        tier = double(msg.payload(1));
        battery = double(msg.payload(2));
    end

    if msg.payloadLen >= 3
        neighborCount = double(msg.payload(3));
    end

    % Extract verified flag from msg.flag (bit 0)
    isVerified = bitget(msg.flag, 1) == 1;

    data = struct(...
        'tier', tier, ...
        'battery', battery, ...
        'neighborCount', neighborCount, ...
        'isVerified', isVerified);
end

% =====================================================
% SHUTDOWN MESSAGE (Enforcement)
% =====================================================

% parseShutdownMessage(msg)
% Extract shutdown command from Type 12 message
% Returns: struct with (shutdownLevel, targetID)
function data = parseShutdownMessage(msg)
    shutdownLevel = msg.subtype;  % 0=SOFT, 1=HARD, 2=BLACKLIST

    targetID = 0;
    if msg.payloadLen >= 2
        targetID = double(typecast(msg.payload(1:2), 'uint16'));
    end

    data = struct('shutdownLevel', shutdownLevel, 'targetID', targetID);
end

% =====================================================
% MESSAGE FILTERING
% =====================================================

% shouldProcessMessage(msg, myID, myTier, isAwake, isBroadcast)
% Pre-filter check before routing to handler
% Returns: boolean (true = process, false = drop)
function accept = shouldProcess(msg, myID, isAwake, isVerified)
    % Drop if not awake
    if ~isAwake
        accept = false;
        return;
    end

    % Type-specific filtering
    switch msg.type
        case 0  % HELLO
            % Always process broadcasts
            accept = true;
        case 2  % PANIC
            % Process all panic (high priority)
            accept = true;
        case 11  % CENSUS
            % Process all census (voting)
            accept = true;
        case 12  % SHUTDOWN
            % Process only if directed at me
            accept = true;  % Will check dst in handler
        case 1  % SENSOR
            % SNs don't aggregate sensor data; drop
            accept = false;
        otherwise
            accept = false;
    end
end

% =====================================================
% END OF SN_MESSAGING
% =====================================================
