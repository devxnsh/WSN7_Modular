classdef WSN_GUI_GlobalEventFeed < handle
    properties
        logTable
    end

    methods
        function obj = WSN_GUI_GlobalEventFeed(parentTab)

            uicontrol('Parent',parentTab, 'Units','normalized', 'Style','text', ...
                'String',' GLOBAL EVENT FEED', ...
                'Position',[0.62 0.94 0.36 0.03], ...
                'BackgroundColor',[0.2 0.2 0.2], ...
                'ForegroundColor','w', ...
                'FontWeight','bold');

            obj.logTable = uitable('Parent',parentTab, 'Units','normalized', ...
                'Position',[0.62 0.42 0.36 0.52], ...
                'RowName',[], ...
                'FontName','Consolas', ...
                'FontSize',8);

            set(obj.logTable, 'ColumnName', { ...
                'T','Frame','Inference', ...
                'Type','Sub', ...
                'Src','Dst', ...
                'Len','Enc','Ver','CHK', ...
                'Payload'});

            set(obj.logTable,'ColumnWidth',{ ...
                30,160,80, ...
                40,35,50,50, ...
                30,30,30,35});
        end

        % --------------------------------------------------
        % ENTRY POINT (WIRE → DECODE → DISPLAY)
        % --------------------------------------------------
        function addEntry(obj, t, msg)

            if ~isvalid(obj.logTable)
                return;
            end

            % ---------- WIRE NORMALIZATION ----------
            if ischar(msg)
                raw = msg;
            elseif isa(msg,'WSN_Message')
                raw = msg.serialize();   % legacy safety
            else
                return;
            end

            % ---------- DESERIALIZE ONCE ----------
            [m, ok] = WSN_Message.deserialize(raw);

            if ~ok
                % corrupted frame: show minimal info
                obj.insertRow(t, raw, 'CHK_FAIL', ...
                    NaN,NaN,NaN,NaN, ...
                    NaN,0,0,0,'');
                return;
            end

            % ---------- BASIC FIELDS ----------
            type = m.type;
            sub  = m.subtype;
            src  = m.src;
            dst  = m.dst;
            len  = m.payloadLen;

            enc = bitget(m.flag,1) ~= 0;
            ver = bitget(m.flag,2) ~= 0;
            chk = m.verifyChecksum();

            % ---------- PAYLOAD ----------
            payloadStr = '';
            if ~isempty(m.payload)
                try
                    payloadStr = upper(reshape(dec2hex(uint8(m.payload),2).',1,[]));
                catch
                    payloadStr = '[BIN]';
                end
            end
            if strlength(payloadStr) > 32
                payloadStr = payloadStr(1:32) + "...";
            end

            % ---------- INFERENCE ----------
            inference = obj.inferMessage(m);

            % ---------- FRAME LABEL ----------
            frame = sprintf('[%d.%d] %04X→%04X', ...
                type, sub, uint16(src), uint16(dst));

            % Encryption prefix:
            % {} = Local key only (Type 5 CH->GWN messages after handshake)
            % [] = Global key only (ENC_HELLO, TOKEN_DOWN, ENC_HB)
            % [{}] = Both local + global (5.2 SENSOR_AGG from GWN, 8.1 TOKEN_REQ, 8.2 PATH_COMPLETE)
            % Note: 7.4 GLOBAL_KEY is NOT encrypted - payload IS the key
            if enc
                % Double-encrypted: 5.2 from GWN (to Sink), 8.1 TOKEN_REQ, 8.2 PATH_COMPLETE
                isDoubleEnc = (type == 8 && sub == 1) || ...  % 8.1 TOKEN_REQ (broadcast FF00)
                              (type == 8 && sub == 2);        % 8.2 PATH_COMPLETE (broadcast FF00)
                % Also 5.2 to Sink is double-encrypted (but 5.2 to parent GWN is local only)
                % We can't easily tell from the message, so check dst for FF00 or Sink
                if type == 5 && sub == 2
                    % 5.2 from GWN is double-encrypted when going to Sink
                    isDoubleEnc = true;  % Assume double for 5.2 from GWN
                end
                
                % Local-only: Type 5 (except 5.2) from CH to GWN - CH uses local key
                isLocalOnly = (type == 5 && sub ~= 2);        % 5.0, 5.1, 5.3 etc from CH
                
                % Global-only: ENC_HELLO (7.5), TOKEN_DOWN (8.0), ENC_HB (9.3)
                % Note: 7.4 GLOBAL_KEY should NOT have enc flag set
                isGlobalOnly = (type == 7 && sub == 5) || ... % 7.5 ENC_HELLO
                               (type == 8 && sub == 0) || ... % 8.0 TOKEN_DOWN
                               (type == 9 && sub == 3);       % 9.3 ENC_HB
                
                if isDoubleEnc
                    frame = ['[{}] ' frame];   % Both: local first, then global
                elseif isLocalOnly
                    frame = ['{} ' frame];     % Local key only
                elseif isGlobalOnly
                    frame = ['[] ' frame];     % Global key only
                else
                    frame = ['[] ' frame];     % Default: global
                end
            end

            % ---------- INSERT ----------
            obj.insertRow( ...
                t, raw, inference, ...
                type, sub, ...
                dec2hex(uint16(src),4), dec2hex(uint16(dst),4), ...
                len, enc, ver, chk, ...
                payloadStr);
        end
    end

    % =========================================================
    % INFERENCE ENGINE (SEMANTIC ONLY)
    % =========================================================
    methods (Access=private)
        function txt = inferMessage(~, m)

            if m.type == 9
                names = {'HB_BOOT','HB_DISC','HB_PLACEHOLDER','ENC_HB'};
                if m.subtype+1 <= numel(names)
                    txt = names{m.subtype+1};
                else
                    txt = 'HEARTBEAT';
                end
                return;
            end
            if m.type == 0
                txt = 'HELLO';
                return;
            end
            
            % Type 1: Sensor Data
            if m.type == 1
                priNames = {'SENSOR', 'SENSOR_P1', 'SENSOR_P2', 'SENSOR_P3'};
                pri = min(m.subtype + 1, 4);
                txt = priNames{pri};
                return;
            end
            
            % Type 2: Panic/Emergency
            if m.type == 2
                panicNames = {'PANIC', 'PANIC_RELAY', 'PANIC_ACK', 'PANIC_CANCEL'};
                if m.subtype < numel(panicNames)
                    txt = panicNames{m.subtype + 1};
                else
                    txt = 'PANIC';
                end
                if bitget(m.flag,1)
                    txt = ['[ENC] ' txt];
                end
                return;
            end
            
            % CH_HELLO (Type 5) with subtypes
            if m.type == 5
                if m.subtype == 2
                    txt = 'SENSOR_AGG';  % 5.2
                elseif m.subtype == 3
                    txt = 'AGG_ACK';     % 5.3
                else
                    txt = 'CH_HELLO';    % 5.0/5.1
                end
                if bitget(m.flag,1)
                    txt = ['[ENC] ' txt];
                end
                return;
            end
            
            % CH_CMD (Type 6) - CH-GWN handshake
            if m.type == 6
                chCmdMap = {
                    0,'CH_REQ'
                    1,'CH_ACK'
                    2,'KEY_ACK'
                    3,'CH_REJECT'
                    4,'CH_JOINOK'
                    5,'CH_INFO'
                    };
                idx = find([chCmdMap{:,1}] == m.subtype, 1);
                if isempty(idx)
                    txt = 'CH_CMD';
                else
                    txt = chCmdMap{idx,2};
                end
                if bitget(m.flag,1)
                    txt = ['[ENC] ' txt];
                end
                return;
            end
            
            % TOKEN (Type 8) - Token passing protocol
            if m.type == 8
                tokenMap = {
                    0,'TOKEN_DOWN'
                    1,'TOKEN_REQ'
                    2,'PATH_COMPLETE'
                    };
                idx = find([tokenMap{:,1}] == m.subtype, 1);
                if isempty(idx)
                    txt = 'TOKEN';
                else
                    txt = tokenMap{idx,2};
                end
                if bitget(m.flag,1)
                    txt = ['[ENC] ' txt];
                end
                return;
            end
            
            if m.type ~= 7
                txt = 'UNKNOWN';
                return;
            end

            map = {
                0,'PARENT_INIT'
                1,'REQ_JOIN'
                2,'ACK_JOIN'
                3,'PARENT_REJECT'
                4,'GLOBAL_KEY'
                5,'ENC_HELLO'
                6,'CMD_DOWN'
                7,'CMD_UP'
                };

            idx = find([map{:,1}] == m.subtype,1);
            if isempty(idx)
                txt = 'CMD';
            else
                txt = map{idx,2};
            end

            if bitget(m.flag,1)
                txt = ['[ENC] ' txt];
            end
        end

        % --------------------------------------------------
        % TABLE INSERT (ISOLATED UI MUTATION)
        % --------------------------------------------------
        function insertRow(obj, t, frame, inference, ...
                type, sub, src, dst, len, enc, ver, chk, payload)
            frame     = char(frame);
            inference = char(inference);
            payload   = char(payload);

            d = get(obj.logTable,'Data');
            if isempty(d)
                d = {};
            end

            newRow = { ...
                t, frame, inference, ...
                type, sub, ...
                src, dst, ...
                len, double(enc), double(ver), double(chk), ...
                payload };

            d = [newRow; d];
            if size(d,1) > 50
                d = d(1:50,:);
            end

            set(obj.logTable,'Data',d);
        end
    end
end
