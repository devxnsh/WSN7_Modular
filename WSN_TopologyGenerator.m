classdef WSN_TopologyGenerator
    methods (Static)

        % =====================================================
        % POISSON DISK SAMPLING (EVEN DISTRIBUTION)
        % =====================================================
        function positions = distributePoissonDisk(hullX, hullY, numPoints, field)
            % Distribute numPoints evenly inside polygon using grid + randomness
            % Combines grid-based init with Poisson disk refinement
            
            % Calculate bounding box of hull
            minX = max(1, floor(min(hullX))); maxX = min(field(1), ceil(max(hullX)));
            minY = max(1, floor(min(hullY))); maxY = min(field(2), ceil(max(hullY)));
            
            % Grid cell size based on target point density
            cellSize = sqrt((maxX-minX) * (maxY-minY) / max(1, numPoints)) * 0.8;
            cellSize = max(2, cellSize);
            
            % Create candidate grid points
            gridPoints = [];
            for x = minX:cellSize:maxX
                for y = minY:cellSize:maxY
                    % Add grid point with random offset
                    offset = (cellSize/3) * (rand(1,2) - 0.5);
                    cand = [x + offset(1), y + offset(2)];
                    if all(cand >= 1) && all(cand <= field) && ...
                       inpolygon(cand(1), cand(2), hullX, hullY)
                        gridPoints = [gridPoints; cand]; %
                    end
                end
            end
            
            % If we have more grid points than needed, select uniformly spaced subset
            if size(gridPoints, 1) > numPoints
                % Use stratified sampling for even distribution
                [~, indices] = sort(rand(size(gridPoints,1), 1));
                indices = indices(1:numPoints);
                positions = gridPoints(indices, :);
            elseif size(gridPoints, 1) == numPoints
                positions = gridPoints;
            else
                % Not enough grid points - fill with random placement
                positions = gridPoints;
                remaining = numPoints - size(gridPoints, 1);
                for r = 1:remaining
                    placed = false;
                    attempts = 0;
                    while ~placed && attempts < 50
                        cand = rand(1,2) .* [maxX-minX, maxY-minY] + [minX, minY];
                        if inpolygon(cand(1), cand(2), hullX, hullY)
                            % Check minimum distance to existing points
                            dists = vecnorm(positions - cand, 2, 2);
                            if all(dists > cellSize/2)
                                positions = [positions; cand]; %
                                placed = true;
                            end
                        end
                        attempts = attempts + 1;
                    end
                    if ~placed && size(positions,1) < numPoints
                        % Force placement if still needed
                        cand = rand(1,2) .* [maxX-minX, maxY-minY] + [minX, minY];
                        if inpolygon(cand(1), cand(2), hullX, hullY)
                            positions = [positions; cand]; %
                        end
                    end
                end
            end
        end

        % =====================================================
        % GUI HULL (UNCHANGED)
        % =====================================================
        function hullCoords = getGWNHull(nodes)
            gwnPos = [];
            for i = 1:numel(nodes)
                if isprop(nodes(i),'tier') && nodes(i).tier == WSN_Config.TIER_GWN
                    gwnPos(end+1,:) = nodes(i).pos; %
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
            targetCHs  = round(N * (0.06 + 0.04*rand()));   % 6–10% (+10% more CHs)
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

            % sort demotion candidates (closest first, non-hull preferred)
            demotable = setdiff(1:throwGWNs, hullIdx);
            [~,ord] = sort(dists(demotable),'ascend');
            demotable = demotable(ord);

            % fallback: if demotable too small, append hull nodes (closest first)
            if numel(demotable) < (throwGWNs - targetGWNs)
                hullSorted = hullIdx(~ismember(hullIdx, demotable));
                [~,hord] = sort(dists(hullSorted),'ascend');
                demotable = [demotable; hullSorted(hord)];
            end

            ptr = 1;
            while sum([nodes(1:throwGWNs).tier] == 3) > targetGWNs && ptr <= numel(demotable)
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
            % PHASE E — ADDITIONAL CHs (EVENLY DISTRIBUTED)
            % =================================================
            chCount = sum([nodes(1:idx-1).tier] == 2);
            needCH = max(0, targetCHs - chCount);

            if needCH > 0
                % Use grid-based distribution with random perturbation
                % for even/uniform spread inside the polygon
                chPositions = WSN_TopologyGenerator.distributePoissonDisk(...
                    hullX, hullY, needCH, field);
                
                for c = 1:size(chPositions, 1)
                    nodes(idx).pos = chPositions(c,:);
                    nodes(idx).tier = 2;
                    nodes(idx).type = 'CH';
                    nodes(idx).offset = randi([0 100]);
                    idx = idx + 1;
                end
            end

            % =================================================
            % PHASE F — SENSOR PLACEMENT (AROUND CHs + FILL)
            % =================================================
            % Get all current clusterheads
            chIdx = find([nodes(1:idx-1).tier] == 2);
            chPositions = reshape([nodes(chIdx).pos],2,[])';
            
            numSensorsPlaced = 0;
            sensorsPerCH = max(1, floor(numSensors / max(1, numel(chIdx))));
            
            % Step 1: Distribute sensors around each clusterhead
            for ch = 1:numel(chIdx)
                chPos = chPositions(ch,:);
                
                % Place sensorsPerCH sensors in a radius around this CH
                for s = 1:sensorsPerCH
                    if numSensorsPlaced >= numSensors
                        break;
                    end
                    
                    placed = false;
                    attempts = 0;
                    while ~placed && attempts < 20
                        % Random angle and radius for clustering
                        angle = rand() * 2 * pi;
                        % Radius: 5-20 units from CH (proximity clustering)
                        radius = 5 + rand() * 15;
                        cand = chPos + radius * [cos(angle), sin(angle)];
                        
                        % Ensure within field bounds and polygon
                        if all(cand >= 1) && all(cand <= field) && ...
                           inpolygon(cand(1),cand(2),hullX,hullY)
                            nodes(idx).pos = cand;
                            nodes(idx).tier = 1;
                            nodes(idx).type = 'SENSOR';
                            nodes(idx).offset = randi([0 100]);
                            idx = idx + 1;
                            numSensorsPlaced = numSensorsPlaced + 1;
                            placed = true;
                        end
                        attempts = attempts + 1;
                    end
                end
            end
            
            % Step 2: Fill remaining sensors uniformly across polygon
            while numSensorsPlaced < numSensors
                cand = rand(1,2).*field;
                if inpolygon(cand(1),cand(2),hullX,hullY)
                    nodes(idx).pos = cand;
                    nodes(idx).tier = 1;
                    nodes(idx).type = 'SENSOR';
                    nodes(idx).offset = randi([0 100]);
                    idx = idx + 1;
                    numSensorsPlaced = numSensorsPlaced + 1;
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
