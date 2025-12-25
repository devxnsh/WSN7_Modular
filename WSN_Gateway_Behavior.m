classdef WSN_Gateway_Behavior < handle
    % =========================================================
    % WSN GATEWAY BEHAVIOR — FSM + RECRUITMENT + STATE LOGIC
    % Owns WHEN decisions, never packet construction
    % =========================================================

    properties
        gw   % handle to owning WSN_Gateway
    end

    % =========================================================
    % CONSTRUCTOR
    % =========================================================
    methods
        function obj = WSN_Gateway_Behavior(gateway)
            obj.gw = gateway;
        end
    end

    % =========================================================
    % STEP FSM
    % =========================================================
    methods
        function actions = step(obj, t)
            gw = obj.gw;
            actions = {};

            % ---------- PURGE DEAD NEIGHBORS ----------
            if ~isempty(gw.neighborTable)
                timeout = 3 * WSN_Config.HelloInterval;
                dead = [gw.neighborTable.lastSeen] < (t - timeout);

                if any(dead)
                    deadIDs = [gw.neighborTable(dead).id];
                    gw.neighborTable(dead) = [];

                    % --- remove only dead children (NO CASCADE) ---
                    if ~isempty(gw.children)
                        gw.children = setdiff(gw.children, intersect(gw.children, deadIDs));
                    end

                    % --- parent loss: upward reset ONLY ---
                    if ~isempty(gw.parent) && ismember(gw.parent, deadIDs)
                        gw.addLog(sprintf('t=%d [CRITICAL] Parent lost', t));
                        gw.parent = [];
                        gw.hasKey = false;
                        gw.isVerified = false;
                        gw.handshakePartner = [];
                        gw.state = WSN_Config.STATE_DISCOVERY;
                    end
                end
            end

            % ---------- INTERVAL SELECTION ----------
            currInt = WSN_Config.HelloInterval;
            if gw.crazyTimer > 0 || gw.state < WSN_Config.STATE_SECURE
                currInt = WSN_Config.AggressiveInterval;
            end

            % ---------- FSM ----------
            switch gw.state

                case WSN_Config.STATE_BOOT
                    if ~isempty(gw.neighborTable)
                        gw.state = WSN_Config.STATE_DISCOVERY;
                        gw.addLog(sprintf('t=%d [STATE] BOOT→DISCOVERY', t));
                    end
                    if mod(t,currInt)==mod(gw.offset,currInt)
                        actions{end+1} = struct('type','HB','hb','HB_BOOT');
                    end

                case WSN_Config.STATE_DISCOVERY
                    if mod(t,currInt)==mod(gw.offset,currInt)
                        actions{end+1} = struct('type','HB','hb','HB_DISC');
                    end

                case WSN_Config.STATE_HANDSHAKE
                    % non-blocking handshake
                    if isempty(gw.handshakePartner)
                        gw.state = WSN_Config.STATE_SECURE;
                    end
                    if mod(t,currInt)==mod(gw.offset,currInt)
                        actions{end+1} = struct('type','HB','hb','HB_WAIT');
                    end

                case WSN_Config.STATE_SECURE

                    % ----- ACTIVE COUNT SEMANTICS -----
                    if isempty(gw.parent)
                        active = sum([gw.neighborTable.status] == gw.ST_PROSP);
                    else
                        active = sum([gw.neighborTable.status] == gw.ST_PROSP | ...
                            [gw.neighborTable.status] == gw.ST_CHILD);
                    end

                    nbrs = gw.neighborTable;
                    if isempty(nbrs), return; end

                    % ---- ELIGIBILITY SET ----
                    if isempty(gw.parent)
                        validIdx = find([nbrs.status] ~= gw.ST_REJECT);
                    else
                        validIdx = find([nbrs.status] ~= gw.ST_REJECT & ...
                            [nbrs.id] ~= gw.parent);
                    end

                    if isempty(validIdx), return; end

                    rssiSorted = sort([nbrs(validIdx).rssi],'descend');
                    rssi1 = rssiSorted(1);
                    thresh = 0.95 * rssi1;
                    eligible = validIdx([nbrs(validIdx).rssi] >= thresh);

                    while active < gw.minProspectiveChildren && ...
                            gw.candidatePtr <= numel(gw.neighborTable)

                        if ~ismember(gw.candidatePtr, eligible)
                            gw.candidatePtr = gw.candidatePtr + 1;
                            continue;
                        end

                        nbr = gw.neighborTable(gw.candidatePtr);

                        if (nbr.status == gw.ST_NONE || nbr.status == gw.ST_REJECT) && ...
                                (isempty(gw.parent) || nbr.id ~= gw.parent)

                            gw.neighborTable(gw.candidatePtr).status = gw.ST_PROSP;
                            gw.handshakePartner = nbr.id;

                            actions{end+1} = struct( ...
                                'type','SEND', ...
                                'cmd','PARENT_INIT', ...
                                'dst',nbr.id);

                            gw.addLog(sprintf( ...
                                't=%d [RECRUIT] INIT→%s', ...
                                t, dec2hex(uint16(nbr.id),4)));

                            active = active + 1;
                        end

                        gw.candidatePtr = gw.candidatePtr + 1;
                    end

                    % ---- VERIFIED HEARTBEAT ----
                    if gw.isVerified && ...
                            mod(t,WSN_Config.HelloInterval)==mod(gw.offset,WSN_Config.HelloInterval)
                        actions{end+1} = struct('type','HB','hb','ENC_HB');
                    end
            end
        end
    end

    % =========================================================
    % APPLY ACTIONS FROM RX (FSM SIDE-EFFECTS)
    % =========================================================
    methods
        function apply(obj, actions, t)
            gw = obj.gw;

            for k = 1:numel(actions)
                a = actions{k};
                if ~isfield(a,'effect'), continue; end

                switch a.effect
                    case 'SET_PARENT'
                        gw.parent = a.value;
                        gw.state  = WSN_Config.STATE_SECURE;

                    case 'CLEAR_HANDSHAKE'
                        gw.handshakePartner = [];

                    case 'STATE'
                        gw.state = a.value;

                    case 'MARK_CHILD'
                        if ~ismember(a.value, gw.children)
                            gw.children(end+1) = a.value;
                        end

                    case 'REJECT_NEIGHBOR'
                        idx = find([gw.neighborTable.id]==a.value,1);
                        if ~isempty(idx)
                            gw.neighborTable(idx).status = gw.ST_REJECT;
                        end

                    case 'RESET_PROSPECTS'
                        idx = find([gw.neighborTable.status]==gw.ST_PROSP);
                        if ~isempty(idx)
                            [gw.neighborTable(idx).status] = deal(gw.ST_NONE);
                        end
                        gw.candidatePtr = 1;
                        gw.crazyTimer = WSN_Config.CrazyDuration_Neighbor;
                end
            end
        end
    end
end
