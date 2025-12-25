classdef WSN_Protocol
    methods (Static)
        function [newMsgs, nodes] = scheduleTx(t, nodes, physAdj, stblAdj, distMat)
            newMsgs = [];
            % Silent in Stage 1
        end
        
        function [nodes, prunedLog] = checkNeighborTimeout(t, nodes)
            prunedLog = {};
        end

        function [nodes, nextQ, delivered] = deliver(t, msgs, nodes, distMat, physAdj)
            nextQ = [];
            delivered = {};
        end
        
        function survivors = resolveCollisions(batch, nodes, distMat)
            survivors = [];
        end
        
        function msg = createPacket(type, src, dsts, spoofID, pay, flag, prio, ttl, col)
            msg = struct('type',type, 'src',src, 'dsts',dsts, 'spoofID',spoofID, ...
                'payload',pay, 'flag',flag, 'prio',prio, 'ttl',ttl, 'color',col, 'uid',randi(1e9));
        end
    end
end