classdef WSN_RadioStack < handle
    % =========================================================
    % WSN RADIOSTACK — DUAL RADIO FOR GWN (Backbone + Access)
    % =========================================================
    % GWNs have two independent half-duplex radios:
    %   - backbone: LoRa (GWN-GWN control, long-range, low-bandwidth)
    %   - access: HC12 (GWN-CH/Sensor, medium-range, normal traffic)
    %
    % Non-GWN nodes use single radio (backward compatible via WSN_Radio)
    
    properties
        node
        
        % Two independent radios
        backbone  % LoRa: GWN-GWN backbone
        access    % HC12: Normal access network
        
        % State tracking
        lastActiveTime = -inf
        handshakePartner = []
        lockTimer = 0
        lockExpired = false
        MAX_RETRIES
    end
    
    % ================= CONSTRUCTOR =================
    methods
        function obj = WSN_RadioStack(node)
            obj.node = node;
            obj.backbone = WSN_Radio(node);
            obj.access = WSN_Radio(node);
            obj.lastActiveTime = -inf;
            obj.handshakePartner = [];
            obj.lockTimer = 0;
            obj.lockExpired = false;
            obj.MAX_RETRIES = WSN_Config.MAX_RETRIES;
        end
    end
    
    % ================= TX REQUEST (DUAL ROUTING) =================
    methods
        function requestTX(obj, msg)
            % Route to appropriate radio(s) based on message type and destination
            gw = obj.node;
            
            % Determine which radio(s) to use
            isBroadcast = isempty(msg.dst) || msg.dst == 0 || msg.dst == hex2dec('FFFF');
            
            % Type 0 (Hello): Both radios (but backbone messages inconsequential)
            if msg.type == WSN_Config.MSG_TYPE_HELLO
                obj.access.requestTX(msg);
                % GWNs also send on backbone (but not processed for recruitment)
                obj.backbone.requestTX(msg);
                return;
            end
            
            % Type 7 (CMD): Access radio (handshake/routing over access channel)
            if msg.type == WSN_Config.MSG_TYPE_CMD
                obj.access.requestTX(msg);
                return;
            end
            
            % Type 9 (Heartbeat): Both radios (redundancy)
            if msg.type == WSN_Config.MSG_TYPE_HB
                obj.access.requestTX(msg);
                obj.backbone.requestTX(msg);
                return;
            end
            
            % Default: access radio
            obj.access.requestTX(msg);
        end
    end
    
    % ================= RX PUSH (DUAL RECEPTION) =================
    methods
        function pushRX(obj, msg, rssi, radio)
            % Push RX to appropriate radio
            if nargin < 4
                % Default: route to access if no radio specified
                radio = 'access';
            end
            
            switch radio
                case 'backbone'
                    obj.backbone.pushRX(msg, rssi);
                case 'access'
                    obj.access.pushRX(msg, rssi);
                otherwise
                    obj.access.pushRX(msg, rssi);
            end
        end
    end
    
    % ================= STEP (DUAL OPERATION) =================
    methods
        function [txOut, rxMsg, rxRSSI] = step(obj, t)
            % Both radios operate independently in parallel (half-duplex each)
            txOut = {};
            rxMsg = [];
            rxRSSI = [];
            
            % Step backbone radio
            [txBackbone, rxMsgBB, rxRSSIBB] = obj.backbone.step(t);
            
            % Step access radio
            [txAccess, rxMsgAcc, rxRSSIAcc] = obj.access.step(t);
            
            % Combine TX outputs (both may transmit different messages)
            txOut = [txBackbone, txAccess];
            
            % Priority for RX: access takes priority if both have messages
            if ~isempty(rxMsgAcc)
                rxMsg = rxMsgAcc;
                rxRSSI = rxRSSIAcc;
            elseif ~isempty(rxMsgBB)
                rxMsg = rxMsgBB;
                rxRSSI = rxRSSIBB;
            end
        end
    end
    
    % ================= LOCK CONTROL =================
    methods
        function setLock(obj, partner, timeout)
            obj.handshakePartner = partner;
            obj.lockTimer = timeout;
            obj.lockExpired = false;
            obj.access.setLock(partner, timeout);
            % Note: backbone doesn't need lock (GWN-GWN heartbeats are multicast)
        end
        
        function refreshLock(obj, timeout)
            % Refresh lock timer without changing partner
            if ~isempty(obj.handshakePartner)
                obj.lockTimer = timeout;
                obj.lockExpired = false;
                obj.access.refreshLock(timeout);
            end
        end
        
        function clearLock(obj, reason)
            if nargin < 2, reason = ''; end
            obj.handshakePartner = [];
            obj.lockTimer = 0;
            obj.lockExpired = false;
            obj.access.clearLock(reason);
        end

        function timeout(obj)
            % Mark lock as expired and log
            if ~isempty(obj.handshakePartner) && ~obj.lockExpired
                obj.lockExpired = true;
                obj.access.timeout();
            end
        end
    end
    
    % ================= BUFFER UTILITIES =================
    methods
        function clearBuffers(obj)
            obj.backbone.txBuffer = {};
            obj.backbone.rxBuffer = {};
            obj.access.txBuffer = {};
            obj.access.rxBuffer = {};
        end
        
        function [hasTx, hasRx] = getStatus(obj)
            hasTx = ~isempty(obj.backbone.txBuffer) || ~isempty(obj.access.txBuffer);
            hasRx = ~isempty(obj.backbone.rxBuffer) || ~isempty(obj.access.rxBuffer);
        end
    end
end
