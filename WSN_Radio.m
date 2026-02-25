classdef WSN_Radio < handle
    properties
        node
        radioType = 'BACKBONE'  % 'BACKBONE' (LoRa) or 'ACCESS' (HC12)

        % Physical radio state (informational)
        state = 'IDLE'        % 'IDLE' | 'RX' | 'TX'

        % Buffers
        txBuffer = {}         % FIFO queue
        % NO RX BUFFER - single pending slot only
        pendingRX = []        % Single pending RX frame (struct with msg, rssi)

        % Half-duplex enforcement (per radio)
        lastActiveTime = -inf % timestep when TX or RX occurred
        txScheduledThisTick = false  % True if TX is scheduled for this tick (blocks RX)
        txPending = false  % True if TX request already made this tick

        % Lock enforcement (FSM-owned) - INDEPENDENT per radio
        handshakePartner = []
        lockTimer = 0
        lockExpired = false
        MAX_RETRIES
    end

    % ================= CONSTRUCTOR =================
    methods
        function obj = WSN_Radio(node, radioType)
            obj.node = node;
            if nargin >= 2
                obj.radioType = radioType;
            end
            obj.state = 'IDLE';
            obj.txBuffer = {};
            obj.pendingRX = [];
            obj.lastActiveTime = -inf;
            obj.txScheduledThisTick = false;
            obj.txPending = false;
            obj.handshakePartner = [];
            obj.lockTimer = 0;
            obj.lockExpired = false;
            obj.MAX_RETRIES = WSN_Config.MAX_RETRIES;
        end
    end

    % ================= TX REQUEST =================
    methods
        function requestTX(obj, msg)
            % ---- LIMIT ONE TX PER TIMESTEP ----
            if obj.txPending
                obj.logLocal(sprintf('[DROP][LIMIT] TX request dropped - already requested this tick'));
                return;
            end
            obj.txPending = true;

            % ---- LOCK ENFORCEMENT (LOGICAL ONLY) ----
            % When locked, only allow TX to handshakePartner
            % EXCEPT: ENC_HELLO (Type 7 subtype 5) and CH_HELLO (Type 5) always pass
            if ~isempty(obj.handshakePartner)
                isENC_HELLO = (msg.type == 7 && msg.subtype == 5);
                isCH_HELLO = (msg.type == 5);
                if ~isENC_HELLO && ~isCH_HELLO && msg.dst ~= obj.handshakePartner
                    obj.logLocal(sprintf('[DROP][LOCK][TX] type=%d dst=%04X partner=%04X', ...
                        msg.type, msg.dst, obj.handshakePartner));
                    return;
                end
            end

            % ---- ALWAYS FIFO BUFFER ----
            obj.txBuffer{end+1} = msg;
        end
    end

    % ================= RX PUSH =================
    methods
        function pushRX(obj, msg, rssi)
            % NO BUFFER - single pending slot, arbitrate immediately
            % If TX is scheduled this tick, block all RX
            if obj.txScheduledThisTick
                return;  % Drop - cannot receive while transmitting
            end

            newFrame = struct('msg', msg, 'rssi', rssi);
            
            if isempty(obj.pendingRX)
                % First frame this tick - accept if passes filter
                if obj.passesLockFilter(msg)
                    obj.pendingRX = newFrame;
                end
            else
                % Already have a pending frame - compare priorities
                if obj.passesLockFilter(msg)
                    newPri = obj.getPriority(msg);
                    oldPri = obj.getPriority(obj.pendingRX.msg);
                    if newPri > oldPri
                        obj.pendingRX = newFrame;  % New frame wins
                    elseif newPri == oldPri && rssi > obj.pendingRX.rssi
                        obj.pendingRX = newFrame;  % Same priority, better RSSI wins
                    end
                    % Else drop new frame
                end
            end
        end
    end

    % ================= STEP =================
    methods
        function [txOut, rxMsg, rxRSSI] = step(obj, t)
            txOut  = {};
            rxMsg  = [];
            rxRSSI = [];

            % Reset per-timestep flags
            obj.txPending = false;

            % =================================================
            % PRE-CHECK: TX SCHEDULED THIS TICK (BLOCKS RX)
            % =================================================
            obj.txScheduledThisTick = ~isempty(obj.txBuffer);

            % =================================================
            % HALF-DUPLEX GUARD: one action per timestep
            % =================================================
            if obj.lastActiveTime == t
                obj.pendingRX = [];   % clear pending
                return;
            end

            % =================================================
            % RX HAS PRIORITY (blocking TX for this tick)
            % =================================================
            if ~isempty(obj.pendingRX)
                obj.state = 'RX';
                obj.lastActiveTime = t;

                rxMsg = obj.pendingRX.msg;
                rxRSSI = obj.pendingRX.rssi;
                obj.pendingRX = [];
                return;
            end

            % =================================================
            % TX IF AVAILABLE
            % =================================================
            if ~isempty(obj.txBuffer)
                obj.state = 'TX';
                obj.lastActiveTime = t;

                txOut = obj.txBuffer(1);
                obj.txBuffer(1) = [];
                return;
            end

            % =================================================
            % ELSE: remain IDLE
            % =================================================
            obj.state = 'IDLE';
        end
        
        function resetTick(obj)
            % Called at start of each timestep to reset tick-local state
            obj.txScheduledThisTick = false;
        end
    end

    % ================= LOCK FILTER =================
    methods
        function ok = passesLockFilter(obj, msg)
            % Check if message passes the lock filter
            ok = true;
            
            if ~isempty(obj.handshakePartner)
                src = msg.src;
                isFromPartner = (src == obj.handshakePartner);
                
                % Exceptions that bypass lock:
                % - Type 5: CH_HELLO (forwarded backbone traffic)
                % - Type 7 subtype 5: ENC_HELLO
                % - Type 6: CH_CMD (handshake protocol with partner)
                isException = (msg.type == 5) || ...
                              (msg.type == 7 && isfield(msg,'subtype') && msg.subtype == 5) || ...
                              (msg.type == 6 && isFromPartner);
                
                if ~isFromPartner && ~isException
                    ok = false;
                end
            end
        end
    end

    % ================= RX ARBITRATION (legacy wrapper) =================
    methods
        function [msg,rssi] = arbitrateRX(obj)
            % Legacy method - now handled in pushRX
            msg = [];
            rssi = [];

            if ~isempty(obj.pendingRX)
                msg = obj.pendingRX.msg;
                rssi = obj.pendingRX.rssi;
                obj.pendingRX = [];
            end
        end
    end

    % ================= LOCK CONTROL (FSM ONLY) =================
    methods
        function setLock(obj, partner, timeout)
            obj.handshakePartner = partner;
            obj.lockTimer = timeout;
            obj.lockExpired = false;
            obj.logLocal(sprintf('[LOCK][SET] partner=%04X timeout=%d', ...
                partner, timeout));
        end

        function refreshLock(obj, timeout)
            % Refresh lock timer without changing partner
            if ~isempty(obj.handshakePartner)
                obj.lockTimer = timeout;
                obj.lockExpired = false;
                obj.logLocal(sprintf('[LOCK][REFRESH] partner=%04X timeout=%d', ...
                    obj.handshakePartner, timeout));
            end
        end

        function clearLock(obj, reason)
            if nargin < 2, reason = ''; end
            if ~isempty(obj.handshakePartner)
                if isempty(reason)
                    obj.logLocal(sprintf('[LOCK][CLEAR] partner=%04X', ...
                        obj.handshakePartner));
                else
                    obj.logLocal(sprintf('[LOCK][CLEAR][%s] partner=%04X', ...
                        reason, obj.handshakePartner));
                end
            end
            obj.handshakePartner = [];
            obj.lockTimer = 0;
            obj.lockExpired = false;
        end

        function timeout(obj)
            % Mark lock as expired and log
            if ~isempty(obj.handshakePartner) && ~obj.lockExpired
                obj.lockExpired = true;
                obj.logLocal(sprintf('[LOCK][TIMEOUT] partner=%04X', ...
                    obj.handshakePartner));
            end
        end
    end
    
    % ================= LOCAL LOGGING (routes based on radio type) =================
    methods
        function logLocal(obj, txt)
            % Route logs based on radio type for GWN (dual-radio)
            % Backbone radio logs to Backbone log
            % Access radio logs to Access log
            if isa(obj.node, 'WSN_Gateway')
                if strcmp(obj.radioType, 'ACCESS')
                    obj.node.addLogAccess(txt, [], []);
                else
                    obj.node.addLogBackbone(txt, [], []);
                end
            else
                obj.node.addLog(txt);
            end
        end
    end

    % ================= PRIORITY =================
    methods
        function p = getPriority(obj, msg)
            % Priority depends on radio type
            if strcmp(obj.radioType, 'BACKBONE')
                % Backbone (LoRa): Type 7 > Type 8 > Type 5 > Type 9
                % Within Type 8: 8.0 TOKEN_DOWN > 8.1 TOKEN_REQ > 8.2 > 8.3
                if msg.type == 7
                    p = 50;      % CMD / handshake (highest)
                elseif msg.type == 8
                    % Token messages: 8.0 > 8.1 > 8.2 > 8.3
                    p = 40 - msg.subtype;  % 8.0=40, 8.1=39, 8.2=38, 8.3=37
                elseif msg.type == 5
                    p = 30;      % CH_HELLO / SENSOR_AGG
                elseif msg.type == 9
                    p = 20;      % Heartbeat (lowest backbone)
                else
                    p = 10;
                end
            else
                % Access (HC12): Type 6 > Type 5 > Type 1 = Type 0
                % Priority order: 6 > 5 > 1 = 0
                if msg.type == 6
                    p = 3;      % CH_CMD (recruitment) - highest
                elseif msg.type == 5
                    p = 2;      % CH_HELLO / SENSOR_AGG
                elseif msg.type == 1
                    p = 1;      % Sensor data (Type 1)
                elseif msg.type == 0
                    p = 1;      % Hello (same priority as Type 1)
                else
                    p = 0;
                end
            end
        end
    end
end
