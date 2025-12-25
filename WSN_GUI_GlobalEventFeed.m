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

            if enc
                frame = ['[ENC] ' frame];

            end

            % ---------- INSERT ----------
            obj.insertRow( ...
                t, raw, inference, ...
                type, sub, ...
                src, dst, ...
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
