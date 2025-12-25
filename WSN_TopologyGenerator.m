classdef WSN_TopologyGenerator
    methods (Static)

        % =====================================================
        % GUI HULL (UNCHANGED)
        % =====================================================
        function hullCoords = getGWNHull(nodes)
            gwnPos = [];
            for i = 1:numel(nodes)
                if isprop(nodes(i),'tier') && nodes(i).tier == WSN_Config.TIER_GWN
                    gwnPos(end+1,:) = nodes(i).pos; %#ok<AGROW>
                end
            end

            if size(gwnPos,1) < 3
                hullCoords = [];
                return;
            end

            try
                k = convhull(gwnPos(:,1), gwnPos(:,2));
                hullCoords = gwnPos(k,:);
            catch
                hullCoords = [];
            end
        end

        % =====================================================
        % TOPOLOGY GENERATION (STRUCT LEVEL)
        % =====================================================
        function [nodes, posArray] = getStructTopology(N, field)

            template = struct( ...
                'id',0,'hexID','', ...
                'pos',[0 0],'tier',0,'type','', ...
                'isSink',false,'offset',0);

            ctr = WSN_Config.CenterPos;

            % ---------- FINAL TARGET COUNTS ----------
            targetGWNs = round(N * (0.12 + 0.03*rand()));   % 12–15%
            targetCHs  = round(N * (0.05 + 0.03*rand()));   % 5–8%
            numSensors = N;

            % ---------- THROW EXTRA GWNs (BUFFERED) ----------
            throwGWNs = ceil(targetGWNs * 1.8);

            nodes = repmat(template, throwGWNs + numSensors + targetCHs, 1);
            idx = 1;

            % =================================================
            % PHASE A — GWN THROW (KEEP YOUR LOGIC)
            % =================================================
            theta = rand(throwGWNs,1) * 2*pi;
            r = sqrt(rand(throwGWNs,1) * ((field(1)/2)^2 - 10^2) + 10^2);
            pos = [ctr(1)+r.*cos(theta), ctr(2)+r.*sin(theta)];
            pos = max(1, min(field(1)-1, pos));

            for i = 1:throwGWNs
                nodes(idx).pos    = pos(i,:);
                nodes(idx).tier   = 3;
                nodes(idx).type   = 'GWN';
                nodes(idx).offset = randi([0 100]);
                idx = idx + 1;
            end

            % =================================================
            % PHASE B — DEMOTION (UNTIL targetGWNs SURVIVE)
            % =================================================
            gwnIdx = 1:throwGWNs;
            dists = vecnorm(pos - ctr, 2, 2);

            % protect hull
            try
                hullIdx = unique(convhull(pos(:,1), pos(:,2)));
            catch
                hullIdx = [];
            end

            % sort demotion candidates (closest first)
            demotable = setdiff(1:throwGWNs, hullIdx);
            [~,ord] = sort(dists(demotable),'ascend');
            demotable = demotable(ord);

            ptr = 1;
            while sum([nodes(1:throwGWNs).tier] == 3) > targetGWNs
                k = demotable(ptr);
                nodes(k).tier = 2;
                nodes(k).type = 'CH';
                ptr = ptr + 1;
            end

            % =================================================
            % PHASE C — SINK SELECTION (FROM SURVIVING GWNs)
            % =================================================
            gwnFinal = find([nodes(1:throwGWNs).tier] == 3);
            nodes(gwnFinal(randi(numel(gwnFinal)))).isSink = true;

            % =================================================
            % PHASE D — HULL AFTER DEMOTION
            % =================================================
            gwnPos = reshape([nodes(gwnFinal).pos],2,[])';
            try
                k = convhull(gwnPos(:,1), gwnPos(:,2));
                hullX = gwnPos(k,1); hullY = gwnPos(k,2);
            catch
                hullX = [0 field(1) field(1) 0];
                hullY = [0 0 field(2) field(2)];
            end

            % =================================================
            % PHASE E — ADDITIONAL CHs (ONLY IF NEEDED)
            % =================================================
            chCount = sum([nodes(1:idx-1).tier] == 2);
            needCH = max(0, targetCHs - chCount);

            for c = 1:needCH
                placed = false;
                while ~placed
                    cand = rand(1,2).*field;
                    if inpolygon(cand(1),cand(2),hullX,hullY)
                        nodes(idx).pos = cand;
                        nodes(idx).tier = 2;
                        nodes(idx).type = 'CH';
                        nodes(idx).offset = randi([0 100]);
                        idx = idx + 1;
                        placed = true;
                    end
                end
            end

            % =================================================
            % PHASE F — SENSOR PLACEMENT
            % =================================================
            for s = 1:numSensors
                placed = false;
                while ~placed
                    cand = rand(1,2).*field;
                    if inpolygon(cand(1),cand(2),hullX,hullY)
                        nodes(idx).pos = cand;
                        nodes(idx).tier = 1;
                        nodes(idx).type = 'SENSOR';
                        nodes(idx).offset = randi([0 100]);
                        idx = idx + 1;
                        placed = true;
                    end
                end
            end

            nodes = nodes(1:idx-1);

            % =================================================
            % FINAL SORT + HEX IDs
            % =================================================
            [~,ord] = sort([nodes.tier],'descend');
            nodes = nodes(ord);

            cnt = [0 0 0];
            pfx = {'00','AA','FF'};

            for i = 1:numel(nodes)
                t = nodes(i).tier;
                cnt(t) = cnt(t)+1;
                nodes(i).hexID = sprintf('%s%02X',pfx{t},cnt(t));
            end

            posArray = reshape([nodes.pos],2,[])';
        end

        % =====================================================
        % OBJECT GENERATION (UNCHANGED SEMANTICS)
        % =====================================================
        function nodes = generateTopology(N, field)
            [structNodes, ~] = WSN_TopologyGenerator.getStructTopology(N, field);

            totalN = numel(structNodes);
            temp = cell(1,totalN);

            for i = 1:totalN
                s = structNodes(i);
                switch s.tier
                    case 3
                        if s.isSink
                            obj = WSN_Sink(0,s.pos);
                        else
                            obj = WSN_Gateway(0,s.pos);
                        end
                    case 2
                        obj = WSN_ClusterHead(0,s.pos);
                    otherwise
                        obj = WSN_Sensor(0,s.pos);
                end
                obj.hexID = s.hexID;
                obj.offset = s.offset;
                temp{i} = obj;
            end

            nodes = [temp{:}];

            for i = 1:numel(nodes)
                nodes(i).id = i;  % 🔒 routing invariant
            end
        end
    end
end
