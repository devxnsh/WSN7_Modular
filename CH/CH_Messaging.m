% =====================================================
% CLUSTER HEAD (CH) MESSAGING MODULE
% =====================================================
% This module contains message creation, parsing, and handling for Cluster Heads:
% - Handshake messages (Type 6: CH_CMD with subtypes 0-5)
% - Sensor aggregation (Type 5: CH_HELLO with subtypes 2-3)
% - Panic message handling (Type 2)
% - Census protocol (Type 11)
% - Shutdown enforcement (Type 12)
%
% Intended to be delegated from WSN_ClusterHead main class.
% See CH_Behavior.m for decision logic.
%
% Status: Documented messaging reference (not yet separated into dedicated class)
% =====================================================

% =====================================================
% HANDSHAKE MESSAGE CREATION (Type 6: CH_CMD)
% =====================================================

% createCHREQ(srcID, dstID, t)
% Create 6.0 CH_REQ message (CH wants to join parent)
% Returns: WSN_Message object
function msg = createCHREQ(srcID, dstID, t)
    msg = WSN_Message();
    msg.type = 6;  % MSG_TYPE_CH_CMD
    msg.subtype = 0;  % CH_SUB_REQ
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));
    msg.flag = 0;
    msg.payloadLen = 0;
    msg.payload = [];
    msg.addChecksum();
end

% createCHACK_Response(srcID, dstID, localKey, t)
% Create 6.1 CH_ACK message (Parent GWN sends key to child CH)
% Returns: WSN_Message object
function msg = createCHACK_Response(srcID, dstID, localKey, t)
    msg = WSN_Message();
    msg.type = 6;  % MSG_TYPE_CH_CMD
    msg.subtype = 1;  % CH_SUB_ACK
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));
    msg.flag = 0;  % Not encrypted (parent sends first)
    msg.payload = localKey(1:min(16, numel(localKey)));  % 16-byte key
    msg.payloadLen = numel(msg.payload);
    msg.addChecksum();
end

% createKEY_ACK(srcID, dstID, localKey, t)
% Create 6.2 KEY_ACK message (Child CH confirms key receipt)
% Returns: WSN_Message object
function msg = createKEY_ACK(srcID, dstID, localKey, t)
    msg = WSN_Message();
    msg.type = 6;  % MSG_TYPE_CH_CMD
    msg.subtype = 2;  % CH_SUB_KEY_ACK
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));
    msg.flag = bitset(0, 1, 1);  % Encrypted flag
    msg.payload = localKey;  % Echo key as confirmation
    msg.payloadLen = numel(msg.payload);
    msg.addChecksum();
end

% createCHREJECT(srcID, dstID, t)
% Create 6.3 CH_REJECT message (Cannot accept recruit)
% Returns: WSN_Message object
function msg = createCHREJECT(srcID, dstID, t)
    msg = WSN_Message();
    msg.type = 6;
    msg.subtype = 3;  % CH_SUB_REJECT
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));
    msg.flag = 0;
    msg.payloadLen = 0;
    msg.payload = [];
    msg.addChecksum();
end

% createCHJOINOK(srcID, dstID, t)
% Create 6.4 CH_JOINOK message (Parent CH accepts child)
% Returns: WSN_Message object
function msg = createCHJOINOK(srcID, dstID, t)
    msg = WSN_Message();
    msg.type = 6;
    msg.subtype = 4;  % CH_SUB_JOINOK
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));
    msg.flag = 0;
    msg.payloadLen = 0;
    msg.payload = [];
    msg.addChecksum();
end

% createCHINFO(srcID, dstID, recruitedID, t, localKey)
% Create 6.5 CH_INFO message (Announce child recruitment to parent)
% Returns: WSN_Message object
function msg = createCHINFO(srcID, dstID, recruitedID, t, localKey)
    msg = WSN_Message();
    msg.type = 6;
    msg.subtype = 5;  % CH_SUB_INFO
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));

    % Payload: [RecruitedID(2), ParentID(2)]
    plainPayload = [typecast(uint16(recruitedID), 'uint8'), ...
                    typecast(uint16(srcID), 'uint8')];

    % Encrypt with local key if available
    if ~isempty(localKey)
        msg.payload = encryptPayloadXor(plainPayload, localKey);
        msg.flag = bitset(0, 1, 1);  % Encrypted flag
    else
        msg.payload = plainPayload;
        msg.flag = 0;
    end

    msg.payloadLen = numel(msg.payload);
    msg.addChecksum();
