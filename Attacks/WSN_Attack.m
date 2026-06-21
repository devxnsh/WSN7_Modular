classdef WSN_Attack < handle
    % =========================================================
    % WSN ATTACK MODULE â€” Central Attack Configuration & Logic
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
        % DECOUPLED ATTACK CONFIGURATION (launcher / WSN_Main entry point)
        % =========================================================
        function cfg = defaultConfig()
            % Default attack config: attacks OFF. ActivateAttacks is the only
            % required-effective field; every other field is optional and,
            % when ActivateAttacks=true and left empty, is filled in with a
            % randomized-but-constrained value by WSN_Attack.configure().
            cfg = struct( ...
                'ActivateAttacks', false, ...  % false = guaranteed zero attackers
                'NumAttackers',    [], ...     % [] = random, ~5-15% of eligible nodes (min 1)
                'AttackTypes',     [], ...     % [] = random from all 7 real attack types
                'IntensityRange',  [], ...     % [] = [1 10] (full range)
                'Tiers',           [], ...     % [] = {'Sensor','CH','GWN'} (Sink never eligible)
                'StartTimeRange',  [], ...     % [] = [0 300] (staggered random activation)
                'Seed',            [] ...      % [] = non-reproducible (rng left as-is)
            );
        end

        function attackCfg = configure(numNodes, nodes, attackCfg)
            % Single decoupled entry point for attack initialization, used by
            % both GUI and headless WSN_Main runs (and the root launcher).
            %
            %   WSN_Attack.configure(numNodes, nodes, struct('ActivateAttacks', false))
            %       -> resets to a clean baseline; NO node ever becomes malicious.
            %   WSN_Attack.configure(numNodes, nodes, struct('ActivateAttacks', true))
            %       -> resets, then assigns randomized-but-constrained attacker(s).
            %   WSN_Attack.configure(numNodes, nodes, struct('ActivateAttacks', true, 'NumAttackers', 2, ...))
            %       -> any field left out/empty is still randomized within bounds.
            if nargin < 3 || isempty(attackCfg)
                attackCfg = struct('ActivateAttacks', false);
            end
            defaults = WSN_Attack.defaultConfig();
            fn = fieldnames(defaults);
            for i = 1:numel(fn)
                if ~isfield(attackCfg, fn{i}) || isempty(attackCfg.(fn{i}))
                    attackCfg.(fn{i}) = defaults.(fn{i});
                end
            end

            % Always start from a clean slate so re-configuring (e.g. GUI restart)
            % never leaks stale attacker state from a previous run.
            WSN_Attack.init(numNodes);

            if ~islogical(attackCfg.ActivateAttacks)
                attackCfg.ActivateAttacks = logical(attackCfg.ActivateAttacks);
            end

            if ~attackCfg.ActivateAttacks
                % HARD GUARANTEE: no other field can override this. No node
                % becomes an attacker for the entire simulation run.
                return;
            end

            if ~isempty(attackCfg.Seed)
                rng(attackCfg.Seed);
            end

            % --- Build tier-eligible candidate pools (Sink is NEVER eligible) ---
            sensors = []; chs = []; gwns = [];
            for k = 1:numNodes
                if isa(nodes(k), 'WSN_Sink')
                    continue;
                elseif isa(nodes(k), 'WSN_Gateway')
                    gwns(end+1) = k; %#ok<AGROW>
                elseif isa(nodes(k), 'WSN_ClusterHead')
                    chs(end+1) = k; %#ok<AGROW>
                elseif isa(nodes(k), 'WSN_Sensor')
                    sensors(end+1) = k; %#ok<AGROW>
                end
            end
            tierPools = struct('Sensor', sensors, 'CH', chs, 'GWN', gwns);
            allCandidates = [sensors, chs, gwns];
            if isempty(allCandidates)
                return;
            end

            % --- NumAttackers: random, constrained to ~10% of nodes (min 1).
            % Note: a Wormhole pick consumes 2 candidate nodes (both tunnel
            % endpoints become malicious), so the realized malicious-node
            % count can run slightly above this loop bound. ---
            if isempty(attackCfg.NumAttackers)
                maxAttackers = max(1, round(0.10 * numel(allCandidates)));
                numAttackers = randi([1, maxAttackers]);
            else
                numAttackers = max(1, min(round(attackCfg.NumAttackers), numel(allCandidates)));
            end

            % --- AttackTypes: random from all 7 real attack types (excludes NONE) ---
            if isempty(attackCfg.AttackTypes)
                attackTypePool = [WSN_Attack.ATTACK_FLOODING, WSN_Attack.ATTACK_PANIC_FLOOD, ...
                                   WSN_Attack.ATTACK_SYBIL, WSN_Attack.ATTACK_BLACKHOLE, ...
                                   WSN_Attack.ATTACK_WORMHOLE, WSN_Attack.ATTACK_GRAYHOLE, ...
                                   WSN_Attack.ATTACK_DENIAL_SLEEP];
            else
                attackTypePool = attackCfg.AttackTypes;
            end

            % --- IntensityRange: clamp to valid [1,10] scale ---
            if isempty(attackCfg.IntensityRange)
                intensityRange = [1, 10];
            else
                intensityRange = [max(1, min(attackCfg.IntensityRange)), min(10, max(attackCfg.IntensityRange))];
            end

            % --- Tiers: which tiers are eligible to be picked as attackers ---
            if isempty(attackCfg.Tiers)
                tierChoices = {'Sensor', 'CH', 'GWN'};
            else
                tierChoices = attackCfg.Tiers;
                if ischar(tierChoices)
                    tierChoices = {tierChoices};
                end
            end
            tierChoices = tierChoices(isfield(tierPools, tierChoices));
            if isempty(tierChoices)
                tierChoices = {'Sensor', 'CH', 'GWN'};
            end

            % --- StartTimeRange: stagger activation so attacks don't all begin at t=0 ---
            if isempty(attackCfg.StartTimeRange)
                startTimeRange = [0, 300];
            else
                startTimeRange = [max(0, min(attackCfg.StartTimeRange)), max(attackCfg.StartTimeRange)];
            end

            usedIndices = [];
            for i = 1:numAttackers
                tierName = tierChoices{randi(numel(tierChoices))};
                pool = setdiff(tierPools.(tierName), usedIndices);
                if isempty(pool)
                    pool = setdiff(allCandidates, usedIndices);
                end
                if isempty(pool)
                    break;
                end
                idx = pool(randi(numel(pool)));
                usedIndices(end+1) = idx; %#ok<AGROW>

                aType = attackTypePool(randi(numel(attackTypePool)));
                intensity = randi(intensityRange);
                startT = randi([round(startTimeRange(1)), max(round(startTimeRange(1)), round(startTimeRange(2)))]);

                if aType == WSN_Attack.ATTACK_WORMHOLE
                    otherPool = setdiff(allCandidates, usedIndices);
                    if isempty(otherPool)
                        continue; % no eligible pair this round - skip rather than break
                    end
                    idx2 = otherPool(randi(numel(otherPool)));
                    usedIndices(end+1) = idx2; %#ok<AGROW>
                    WSN_Attack.setWormholeEndpoints(idx, idx2, intensity, nodes);
                else
                    WSN_Attack.setMalicious(idx, aType, intensity, nodes, startT);
                end
            end
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
        
        % =========================================================
        % SYBIL ATTACK MODULE (visual/HELLO helpers) - see Attacks/WSN_Attack_Sybil.m
        % =========================================================
        function [sybilNodes, sybilIDs] = getSybilVisuals(varargin)
            [sybilNodes, sybilIDs] = WSN_Attack_Sybil.getSybilVisuals(varargin{:});
        end

        function msgs = getSybilHelloMessages(varargin)
            msgs = WSN_Attack_Sybil.getSybilHelloMessages(varargin{:});
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
        
        % WORMHOLE ATTACK MODULE - see Attacks/WSN_Attack_Wormhole.m
        function setWormholeEndpoints(varargin)
            WSN_Attack_Wormhole.setWormholeEndpoints(varargin{:});
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
        % BLACKHOLE ATTACK MODULE - see Attacks/WSN_Attack_Blackhole.m
        % =========================================================
        function drop = shouldDropBlackhole(varargin)
            drop = WSN_Attack_Blackhole.shouldDropBlackhole(varargin{:});
        end

        function [dropAccess, dropBackbone] = shouldDropBlackholeGWN(varargin)
            [dropAccess, dropBackbone] = WSN_Attack_Blackhole.shouldDropBlackholeGWN(varargin{:});
        end

        % =========================================================
        % GRAYHOLE ATTACK MODULE - see Attacks/WSN_Attack_Grayhole.m
        % =========================================================
        function drop = shouldDropGrayhole(varargin)
            drop = WSN_Attack_Grayhole.shouldDropGrayhole(varargin{:});
        end

        function [dropAccess, dropBackbone] = shouldDropGrayholeGWN(varargin)
            [dropAccess, dropBackbone] = WSN_Attack_Grayhole.shouldDropGrayholeGWN(varargin{:});
        end

        % =========================================================
        % FLOODING ATTACK MODULE - see Attacks/WSN_Attack_Flooding.m
        % =========================================================
        function [count, collisionLoss] = getFloodingBurstCount(varargin)
            [count, collisionLoss] = WSN_Attack_Flooding.getFloodingBurstCount(varargin{:});
        end

        function [countAccess, countBackbone, collisionLoss] = getFloodingBurstCountGWN(varargin)
            [countAccess, countBackbone, collisionLoss] = WSN_Attack_Flooding.getFloodingBurstCountGWN(varargin{:});
        end

        function txPower = getFloodingTxPower(varargin)
            txPower = WSN_Attack_Flooding.getFloodingTxPower(varargin{:});
        end

        % =========================================================
        % SYBIL ATTACK MODULE (identity logic) - see Attacks/WSN_Attack_Sybil.m
        % =========================================================
        function [isSybil, fakeIDs] = getSybilIdentities(varargin)
            [isSybil, fakeIDs] = WSN_Attack_Sybil.getSybilIdentities(varargin{:});
        end

        function [isSybil, fakeIDs, fakeTiers] = getActiveSybilIdentities(varargin)
            [isSybil, fakeIDs, fakeTiers] = WSN_Attack_Sybil.getActiveSybilIdentities(varargin{:});
        end

        function fakeID = getRandomSybilID(varargin)
            fakeID = WSN_Attack_Sybil.getRandomSybilID(varargin{:});
        end

        function [fakeID, fakeTier] = getSybilIdentityWithTier(varargin)
            [fakeID, fakeTier] = WSN_Attack_Sybil.getSybilIdentityWithTier(varargin{:});
        end

        function numIDs = getSybilIdentityCount(varargin)
            numIDs = WSN_Attack_Sybil.getSybilIdentityCount(varargin{:});
        end

        function shouldAdvertise = shouldSybilAdvertiseHello(varargin)
            shouldAdvertise = WSN_Attack_Sybil.shouldSybilAdvertiseHello(varargin{:});
        end

        function [intercept, fakeIDs] = shouldSybilInterceptPacket(varargin)
            [intercept, fakeIDs] = WSN_Attack_Sybil.shouldSybilInterceptPacket(varargin{:});
        end

        function drop = shouldSybilDropIntercepted(varargin)
            drop = WSN_Attack_Sybil.shouldSybilDropIntercepted(varargin{:});
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
        % DENIAL OF SLEEP ATTACK MODULE - see Attacks/WSN_Attack_DenialOfSleep.m
        % =========================================================
        function [targets, wakeMsgs] = getDenialOfSleepTargets(varargin)
            [targets, wakeMsgs] = WSN_Attack_DenialOfSleep.getDenialOfSleepTargets(varargin{:});
        end

        function msg = createWakePacket(varargin)
            msg = WSN_Attack_DenialOfSleep.createWakePacket(varargin{:});
        end

        function msg = createSpuriousPacket(varargin)
            msg = WSN_Attack_DenialOfSleep.createSpuriousPacket(varargin{:});
        end

        % =========================================================
        % WORMHOLE ATTACK MODULE - see Attacks/WSN_Attack_Wormhole.m
        % =========================================================
        function [shouldRelay, otherEndpoint, latencyTicks] = shouldWormholeRelay(varargin)
            [shouldRelay, otherEndpoint, latencyTicks] = WSN_Attack_Wormhole.shouldWormholeRelay(varargin{:});
        end

        function rssi = getWormholeRSSI(varargin)
            rssi = WSN_Attack_Wormhole.getWormholeRSSI(varargin{:});
        end

        function resetWormholeBandwidth(varargin)
            WSN_Attack_Wormhole.resetWormholeBandwidth(varargin{:});
        end

        % =========================================================
        % PANIC FLOOD ATTACK MODULE - see Attacks/WSN_Attack_PanicFlood.m
        % =========================================================
        function [shouldFlood, panicSubtype] = shouldPanicFlood(varargin)
            [shouldFlood, panicSubtype] = WSN_Attack_PanicFlood.shouldPanicFlood(varargin{:});
        end

        function msg = createFakePanicBeacon(varargin)
            msg = WSN_Attack_PanicFlood.createFakePanicBeacon(varargin{:});
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
