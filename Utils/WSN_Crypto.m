classdef WSN_Crypto
    methods (Static)
        function out = encrypt(input, key)
            % Placeholder reversible cipher (XOR-style)
            % Supports both hex string and uint8 array input
            if isempty(input), out = input; return; end
            
            % Get key byte
            if ischar(key) || isstring(key)
                k = uint8(sum(double(char(key))));
            else
                k = uint8(sum(double(key)));
            end
            
            % Handle input type
            if ischar(input) || isstring(input)
                % Hex string input
                hexIn = char(input);
                bytes = uint8(hex2dec(reshape(hexIn,2,[]).'));
                enc = bitxor(bytes, k);
                out = upper(reshape(dec2hex(enc,2).',1,[]));
            else
                % uint8 array input
                out = bitxor(uint8(input), k);
            end
        end

        function out = decrypt(input, key)
            % Symmetric
            out = WSN_Crypto.encrypt(input, key);
        end
    end
end
