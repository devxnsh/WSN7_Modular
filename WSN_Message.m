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
        src         uint16
        dst         uint16

        % ---------------- Payload ----------------
        payload     uint8 = uint8([])
        payloadLen  uint8 = uint8(0)

        % ---------------- Control ----------------
        flag        uint8 = uint8(0)   % bit1=ENC, bit2=VER
        prio        uint8 = uint8(0)
        ttl         uint8 = uint8(5)

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

        function tf = isEncrypted(obj)
            tf = bitget(obj.flag,1);
        end

        function tf = isVerified(obj)
            tf = bitget(obj.flag,2);
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
    end

    % =========================================================
    % RAW BYTES
    % =========================================================
    methods
        function bytes = rawBytesNoChecksum(obj)
            b0 = bitshift(obj.type,4) + bitand(obj.subtype,15);

            bytes = uint8(b0);
            bytes = [bytes; typecast(obj.src,'uint8').'];
            bytes = [bytes; typecast(obj.dst,'uint8').'];
            bytes = [bytes; obj.payloadLen];

            if obj.payloadLen > 0
                bytes = [bytes; obj.payload(:)];
            end

            bytes = [bytes; obj.flag];
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
                if numel(bytes) < 8, return; end

                msg.type    = bitshift(bytes(1),-4);
                msg.subtype = bitand(bytes(1),15);
                msg.src     = typecast(bytes(2:3),'uint16');
                msg.dst     = typecast(bytes(4:5),'uint16');
                msg.payloadLen = bytes(6);

                pEnd = 6 + msg.payloadLen;
                if numel(bytes) ~= pEnd + 2, return; end

                if msg.payloadLen > 0
                    msg.payload = bytes(7:pEnd).';
                end

                msg.flag     = bytes(pEnd+1);
                msg.checksum = bytes(pEnd+2);

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
        function setGlobalKeyPayload(obj)
            gk = obj.GLOBAL_AES_KEY_HEX;
            obj.payload = uint8(hex2dec(reshape(gk,2,[])'));
            obj.payloadLen = uint8(16);
            obj.addChecksum();
        end
        function s = getEncHelloPayload(obj)
            % <srcID:2><parentID:2><localKey:8><chCnt:1><snCnt:2>

            p = obj.payload;

            if numel(p) < 15
                error('ENC_HELLO payload too short');
            end

            s.srcID    = typecast(p(1:2),'uint16');
            s.parentID = typecast(p(3:4),'uint16');
            s.localKeyHex = upper(reshape(dec2hex(p(5:12),2).',1,[]));
            s.chCount  = p(13);
            s.snCount  = typecast(p(14:15),'uint16');
        end

        function hex = getGlobalKeyPayload(obj)
            hex = upper(reshape(dec2hex(obj.payload,2).',1,[]));
        end

        function setEncHelloPayload(obj, srcID, parentID, localKeyHex, chCnt, snCnt)
            p = uint8([]);
            p = [p, typecast(uint16(srcID),'uint8')];
            p = [p, typecast(uint16(parentID),'uint8')];
            lk = uint8(hex2dec(reshape(upper(localKeyHex),2,[])'));
            p  = [p, lk(:).'];
            p = [p, uint8(chCnt)];
            p = [p, typecast(uint16(snCnt),'uint8')];

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
            if obj.type == 7
                str = 'CMD';
            elseif obj.type == 9
                str = 'HB';
            else
                str = 'UNK';
            end
        end
    end
end

function y = ifelse(c,a,b)
if c, y=a; else, y=b; end
end
