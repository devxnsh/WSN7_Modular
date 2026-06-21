classdef WSN_ProtocolFrames
    properties (Constant)
        % ---------------- CORE ----------------
        FRAME_MIN_BYTES = 8;
        % ---- HEADER NIBBLES / BYTES ----
        % Byte 0
        NIB_TYPE        = 1;   % upper nibble
        NIB_FLAGS       = 2;   % lower nibble
        % Bytes 1–2
        SRC_ID_BYTES    = 2;
        % Bytes 3–4
        DST_ID_BYTES    = 2;
        % Byte 5
        SEQ_BYTES       = 1;
        % Byte 6
        TTL_TX_BYTES    = 1;
        % Byte 7
        ENC_SUB_BYTES   = 1;
        % ---------------- FLAGS ----------------
        FLAG_ENCRYPTED  = hex2dec('8');   % 1000
        % ---------------- MULTICAST ----------------
        MULTICAST_GWN   = hex2dec('FF00');
        % ---------------- CMD SUBTYPES ----------------
        SUB_PARENT_INIT   = 1;
        SUB_REQ_JOIN      = 2;
        SUB_ACK_JOIN      = 3;
        SUB_PARENT_REJECT = 4;
        SUB_GLOBAL_KEY    = 5;
        SUB_ENC_HELLO     = 6;

        % ---------------- HEARTBEAT SUBTYPES ----------------
        SUB_HB_BOOT   = 1;
        SUB_HB_DISC   = 2;
        SUB_HB_SECURE = 3;
        SUB_ENC_HB    = 4;
    end
end
