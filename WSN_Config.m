classdef WSN_Config
    properties (Constant)
        % --- STAGING ---
        SimulationStage = 3;

        % --- TOPOLOGY ---
        NodeCount = 100;
        FieldSize = [100, 100];
        CenterPos = [50, 50];
        HelloRange = 80;         % Default radio range for HELLO messages (Sybil etc.)

        % --- TIERS ---
        TIER_SENSOR = 1; TIER_CH = 2; TIER_GWN = 3;

        % --- STATES ---
        STATE_BOOT = 0; STATE_DISCOVERY = 1; STATE_HANDSHAKE = 2; STATE_SECURE = 3; STATE_DORMANT = 4;
        
        % --- PHASE RADIO STATES (GWN Backbone) ---
        PHASE_RX = 0;    % Listening to children
        PHASE_TX = 1;    % Transmitting to parent
        PHASE_IDLE = 2;  % No activity

        % --- NEIGHBOR TABLE STATUS CODES ---
        ST_CANDIDATE = 0;    % Newly discovered neighbor, not yet recruited/rejected
        ST_ACCEPTED = 1;     % Successfully recruited or handshook
        ST_REJECT = 2;       % Rejected neighbor (don't retry)
        
        % --- MESSAGE TYPES ---
        MSG_TYPE_HELLO = 0;  % Phase 2: Hello messages for neighbor discovery
        MSG_TYPE_SENSOR = 1; % Type 1: Sensor -> CH/GWN raw sensor data
        MSG_TYPE_PANIC = 2;  % Type 2: PANIC signals (anomaly/emergency)
        MSG_TYPE_CH_HELLO = 5;  % CH_HELLO to Sink (routing update)
        MSG_TYPE_CH_CMD = 6;    % CH-GWN handshake (CH_REQ, CH_ACK, KEY_ACK, CH_REJECT)
        MSG_TYPE_CMD = 7;    % Handshake/routing
        MSG_TYPE_TOKEN = 8;  % Token passing (TOKEN_DOWN, TOKEN_REQ, PATH_COMPLETE)
        MSG_TYPE_HB = 9;     % Heartbeat
        
        % --- PANIC SUBTYPES (Type 2) ---
        PANIC_SUB_ANOMALY = 0;       % 2.0 Sensor anomaly (threshold breach)
        PANIC_SUB_BATTERY_CRIT = 1;  % 2.1 Critical battery level
        PANIC_SUB_INTRUSION = 2;     % 2.2 Suspected intrusion/tampering
        PANIC_SUB_LINK_LOSS = 3;     % 2.3 Link loss (orphan alert)
        
        % --- PANIC SEVERITY LEVELS ---
        PANIC_SEV_LOW = 0;           % Forward to parent CH only (unicast)
        PANIC_SEV_MEDIUM = 1;        % Multicast to nearby CHs
        PANIC_SEV_HIGH = 2;          % Broadcast flood with TTL
        PANIC_SEV_CRITICAL = 3;      % Maximum priority flood
        
        % --- PANIC CONFIG ---
        PANIC_DEFAULT_TTL = 3;       % Default TTL for panic flood
        PANIC_ANOMALY_THRESHOLD = 300; % % change to trigger anomaly panic (very rare - actual emergency)
        PANIC_BATTERY_CRIT_LEVEL = 5;  % Battery % to trigger critical alert (near-death only)
        PANIC_COOLDOWN = 500;          % Min TFs between panics from same node
        
        % --- SENSOR DATA SUBTYPES (Type 5) ---
        % 5.0 = CH_HELLO (existing)
        % 5.1 = CH_HELLO forwarded (existing)
        SENSOR_SUB_AGG = 2;      % 5.2 SENSOR_AGG: Aggregated sensor data
        SENSOR_SUB_ACK = 3;      % 5.3 CH_ACK: Acknowledgment for 5.2
        
        % --- SENSOR DATA TIMING ---
        SENSOR_START_TIME = 350;         % When sensors start transmitting
        SENSOR_PERIOD_MIN = 3;           % Min period for sensor TX (TFs)
        SENSOR_PERIOD_MAX = 7;           % Max period for sensor TX (TFs)
        SENSOR_JITTER_MIN = 1;           % Min jitter (TFs)
        SENSOR_JITTER_MAX = 3;           % Max jitter (TFs)
        
        % --- AGGREGATION TIMING ---
        AGG_PERIOD_MIN = 7;              % Min period for 5.2 TX (TFs)
        AGG_PERIOD_MAX = 10;             % Max period for 5.2 TX (TFs)
        AGG_RETRY_INTERVAL = 3;          % Retransmission interval for unACKed 5.2
        AGG_MAX_RETRIES = 3;             % Max retries before discarding batch
        
        % --- PAYLOAD LIMITS ---
        MAX_PAYLOAD_BYTES = 64;          % Max payload size per message
        SENSOR_ENTRY_BYTES = 8;          % [SensorID(2), Time(2), Value(2), RSSI(1), Battery(1)]
        MAX_SENSORS_PER_FRAGMENT = 8;    % floor(64/8) = 8 sensors per fragment
        
        % --- GWN CHARGING ---
        GWN_CHARGE_AMOUNT = 0.005;    % Battery charge per cycle
        GWN_CHARGE_INTERVAL = 5;         % Charge every N timeframes
        
        % --- SN -> GWN THRESHOLD ---
        SN_GWN_DISTANCE_FACTOR = 0.8;    % SN prefers GWN if GWN distance < CH distance * factor
        
        % --- TOKEN SUBTYPES (Type 8) - DEPRECATED, kept for message type compatibility ---
        TOKEN_SUB_DOWN = 0;      % 8.0 (unused)
        TOKEN_SUB_REQ = 1;       % 8.1 (unused)
        TOKEN_SUB_COMPLETE = 2;  % 8.2 (unused)
        
        % --- PHASE SCHEDULING (Replaces Token System) ---
        PHASE_TX_DURATION = 3;       % Timeframes in TX phase per cycle
        PHASE_RX_DURATION = 3;       % Timeframes in RX phase per cycle
        PHASE_CYCLE_LENGTH = 6;      % Total cycle = TX + RX
        PHASE_START_TIME = 200;      % When phase scheduling begins (after setup)
        
        % --- BACKBONE QUEUE LIMITS ---
        QUEUE_FWD_MAX = 15;          % Max forwarding queue (child→parent)
        QUEUE_LOCAL_MAX = 15;        % Max local queue (own data)
        QUEUE_PURGE_COUNT = 3;       % Purge oldest N when queue full
        
        % --- CH-GWN HANDSHAKE SUBTYPES (Type 6) ---
        CH_SUB_REQ = 0;      % 6.0 CH_REQ: CH→GWN join request
        CH_SUB_ACK = 1;      % 6.1 CH_ACK: GWN→CH with local key
        CH_SUB_KEY_ACK = 2;  % 6.2 KEY_ACK: CH→GWN encrypted confirmation
        CH_SUB_REJECT = 3;   % 6.3 CH_REJECT: GWN→CH rejection
        CH_SUB_JOINOK = 4;   % 6.4 CH_JOINOK: CH→CH join acceptance
        CH_SUB_INFO = 5;     % 6.5 CH_INFO: Parent CH→GWN with recruited CH info
        
        % --- CH RECRUITMENT TIMING ---
        CH_ACCESS_LOCK_TIMER = 4;   % Access radio lock duration for CH handshake
        CH_MAX_RETRIES = 5;         % Max retries per GWN for any CH
        
        % --- CH DYNAMIC VOLTAGE SCALING (DVS) ---
        CH_DVS_ENABLED = true;              % Enable dynamic voltage scaling
        CH_DVS_SCALE_FACTOR = 1.5;          % Power multiplier on scale-up
        CH_DVS_MAX_POWER = 6.0;             % Maximum TX power for CH after scaling
        CH_DVS_MAX_SCALE_ATTEMPTS = 2;      % Max times CH can scale up before dormant
        
        % --- SENSOR ORPHAN SLEEP MODE ---
        SENSOR_ORPHAN_SLEEP_FACTOR = 0.75;  % 75% longer sleep when orphaned
        SENSOR_ORPHAN_WAKE_WINDOW = 1;      % Narrower wake window when orphaned
        SENSOR_NORMAL_WAKE_WINDOW = 4;      % Normal wake window duration

        % --- POWER (Constant) ---
        TxPower_Sensor = 1.0;
        TxPower_CH = 2.0;
        TxPower_GWN = 4.0;          % Normal Data Power
        TxPower_GWN_Control = 6.0;  % Control/Discovery Power
        MaxGWNPower = 12.0;

        % --- PHYSICS ---
        PathLossExp = 2.4; Sensitivity = 0.15; RayleighScale = 0.5;
        RxCost = 0.001; TxCost = 0.01; BaseTxCost = 0.01;
        IdleCost = 0.0005;      % CHs/GWNs always idle (awake) cost per TF
        SleepCost = 0.00002;    % Sensors sleep (very low discharge) when not TX
        NormalPower = 2.0;
        PathLossExp_Backbone = 1.5
        % --- RADIO BANDS (Hz) ---
        % Normal band used for sensor/CH links (e.g. 2.4 GHz)
        Frequency_Normal = 2.4e9;
        % Backbone / Encrypted band used for GWN-GWN (e.g. 900 MHz)
        Frequency_Backbone = 900e6;
        % Modulation/SNR factors (informational). Backbone modulation assumed
        % to have lower effective SNR for encrypted/control traffic. These
        % factors are NOT used to change connectivity (they are for later
        % estimation/logging and can be used by delay/SNR models).
        NormalSNRFactor = 1.0;
        BackboneSNRFactor = 0.7;
        % Toggle local logging of heartbeat messages (true = filter out HB logs)
        FilterLocalHeartbeat = false;

        % --- TIMING ---
        AggressiveInterval = 7;
        HelloInterval = 500;
        HelloBurstInterval = 7;     % Fixed interval for Hello bursts
        HelloBurstJitter = 3;       % Jitter: ±3 timesteps
        SimSteps = 10000;
        BootSteps = 3*WSN_Config.AggressiveInterval;
        MinBootNeighbors   = 2;
        PowerScaleFactor   = 1.2;
        
        % --- PHASE 2: HELLO COLLECTION (SetupTime) ---
        % Duration from end of GWN verification until CH/Sensors initiate joins
        % All nodes within range receive hello messages from all neighboring verified GWNs
        SetupTime = 200;             % timesteps (short window, only verified GWNs send)
        
        % --- RECRUITMENT THRESHOLDS ---
        % Min RSSI quality (as ratio of best available neighbor) to initiate join
        CH_GWN_RSSI_Threshold = 0.5;         % CH joining GWN: 50% of best
        Sensor_CH_RSSI_Threshold = 0.5;      % Sensor joining CH: 50% of best
        Sensor_GWN_RSSI_Threshold = 0.4;     % Sensor joining GWN: 40% (fallback)
        CH_CH_RSSI_Threshold = 0.5;          % CH joining CH: orphan case
        
        
        % --- ADAPTIVE LOGIC ---
        CrazyDuration_Neighbor = 50; CrazyDuration_Parent = 100;
        DemotionRadius = 35;
        % --- VISUALS ---
        ActiveRefresh = 1;
        HandshakeTimeout = 6;
        MAX_RETRIES = 4;

    end
end