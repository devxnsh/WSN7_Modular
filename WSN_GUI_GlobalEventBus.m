classdef WSN_GUI_GlobalEventBus
    methods (Static)

        function bind(feedObj)
            % Store feed in shared singleton
            bus = WSN_GUI_GlobalEventBus.store();
            bus.feed = feedObj;
            WSN_GUI_GlobalEventBus.store(bus);
        end

        function emit(t, msg)
            bus = WSN_GUI_GlobalEventBus.store();
            if isempty(bus) || ~isfield(bus,'feed') || isempty(bus.feed) ...
                    || ~isvalid(bus.feed)
                return;
            end

            if isa(msg,'WSN_Message')
                msg = msg.serialize();   % force wire representation
            end

            bus.feed.addEntry(t, msg);
        end


    end

    methods (Static, Access = private)
        function bus = store(newBus)
            persistent BUS
            if nargin > 0
                BUS = newBus;
            end
            bus = BUS;
        end
    end
end