end

% =====================================================
% SENSOR AGGREGATION (Type 5: CH_HELLO)
% =====================================================

% createSensorAgg(srcID, dstID, sensorTable, fragIdx, totalFrags, t, localKey)
% Create 5.2 SENSOR_AGG message (Aggregated sensor data)
% Returns: WSN_Message object
function msg = createSensorAgg(srcID, dstID, sensorTable, fragIdx, totalFrags, t, localKey)
    msg = WSN_Message();
    msg.type = 5;  % MSG_TYPE_CH_HELLO
    msg.subtype = 2;  % SENSOR_SUB_AGG
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 5;
    msg.seq = uint8(mod(t + fragIdx, 256));

    % Payload: [TotalFrags(1), FragIdx(1), NumSensors(1), {SensorEntry} x N]
    numSensors = numel(sensorTable);
    payload = [uint8(totalFrags), uint8(fragIdx), uint8(numSensors)];

    for i = 1:numSensors
        s = sensorTable(i);
        sensorEntry = [ ...
            typecast(uint16(s.id), 'uint8'), ...
            typecast(uint16(s.lastTime), 'uint8'), ...
            typecast(uint16(s.value), 'uint8'), ...
            uint8(round(s.rssi * 10)), ...
            uint8(s.battery)];
        payload = [payload, sensorEntry];
    end

    % Encrypt with local key if available
    if ~isempty(localKey)
        msg.payload = encryptPayloadXor(payload, localKey);
        msg.flag = bitset(0, 1, 1);  % Encrypted flag
    else
        msg.payload = payload;
        msg.flag = 0;
    end

    msg.payloadLen = numel(msg.payload);
    msg.addChecksum();
end

% createAggACK(srcID, dstID, fragIdx, totalFrags, origSeq, t)
% Create 5.3 CH_ACK message (Acknowledge aggregation receipt)
% Returns: WSN_Message object
function msg = createAggACK(srcID, dstID, fragIdx, totalFrags, origSeq, t)
    msg = WSN_Message();
    msg.type = 5;
    msg.subtype = 3;  % SENSOR_SUB_ACK
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 1;
    msg.seq = origSeq;  % Echo back original sequence

    % Payload: [TotalFrags(1), AckedFragIdx(1)]
    msg.payload = [uint8(totalFrags), uint8(fragIdx)];
    msg.payloadLen = 2;

    msg.addChecksum();
end

% =====================================================
% PANIC MESSAGE CREATION (Type 2)
% =====================================================

% createPanicForward(srcID, dstID, origMsg, t)
% Create forwarded panic message (decremented TTL)
% Returns: WSN_Message object
function msg = createPanicForward(srcID, dstID, origMsg, t)
    msg = WSN_Message();
    msg.type = 2;  % MSG_TYPE_PANIC
    msg.subtype = origMsg.subtype;
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = origMsg.ttl - 1;
    msg.prio = origMsg.prio;
    msg.seq = origMsg.seq;
    msg.uid = origMsg.uid;

    msg.payload = origMsg.payload;
    msg.payloadLen = origMsg.payloadLen;

    msg.addChecksum();
end

% =====================================================
% CENSUS MESSAGE CREATION (Type 11)
% =====================================================

% createCensusPollInitiate(srcID, dstID, suspectID, pollUID, t)
% Create Type 11 CENSUS_POLL_INITIATE message
% Returns: WSN_Message object
function msg = createCensusPollInitiate(srcID, dstID, suspectID, pollUID, t)
    msg = WSN_Message();
    msg.type = 11;  % MSG_TYPE_CENSUS
    msg.subtype = 0;  % CENSUS_POLL_INITIATE
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));
    msg.uid = pollUID;

    payload = [typecast(uint16(suspectID), 'uint8'), ...
               typecast(uint16(pollUID), 'uint8'), ...
               uint8(1)];
    msg.payload = payload;
    msg.payloadLen = 5;

    msg.addChecksum();
end

