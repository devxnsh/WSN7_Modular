classdef WSN_Message < handle
    % =========================================================
    % WSN MESSAGE — CANONICAL FLAGS, STABLE CHECKSUM
    % =========================================================

    properties (Constant)
        GLOBAL_AES_KEY_HEX = '2B7E151628AED2A6ABF7158809CF4F3C'
    end

    properties
        % ---------------- Header ----------------
        type        uint8
        subtype     uint8
        src         uint16  % Immediate sender (unencrypted)
        dst         uint16  % Immediate receiver (unencrypted)

        % ---------------- Layered Encryption Fields ----------------
        originalSrc uint16 = uint16(0)  % Original message sender (globally encrypted)
        globalEncryptedPayload uint8 = uint8([])  % Globally encrypted data
        doubleEncryptedPayload uint8 = uint8([])  % Double encrypted data

        % ---------------- Payload (legacy, for backward compatibility) ----------------
        payload     uint8 = uint8([])
        payloadLen  uint8 = uint8(0)

        % ---------------- Control ----------------
        flag        uint8 = uint8(0)   % bit1=ENC, bit2=VER, bit3=GLOBAL_ENC, bit4=DOUBLE_ENC
        prio        uint8 = uint8(0)
        ttl         uint8 = uint8(5)
        seq         uint8 = uint8(0)   % Sequence number

        % ---------------- Integrity ----------------
        checksum    uint8 = uint8(0)
        checksumOK  logical = true

        % ---------------- Visualization ----------------
        color
        uid
    end

    % =========================================================
    % CONSTRUCTOR
    % =========================================================
    methods
        function obj = WSN_Message(type, src, dst, payloadHex, col)
            if nargin == 0, return; end

            obj.type    = uint8(type);
            obj.subtype = uint8(0);
            obj.src     = uint16(src);
            obj.dst     = uint16(ifelse(isempty(dst),0,dst));

            if nargin >= 4 && ~isempty(payloadHex)
                payloadHex = upper(char(payloadHex));
                if mod(numel(payloadHex),2) ~= 0
                    error('Payload hex must be byte-aligned');
                end
                obj.payload = uint8(hex2dec(reshape(payloadHex,2,[])'));
            end

            obj.payloadLen = uint8(numel(obj.payload));

            if nargin >= 5
                obj.color = col;
            end

            obj.uid = randi(1e9);

            obj.addChecksum();
        end
    end

    % =========================================================
    % FLAGS (CANONICAL)
    % =========================================================
    methods
        function setEncrypted(obj, tf)
            obj.flag = bitset(obj.flag,1,logical(tf));
        end

        function setVerified(obj, tf)
            obj.flag = bitset(obj.flag,2,logical(tf));
        end

        function setGlobalEncrypted(obj, tf)
            obj.flag = bitset(obj.flag,3,logical(tf));
        end

        function setDoubleEncrypted(obj, tf)
            obj.flag = bitset(obj.flag,4,logical(tf));
        end

        function tf = isEncrypted(obj)
            tf = bitget(obj.flag,1);
        end

        function tf = isVerified(obj)
            tf = bitget(obj.flag,2);
        end

        function tf = isGlobalEncrypted(obj)
            tf = bitget(obj.flag,3);
        end

        function tf = isDoubleEncrypted(obj)
            tf = bitget(obj.flag,4);
        end
    end

    % =========================================================
    % LAYERED ENCRYPTION METHODS
    % =========================================================
    methods
        function applyLayeredEncryption(obj, originalSender, globalKey, localKey)
            % Apply layered encryption as specified:
            % 1. Unencrypted: immediate sender, receiver, message type (already set)
            % 2. Globally encrypted: original sender (prepended to payload)
            % 3. Double encrypted: payload data
            %
            % Final payload format: [originalSrc(2 bytes), encryptedPayload...]
            % This matches deserialize() which extracts originalSrc from first 2 bytes

            if nargin < 2, originalSender = obj.src; end
            if nargin < 3, globalKey = obj.GLOBAL_AES_KEY_HEX; end

            obj.originalSrc = uint16(originalSender);
            originalSrcBytes = typecast(obj.originalSrc, 'uint8');

            % Step 1: Encrypt the payload
            if nargin >= 4 && ~isempty(localKey) && ~isempty(obj.payload)
                % Double encrypt: local key first, then global key
                localEncrypted = WSN_Crypto.encrypt(obj.payload, localKey);
                encryptedPayload = WSN_Crypto.encrypt(localEncrypted, globalKey);
                obj.setDoubleEncrypted(true);
            elseif ~isempty(obj.payload)
                % Single encryption with global key
                encryptedPayload = WSN_Crypto.encrypt(obj.payload, globalKey);
                obj.setDoubleEncrypted(true);
            else
                encryptedPayload = uint8([]);
            end

            % Step 2: Prepend originalSrc (unencrypted) to encrypted payload
            % This format matches deserialize() expectations
            obj.doubleEncryptedPayload = [originalSrcBytes(:)', encryptedPayload(:)'];
            obj.globalEncryptedPayload = originalSrcBytes;  % Keep for compatibility
            obj.setGlobalEncrypted(true);
        end

        function [decryptedPayload, originalSender] = decryptLayered(obj, globalKey, localKey)
            % Decrypt layered encryption
            % Format: first 2 bytes of payload = originalSrc (unencrypted)
            %         remaining bytes = encrypted payload data
            % NOTE: doubleEncryptedPayload now includes originalSrc for checksum
            %       so we must skip first 2 bytes when decrypting
            originalSender = obj.originalSrc; % Original sender (already extracted in deserialize)
            if originalSender == 0
                originalSender = obj.src; % Fallback to immediate sender
            end
            decryptedPayload = obj.payload; % Default to current payload

            try
                if obj.isDoubleEncrypted() && ~isempty(obj.doubleEncryptedPayload)
                    % Skip first 2 bytes (originalSrc) then decrypt
                    encryptedPart = obj.doubleEncryptedPayload(3:end);
                    % Double decryption: global key first, then local key
                    globalDecrypted = WSN_Crypto.decrypt(encryptedPart, globalKey);
                    if nargin >= 3 && ~isempty(localKey)
                        decryptedPayload = WSN_Crypto.decrypt(globalDecrypted, localKey);
                    else
                        decryptedPayload = globalDecrypted;
                    end
                elseif obj.isGlobalEncrypted() && ~isempty(obj.globalEncryptedPayload)
                    % Skip first 2 bytes (originalSrc) then decrypt
                    encryptedPart = obj.globalEncryptedPayload(3:end);
                    decryptedPayload = WSN_Crypto.decrypt(encryptedPart, globalKey);
                end
            catch
                % Decryption failed, return original data
            end
        end
    end

    % =========================================================
    % CHECKSUM
    % =========================================================
    methods
        function addChecksum(obj)
            bytes = obj.rawBytesNoChecksum();
            c = uint8(0);
            for i = 1:numel(bytes)
                c = bitxor(c, bytes(i));
            end
            obj.checksum = bitand(c,15);
            obj.checksumOK = true;
        end

        function ok = verifyChecksum(obj)
            bytes = obj.rawBytesNoChecksum();
            c = uint8(0);
            for i = 1:numel(bytes)
                c = bitxor(c, bytes(i));
            end
            ok = (bitand(c,15) == obj.checksum);
            obj.checksumOK = ok;
        end

        function setDownPayload(obj, targetID, flags)
            % Set DOWN message payload: {targetID : uint16, flags : uint8}
            obj.payload = uint8([ ...
                bitshift(uint16(targetID),-8), ...
                bitand(uint16(targetID),255), ...
                uint8(flags)]);
            obj.payloadLen = uint8(3);
        end

        function [targetID, flags] = getDownPayload(obj)
            % Read DOWN/SHUTDOWN message payload: {targetID : uint16, flags : uint8}
            targetID = 0; flags = 0;
            if obj.payloadLen < 3, return; end
            targetID = bitshift(uint16(obj.payload(1)), 8) + uint16(obj.payload(2));
            flags = double(obj.payload(3));
        end

        function setCensusPollPayload(obj, suspectID, pollUID, reasonCode)
            % Set Census 11.0/11.1/11.2 payload: {suspectID:u16, pollUID:u16, reasonCode:u8}
            % reasonCode only meaningful for 11.0 POLL_INITIATE; pass 0 for votes.
            obj.payload = uint8([ ...
                typecast(uint16(suspectID), 'uint8'), ...
                typecast(uint16(pollUID), 'uint8'), ...
                uint8(reasonCode)]);
            obj.payloadLen = uint8(5);
        end

        function [suspectID, pollUID, reasonCode] = getCensusPollPayload(obj)
            suspectID = 0; pollUID = 0; reasonCode = 0;
            if obj.payloadLen < 5, return; end
            suspectID = typecast(obj.payload(1:2), 'uint16');
            pollUID = typecast(obj.payload(3:4), 'uint16');
            reasonCode = double(obj.payload(5));
        end

        function setCensusCompletePayload(obj, suspectID, verdict, yesCount, totalVoters)
            % Set Census 11.3 POLL_COMPLETE payload:
            % {suspectID:u16, verdict:u8 (0=cleared,1=malicious,2=inconclusive), yesCount:u8, totalVoters:u8}
            obj.payload = uint8([ ...
                typecast(uint16(suspectID), 'uint8'), ...
                uint8(verdict), uint8(yesCount), uint8(totalVoters)]);
            obj.payloadLen = uint8(5);
        end

        function [suspectID, verdict, yesCount, totalVoters] = getCensusCompletePayload(obj)
            suspectID = 0; verdict = 2; yesCount = 0; totalVoters = 0;
            if obj.payloadLen < 5, return; end
            suspectID = typecast(obj.payload(1:2), 'uint16');
            verdict = double(obj.payload(3));
            yesCount = double(obj.payload(4));
            totalVoters = double(obj.payload(5));
        end

        function setHelloPayload(obj, tier, battery, neighborCount)
            % Set HELLO message payload: {Tier (4b) | Battery (4b) | NeighborCount (8b)}
            % tier: 1=Sensor, 2=CH, 3=GWN
            % battery: 0-15 (quantized percentage)
            % neighborCount: 0-255
            tierNib = bitand(uint8(tier), 15);
            batteryNib = bitand(uint8(battery), 15);
            tierBat = bitor(bitshift(tierNib, 4), batteryNib);
            
            obj.payload = uint8([tierBat, uint8(neighborCount)]);
            obj.payloadLen = uint8(2);
        end

        function [tier, battery, neighborCount] = getHelloPayload(obj)
            % Extract HELLO payload
            if obj.payloadLen < 2
                tier = 0; battery = 0; neighborCount = 0;
                return;
            end
            
            tierBat = obj.payload(1);
            tier = bitshift(bitand(tierBat, 240), -4);
            battery = bitand(tierBat, 15);
            neighborCount = obj.payload(2);
        end
    end

    % =========================================================
    % RAW BYTES
    % =========================================================
    methods
        function bytes = rawBytesNoChecksum(obj)
            b0 = bitshift(obj.type,4) + bitand(obj.subtype,15);

            bytes = uint8(b0);
            bytes = [bytes; typecast(obj.src,'uint8').'];        % Immediate sender (unencrypted)
            bytes = [bytes; typecast(obj.dst,'uint8').'];        % Immediate receiver (unencrypted)

            % NOTE: originalSrc is NOT added separately here.
            % For encrypted messages, originalSrc is prepended to the payload
            % during applyLayeredEncryption, so it's included in doubleEncryptedPayload.
            % This matches deserialize() which extracts originalSrc from payload bytes.

            % Payload data (double encrypted if flag set)
            if obj.isDoubleEncrypted() && ~isempty(obj.doubleEncryptedPayload)
                payloadBytes = obj.doubleEncryptedPayload;
            elseif obj.isGlobalEncrypted() && ~isempty(obj.globalEncryptedPayload)
                payloadBytes = obj.globalEncryptedPayload;
            elseif ~isempty(obj.payload)
                payloadBytes = obj.payload;
            else
                payloadBytes = uint8([]);
            end

            payloadLen = uint8(numel(payloadBytes));
            bytes = [bytes; payloadLen];

            if payloadLen > 0
                bytes = [bytes; payloadBytes(:)];
            end

            bytes = [bytes; obj.flag];
            bytes = [bytes; obj.seq];
            bytes = [bytes; obj.ttl];
            bytes = [bytes; obj.prio];
        end
    end

    % =========================================================
    % SERIALIZATION
    % =========================================================
    methods
        function hex = serialize(obj)
            bytes = obj.rawBytesNoChecksum();
            bytes(end+1) = obj.checksum;
            hex = upper(reshape(dec2hex(bytes,2).',1,[]));
        end
    end

    % =========================================================
    % DESERIALIZATION
    % =========================================================
    methods (Static)
        function [msg, ok] = deserialize(hex)
            msg = WSN_Message();
            ok = false;

            try
                hex = upper(char(hex));
                if mod(numel(hex),2) ~= 0, return; end

                bytes = uint8(hex2dec(reshape(hex,2,[])'));
                if numel(bytes) < 11, return; end

                msg.type    = bitshift(bytes(1),-4);
                msg.subtype = bitand(bytes(1),15);
                msg.src     = typecast(bytes(2:3),'uint16');
                msg.dst     = typecast(bytes(4:5),'uint16');
                msg.payloadLen = bytes(6);

                pEnd = 6 + msg.payloadLen;
                if numel(bytes) ~= pEnd + 5, return; end

                if msg.payloadLen > 0
                    msg.payload = bytes(7:pEnd).';
                end

                msg.flag     = bytes(pEnd+1);
                msg.seq      = bytes(pEnd+2);
                msg.ttl      = bytes(pEnd+3);
                msg.prio     = bytes(pEnd+4);
                msg.checksum = bytes(pEnd+5);

                % Handle layered encryption parsing
                % Format: first 2 bytes = originalSrc, rest = encryptedPayload
                % IMPORTANT: Keep full payload in doubleEncryptedPayload for checksum
                % The decryptLayered() function will skip originalSrc bytes
                if msg.isGlobalEncrypted() && msg.payloadLen >= 2
                    % First 2 bytes of payload are original sender (unencrypted)
                    msg.originalSrc = typecast(msg.payload(1:2), 'uint16');
                    % Keep FULL payload for checksum verification
                    if msg.isDoubleEncrypted()
                        msg.doubleEncryptedPayload = msg.payload;  % Full payload
                    else
                        msg.globalEncryptedPayload = msg.payload;  % Full payload
                    end
                elseif msg.isDoubleEncrypted()
                    msg.doubleEncryptedPayload = msg.payload;
                end

                ok = msg.verifyChecksum();
            catch
                ok = false;
            end
        end
    end

    % =========================================================
    % PAYLOAD HELPERS (UNCHANGED)
    % =========================================================
    methods
        function setGlobalKeyPayload(obj, childPhaseOffset)
            % Set GLOBAL_KEY payload with AES key and phase offset
            % childPhaseOffset: 0 or 1 (child gets opposite of parent)
            if nargin < 2
                childPhaseOffset = 0;  % Default for backward compatibility
            end
            gk = obj.GLOBAL_AES_KEY_HEX;
            keyBytes = uint8(hex2dec(reshape(gk,2,[])'));
            % Ensure row vector for concatenation, then append phase offset as byte 17
            obj.payload = [keyBytes(:)', uint8(childPhaseOffset)];
            obj.payloadLen = uint8(17);  % 16 bytes key + 1 byte phase
            obj.addChecksum();
        end
        function s = getEncHelloPayload(obj)
            % Extended ENC_HELLO payload format:
            % <srcID:2><parentID:2><localKey:8><chCnt:1><snCnt:2><gwChildCnt:1><chChildCnt:1>
            % [<gwChild1:2>...<gwChildN:2>][<chChild1:2>...<chChildM:2>][<secChild1:2>...]

            p = obj.payload;

            if numel(p) < 17
                % Legacy format (15 bytes) - return with defaults
                if numel(p) >= 15
                    s.srcID    = typecast(p(1:2),'uint16');
                    s.parentID = typecast(p(3:4),'uint16');
                    s.localKeyHex = upper(reshape(dec2hex(p(5:12),2).',1,[]));
                    s.chCount  = p(13);
                    s.snCount  = typecast(p(14:15),'uint16');
                    s.gwChildren = [];
                    s.chChildren = [];
                    s.secondaryChildren = [];
                else
                    error('ENC_HELLO payload too short');
                end
                return;
            end

            s.srcID    = typecast(p(1:2),'uint16');
            s.parentID = typecast(p(3:4),'uint16');
            s.localKeyHex = upper(reshape(dec2hex(p(5:12),2).',1,[]));
            s.chCount  = p(13);
            s.snCount  = typecast(p(14:15),'uint16');
            gwChildCnt = double(p(16));
            chChildCnt = double(p(17));
            
            offset = 18;
            % Parse GWN children (first degree)
            s.gwChildren = [];
            for i = 1:gwChildCnt
                if offset+1 <= numel(p)
                    s.gwChildren(end+1) = typecast(p(offset:offset+1),'uint16');
                    offset = offset + 2;
                end
            end
            
            % Parse CH children (first degree)
            s.chChildren = [];
            for i = 1:chChildCnt
                if offset+1 <= numel(p)
                    s.chChildren(end+1) = typecast(p(offset:offset+1),'uint16');
                    offset = offset + 2;
                end
            end
            
            % Parse secondary children (second degree - CHs recruited by our CHs)
            s.secondaryChildren = [];
            while offset+1 <= numel(p)
                s.secondaryChildren(end+1) = typecast(p(offset:offset+1),'uint16');
                offset = offset + 2;
            end
        end

        function [hex, childPhaseOffset] = getGlobalKeyPayload(obj)
            % Get GLOBAL_KEY payload: returns key hex and phase offset
            hex = upper(reshape(dec2hex(obj.payload(1:16),2).',1,[]));
            if numel(obj.payload) >= 17
                childPhaseOffset = double(obj.payload(17));
            else
                childPhaseOffset = 0;  % Backward compatibility
            end
        end

        function setEncHelloPayload(obj, srcID, parentID, localKeyHex, chCnt, snCnt, varargin)
            % Extended ENC_HELLO payload with children lists
            % varargin: gwChildren, chChildren, secondaryChildren (optional)
            gwChildren = [];
            chChildren = [];
            secondaryChildren = [];
            if nargin >= 7, gwChildren = varargin{1}; end
            if nargin >= 8, chChildren = varargin{2}; end
            if nargin >= 9, secondaryChildren = varargin{3}; end
            
            p = uint8([]);
            p = [p, typecast(uint16(srcID),'uint8')];       % 2 bytes
            p = [p, typecast(uint16(parentID),'uint8')];    % 2 bytes
            lk = uint8(hex2dec(reshape(upper(localKeyHex),2,[])'));
            p  = [p, lk(:).'];                               % 8 bytes
            p = [p, uint8(chCnt)];                           % 1 byte
            p = [p, typecast(uint16(snCnt),'uint8')];       % 2 bytes
            p = [p, uint8(numel(gwChildren))];              % 1 byte: GWN child count
            p = [p, uint8(numel(chChildren))];              % 1 byte: CH child count
            
            % Append GWN children (first degree)
            for i = 1:numel(gwChildren)
                p = [p, typecast(uint16(gwChildren(i)),'uint8')]; %
            end
            
            % Append CH children (first degree)
            for i = 1:numel(chChildren)
                p = [p, typecast(uint16(chChildren(i)),'uint8')]; %
            end
            
            % Append secondary children (second degree)
            for i = 1:numel(secondaryChildren)
                p = [p, typecast(uint16(secondaryChildren(i)),'uint8')]; %
            end

            obj.payload = p;
            obj.payloadLen = uint8(numel(p));
            obj.addChecksum();
        end
    end

    % =========================================================
    % GUI
    % =========================================================
    methods
        function str = getTypeStr(obj)
            switch obj.type
                case 0
                    str = 'HELLO';
                case 1
                    str = 'SENSOR';
                case 2
                    str = 'PANIC';
                case 5
                    str = 'CH_HELLO';
                case 6
                    str = 'CH_CMD';
                case 7
                    str = 'CMD';
                case 8
                    str = 'TOKEN';
                case 9
                    str = 'HB';
                case 11
                    str = 'CENSUS';
                case 12
                    str = 'SHUTDOWN';
                case 13
                    str = 'UPDATE';
                otherwise
                    str = 'UNK';
            end
        end
    end
end

function y = ifelse(c,a,b)
if c, y=a; else, y=b; end
end
