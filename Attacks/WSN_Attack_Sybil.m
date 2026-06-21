classdef WSN_Attack_Sybil
    % =========================================================
    % SYBIL ATTACK MODULE
    % =========================================================
    % Extracted verbatim from WSN_Attack.m: visual/HELLO-injection
    % helpers (originally in the VISUAL TRACKING HELPERS section,
    % interleaved with generic ghost-link/DoS-target tracking which
    % stayed in WSN_Attack.m core) plus the SYBIL ATTACK LOGIC and
    % SYBIL ATTACK - SENSOR NODE BEHAVIOR sections. Stateless - all
    % state lives in WSN_Attack's persistent pDataStore, accessed via
    % WSN_Attack.getData()/setData()/recordGroundTruth() exactly as
    % before the split. WSN_Attack.m keeps thin one-line wrappers so
    % every existing call site is unaffected.
    % =========================================================
    methods (Static)
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
        
    end
end