% createCensusVote(srcID, dstID, suspectID, pollUID, voteYes, t)
% Create Type 11 CENSUS_POLL_YES/NO message
% Returns: WSN_Message object
function msg = createCensusVote(srcID, dstID, suspectID, pollUID, voteYes, t)
    msg = WSN_Message();
    msg.type = 11;
    if voteYes
        msg.subtype = 1;  % CENSUS_POLL_YES
    else
        msg.subtype = 2;  % CENSUS_POLL_NO
    end
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));
    msg.uid = pollUID;

    payload = [typecast(uint16(suspectID), 'uint8'), ...
               typecast(uint16(pollUID), 'uint8')];
    msg.payload = payload;
    msg.payloadLen = 4;

    msg.addChecksum();
end

% createCensusPollComplete(srcID, dstID, suspectID, verdict, yesVotes, totalVotes, t)
% Create Type 11 CENSUS_POLL_COMPLETE message
% Returns: WSN_Message object
function msg = createCensusPollComplete(srcID, dstID, suspectID, verdict, yesVotes, totalVotes, t)
    msg = WSN_Message();
    msg.type = 11;
    msg.subtype = 3;  % CENSUS_POLL_COMPLETE
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 5;
    msg.seq = uint8(mod(t, 256));

    payload = [typecast(uint16(suspectID), 'uint8'), ...
               uint8(verdict), ...
               uint8(min(255, yesVotes)), ...
               uint8(min(255, totalVotes))];
    msg.payload = payload;
    msg.payloadLen = 5;

    msg.addChecksum();
end

% =====================================================
% SHUTDOWN MESSAGE CREATION (Type 12)
% =====================================================

% createShutdownMessage(srcID, dstID, targetID, shutdownLevel, t)
% Create Type 12 SHUTDOWN message (Enforcement)
% Returns: WSN_Message object
function msg = createShutdownMessage(srcID, dstID, targetID, shutdownLevel, t)
    msg = WSN_Message();
    msg.type = 12;  % MSG_TYPE_SHUTDOWN
    msg.subtype = uint8(shutdownLevel);  % 0=SOFT, 1=HARD, 2=BLACKLIST
    msg.src = srcID;
    msg.dst = dstID;
    msg.ttl = 1;
    msg.seq = uint8(mod(t, 256));

    msg.payload = typecast(uint16(targetID), 'uint8');
    msg.payloadLen = 2;

    msg.addChecksum();
end

% =====================================================
% PAYLOAD PARSING
% =====================================================

% parseAggregation(msg)
% Extract sensor aggregation data from Type 5.2 message
% Returns: struct with (totalFrags, fragIdx, numSensors, sensors)
function data = parseAggregation(msg)
    totalFrags = 1;
    fragIdx = 1;
    numSensors = 0;
    sensors = [];

    if msg.payloadLen < 3
        data = struct('totalFrags', totalFrags, 'fragIdx', fragIdx, ...
                     'numSensors', numSensors, 'sensors', sensors);
        return;
    end

    totalFrags = double(msg.payload(1));
    fragIdx = double(msg.payload(2));
    numSensors = double(msg.payload(3));

    offset = 4;
    sensors = [];
    for i = 1:numSensors
        if offset + 7 > msg.payloadLen
            break;
        end

        sensorID = double(typecast(msg.payload(offset:offset+1), 'uint16'));
        sensorTime = double(typecast(msg.payload(offset+2:offset+3), 'uint16'));
        sensorValue = double(typecast(msg.payload(offset+4:offset+5), 'uint16'));
        sensorRSSI = double(msg.payload(offset+6)) / 10;
        sensorBattery = double(msg.payload(offset+7));

        sensors(i) = struct(...
            'id', sensorID, ...
            'lastTime', sensorTime, ...
            'value', sensorValue, ...
            'rssi', sensorRSSI, ...
            'battery', sensorBattery);

        offset = offset + 8;
    end

    data = struct('totalFrags', totalFrags, 'fragIdx', fragIdx, ...
                 'numSensors', numel(sensors), 'sensors', sensors);
end

% =====================================================
% HELPER: ENCRYPTION
% =====================================================

% encryptPayloadXor(payload, key)
% Simple XOR encryption with repeating key
% Returns: encrypted payload
function encrypted = encryptPayloadXor(payload, key)
    encrypted = payload;
    for i = 1:numel(payload)
        keyIdx = mod(i - 1, numel(key)) + 1;
        encrypted(i) = bitxor(payload(i), key(keyIdx));
    end
end

% =====================================================
% END OF CH_MESSAGING
% =====================================================
