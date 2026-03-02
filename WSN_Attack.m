classdef WSN_Attack < handle
    % =========================================================
    % WSN ATTACK MODULE — Central Attack Configuration & Logic
    % =========================================================
    % Attack types match GUI dropdown order (1-indexed in GUI):
    %   0. NONE           - Normal operation (GUI index 1)
    %   1. FLOODING       - Hello Flood (GUI index 2)
    %   2. PANIC_FLOOD    - Fake emergency alerts (GUI index 3)
    %   3. SYBIL          - Multiple identity impersonation (GUI index 4)
    %   4. BLACKHOLE      - Drop all data packets (GUI index 5)
    %   5. WORMHOLE       - False tunnel (GUI index 6)
    %   6. GRAYHOLE       - Selective forwarding (GUI index 7)
    %   7. DENIAL_SLEEP   - Vampire attack (GUI index 8)
    %
    % INTENSITY SCALE (1-10):
    %   1 = EASILY DETECTABLE: Aggressive, constant, affects both radios
    %       - GWN floods/blocks BOTH Access+Backbone radios
    %       - Constant malicious behavior, obvious patterns
    %       - High packet drop/flood rates
    %   10 = HARD TO DETECT: Subtle, intermittent, appears normal
    %       - GWN affects only ONE radio (random selection)
    %       - Intermittent attacks, node often behaves normally
    %       - Low rates, hard to distinguish from network issues
    %
    % Features:
    %   - Sink cannot be attacked
    %   - Attack messages have distinct bright colors
    %   - Attacked nodes shown with unique colors in topology
    %   - Ground truth recording for IDS (no explicit node logging)
    % =========================================================
    
    properties (Constant)
        % --- RADIO SELECTION (for GWN dual-radio attacks) ---
        RADIO_BOTH = 0
        RADIO_ACCESS = 1
        RADIO_BACKBONE = 2
        
        % --- ATTACK TYPE ENUMS (Match GUI dropdown order) ---
        ATTACK_NONE        = 0   % GUI: 'Normal'
        ATTACK_FLOODING    = 1   % GUI: 'Hello Flood'
        ATTACK_PANIC_FLOOD = 2   % GUI: 'Panic Flood'
        ATTACK_SYBIL       = 3   % GUI: 'Sybil'
        ATTACK_BLACKHOLE   = 4   % GUI: 'Black Hole'
        ATTACK_WORMHOLE    = 5   % GUI: 'Wormhole'
        ATTACK_GRAYHOLE    = 6   % GUI: 'Selective Forwarding'
        ATTACK_DENIAL_SLEEP= 7   % GUI: 'Denial of Sleep (Vampire)'
        
        % --- ATTACK MESSAGE COLORS (Bright distinct colors) ---
        COLOR_FLOODING     = [1.0 0.0 0.5]   % Hot Pink
        COLOR_PANIC_FLOOD  = [1.0 0.0 0.0]   % Bright Red
        COLOR_SYBIL        = [1.0 0.5 0.0]   % Orange
        COLOR_BLACKHOLE    = [0.2 0.2 0.2]   % Dark (absorbed)
        COLOR_WORMHOLE     = [0.6 0.0 1.0]   % Purple
        COLOR_GRAYHOLE     = [0.7 0.7 0.3]   % Olive/Gray-Yellow
        COLOR_DENIAL_SLEEP = [1.0 1.0 0.0]   % Bright Yellow
        
        % --- SYBIL IDENTITY COLORS (rotating) ---
        SYBIL_COLORS = [1.0 0.5 0.0; 1.0 0.7 0.0; 1.0 0.3 0.3; 0.9 0.5 0.9; 0.5 1.0 0.5]
    end
    
    methods (Static)
        % =========================================================
        % DATA STORAGE (Single persistent variable for all access)
        % =========================================================
        function data = pDataStore(newData)
            % Single function with persistent variable for get/set
            % Usage: getData -> pDataStore()
            %        setData -> pDataStore(newData)
            persistent pData
            if nargin > 0
                pData = newData;
            end
            data = pData;
        end
        
        function setData(data)
            WSN_Attack.pDataStore(data);
        end
        
        function data = getData()
            data = WSN_Attack.pDataStore();
        end
        
        % =========================================================
        % INITIALIZATION
        % =========================================================
        function init(numNodes)
            pData = struct();
            pData.isMalicious = false(1, numNodes);
            pData.attackType = zeros(1, numNodes);
            pData.intensity = zeros(1, numNodes);
            pData.attackParam = zeros(1, numNodes);
            pData.wormholeEndpoints = [];
            pData.sybilIdentities = cell(1, numNodes);
            pData.attackStartTime = zeros(1, numNodes);
            pData.packetsDropped = zeros(1, numNodes);
            pData.packetsFlooded = zeros(1, numNodes);
            pData.energyDrained = zeros(1, numNodes);
            pData.groundTruth = struct('time',{}, 'nodeIdx',{}, 'attackType',{}, 'action',{});
            
            % === REALISTIC ATTACK TRACKING FIELDS ===
            % Flooding: spread burst over ticks, track collision state
            pData.floodingBurstRemaining = zeros(1, numNodes);    % packets left in current burst
            pData.floodingLastBurstTick = zeros(1, numNodes);     % when last burst started
            pData.floodingCollisionCount = zeros(1, numNodes);    % self-collisions this tick
            
            % Blackhole/Grayhole: track drop history for realism
            pData.dropWindow = cell(1, numNodes);                 % recent drop decisions
            pData.promisedForwards = zeros(1, numNodes);          % packets promised to forward
            pData.actualForwards = zeros(1, numNodes);            % packets actually forwarded
            
            % Sybil: staggered identity injection (single radio constraint)
            pData.sybilInjectionTick = cell(1, numNodes);         % when each identity becomes active
            pData.sybilIdentityTier = cell(1, numNodes);          % tier type for each identity
            pData.sybilActiveIdentity = zeros(1, numNodes);       % which identity is currently on the radio (0=real node)
            
            % Wormhole: bandwidth and latency tracking
            pData.wormholeBandwidthUsed = zeros(1, numNodes);     % bytes used this tick
            pData.wormholeLatencyQueue = cell(1, numNodes);       % delayed packet queue
            
            % Denial of Sleep: cooldown tracking
            pData.denialLastWakeTick = zeros(1, numNodes);        % last wake packet sent
            pData.denialWakeCount = zeros(1, numNodes);           % total wakes sent
            
            % Panic Flood: rate limiting
            pData.panicLastTick = zeros(1, numNodes);             % last panic sent
            pData.panicCooldown = zeros(1, numNodes);             % cooldown remaining
            
            % === VISUAL TRACKING FOR GUI ===
            % Ghost links: dropped messages that should have been forwarded
            % struct array: {srcIdx, dstHexID, expiry, msgType}
            pData.ghostLinks = struct('srcIdx',{}, 'dstHexID',{}, 'expiry',{}, 'msgType',{});
            
            % DoS target tracking for double-line visual
            % struct array: {srcIdx, dstHexID, expiry}
            pData.dosTargets = struct('srcIdx',{}, 'dstHexID',{}, 'expiry',{});
            
            WSN_Attack.setData(pData);
        end
        
        % =========================================================
        % VISUAL TRACKING HELPERS
        % =========================================================
        function addGhostLink(srcIdx, dstHexID, expiry, msgType)
            % Add a ghost link for a dropped message
            % srcIdx is node array index, dstHexID is destination hex ID
            data = WSN_Attack.getData();
            if isempty(data), return; end
            if ~isfield(data, 'ghostLinks')
                data.ghostLinks = struct('srcIdx',{}, 'dstHexID',{}, 'expiry',{}, 'msgType',{});
            end
            
            newLink = struct('srcIdx', srcIdx, 'dstHexID', dstHexID, ...
                'expiry', expiry, 'msgType', msgType);
            data.ghostLinks(end+1) = newLink;
            
            % Prune old links (keep last 100)
            if numel(data.ghostLinks) > 100
                data.ghostLinks = data.ghostLinks(end-99:end);
            end
            
            WSN_Attack.setData(data);
        end
        
        function links = getGhostLinks(t)
            % Get all active ghost links for current time
            data = WSN_Attack.getData();
            links = [];
            if isempty(data) || ~isfield(data, 'ghostLinks'), return; end
            if isempty(data.ghostLinks), return; end
            
            active = [data.ghostLinks.expiry] >= t;
            links = data.ghostLinks(active);
            
            % Clean expired
            data.ghostLinks = data.ghostLinks(active);
            WSN_Attack.setData(data);
        end
        
        function addDoSTarget(srcIdx, dstHexID, expiry)
            % Track DoS wake packet for double-line visual
            data = WSN_Attack.getData();
            if isempty(data), return; end
            if ~isfield(data, 'dosTargets')
                data.dosTargets = struct('srcIdx',{}, 'dstHexID',{}, 'expiry',{});
            end
            
            newTarget = struct('srcIdx', srcIdx, 'dstHexID', dstHexID, 'expiry', expiry);
            data.dosTargets(end+1) = newTarget;
            
            % Prune expired
            if numel(data.dosTargets) > 50
                data.dosTargets = data.dosTargets(end-49:end);
            end
            
            WSN_Attack.setData(data);
        end
        
        function targets = getDoSTargets(t)
            % Get active DoS targets
            data = WSN_Attack.getData();
            targets = [];
            if isempty(data) || ~isfield(data, 'dosTargets'), return; end
            if isempty(data.dosTargets), return; end
            
            active = [data.dosTargets.expiry] >= t;
            targets = data.dosTargets(active);
            
            data.dosTargets = data.dosTargets(active);
            WSN_Attack.setData(data);
        end
        
        function [sybilNodes, sybilIDs] = getSybilVisuals(nodeIdx, nodePos, t)
            % Get visual data for Sybil fake nodes
            % Returns positions and IDs for rendering grey faux nodes
            sybilNodes = [];
            sybilIDs = {};
            
            data = WSN_Attack.getData();
            if isempty(data), return; end
            if ~data.isMalicious(nodeIdx), return; end
            if data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_SYBIL, return; end
            
            [~, fakeIDs, ~] = WSN_Attack.getActiveSybilIdentities(nodeIdx, t);
            if isempty(fakeIDs), return; end
            
            % Generate positions in a circle around the real node
            numFake = numel(fakeIDs);
            radius = 4;  % Offset radius in field units
            for i = 1:numFake
                angle = (i-1) * 2 * pi / numFake;
                fakePos = nodePos + radius * [cos(angle), sin(angle)];
                sybilNodes(i, :) = fakePos;
                sybilIDs{i} = dec2hex(fakeIDs(i), 4);
            end
        end
        
        function msgs = getSybilHelloMessages(nodeIdx, t, realPos, rssiRange)
            % Get fake HELLO message from the ACTIVE Sybil identity
            % SINGLE RADIO CONSTRAINT: Only ONE identity can broadcast at a time
            % The attacker cycles through identities over time
            msgs = {};
            
            data = WSN_Attack.getData();
            if isempty(data), return; end
            if ~data.isMalicious(nodeIdx), return; end
            if data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_SYBIL, return; end
            
            [~, fakeIDs, fakeTiers] = WSN_Attack.getActiveSybilIdentities(nodeIdx, t);
            if isempty(fakeIDs), return; end
            
            if nargin < 4, rssiRange = 80; end  % Default radio range
            
            % SINGLE RADIO: Cycle through identities (one per tick)
            % Use modulo to rotate through active identities
            numFake = numel(fakeIDs);
            activeIdx = mod(t, numFake) + 1;  % 1-indexed, cycles each tick
            
            % Store which identity is currently active
            data.sybilActiveIdentity(nodeIdx) = activeIdx;
            WSN_Attack.setData(data);
            
            % Only generate message for the active identity
            i = activeIdx;
            radius = 4;  % Offset radius in field units
            angle = (i-1) * 2 * pi / numFake;
            fakePos = realPos + radius * [cos(angle), sin(angle)];
            
            % Determine message type based on tier
            tierStr = fakeTiers{i};
            msg = WSN_Message();
            msg.type = 0;  % HELLO
            msg.dst = [];  % Broadcast
            msg.ttl = 1;
            msg.src = fakeIDs(i);
            
            if strcmp(tierStr, 'GWN')
                % GWN HELLO
                msg.subtype = 2;  % GWN HELLO
                msg.payload = uint8([80, 3]);  % 80% battery, tier=GWN
                msg.payloadLen = 2;
            elseif strcmp(tierStr, 'CH')
                % CH HELLO
                msg.subtype = 1;  % CH HELLO
                msg.payload = uint8([85, 2]);  % 85% battery, tier=CH
                msg.payloadLen = 2;
            else
                % Sensor HELLO
                msg.subtype = 0;  % Sensor HELLO
                msg.payload = uint8([90, 1]);  % 90% battery, tier=Sensor
                msg.payloadLen = 2;
            end
            
            msg.addChecksum();
            
            msgs{end+1} = struct('msg', msg, 'pos', fakePos, 'range', rssiRange, ...
                'fakeID', fakeIDs(i), 'tier', tierStr);
            
            % Record ground truth for Sybil hello injection
            WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_SYBIL, ...
                sprintf('HELLO_ID_%s_ACTIVE_%d_OF_%d', dec2hex(fakeIDs(i),4), activeIdx, numFake));
        end
        
        % =========================================================
        % GUI INTEGRATION
        % =========================================================
        function attackType = guiIndexToAttackType(guiIndex)
            % Convert GUI dropdown index (1-8) to attack type constant
            attackType = guiIndex - 1;
        end
        
        function guiIndex = attackTypeToGuiIndex(attackType)
            % Convert attack type constant to GUI dropdown index
            guiIndex = attackType + 1;
        end
        
        % =========================================================
        % CONFIGURATION
        % =========================================================
        function success = setMalicious(nodeIdx, attackTypeVal, intensityVal, nodes, startTime)
            % Set node as malicious with optional startTime
            % If startTime not provided and node already malicious, preserve existing
            success = false;
            data = WSN_Attack.getData();
            
            if isempty(data) || nodeIdx > numel(data.isMalicious)
                return;
            end
            
            % SINK PROTECTION: Cannot attack Sink
            if nargin >= 4 && ~isempty(nodes)
                if isa(nodes(nodeIdx), 'WSN_Sink')
                    return;
                end
            end
            
            % Clear if setting to NONE
            if attackTypeVal == WSN_Attack.ATTACK_NONE
                WSN_Attack.clearMalicious(nodeIdx);
                success = true;
                return;
            end
            
            % Preserve existing startTime if already malicious and not explicitly provided
            existingStartTime = data.attackStartTime(nodeIdx);
            wasAlreadyMalicious = data.isMalicious(nodeIdx);
            
            data.isMalicious(nodeIdx) = true;
            data.attackType(nodeIdx) = attackTypeVal;
            data.intensity(nodeIdx) = intensityVal;
            data.attackParam(nodeIdx) = WSN_Attack.computeAttackParam(attackTypeVal, intensityVal);
            
            % Handle startTime: explicit > preserve existing > default 0
            if nargin >= 5 && ~isempty(startTime)
                data.attackStartTime(nodeIdx) = startTime;
            elseif wasAlreadyMalicious && existingStartTime > 0
                data.attackStartTime(nodeIdx) = existingStartTime;  % Preserve
            else
                data.attackStartTime(nodeIdx) = 0;  % Immediate
            end
            
            % === REALISTIC SYBIL IDENTITY GENERATION ===
            if attackTypeVal == WSN_Attack.ATTACK_SYBIL
                % Intensity 1-3: many identities, Intensity 7-10: fewer, stealthier
                numIds = max(1, 5 - floor((intensityVal - 1) / 2));  % 5 at intensity 1, 1 at intensity 10
                
                % Determine attacker's tier from nodes array
                attackerTier = 'SENSOR';  % Default
                if nargin >= 4 && ~isempty(nodes)
                    if isa(nodes(nodeIdx), 'WSN_Gateway')
                        attackerTier = 'GATEWAY';
                    elseif isa(nodes(nodeIdx), 'WSN_ClusterHead')
                        attackerTier = 'CH';
                    end
                end
                
                % Generate tier-plausible IDs with correct prefixes:
                % 00xx = Sensor, AAxx = CH, FFxx = GWN
                ids = zeros(1, numIds);
                tiers = cell(1, numIds);
                injectionTicks = zeros(1, numIds);
                for i = 1:numIds
                    % Generate random suffix (00-FF for pqrs portion)
                    suffix = randi([0, 255]);
                    
                    switch attackerTier
                        case 'GATEWAY'
                            % GWN can impersonate CH, Sensor, or other GWN
                            r = rand();
                            if r < 0.3
                                ids(i) = hex2dec('AA00') + suffix;  % AAxx = CH
                                tiers{i} = 'CH';
                            elseif r < 0.6
                                ids(i) = hex2dec('FF00') + suffix;  % FFxx = GWN (risky)
                                tiers{i} = 'GWN';
                            else
                                ids(i) = hex2dec('0000') + suffix;  % 00xx = Sensor
                                tiers{i} = 'SENSOR';
                            end
                        case 'CH'
                            % CH can impersonate sensors or other CHs
                            if rand() < 0.3
                                ids(i) = hex2dec('AA00') + suffix;  % AAxx = CH
                                tiers{i} = 'CH';
                            else
                                ids(i) = hex2dec('0000') + suffix;  % 00xx = Sensor
                                tiers{i} = 'SENSOR';
                            end
                        otherwise
                            % Sensor can only impersonate other sensors
                            ids(i) = hex2dec('0000') + suffix;  % 00xx = Sensor
                            tiers{i} = 'SENSOR';
                    end
                    % Stagger injection: high intensity = slower injection
                    baseDelay = (intensityVal - 1) * 3;  % 0 ticks at intensity 1, 27 at intensity 10
                    injectionTicks(i) = baseDelay + (i - 1) * intensityVal;
                end
                data.sybilIdentities{nodeIdx} = ids;
                data.sybilIdentityTier{nodeIdx} = tiers;
                data.sybilInjectionTick{nodeIdx} = injectionTicks;
            end
            
            WSN_Attack.setData(data);
            success = true;
        end
        
        function clearMalicious(nodeIdx)
            data = WSN_Attack.getData();
            
            if ~isempty(data) && nodeIdx <= numel(data.isMalicious)
                data.isMalicious(nodeIdx) = false;
                data.attackType(nodeIdx) = 0;
                data.intensity(nodeIdx) = 0;
                data.attackParam(nodeIdx) = 0;
                
                % Clear Sybil state
                if numel(data.sybilIdentities) >= nodeIdx
                    data.sybilIdentities{nodeIdx} = [];
                end
                if numel(data.sybilIdentityTier) >= nodeIdx
                    data.sybilIdentityTier{nodeIdx} = {};
                end
                if numel(data.sybilInjectionTick) >= nodeIdx
                    data.sybilInjectionTick{nodeIdx} = [];
                end
                
                % Clear flooding state
                data.floodingBurstRemaining(nodeIdx) = 0;
                data.floodingLastBurstTick(nodeIdx) = 0;
                data.floodingCollisionCount(nodeIdx) = 0;
                
                % Clear drop tracking
                if numel(data.dropWindow) >= nodeIdx
                    data.dropWindow{nodeIdx} = [];
                end
                data.promisedForwards(nodeIdx) = 0;
                data.actualForwards(nodeIdx) = 0;
                
                % Clear wormhole state
                data.wormholeBandwidthUsed(nodeIdx) = 0;
                if numel(data.wormholeLatencyQueue) >= nodeIdx
                    data.wormholeLatencyQueue{nodeIdx} = [];
                end
                
                % Clear denial of sleep state
                data.denialLastWakeTick(nodeIdx) = 0;
                data.denialWakeCount(nodeIdx) = 0;
                
                % Clear panic flood state
                data.panicLastTick(nodeIdx) = 0;
                data.panicCooldown(nodeIdx) = 0;
                
                WSN_Attack.setData(data);
            end
        end
        
        function setWormholeEndpoints(nodeA, nodeB, intensity, nodes)
            data = WSN_Attack.getData();
            
            % Prevent Sink from being wormhole endpoint
            if nargin >= 4 && ~isempty(nodes)
                if isa(nodes(nodeA), 'WSN_Sink') || isa(nodes(nodeB), 'WSN_Sink')
                    return;
                end
            end
            
            if nargin < 3, intensity = 5; end
            
            data.wormholeEndpoints = [nodeA, nodeB];
            WSN_Attack.setData(data);
            
            WSN_Attack.setMalicious(nodeA, WSN_Attack.ATTACK_WORMHOLE, intensity, []);
            WSN_Attack.setMalicious(nodeB, WSN_Attack.ATTACK_WORMHOLE, intensity, []);
        end
        
        function result = isMaliciousNode(nodeIdx, t)
            % Check if node is malicious and attack is active at time t
            % If t not provided, ignores start time (backward compatible)
            data = WSN_Attack.getData();
            result = ~isempty(data) && nodeIdx <= numel(data.isMalicious) && data.isMalicious(nodeIdx);
            
            % Check start time if provided
            if result && nargin >= 2 && ~isempty(t)
                startTime = data.attackStartTime(nodeIdx);
                if startTime > 0 && t < startTime
                    result = false;  % Attack not yet active
                end
            end
        end
        
        function result = isAttackActiveAt(nodeIdx, t)
            % Explicit time-aware check: is attack active at tick t?
            data = WSN_Attack.getData();
            if isempty(data) || nodeIdx > numel(data.isMalicious)
                result = false;
                return;
            end
            if ~data.isMalicious(nodeIdx)
                result = false;
                return;
            end
            startTime = data.attackStartTime(nodeIdx);
            result = (startTime == 0) || (t >= startTime);
        end
        
        function aType = getAttackType(nodeIdx)
            data = WSN_Attack.getData();
            if ~isempty(data) && nodeIdx <= numel(data.attackType)
                aType = data.attackType(nodeIdx);
            else
                aType = 0;
            end
        end
        
        function inten = getIntensity(nodeIdx)
            data = WSN_Attack.getData();
            if ~isempty(data) && nodeIdx <= numel(data.intensity)
                inten = data.intensity(nodeIdx);
            else
                inten = 0;
            end
        end
        
        function st = getStartTime(nodeIdx)
            % Get the activation tick for this node's attack
            data = WSN_Attack.getData();
            if ~isempty(data) && nodeIdx <= numel(data.attackStartTime)
                st = data.attackStartTime(nodeIdx);
            else
                st = 0;
            end
        end
        
        function setStartTime(nodeIdx, startTime)
            % Set/update the activation tick for a node's attack
            data = WSN_Attack.getData();
            if ~isempty(data) && nodeIdx <= numel(data.attackStartTime)
                data.attackStartTime(nodeIdx) = startTime;
                WSN_Attack.setData(data);
            end
        end
        
        function param = computeAttackParam(attackTypeVal, intensityVal)
            switch attackTypeVal
                case WSN_Attack.ATTACK_BLACKHOLE
                    param = 1.0;
                case WSN_Attack.ATTACK_GRAYHOLE
                    if intensityVal <= 4
                        param = 0.5 + (intensityVal / 4) * 0.2;
                    else
                        param = 0.6 + rand() * 0.3;
                    end
                case WSN_Attack.ATTACK_FLOODING
                    param = 20 + intensityVal * 8;
                case WSN_Attack.ATTACK_SYBIL
                    param = 2 + floor(intensityVal / 3);
                otherwise
                    param = intensityVal;
            end
        end
        
        % =========================================================
        % MESSAGE COLOR ASSIGNMENT (for GUI visualization)
        % =========================================================
        function color = getMessageColor(nodeIdx, ~)
            % Get distinct bright color for messages from attacked node
            % Returns empty [] if node is not malicious (use default)
            
            if ~WSN_Attack.isMaliciousNode(nodeIdx)
                color = [];
                return;
            end
            
            attackType = WSN_Attack.getAttackType(nodeIdx);
            
            switch attackType
                case WSN_Attack.ATTACK_FLOODING
                    color = WSN_Attack.COLOR_FLOODING;
                case WSN_Attack.ATTACK_PANIC_FLOOD
                    color = WSN_Attack.COLOR_PANIC_FLOOD;
                case WSN_Attack.ATTACK_SYBIL
                    colors = WSN_Attack.SYBIL_COLORS;
                    color = colors(randi(size(colors,1)), :);
                case WSN_Attack.ATTACK_BLACKHOLE
                    color = WSN_Attack.COLOR_BLACKHOLE;
                case WSN_Attack.ATTACK_WORMHOLE
                    color = WSN_Attack.COLOR_WORMHOLE;
                case WSN_Attack.ATTACK_GRAYHOLE
                    color = WSN_Attack.COLOR_GRAYHOLE;
                case WSN_Attack.ATTACK_DENIAL_SLEEP
                    color = WSN_Attack.COLOR_DENIAL_SLEEP;
                otherwise
                    color = [1.0 0.2 0.2];  % Default malicious red
            end
        end
        
        function [faceColor, edgeColor, lineWidth] = getNodeColor(nodeIdx)
            % Get node colors for GUI topology
            % Returns empty if not malicious
            
            if ~WSN_Attack.isMaliciousNode(nodeIdx)
                faceColor = [];
                edgeColor = [];
                lineWidth = [];
                return;
            end
            
            attackType = WSN_Attack.getAttackType(nodeIdx);
            intensity = WSN_Attack.getIntensity(nodeIdx);
            
            % Intensity affects brightness
            bright = 0.7 + (intensity / 10) * 0.3;
            lineWidth = 2.0 + (intensity / 10);
            
            switch attackType
                case WSN_Attack.ATTACK_FLOODING
                    faceColor = [bright, 0.0, 0.5];
                    edgeColor = [0.8, 0.0, 0.3];
                case WSN_Attack.ATTACK_PANIC_FLOOD
                    faceColor = [bright, 0.1, 0.1];
                    edgeColor = [0.6, 0.0, 0.0];
                case WSN_Attack.ATTACK_SYBIL
                    faceColor = [1.0, 0.5, 0.0];
                    edgeColor = [0.8, 0.3, 0.0];
                case WSN_Attack.ATTACK_BLACKHOLE
                    faceColor = [0.15, 0.15, 0.15];
                    edgeColor = [0.0, 0.0, 0.0];
                case WSN_Attack.ATTACK_WORMHOLE
                    faceColor = [0.6, 0.0, bright];
                    edgeColor = [0.4, 0.0, 0.6];
                case WSN_Attack.ATTACK_GRAYHOLE
                    faceColor = [0.55, 0.55, 0.35];
                    edgeColor = [0.3, 0.3, 0.2];
                case WSN_Attack.ATTACK_DENIAL_SLEEP
                    faceColor = [1.0, bright, 0.0];
                    edgeColor = [0.8, 0.6, 0.0];
                otherwise
                    faceColor = [1.0, 0.2, 0.2];
                    edgeColor = [0.8, 0.0, 0.0];
            end
        end
        
        % =========================================================
        % BLACKHOLE ATTACK LOGIC
        % Intensity 1 = Always drop (obvious), Intensity 10 = Rare drops (stealthy)
        % REALISTIC: Tracks drop history, uses smart selection, maintains cover
        % =========================================================
        function drop = shouldDropBlackhole(nodeIdx, t)
            data = WSN_Attack.getData();
            drop = false;
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_BLACKHOLE
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Track promised vs actual to maintain realistic behavior
            data.promisedForwards(nodeIdx) = data.promisedForwards(nodeIdx) + 1;
            
            % Initialize drop window if needed
            if isempty(data.dropWindow{nodeIdx})
                data.dropWindow{nodeIdx} = [];
            end
            
            % Compute recent drop ratio from history (for adaptive behavior)
            windowSize = 20;
            history = data.dropWindow{nodeIdx};
            recentDropRatio = 0;
            if ~isempty(history)
                recentHistory = history(max(1, end-windowSize+1):end);
                recentDropRatio = sum(recentHistory) / numel(recentHistory);
            end
            
            % Intensity 1-3: Always drop (easily detectable)
            % Intensity 4-6: Periodic drops with adaptive timing
            % Intensity 7-10: Smart drops - maintain low but consistent drop ratio
            if intensity <= 3
                drop = true;  % 100% drop rate - obvious
            elseif intensity <= 6
                % Periodic: drop less frequently, but adapt if too obvious
                basePeriod = 2 + intensity;  % period 6-8
                if recentDropRatio > 0.6  % Too obvious, back off
                    basePeriod = basePeriod + 2;
                end
                drop = mod(t, basePeriod) == 0;
            else
                % Stealthy: maintain low drop ratio, looks like normal packet loss
                targetDropRatio = 0.3 - (intensity - 7) * 0.07;  % 30% -> 9%
                if recentDropRatio < targetDropRatio * 0.8
                    % Below target - can drop
                    drop = rand() < (targetDropRatio * 1.2);
                elseif recentDropRatio > targetDropRatio * 1.3
                    % Above target - don't drop
                    drop = false;
                else
                    % Near target - random with target probability
                    drop = rand() < targetDropRatio;
                end
            end
            
            % Update tracking
            data.dropWindow{nodeIdx} = [data.dropWindow{nodeIdx}, double(drop)];
            if numel(data.dropWindow{nodeIdx}) > 50
                data.dropWindow{nodeIdx} = data.dropWindow{nodeIdx}(end-49:end);
            end
            
            if drop
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
            else
                data.actualForwards(nodeIdx) = data.actualForwards(nodeIdx) + 1;
            end
            WSN_Attack.setData(data);
            
            if drop
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_BLACKHOLE, 'DROP');
            end
        end
        
        function [dropAccess, dropBackbone] = shouldDropBlackholeGWN(nodeIdx, t)
            % GWN-specific: which radio(s) to block
            % Intensity 1 = Block BOTH radios (obvious)
            % Intensity 10 = Block only ONE radio intermittently (stealthy)
            dropAccess = false;
            dropBackbone = false;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_BLACKHOLE
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            if intensity <= 3
                % Block BOTH radios constantly
                dropAccess = true;
                dropBackbone = true;
            elseif intensity <= 6
                % Block both but periodically
                period = intensity + 2;
                if mod(t, period) < 2
                    dropAccess = true;
                    dropBackbone = true;
                end
            else
                % Stealthy: block only ONE radio, randomly
                if rand() < (0.4 - (intensity - 7) * 0.08)
                    if rand() < 0.5
                        dropAccess = true;
                    else
                        dropBackbone = true;
                    end
                end
            end
            
            if dropAccess || dropBackbone
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
                WSN_Attack.setData(data);
                if dropAccess && dropBackbone
                    radioStr = 'BOTH';
                elseif dropAccess
                    radioStr = 'ACCESS';
                else
                    radioStr = 'BACKBONE';
                end
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_BLACKHOLE, ['DROP_' radioStr]);
            end
        end
        
        % =========================================================
        % GRAYHOLE ATTACK LOGIC (Selective Forwarding)
        % Intensity 1 = High drop rate (obvious), Intensity 10 = Low drop rate (stealthy)
        % REALISTIC: Tracks history, varies pattern to avoid detection
        % =========================================================
        function drop = shouldDropGrayhole(nodeIdx, t)
            data = WSN_Attack.getData();
            drop = false;
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_GRAYHOLE
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Initialize drop window if needed
            if isempty(data.dropWindow{nodeIdx})
                data.dropWindow{nodeIdx} = [];
            end
            
            % Compute recent drop ratio from history
            windowSize = 30;
            history = data.dropWindow{nodeIdx};
            recentDropRatio = 0;
            if ~isempty(history)
                recentHistory = history(max(1, end-windowSize+1):end);
                recentDropRatio = sum(recentHistory) / numel(recentHistory);
            end
            
            % Determine target drop rate based on intensity
            % Intensity 1-3: High drop rate 70-80% (obvious)
            % Intensity 4-6: Medium drop rate 40-50% (moderate)
            % Intensity 7-10: Low drop rate 10-25% (stealthy, looks like packet loss)
            if intensity <= 3
                targetDropRate = 0.8 - (intensity - 1) * 0.05;  % 0.8 -> 0.7
            elseif intensity <= 6
                targetDropRate = 0.55 - (intensity - 4) * 0.05;  % 0.55 -> 0.4
            else
                targetDropRate = 0.25 - (intensity - 7) * 0.05;  % 0.25 -> 0.1
            end
            
            % Adaptive dropping: vary rate around target to create natural pattern
            variance = 0.1;  % Allow 10% variance
            if recentDropRatio < targetDropRate - variance
                % Below target - increase drop rate
                drop = rand() < (targetDropRate + variance);
            elseif recentDropRatio > targetDropRate + variance
                % Above target - decrease drop rate
                drop = rand() < (targetDropRate - variance);
            else
                % At target - use base rate with small random adjustment
                drop = rand() < (targetDropRate + (rand() - 0.5) * variance);
            end
            
            % Track decision
            data.dropWindow{nodeIdx} = [data.dropWindow{nodeIdx}, double(drop)];
            if numel(data.dropWindow{nodeIdx}) > 50
                data.dropWindow{nodeIdx} = data.dropWindow{nodeIdx}(end-49:end);
            end
            
            if drop
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_GRAYHOLE, 'DROP');
            else
                data.actualForwards(nodeIdx) = data.actualForwards(nodeIdx) + 1;
            end
            data.promisedForwards(nodeIdx) = data.promisedForwards(nodeIdx) + 1;
            WSN_Attack.setData(data);
        end
        
        function [dropAccess, dropBackbone] = shouldDropGrayholeGWN(nodeIdx, t) %
            % GWN-specific selective forwarding
            % t argument reserved for future time-based pattern variation
            dropAccess = false;
            dropBackbone = false;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_GRAYHOLE
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            if intensity <= 3
                % Drop on both radios with high rate
                dropRate = 0.75 - (intensity - 1) * 0.05;
                dropAccess = rand() < dropRate;
                dropBackbone = rand() < dropRate;
            elseif intensity <= 6
                % Medium rate, sometimes only one radio
                dropRate = 0.45 - (intensity - 4) * 0.05;
                if rand() < 0.7  % 70% chance to affect both
                    dropAccess = rand() < dropRate;
                    dropBackbone = rand() < dropRate;
                else  % 30% chance single radio
                    if rand() < 0.5
                        dropAccess = rand() < dropRate;
                    else
                        dropBackbone = rand() < dropRate;
                    end
                end
            else
                % Stealthy: low rate, usually single radio
                dropRate = 0.2 - (intensity - 7) * 0.03;
                if rand() < 0.3  % Rarely affect both
                    dropAccess = rand() < dropRate;
                    dropBackbone = rand() < dropRate;
                else
                    if rand() < 0.5
                        dropAccess = rand() < dropRate;
                    else
                        dropBackbone = rand() < dropRate;
                    end
                end
            end
            
            if dropAccess || dropBackbone
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
                WSN_Attack.setData(data);
            end
        end
        
        % =========================================================
        % FLOODING ATTACK LOGIC
        % Intensity 1 = Massive constant flood (obvious)
        % Intensity 10 = Occasional small bursts (stealthy)
        % REALISTIC: Spreads packets over ticks, models self-interference/collision
        % =========================================================
        function [count, collisionLoss] = getFloodingBurstCount(nodeIdx, t)
            data = WSN_Attack.getData();
            count = 0;
            collisionLoss = 0;
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_FLOODING
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Check if we have remaining packets from a previous burst
            if data.floodingBurstRemaining(nodeIdx) > 0
                % Continue spreading previous burst over this tick
                maxPerTick = 15;  % Realistic per-tick limit
                count = min(data.floodingBurstRemaining(nodeIdx), maxPerTick);
                data.floodingBurstRemaining(nodeIdx) = data.floodingBurstRemaining(nodeIdx) - count;
            else
                % Decide whether to start a new burst
                newBurstSize = 0;
                
                % Intensity 1-3: Massive constant flooding (50-100 packets total)
                % Intensity 4-6: Moderate periodic flooding (20-40 packets)
                % Intensity 7-10: Occasional small bursts (5-15 packets, rare)
                if intensity <= 3
                    newBurstSize = 100 - (intensity - 1) * 15;  % 100 -> 70
                elseif intensity <= 6
                    % Periodic flooding
                    period = 3 + intensity;  % period 7-9
                    if mod(t, period) == 0
                        newBurstSize = 40 - (intensity - 4) * 7;  % 40 -> 26
                    end
                else
                    % Stealthy: rare small bursts
                    if rand() < (0.25 - (intensity - 7) * 0.05)  % 25% -> 10% chance
                        newBurstSize = 15 - (intensity - 7) * 3;  % 15 -> 6
                        newBurstSize = max(3, newBurstSize);
                    end
                end
                
                if newBurstSize > 0
                    % Start new burst - spread over multiple ticks
                    maxPerTick = 15;
                    count = min(newBurstSize, maxPerTick);
                    data.floodingBurstRemaining(nodeIdx) = newBurstSize - count;
                    data.floodingLastBurstTick(nodeIdx) = t;
                end
            end
            
            % Model self-interference: too many packets cause collisions
            if count > 0
                % Collision probability increases with packet count
                collisionProb = min(0.5, count * 0.03);  % Up to 50% loss at 15+ packets
                collisionLoss = floor(count * collisionProb);
                actualSent = count - collisionLoss;
                
                % Track energy cost per packet (realistic drain)
                energyCostPerPacket = 0.02;  % 2% of base per packet
                data.energyDrained(nodeIdx) = data.energyDrained(nodeIdx) + count * energyCostPerPacket;
                
                data.packetsFlooded(nodeIdx) = data.packetsFlooded(nodeIdx) + actualSent;
                data.floodingCollisionCount(nodeIdx) = data.floodingCollisionCount(nodeIdx) + collisionLoss;
                WSN_Attack.setData(data);
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_FLOODING, ...
                    sprintf('FLOOD_%d_COLL_%d', actualSent, collisionLoss));
            else
                WSN_Attack.setData(data);
            end
        end
        
        function [countAccess, countBackbone, collisionLoss] = getFloodingBurstCountGWN(nodeIdx, t)
            % GWN-specific: which radio(s) to flood
            % Intensity 1 = Flood BOTH radios massively (obvious)
            % Intensity 10 = Flood only ONE radio occasionally (stealthy)
            % REALISTIC: Per-radio limits, collision modeling, energy tracking
            countAccess = 0;
            countBackbone = 0;
            collisionLoss = 0;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_FLOODING
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            maxPerRadioPerTick = 10;  % Realistic per-radio limit
            
            % Determine target counts based on intensity
            targetAccess = 0;
            targetBackbone = 0;
            
            if intensity <= 3
                % Flood BOTH radios constantly with high volume
                baseCount = 80 - (intensity - 1) * 10;  % 80 -> 60
                targetAccess = baseCount;
                targetBackbone = baseCount;
            elseif intensity <= 6
                % Moderate: flood both but less frequently
                period = intensity + 3;
                if mod(t, period) == 0
                    baseCount = 35 - (intensity - 4) * 5;  % 35 -> 25
                    targetAccess = baseCount;
                    targetBackbone = baseCount;
                end
            else
                % Stealthy: flood only ONE radio, rarely
                if rand() < (0.2 - (intensity - 7) * 0.04)  % 20% -> 8%
                    smallCount = 12 - (intensity - 7) * 2;  % 12 -> 6
                    smallCount = max(3, smallCount);
                    if rand() < 0.5
                        targetAccess = smallCount;
                    else
                        targetBackbone = smallCount;
                    end
                end
            end
            
            % Spread over ticks (don't send more than max per tick)
            countAccess = min(targetAccess, maxPerRadioPerTick);
            countBackbone = min(targetBackbone, maxPerRadioPerTick);
            
            % Model collision losses per radio
            if countAccess > 0
                collisionProbAccess = min(0.4, countAccess * 0.04);
                lossAccess = floor(countAccess * collisionProbAccess);
                countAccess = countAccess - lossAccess;
                collisionLoss = collisionLoss + lossAccess;
            end
            if countBackbone > 0
                collisionProbBackbone = min(0.4, countBackbone * 0.04);
                lossBackbone = floor(countBackbone * collisionProbBackbone);
                countBackbone = countBackbone - lossBackbone;
                collisionLoss = collisionLoss + lossBackbone;
            end
            
            total = countAccess + countBackbone;
            if total > 0
                % Track energy cost
                energyCostPerPacket = 0.025;  % GWN uses more power
                data.energyDrained(nodeIdx) = data.energyDrained(nodeIdx) + (total + collisionLoss) * energyCostPerPacket;
                
                data.packetsFlooded(nodeIdx) = data.packetsFlooded(nodeIdx) + total;
                data.floodingCollisionCount(nodeIdx) = data.floodingCollisionCount(nodeIdx) + collisionLoss;
                WSN_Attack.setData(data);
                if countAccess > 0 && countBackbone > 0
                    radioStr = 'BOTH';
                elseif countAccess > 0
                    radioStr = 'ACCESS';
                else
                    radioStr = 'BACKBONE';
                end
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_FLOODING, ...
                    sprintf('FLOOD_%s_%d_COLL_%d', radioStr, total, collisionLoss));
            end
        end
        
        function txPower = getFloodingTxPower(nodeIdx)
            data = WSN_Attack.getData();
            txPower = WSN_Config.TxPower_CH;
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_FLOODING
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            % Intensity 1: High power (5x), Intensity 10: Normal power (1.2x)
            multiplier = 5 - (intensity - 1) * 0.4;  % 5x -> 1.4x
            multiplier = max(1.2, multiplier);
            txPower = WSN_Config.TxPower_CH * multiplier;
        end
        
        % =========================================================
        % SYBIL ATTACK LOGIC
        % Any node can impersonate any tier (Sensor, CH, or GWN)
        % Intensity 1 = Many fake IDs, obvious patterns
        % Intensity 10 = Few fake IDs, subtle impersonation
        % REALISTIC: Tier-appropriate IDs, staggered injection, resource cost
        % =========================================================
        function [isSybil, fakeIDs] = getSybilIdentities(nodeIdx)
            % Returns ALL configured fake IDs (ignores injection timing)
            % Use getActiveSybilIdentities() for time-aware version
            data = WSN_Attack.getData();
            isSybil = false;
            fakeIDs = [];
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_SYBIL
                return;
            end
            
            isSybil = true;
            if numel(data.sybilIdentities) >= nodeIdx
                fakeIDs = data.sybilIdentities{nodeIdx};
            end
        end
        
        function [isSybil, fakeIDs, fakeTiers] = getActiveSybilIdentities(nodeIdx, t)
            % REALISTIC: Returns only identities that have been "discovered"
            % based on injection timing. Simulates realistic identity spoofing.
            data = WSN_Attack.getData();
            isSybil = false;
            fakeIDs = [];
            fakeTiers = {};
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_SYBIL
                return;
            end
            
            isSybil = true;
            if numel(data.sybilIdentities) >= nodeIdx
                allIDs = data.sybilIdentities{nodeIdx};
                allTiers = data.sybilIdentityTier{nodeIdx};
                injectionTicks = data.sybilInjectionTick{nodeIdx};
                
                if isempty(allIDs) || isempty(injectionTicks)
                    return;
                end
                
                % Only return identities whose injection tick has passed
                attackStartTime = data.attackStartTime(nodeIdx);
                if attackStartTime == 0
                    attackStartTime = t;
                    data.attackStartTime(nodeIdx) = t;
                    WSN_Attack.setData(data);
                end
                
                elapsedTicks = t - attackStartTime;
                activeIdx = injectionTicks <= elapsedTicks;
                fakeIDs = allIDs(activeIdx);
                if ~isempty(allTiers)
                    fakeTiers = allTiers(activeIdx);
                end
            end
        end
        
        function fakeID = getRandomSybilID(nodeIdx)
            [isSybil, fakeIDs] = WSN_Attack.getSybilIdentities(nodeIdx);
            if isSybil && ~isempty(fakeIDs)
                fakeID = fakeIDs(randi(numel(fakeIDs)));
            else
                fakeID = [];
            end
        end
        
        function [fakeID, fakeTier] = getSybilIdentityWithTier(nodeIdx, targetTier)
            % Get a fake ID impersonating a specific tier
            % targetTier: 1=Sensor, 2=CH, 3=GWN (or 0 for random)
            fakeID = [];
            fakeTier = 0;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_SYBIL
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Determine target tier if not specified
            if nargin < 2 || targetTier == 0
                % Intensity affects impersonation "boldness"
                % Low intensity: more likely to impersonate higher tiers
                % High intensity: stick to same or lower tier
                if intensity <= 3
                    % Bold: can impersonate any tier
                    fakeTier = randi([1, 3]);
                elseif intensity <= 6
                    % Moderate: mostly same-tier or one above
                    fakeTier = randi([1, 2]);
                else
                    % Stealthy: usually same tier (less suspicious)
                    fakeTier = 1;  % Default to sensor (safest impersonation)
                end
            else
                fakeTier = targetTier;
            end
            
            % Generate plausible ID for the target tier
            % IDs typically have tier-related patterns
            switch fakeTier
                case 1  % Sensor: typically 0x0xxx range
                    fakeID = randi([hex2dec('0100'), hex2dec('0FFF')]);
                case 2  % CH: typically 0x1xxx-0x3xxx range
                    fakeID = randi([hex2dec('1000'), hex2dec('3FFF')]);
                case 3  % GWN: typically 0x4xxx-0x7xxx range
                    fakeID = randi([hex2dec('4000'), hex2dec('7FFF')]);
            end
        end
        
        function numIDs = getSybilIdentityCount(nodeIdx)
            % Intensity 1 = Many IDs (5-8), obvious
            % Intensity 10 = Few IDs (1-2), stealthy
            numIDs = 0;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_SYBIL
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            if intensity <= 3
                numIDs = 8 - intensity;  % 8 -> 6
            elseif intensity <= 6
                numIDs = 5 - floor((intensity - 4) * 0.7);  % 5 -> 3
            else
                numIDs = max(1, 3 - floor((intensity - 7) * 0.5));  % 3 -> 1
            end
        end
        
        % =========================================================
        % SYBIL ATTACK - SENSOR NODE BEHAVIOR
        % =========================================================
        % Sensors under Sybil attack:
        %   - CAN advertise fake IDs via HELLO packets (Type 0)
        %   - CAN intercept/drop packets addressed to fake IDs
        %   - CANNOT generate Type 1/5/6/7/8 messages as fake higher tier
        %     (they lack the protocol capabilities)
        %   - CAN relay-drop any forwarded Type 2 PANIC for fake IDs
        % =========================================================
        
        function shouldAdvertise = shouldSybilAdvertiseHello(nodeIdx, t)
            % Determine if Sybil sensor should send fake HELLO this tick
            % Returns true if should send one or more fake HELLOs
            shouldAdvertise = false;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_SYBIL
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Intensity 1-3: Advertise fake IDs every tick (obvious)
            % Intensity 4-6: Advertise periodically
            % Intensity 7-10: Rarely advertise (stealthy - hard to detect duplicates)
            if intensity <= 3
                shouldAdvertise = true;
            elseif intensity <= 6
                period = intensity + 1;  % period 5-7
                shouldAdvertise = mod(t, period) == 0;
            else
                shouldAdvertise = rand() < (0.2 - (intensity - 7) * 0.04);  % 20% -> 8%
            end
            
            if shouldAdvertise
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_SYBIL, 'HELLO_FAKE');
            end
        end
        
        function [intercept, fakeIDs] = shouldSybilInterceptPacket(nodeIdx, dstID, t)
            % Check if Sybil node should intercept a packet addressed to dstID
            % Returns true if dstID matches one of the fake identities
            intercept = false;
            fakeIDs = [];
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_SYBIL
                return;
            end
            
            if numel(data.sybilIdentities) >= nodeIdx
                fakeIDs = data.sybilIdentities{nodeIdx};
            end
            
            if isempty(fakeIDs)
                return;
            end
            
            % Check if destination matches any fake ID
            if any(fakeIDs == dstID)
                intercept = true;
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_SYBIL, 'INTERCEPT');
            end
        end
        
        function drop = shouldSybilDropIntercepted(nodeIdx, t)
            % After intercepting, decide whether to drop (blackhole the fake ID)
            % or process/forward (more elaborate attack)
            drop = true;  % Default: drop intercepted packets
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_SYBIL
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Intensity 1-3: Always drop (obvious black hole)
            % Intensity 4-6: Sometimes forward (confusing behavior)
            % Intensity 7-10: Mostly forward (looks like legitimate node)
            if intensity <= 3
                drop = true;
            elseif intensity <= 6
                drop = rand() < 0.7;  % 70% drop
            else
                drop = rand() < 0.3;  % 30% drop (mostly forwards)
            end
            
            if drop
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
                WSN_Attack.setData(data);
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_SYBIL, 'DROP_FAKE_DST');
            end
        end
        
        % =========================================================
        % SENSOR-SPECIFIC ATTACK METHODS
        % =========================================================
        % Sensors can:
        %   - Drop Type 2 PANIC relay (refuse to forward)
        %   - Suppress own Type 1 SENSOR readings
        %   - [Future] Drop any forwarded message types when sensor
        %              forwarding is introduced (Type X, Y, etc.)
        % The generic shouldSensorDropForwarded() handles current and
        % future forwarding types uniformly.
        % =========================================================
        
        function drop = shouldSensorDropForwarded(nodeIdx, msgType, t)
            % Generic sensor drop check for any forwarded message type
            % Currently supports: Type 2 (PANIC)
            % Future: Additional forwarding types will use same logic
            drop = false;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx)
                return;
            end
            
            attackType = data.attackType(nodeIdx);
            if attackType ~= WSN_Attack.ATTACK_BLACKHOLE && attackType ~= WSN_Attack.ATTACK_GRAYHOLE
                return;
            end
            
            % Currently droppable forwarded types from sensors:
            % - Type 2: PANIC
            % - [Future types will be added here]
            droppableTypes = [2];  % Extend this array for future types
            
            if ~any(droppableTypes == msgType)
                return;  % Not a droppable type
            end
            
            intensity = data.intensity(nodeIdx);
            
            if attackType == WSN_Attack.ATTACK_BLACKHOLE
                if intensity <= 3
                    drop = true;
                elseif intensity <= 6
                    period = 2 + intensity;
                    drop = mod(t, period) == 0;
                else
                    drop = rand() < (0.5 - (intensity - 7) * 0.1);
                end
            else  % GRAYHOLE
                if intensity <= 3
                    drop = rand() < 0.7;
                elseif intensity <= 6
                    drop = rand() < 0.4;
                else
                    drop = rand() < 0.15;
                end
            end
            
            if drop
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
                WSN_Attack.setData(data);
                WSN_Attack.recordGroundTruth(t, nodeIdx, attackType, sprintf('DROP_FWD_T%d', msgType));
            end
        end
        
        function drop = shouldSensorDropPanic(nodeIdx, t)
            % Sensor blackhole: drop Type 2 PANIC messages (refuse to relay)
            drop = false;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx)
                return;
            end
            
            attackType = data.attackType(nodeIdx);
            if attackType ~= WSN_Attack.ATTACK_BLACKHOLE && attackType ~= WSN_Attack.ATTACK_GRAYHOLE
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            if attackType == WSN_Attack.ATTACK_BLACKHOLE
                % Same logic as regular blackhole
                if intensity <= 3
                    drop = true;
                elseif intensity <= 6
                    period = 2 + intensity;
                    drop = mod(t, period) == 0;
                else
                    drop = rand() < (0.5 - (intensity - 7) * 0.1);
                end
            else  % GRAYHOLE
                % Selective: maybe drop based on panic type
                if intensity <= 3
                    drop = rand() < 0.7;
                elseif intensity <= 6
                    drop = rand() < 0.4;
                else
                    drop = rand() < 0.15;
                end
            end
            
            if drop
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
                WSN_Attack.setData(data);
                WSN_Attack.recordGroundTruth(t, nodeIdx, attackType, 'DROP_PANIC');
            end
        end
        
        function suppress = shouldSensorSuppressReading(nodeIdx, t)
            % Sensor blackhole variant: suppress own sensor readings
            suppress = false;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_BLACKHOLE
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Intensity 1-3: Always suppress (no data sent)
            % Intensity 4-6: Sometimes suppress
            % Intensity 7-10: Rarely suppress (still sends most readings)
            if intensity <= 3
                suppress = true;
            elseif intensity <= 6
                suppress = rand() < (0.6 - (intensity - 4) * 0.15);
            else
                suppress = rand() < (0.2 - (intensity - 7) * 0.05);
            end
            
            if suppress
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_BLACKHOLE, 'SUPPRESS_READING');
            end
        end
        
        % =========================================================
        % CH-SPECIFIC ATTACK METHODS
        % CHs can: drop sensor aggregations, manipulate AGG_DATA
        % =========================================================
        function drop = shouldCHDropAggregation(nodeIdx, t, sensorSrcID)
            % CH grayhole: selectively drop aggregations from certain sensors
            drop = false;
            
            data = WSN_Attack.getData();
            if ~data.isMalicious(nodeIdx)
                return;
            end
            
            attackType = data.attackType(nodeIdx);
            if attackType ~= WSN_Attack.ATTACK_BLACKHOLE && attackType ~= WSN_Attack.ATTACK_GRAYHOLE
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            if attackType == WSN_Attack.ATTACK_BLACKHOLE
                % Drop everything
                if intensity <= 3
                    drop = true;
                elseif intensity <= 6
                    drop = mod(t, intensity) == 0;
                else
                    drop = rand() < (0.4 - (intensity - 7) * 0.08);
                end
            else  % GRAYHOLE - selective based on source
                % Could be selective based on sensorSrcID
                % For simplicity, use ID-based selection for "unfavored" sensors
                if intensity <= 3
                    drop = mod(sensorSrcID, 3) == 0;  % Drop 1/3 of sources
                elseif intensity <= 6
                    drop = mod(sensorSrcID, 5) == 0;  % Drop 1/5 of sources
                else
                    drop = mod(sensorSrcID, 10) == 0;  % Drop 1/10 of sources
                end
            end
            
            if drop
                data.packetsDropped(nodeIdx) = data.packetsDropped(nodeIdx) + 1;
                WSN_Attack.setData(data);
                WSN_Attack.recordGroundTruth(t, nodeIdx, attackType, 'DROP_AGG');
            end
        end
        
        % =========================================================
        % DENIAL OF SLEEP ATTACK LOGIC (Vampire)
        % Intensity 1 = Constantly wake ALL neighbors (obvious)
        % Intensity 10 = Occasionally wake few neighbors (stealthy)
        % REALISTIC: Cooldown between attacks, requires wake packets, energy tracking
        % =========================================================
        function [targets, wakeMsgs] = getDenialOfSleepTargets(nodeIdx, neighborTable, t)
            data = WSN_Attack.getData();
            targets = [];
            wakeMsgs = {};  % Array of actual wake messages to send
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_DENIAL_SLEEP
                return;
            end
            
            if isempty(neighborTable)
                return;
            end
            
            sensorNeighbors = neighborTable([neighborTable.tier] == 1);
            if isempty(sensorNeighbors)
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Check cooldown - can't spam wake packets instantly
            lastWakeTick = data.denialLastWakeTick(nodeIdx);
            minCooldown = max(1, 4 - floor(intensity / 3));  % 1-4 ticks based on intensity
            if (t - lastWakeTick) < minCooldown
                return;  % Still in cooldown
            end
            
            shouldAttack = false;
            
            % Intensity 1-3: Constantly target ALL sensors (obvious drain)
            % Intensity 4-6: Periodically target most sensors
            % Intensity 7-10: Rarely target few sensors (looks like normal traffic)
            if intensity <= 3
                shouldAttack = true;
                targets = [sensorNeighbors.id];
            elseif intensity <= 6
                period = intensity;  % period 4-6
                if mod(t, period) == 0
                    shouldAttack = true;
                    % Target 60-80% of sensors
                    numTargets = max(1, round(numel(sensorNeighbors) * (0.8 - (intensity - 4) * 0.1)));
                    idx = randperm(numel(sensorNeighbors), min(numTargets, numel(sensorNeighbors)));
                    targets = [sensorNeighbors(idx).id];
                end
            else
                % Stealthy: rare, few targets
                if rand() < (0.3 - (intensity - 7) * 0.06)  % 30% -> 12%
                    shouldAttack = true;
                    numTargets = randi([1, max(1, floor(numel(sensorNeighbors) * 0.3))]);
                    idx = randperm(numel(sensorNeighbors), min(numTargets, numel(sensorNeighbors)));
                    targets = [sensorNeighbors(idx).id];
                end
            end
            
            if shouldAttack && ~isempty(targets)
                % Generate actual wake messages for each target
                attackerID = nodeIdx;  % Would be actual node ID in real implementation
                for i = 1:numel(targets)
                    wakeMsg = WSN_Attack.createWakePacket(attackerID, targets(i), t);
                    wakeMsgs{end+1} = wakeMsg;
                end
                
                % Track energy cost (attacker spends energy too)
                energyPerWake = 0.05;  % Energy cost per wake packet
                data.energyDrained(nodeIdx) = data.energyDrained(nodeIdx) + numel(targets) * energyPerWake;
                data.denialLastWakeTick(nodeIdx) = t;
                data.denialWakeCount(nodeIdx) = data.denialWakeCount(nodeIdx) + numel(targets);
                WSN_Attack.setData(data);
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_DENIAL_SLEEP, ...
                    sprintf('VAMPIRE_%d_TARGETS', numel(targets)));
            end
        end
        
        function msg = createWakePacket(srcID, dstID, t)
            % Create realistic wake packet (requires actual transmission)
            msg = WSN_Message();
            msg.type = 255;  % Spurious/wake type
            msg.subtype = 1;  % Wake subtype
            msg.src = srcID;
            msg.dst = dstID;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            % Minimal payload but requires radio transmission
            msg.payload = uint8([mod(t, 256), randi([0, 255])]);
            msg.payloadLen = 2;
            msg.addChecksum();
            msg.color = WSN_Attack.COLOR_DENIAL_SLEEP;
        end
        
        function msg = createSpuriousPacket(srcID, dstID, t)
            msg = WSN_Message();
            msg.type = 255;
            msg.subtype = 0;
            msg.src = srcID;
            msg.dst = dstID;
            msg.ttl = 1;
            msg.seq = mod(t, 256);
            msg.payload = uint8(randi([0, 255], 1, 8));
            msg.payloadLen = 8;
            msg.addChecksum();
            msg.color = WSN_Attack.COLOR_DENIAL_SLEEP;
        end
        
        % =========================================================
        % WORMHOLE ATTACK LOGIC
        % Intensity 1 = Always tunnel (obvious shortcut)
        % Intensity 10 = Intermittent tunneling (harder to detect RTT anomalies)
        % REALISTIC: Bandwidth limiting, latency modeling, distance-based RSSI
        % =========================================================
        function [shouldRelay, otherEndpoint, latencyTicks] = shouldWormholeRelay(nodeIdx, t)
            data = WSN_Attack.getData();
            shouldRelay = false;
            otherEndpoint = [];
            latencyTicks = 0;
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_WORMHOLE
                return;
            end
            
            wormhole = data.wormholeEndpoints;
            if isempty(wormhole)
                return;
            end
            
            if wormhole(1) == nodeIdx
                otherEndpoint = wormhole(2);
            elseif wormhole(2) == nodeIdx
                otherEndpoint = wormhole(1);
            else
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Check bandwidth limit per tick
            bandwidthLimit = 5;  % Max packets through tunnel per tick
            if data.wormholeBandwidthUsed(nodeIdx) >= bandwidthLimit
                % Bandwidth exhausted this tick
                shouldRelay = false;
                return;
            end
            
            % Intensity 1-3: Always tunnel (100% - creates obvious RTT shortcuts)
            % Intensity 4-6: Frequently tunnel (60-80%)
            % Intensity 7-10: Intermittent tunnel (20-40% - harder to detect)
            if intensity <= 3
                shouldRelay = true;
            elseif intensity <= 6
                relayRate = 0.85 - (intensity - 4) * 0.08;  % 85% -> 69%
                shouldRelay = rand() < relayRate;
            else
                relayRate = 0.45 - (intensity - 7) * 0.07;  % 45% -> 24%
                shouldRelay = rand() < relayRate;
            end
            
            if shouldRelay
                % Model tunnel latency (realistic out-of-band transport)
                % Low intensity = fast (obvious), high intensity = variable (stealthier)
                if intensity <= 3
                    latencyTicks = 0;  % Instant - very suspicious
                elseif intensity <= 6
                    latencyTicks = randi([0, 1]);  % Small delay
                else
                    latencyTicks = randi([1, 3]);  % Variable delay, harder to detect
                end
                
                % Update bandwidth usage
                data.wormholeBandwidthUsed(nodeIdx) = data.wormholeBandwidthUsed(nodeIdx) + 1;
                WSN_Attack.setData(data);
                
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_WORMHOLE, ...
                    sprintf('TUNNEL_LAT%d', latencyTicks));
            end
        end
        
        function rssi = getWormholeRSSI(actualDistance, intensity)
            % REALISTIC: Calculate RSSI based on wormhole behavior
            % Low intensity: Perfect RSSI (suspicious)
            % High intensity: RSSI matches expected distance (stealthier)
            if nargin < 2
                intensity = 5;  % Default medium intensity
            end
            if nargin < 1
                actualDistance = 100;  % Default distance
            end
            
            if intensity <= 3
                % Obvious: Perfect signal regardless of distance
                rssi = 0.95;
            elseif intensity <= 6
                % Moderate: Slightly better than expected
                expectedRSSI = max(0.1, 1.0 - actualDistance / 500);
                rssi = min(1.0, expectedRSSI * 1.3);
            else
                % Stealthy: RSSI matches what would be expected for some plausible distance
                % Add some variance to simulate realistic conditions
                plausibleDistance = actualDistance * (0.3 + rand() * 0.4);  % 30-70% of actual
                rssi = max(0.1, 1.0 - plausibleDistance / 500);
                rssi = rssi + (rand() - 0.5) * 0.1;  % Add noise
                rssi = max(0.1, min(1.0, rssi));
            end
        end
        
        function resetWormholeBandwidth()
            % Call at start of each tick to reset bandwidth counter
            data = WSN_Attack.getData();
            if ~isempty(data)
                data.wormholeBandwidthUsed = zeros(size(data.wormholeBandwidthUsed));
                WSN_Attack.setData(data);
            end
        end
        
        % =========================================================
        % PANIC FLOOD ATTACK LOGIC
        % Intensity 1 = Constant panic floods (obvious false alarms)
        % Intensity 10 = Rare panic signals (hard to distinguish from real)
        % REALISTIC: Cooldown between panics, varied severity, rate limiting
        % =========================================================
        function [shouldFlood, panicSubtype] = shouldPanicFlood(nodeIdx, t)
            data = WSN_Attack.getData();
            shouldFlood = false;
            panicSubtype = 0;  % Default: generic alarm
            
            if ~data.isMalicious(nodeIdx) || data.attackType(nodeIdx) ~= WSN_Attack.ATTACK_PANIC_FLOOD
                return;
            end
            
            intensity = data.intensity(nodeIdx);
            
            % Check cooldown - realistic systems would notice repeated panics from same source
            lastPanicTick = data.panicLastTick(nodeIdx);
            % Minimum ticks between panics (more at high intensity to stay hidden)
            minCooldown = max(1, intensity - 2);  % 1 tick at intensity 1, 8 ticks at intensity 10
            if (t - lastPanicTick) < minCooldown && lastPanicTick > 0
                return;  % Still in cooldown
            end
            
            % Intensity determines base probability of panic this tick
            % Intensity 1-3: Very frequent panics (obvious spam)
            % Intensity 4-6: Periodic panics (every few ticks)
            % Intensity 7-10: Rare panics (occasional, looks like real emergency)
            if intensity <= 3
                shouldFlood = true;  % Every tick after cooldown - obvious spam
            elseif intensity <= 6
                period = 2 + intensity;  % period 6-8
                shouldFlood = mod(t, period) == 0;
            else
                % Rare: 15% -> 5% chance per eligible tick
                shouldFlood = rand() < (0.15 - (intensity - 7) * 0.03);
            end
            
            if shouldFlood
                % Vary panic type based on intensity
                % Low intensity: always uses same type (suspicious pattern)
                % High intensity: varies type (more realistic)
                if intensity <= 3
                    panicSubtype = 1;  % Always intrusion (pattern detectable)
                elseif intensity <= 6
                    panicSubtype = randi([1, 2]);  % Intrusion or fire
                else
                    panicSubtype = randi([1, 4]);  % Any type (intrusion, fire, medical, environmental)
                end
                
                % Update tracking
                data.panicLastTick(nodeIdx) = t;
                data.panicCooldown(nodeIdx) = minCooldown;
                WSN_Attack.setData(data);
                
                WSN_Attack.recordGroundTruth(t, nodeIdx, WSN_Attack.ATTACK_PANIC_FLOOD, ...
                    sprintf('PANIC_TYPE%d', panicSubtype));
            end
        end
        
        function msg = createFakePanicBeacon(nodeIdx, hexID, t, panicSubtype) %
            % REALISTIC: Create panic with specified or varied subtype
            % nodeIdx reserved for future ground truth logging per node
            if nargin < 4
                panicSubtype = 1;  % Default: intrusion
            end
            
            msg = WSN_Message();
            msg.type = WSN_Config.MSG_TYPE_PANIC;
            
            % Map subtype to config constant
            switch panicSubtype
                case 1
                    msg.subtype = WSN_Config.PANIC_SUB_INTRUSION;
                case 2
                    if isprop(WSN_Config, 'PANIC_SUB_FIRE')
                        msg.subtype = WSN_Config.PANIC_SUB_FIRE;
                    else
                        msg.subtype = 2;
                    end
                case 3
                    if isprop(WSN_Config, 'PANIC_SUB_MEDICAL')
                        msg.subtype = WSN_Config.PANIC_SUB_MEDICAL;
                    else
                        msg.subtype = 3;
                    end
                otherwise
                    msg.subtype = panicSubtype;
            end
            
            msg.src = hex2dec(hexID);
            msg.dst = 0;  % Broadcast
            msg.ttl = WSN_Config.PANIC_DEFAULT_TTL;
            msg.seq = mod(t, 256);
            msg.prio = 3;  % High priority
            
            % Create plausible payload based on panic type
            sensorValue = randi([80, 100]);  % High reading to seem urgent
            confidence = randi([85, 99]);    % High confidence
            payload = [uint8(panicSubtype), uint8(sensorValue), uint8(confidence)];
            msg.payload = payload;
            msg.payloadLen = numel(payload);
            msg.addChecksum();
            msg.color = WSN_Attack.COLOR_PANIC_FLOOD;
        end
        
        % =========================================================
        % UNIFIED DROP CHECK
        % =========================================================
        function drop = shouldDropPacket(nodeIdx, t, msgType)
            drop = false;
            
            if ~WSN_Attack.isMaliciousNode(nodeIdx)
                return;
            end
            
            attackType = WSN_Attack.getAttackType(nodeIdx);
            isDataPacket = (msgType == WSN_Config.MSG_TYPE_SENSOR) || ...
                           (msgType == WSN_Config.MSG_TYPE_CH_HELLO);
            
            if ~isDataPacket
                return;
            end
            
            switch attackType
                case WSN_Attack.ATTACK_BLACKHOLE
                    drop = WSN_Attack.shouldDropBlackhole(nodeIdx, t);
                case WSN_Attack.ATTACK_GRAYHOLE
                    drop = WSN_Attack.shouldDropGrayhole(nodeIdx, t);
            end
        end
        
        % =========================================================
        % GROUND TRUTH (for IDS evaluation - not logged to node)
        % =========================================================
        function recordGroundTruth(t, nodeIdx, attackType, action)
            data = WSN_Attack.getData();
            
            entry = struct('time', t, 'nodeIdx', nodeIdx, ...
                          'attackType', attackType, 'action', action);
            data.groundTruth = [data.groundTruth, entry];
            
            if data.attackStartTime(nodeIdx) == 0
                data.attackStartTime(nodeIdx) = t;
            end
            
            WSN_Attack.setData(data);
        end
        
        function gt = getGroundTruth()
            data = WSN_Attack.getData();
            if ~isempty(data)
                gt = data.groundTruth;
            else
                gt = [];
            end
        end
        
        % =========================================================
        % METRICS & SUMMARY
        % =========================================================
        function metrics = getAttackMetrics(nodeIdx)
            data = WSN_Attack.getData();
            metrics = struct();
            
            if isempty(data) || nodeIdx > numel(data.isMalicious)
                metrics.isMalicious = false;
                return;
            end
            
            metrics.isMalicious = data.isMalicious(nodeIdx);
            metrics.attackType = data.attackType(nodeIdx);
            metrics.intensity = data.intensity(nodeIdx);
            metrics.packetsDropped = data.packetsDropped(nodeIdx);
            metrics.packetsFlooded = data.packetsFlooded(nodeIdx);
            metrics.energyDrained = data.energyDrained(nodeIdx);
            metrics.attackStartTime = data.attackStartTime(nodeIdx);
        end
        
        function summary = getAttackSummary()
            data = WSN_Attack.getData();
            summary = struct();
            
            if isempty(data)
                summary.numMalicious = 0;
                return;
            end
            
            summary.numMalicious = sum(data.isMalicious);
            summary.maliciousNodes = find(data.isMalicious);
            summary.attackTypes = data.attackType(data.isMalicious);
            summary.intensities = data.intensity(data.isMalicious);
            summary.wormholeEndpoints = data.wormholeEndpoints;
            summary.groundTruthEntries = numel(data.groundTruth);
            summary.totalDropped = sum(data.packetsDropped);
            summary.totalFlooded = sum(data.packetsFlooded);
        end
        
        function exportGroundTruth(filename)
            gt = WSN_Attack.getGroundTruth();
            if isempty(gt)
                return;
            end
            
            fid = fopen(filename, 'w');
            fprintf(fid, 'Time,NodeIdx,AttackType,Action\n');
            for i = 1:numel(gt)
                fprintf(fid, '%d,%d,%d,%s\n', gt(i).time, gt(i).nodeIdx, ...
                        gt(i).attackType, gt(i).action);
            end
            fclose(fid);
        end
        
        % =========================================================
        % REALISTIC FEATURES
        % =========================================================
        function energyCost = getAttackEnergyCost(nodeIdx)
            data = WSN_Attack.getData();
            energyCost = 0;
            
            if ~data.isMalicious(nodeIdx)
                return;
            end
            
            attackType = data.attackType(nodeIdx);
            intensity = data.intensity(nodeIdx);
            
            switch attackType
                case WSN_Attack.ATTACK_FLOODING
                    energyCost = 0.1 * intensity;
                case WSN_Attack.ATTACK_DENIAL_SLEEP
                    energyCost = 0.05 * intensity;
                case WSN_Attack.ATTACK_PANIC_FLOOD
                    energyCost = 0.08 * intensity;
                case WSN_Attack.ATTACK_WORMHOLE
                    energyCost = 0.02 * intensity;
                case WSN_Attack.ATTACK_SYBIL
                    energyCost = 0.03 * intensity;
            end
        end
        
        function anomaly = getNetworkAnomalyIndicators(t)
            data = WSN_Attack.getData();
            anomaly = struct();
            
            if isempty(data)
                anomaly.active = false;
                return;
            end
            
            anomaly.active = any(data.isMalicious);
            anomaly.time = t;
            anomaly.dropRate = sum(data.packetsDropped) / max(1, t);
            anomaly.floodRate = sum(data.packetsFlooded) / max(1, t);
            anomaly.vampireEnergy = sum(data.energyDrained);
            anomaly.activeBlackholes = sum(data.attackType == WSN_Attack.ATTACK_BLACKHOLE & data.isMalicious);
            anomaly.activeGrayholes = sum(data.attackType == WSN_Attack.ATTACK_GRAYHOLE & data.isMalicious);
            anomaly.activeFlooders = sum(data.attackType == WSN_Attack.ATTACK_FLOODING & data.isMalicious);
        end
        
        % =========================================================
        % HEADLESS MODE - Interactive Terminal Attack Seeding
        % =========================================================
        function config = headless(nodes)
            % Interactive headless attack configuration via terminal prompts
            %
            % Usage:
            %   config = WSN_Attack.headless(nodes);
            %
            % Prompts user for:
            %   1. Number of attacking nodes (or random)
            %   2. Tier filter (Sensor/CH/GWN/Any)
            %   3. Attack type(s) from menu
            %   4. Intensity (1-10) or random
            %   5. Activation time(s) or random
            %   6. Headless simulation duration
            %
            % Returns:
            %   config - Struct with all settings for WSN_Main to use
            
            fprintf('\n');
            fprintf('=======================================================\n');
            fprintf('       WSN_Attack HEADLESS MODE CONFIGURATION\n');
            fprintf('=======================================================\n\n');
            
            config = struct();
            config.timestamp = now;
            config.attacks = {};
            
            numNodes = numel(nodes);
            
            % === BUILD TIER-SPECIFIC CANDIDATE LISTS ===
            sensors = []; chs = []; gwns = [];
            for k = 1:numNodes
                if isa(nodes(k), 'WSN_Sink')
                    continue;  % Never attack Sink
                elseif isa(nodes(k), 'WSN_Gateway')
                    gwns(end+1) = k; %
                elseif isa(nodes(k), 'WSN_ClusterHead')
                    chs(end+1) = k; %
                elseif isa(nodes(k), 'WSN_Sensor')
                    sensors(end+1) = k; %
                end
            end
            allCandidates = [sensors, chs, gwns];
            
            fprintf('Network has: %d Sensors, %d CHs, %d GWNs (Sink excluded)\n\n', ...
                numel(sensors), numel(chs), numel(gwns));
            
            % === 1. NUMBER OF ATTACKING NODES ===
            fprintf('--- Number of Attacking Nodes ---\n');
            fprintf('Enter count (1-%d) or press ENTER for random: ', numel(allCandidates));
            numStr = input('', 's');
            if isempty(strtrim(numStr))
                numAttacks = randi([1, min(3, numel(allCandidates))]);
                fprintf('  -> Random: %d nodes\n', numAttacks);
            else
                numAttacks = str2double(numStr);
                if isnan(numAttacks) || numAttacks < 1
                    numAttacks = 1;
                end
                numAttacks = min(numAttacks, numel(allCandidates));
                fprintf('  -> Selected: %d nodes\n', numAttacks);
            end
            
            % === 2. TIER SELECTION ===
            fprintf('\n--- Target Tier ---\n');
            fprintf('  1. Sensors only (00xx)\n');
            fprintf('  2. Cluster Heads only (AAxx)\n');
            fprintf('  3. Gateways only (FFxx)\n');
            fprintf('Enter tier(s) as comma-separated values:\n');
            fprintf('  Single value (e.g., 1): All nodes from that tier\n');
            fprintf('  Multiple values (e.g., 1,2): Random mix from those tiers\n');
            fprintf('  Exact count (e.g., 1,1,1,2,2): Per-node tier assignment\n');
            fprintf('or ENTER for random tier selection: ');
            tierStr = input('', 's');
            
            % Parse tier input into per-node assignments
            tierPools = {sensors, chs, gwns};  % tier 1=sensors, 2=CHs, 3=GWNs
            tierNames = {'Sensor', 'CH', 'GWN'};
            
            if isempty(strtrim(tierStr))
                % Random: pick from any tier  for each node
                tierAssignments = randi([1, 3], 1, numAttacks);
                fprintf('  -> Random tier assignment\n');
            else
                tierVals = str2num(tierStr); %#ok<ST2NM>
                tierVals = max(1, min(3, tierVals));  % Clamp to 1-3
                if isempty(tierVals)
                    tierAssignments = randi([1, 3], 1, numAttacks);
                elseif numel(tierVals) == 1
                    % Single value: all nodes from that tier
                    tierAssignments = repmat(tierVals, 1, numAttacks);
                    fprintf('  -> All from tier %d (%s)\n', tierVals, tierNames{tierVals});
                elseif numel(tierVals) == numAttacks
                    % Exact count: direct per-node assignment
                    tierAssignments = tierVals;
                    fprintf('  -> Per-node tiers: [%s]\n', num2str(tierAssignments));
                else
                    % Fewer values than nodes: random pick from provided tiers
                    tierAssignments = tierVals(randi(numel(tierVals), 1, numAttacks));
                    fprintf('  -> Mix from tiers [%s]: assigned [%s]\n', ...
                        num2str(unique(tierVals)), num2str(tierAssignments));
                end
            end
            
            % Build per-node candidate pools and assign attackers
            usedIndices = [];
            selectedNodes = [];
            for k = 1:numAttacks
                tier = tierAssignments(k);
                pool = tierPools{tier};
                % Remove already-used indices from this pool
                availablePool = setdiff(pool, usedIndices);
                if isempty(availablePool)
                    % Fallback: try any remaining node
                    availablePool = setdiff(allCandidates, usedIndices);
                end
                if isempty(availablePool)
                    fprintf('WARNING: Not enough unique nodes, truncating.\n');
                    break;
                end
                chosen = availablePool(randi(numel(availablePool)));
                selectedNodes(end+1) = chosen; %#ok<AGROW>
                usedIndices(end+1) = chosen; %#ok<AGROW>
            end
            numAttacks = numel(selectedNodes);  % May be reduced if pool exhausted
            
            % === 3. ATTACK TYPE ===
            fprintf('\n--- Attack Type Menu ---\n');
            fprintf('  0. NONE (clear attack)\n');
            fprintf('  1. BLACKHOLE    - Drop all forwarded packets\n');
            fprintf('  2. GRAYHOLE     - Selectively drop packets\n');
            fprintf('  3. SYBIL        - Multiple fake identities (00xx/AAxx/FFxx)\n');
            fprintf('  4. FLOODING     - Broadcast storm\n');
            fprintf('  5. WORMHOLE     - False tunnel between two nodes\n');
            fprintf('  6. VAMPIRE      - Drain neighbor batteries\n');
            fprintf('  7. SCHEDULING   - Disrupt TDMA timing\n');
            fprintf('  8. DENIAL_SLEEP - Keep nodes awake\n');
            fprintf('  9. PANIC_FLOOD  - Fake emergency broadcasts\n');
            fprintf('\nEnter attack type(s) as comma-separated (e.g., 1,2,3)\n');
            fprintf('or ENTER for random: ');
            attackStr = input('', 's');
            
            if isempty(strtrim(attackStr))
                % Random attack types (exclude NONE and WORMHOLE for simplicity)
                defaultTypes = [1, 2, 3, 4, 6, 7, 8, 9];
                attackTypes = defaultTypes(randi(numel(defaultTypes), 1, numAttacks));
                fprintf('  -> Random attacks assigned\n');
            else
                attackTypes = str2num(attackStr); %#ok<ST2NM>
                if isempty(attackTypes)
                    attackTypes = [1];  % Default to BLACKHOLE
                end
                if numel(attackTypes) == 1
                    % Single value: all nodes get same attack type
                    attackTypes = repmat(attackTypes, 1, numAttacks);
                elseif numel(attackTypes) == numAttacks
                    % Exact count: direct per-node assignment
                    % Keep as-is
                elseif numel(attackTypes) < numAttacks
                    % Random pick from provided values
                    attackTypes = attackTypes(randi(numel(attackTypes), 1, numAttacks));
                else
                    % More values than nodes: truncate
                    attackTypes = attackTypes(1:numAttacks);
                end
                fprintf('  -> Attack types: [%s]\n', num2str(attackTypes));
            end
            
            % === 4. INTENSITY ===
            fprintf('\n--- Intensity (1-10) ---\n');
            fprintf('  Low (1-3): Aggressive, obvious attacks\n');
            fprintf('  Mid (4-6): Balanced\n');
            fprintf('  High (7-10): Stealthy, harder to detect\n');
            fprintf('Enter intensity or range (e.g., 5 or 3,7) or ENTER for random: ');
            intensityStr = input('', 's');
            
            if isempty(strtrim(intensityStr))
                intensities = randi([3, 7], 1, numAttacks);
                fprintf('  -> Random intensities: [%s]\n', num2str(intensities));
            else
                intensityVals = str2num(intensityStr); %#ok<ST2NM>
                intensityVals = max(1, min(10, intensityVals));  % Clamp to 1-10
                if isempty(intensityVals)
                    intensities = 5 * ones(1, numAttacks);
                elseif numel(intensityVals) == 1
                    % Single value: all nodes get same intensity
                    intensities = repmat(intensityVals, 1, numAttacks);
                elseif numel(intensityVals) == numAttacks
                    % Exact count: direct per-node assignment
                    intensities = intensityVals;
                elseif numel(intensityVals) == 2 && numAttacks > 2
                    % Treat as range [min, max] only when numAttacks > 2
                    intensities = randi([intensityVals(1), intensityVals(2)], 1, numAttacks);
                else
                    % Random pick from provided values
                    intensities = intensityVals(randi(numel(intensityVals), 1, numAttacks));
                end
                fprintf('  -> Intensities: [%s]\n', num2str(intensities));
            end
            
            % === 5. ACTIVATION TIMES ===
            fprintf('\n--- Activation Time (tick) ---\n');
            fprintf('When should attacks become active?\n');
            fprintf('  TIP: Times > headless duration will activate in GUI mode\n');
            fprintf('       (attacks load as "pending" until activation tick)\n');
            fprintf('Enter time(s) (e.g., 0 or 0,100,200) or ENTER for immediate: ');
            timeStr = input('', 's');
            
            if isempty(strtrim(timeStr))
                startTimes = zeros(1, numAttacks);
                fprintf('  -> All immediate (t=0)\n');
            else
                timeVals = str2num(timeStr); %#ok<ST2NM>
                timeVals = max(0, timeVals);  % Clamp to non-negative
                if isempty(timeVals)
                    startTimes = zeros(1, numAttacks);
                elseif numel(timeVals) == 1
                    % Single value: all nodes get same time
                    startTimes = repmat(timeVals, 1, numAttacks);
                elseif numel(timeVals) == numAttacks
                    % Exact count: direct per-node assignment
                    startTimes = timeVals;
                else
                    % Random pick from provided values
                    startTimes = timeVals(randi(numel(timeVals), 1, numAttacks));
                end
                fprintf('  -> Start times: [%s]\n', num2str(startTimes));
            end
            
            % === 6. HEADLESS DURATION ===
            fprintf('\n--- Headless Simulation Duration ---\n');
            fprintf('Enter number of ticks to run (e.g., 2000): ');
            durStr = input('', 's');
            if isempty(strtrim(durStr))
                config.duration = 2000;
            else
                config.duration = str2double(durStr);
                if isnan(config.duration) || config.duration < 1
                    config.duration = 2000;
                end
            end
            fprintf('  -> Duration: %d ticks\n', config.duration);
            
            % === SELECT NODES & APPLY ATTACKS ===
            fprintf('\n--- Applying Attacks ---\n');
            % selectedNodes already built in tier selection section
            
            typeNames = {'NONE','BLACKHOLE','GRAYHOLE','SYBIL','FLOODING', ...
                         'WORMHOLE','VAMPIRE','SCHEDULING','DENIAL_SLEEP','PANIC_FLOOD'};
            
            for i = 1:numAttacks
                idx = selectedNodes(i);
                aType = attackTypes(i);
                intensity = intensities(i);
                startT = startTimes(i);
                
                % Special handling for wormhole
                if aType == WSN_Attack.ATTACK_WORMHOLE
                    % Need a pair - find another node not already selected
                    otherCandidates = setdiff(allCandidates, selectedNodes);
                    if ~isempty(otherCandidates)
                        otherIdx = otherCandidates(randi(numel(otherCandidates)));
                        WSN_Attack.setWormholeEndpoints(idx, otherIdx, intensity, nodes);
                        config.attacks{end+1} = struct('nodeIdx', idx, 'nodeIdx2', otherIdx, ...
                            'type', aType, 'intensity', intensity, 'startTime', startT, ...
                            'hexID', nodes(idx).hexID, 'hexID2', nodes(otherIdx).hexID);
                        fprintf('  [%d] %s <-> %s : WORMHOLE, intensity=%d, t=%d\n', ...
                            i, nodes(idx).hexID, nodes(otherIdx).hexID, intensity, startT);
                    else
                        fprintf('  [%d] WORMHOLE skipped - no pair available\n', i);
                    end
                else
                    WSN_Attack.setMalicious(idx, aType, intensity, nodes);
                    
                    % Store start time
                    data = WSN_Attack.getData();
                    data.attackStartTime(idx) = startT;
                    WSN_Attack.setData(data);
                    
                    tName = 'UNKNOWN';
                    if aType >= 0 && aType <= 9
                        tName = typeNames{aType + 1};
                    end
                    
                    config.attacks{end+1} = struct('nodeIdx', idx, ...
                        'type', aType, 'intensity', intensity, 'startTime', startT, ...
                        'hexID', nodes(idx).hexID);
                    fprintf('  [%d] %s : %s, intensity=%d, t=%d\n', ...
                        i, nodes(idx).hexID, tName, intensity, startT);
                end
            end
            
            % === SUMMARY ===
            fprintf('\n=======================================================\n');
            fprintf('  CONFIGURATION COMPLETE\n');
            fprintf('  %d attacks configured, running for %d ticks\n', ...
                numel(config.attacks), config.duration);
            fprintf('=======================================================\n\n');
            
            % Store for WSN_Main to use
            config.numAttacks = numel(config.attacks);
            % Build tier filter string from assignments
            uniqueTiers = unique(tierAssignments);
            tierFilterParts = arrayfun(@(t) tierNames{t}, uniqueTiers, 'UniformOutput', false);
            config.tierFilter = strjoin(tierFilterParts, '/');
        end
        
        % =========================================================
        % RUN - One-command headless attack simulation
        % =========================================================
        function run()
            % Single command to configure and run attack simulation
            %
            % Usage (in MATLAB command window):
            %   WSN_Attack.run()
            %
            % This will:
            %   1. Generate topology automatically
            %   2. Initialize attack system
            %   3. Prompt for attack configuration (interactive)
            %   4. Run simulation headless, then show GUI
            %
            % No arguments needed - everything is prompted interactively.
            
            fprintf('\n');
            fprintf('=======================================================\n');
            fprintf('       WSN_Attack.run() - HEADLESS MODE\n');
            fprintf('=======================================================\n\n');
            
            % === 1. GENERATE TOPOLOGY ===
            nodeCount = WSN_Config.NodeCount;
            fieldSize = WSN_Config.FieldSize;
            fprintf('Generating topology: %d nodes in [%d x %d] field...\n', ...
                nodeCount, fieldSize(1), fieldSize(2));
            nodes = WSN_TopologyGenerator.generateTopology(nodeCount, fieldSize);
            fprintf('  -> %d nodes created\n\n', numel(nodes));
            
            % === 2. INITIALIZE ATTACK SYSTEM ===
            WSN_Attack.init(numel(nodes));
            
            % === 3. INTERACTIVE CONFIGURATION ===
            config = WSN_Attack.headless(nodes);
            
            % === 4. RUN SIMULATION ===
            fprintf('Starting simulation...\n');
            fprintf('  Headless for %d ticks, then GUI will appear.\n\n', config.duration);
            
            % Run WSN_Main with headless duration and pre-created nodes
            % WSN_Main(headlessSteps, printInterval, nodes)
            WSN_Main(config.duration, 1, nodes);
        end
    end
end
