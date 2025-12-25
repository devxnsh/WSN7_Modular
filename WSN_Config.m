classdef WSN_Config
    properties (Constant)
        % --- STAGING ---
        SimulationStage = 3; 

        % --- TOPOLOGY ---
        NodeCount = 100;
        FieldSize = [100, 100];
        CenterPos = [50, 50];
        
        % --- TIERS ---
        TIER_SENSOR = 1; TIER_CH = 2; TIER_GWN = 3;
        
        % --- STATES ---
        STATE_BOOT = 0; STATE_DISCOVERY = 1; STATE_HANDSHAKE = 2; STATE_SECURE = 3; STATE_DORMANT = 4;    
        
        % --- POWER (Constant) ---
        TxPower_Sensor = 1.0; 
        TxPower_CH = 2.0; 
        TxPower_GWN = 4.0;          % Normal Data Power
        TxPower_GWN_Control = 6.0;  % Control/Discovery Power
        MaxGWNPower = 12.0;
        
        % --- PHYSICS ---
        PathLossExp = 2.4; Sensitivity = 0.15; RayleighScale = 0.5;
        RxCost = 0.1; TxCost = 1.0; BaseTxCost = 1.0;
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
        AggressiveInterval = 10; HelloInterval = 500; 
        SimSteps = 10000; BootSteps = 10; 
        
        % --- ADAPTIVE LOGIC ---
        CrazyDuration_Neighbor = 50; CrazyDuration_Parent = 100;   
        DemotionRadius = 35;
        % --- VISUALS ---
        ActiveRefresh = 1;
    end
end