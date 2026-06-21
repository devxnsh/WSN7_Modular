classdef WSN_Gateway_Registry
    % =========================================================
    % GWN REGISTRY MODULE
    % =========================================================
    % Local-key derivation (identity/registry helper used during the
    % secure handshake). Extracted from WSN_Gateway.m; operates on the
    % GWN instance (obj) passed in by the caller. Stateless itself - all
    % state lives on obj. Mirrors WSN_Sink_Registry.deriveRemoteLocalKey.
    % =========================================================

    methods (Static)
        function localKeyHex = deriveLocalKey(obj)
            % Guard against empty or invalid encryption key
            if isempty(obj.encryptionKey) || ~ischar(obj.encryptionKey) || mod(numel(obj.encryptionKey), 2) ~= 0
                localKeyHex = '';  % Return empty if no valid key
                return;
            end

            try
                gk = uint8(hex2dec(reshape(obj.encryptionKey,2,[])'));
                if numel(gk) < 8
                    localKeyHex = '';
                    return;
                end
                idBytes = typecast(uint16(hex2dec(obj.hexID)),'uint8');
                pBytes  = typecast(uint16(obj.parent),'uint8');
                seed = [gk; idBytes(:); pBytes(:)];
                lk = gk(1:8);
                for i = 1:numel(seed)
                    lk(mod(i-1,8)+1) = bitxor(lk(mod(i-1,8)+1), seed(i));
                end
                localKeyHex = upper(reshape(dec2hex(lk,2).',1,[]));
            catch
                localKeyHex = '';  % Return empty on any error
            end
        end
    end
end
