# WSN7 Attack Modus Operandi Flowchart

## Unified Attack Execution Flow

This document presents a single composite flowchart showing the logical progression and decision pathways for all 7 attack types in the WSN7 system. The flowchart illustrates how attackers select and execute attacks based on objectives and available resources.

```mermaid
%%{init: {'flowchart': {'htmlLabels': true}, 'themeVariables': {'fontSize': '40px', 'fontFamily': 'arial'}}}%%
graph TD
    START["Attacker Node Activated<br/>(GWN, CH, or Sensor)"] --> ASSESS["Assess Network State<br/>Topology, Trust Level, Resources"]
    
    ASSESS --> OBJECTIVE{"Attack Objective?"}
    
    OBJECTIVE -->|Disrupt Discovery| HELLO["<b>HELLO_FLOOD</b><br/>Burst HELLO messages<br/>Inflate neighbor counts<br/>Collapse topology"]
    OBJECTIVE -->|Emergency Exploitation| PANIC["<b>PANIC_FLOOD</b><br/>Broadcast false emergencies<br/>Type 2 + high priority<br/>Force response overhead"]
    OBJECTIVE -->|Silent Data Loss| BLACKHOLE["<b>BLACKHOLE</b><br/>Drop all packets silently<br/>Log RX, suppress FWD<br/>Appear operational"]
    OBJECTIVE -->|Path Manipulation| WORMHOLE["<b>WORMHOLE</b><br/>Advertise false low-latency<br/>Re-route traffic through<br/>attacker-controlled path"]
    OBJECTIVE -->|Battery Exhaustion| DOS["<b>DENIAL OF SLEEP</b><br/>Send spurious Type 255<br/>Continuous TX/RX cycles<br/>Drain battery rapidly"]
    OBJECTIVE -->|Influence Amplification| SYBIL["<b>SYBIL</b><br/>Spawn multiple identities<br/>Staggered HELLO broadcast<br/>Gain disproportionate voting"]
    OBJECTIVE -->|Selective Disruption| GRAY["<b>GRAYHOLE</b><br/>Selective forwarding<br/>~50% drop rate by type<br/>Appear partially operational"]
    
    HELLO --> HELLO_EX["Intensity 1-3: Burst 20+ msgs/tick<br/>Intensity 4-7: Burst 5-10 msgs/tick<br/>Intensity 8-10: Burst 1-2 msgs/tick"]
    PANIC --> PANIC_EX["Set Type 2, Priority MAX<br/>TTL = 3-5, Broadcast<br/>Repeat every 50-100 ticks"]
    BLACKHOLE --> BH_EX["Drop rate = 10% × intensity<br/>Record RX, zero FWD<br/>Create ghost links visual"]
    WORMHOLE --> WH_EX["Advertise RSSI -20 to both<br/>Intercept bidirectional packets<br/>Re-encode with false delay"]
    DOS --> DOS_EX["Inject Type 255 spurious<br/>Wake target every 2-5 ticks<br/>Force response ACK cycles"]
    SYBIL --> SYBIL_EX["Create 2-5 fake identities<br/>Rotate HELLO every 10 ticks<br/>Register all as neighbors"]
    GRAY --> GRAY_EX["Drop ~50% of Type 1 (data)<br/>Forward Type 3,7,8,9<br/>Create asymmetric pattern"]
    
    HELLO_EX -->|Sink/Neighbors: Topology instability,<br/>neighbor count spike, HELLO rate anomaly| DETECT["Detection Initiated"]
    PANIC_EX -->|Sink/Neighbors: Emergency source not GWN,<br/>false alert rate > threshold, trust degradation| DETECT
    BH_EX -->|Neighbors: Zero forwarding observed,<br/>end-to-end delivery loss, missing ACKs| DETECT
    WH_EX -->|Sink: Unusual path lengths,<br/>bidirectional timing asymmetry, anomalous RTT| DETECT
    DOS_EX -->|Neighbors: Target continuous RX/TX,<br/>no sleep cycles, battery drain anomaly| DETECT
    SYBIL_EX -->|Neighbors: Multiple IDs same location,<br/>identical packet signatures, correlated voting| DETECT
    GRAY_EX -->|Neighbors: Type 1 data loss > 20%,<br/>control frames pass, asymmetric loss pattern| DETECT
    
    style START fill:#e1f5ff
    style HELLO fill:#ffccbc
    style PANIC fill:#ffccbc
    style BLACKHOLE fill:#ffccbc
    style WORMHOLE fill:#ffccbc
    style DOS fill:#ffccbc
    style SYBIL fill:#ffccbc
    style GRAY fill:#ffccbc
    style DETECT fill:#fff9c4
```

## Attack Type Matrix

| Attack | Intensity Impact | Execution Method | Detection Signal |
|--------|------------------|------------------|----------|
| **HELLO_FLOOD** | Intensity 1-3: 20+ msgs/tick (aggressive) • Intensity 4-7: 5-10 msgs/tick (moderate) • Intensity 8-10: 1-2 msgs/tick (subtle) | Burst fake HELLO messages with inflated neighbor counts | Message count spike from single source |
| **PANIC_FLOOD** | Intensity 1-3: Every 50 ticks (aggressive) • Intensity 4-7: Every 75 ticks (moderate) • Intensity 8-10: Every 100 ticks (subtle) | Broadcast Type 2 messages with MAX priority, TTL 3-5 | Emergency rate spike, multiple false alerts |
| **BLACKHOLE** | Intensity 1: 10% drop • Intensity 5: 50% drop • Intensity 10: 100% drop (linear scaling) | Record all RX packets, suppress FWD to parent chain | End-to-end timeout, ghost links appear at attacker |
| **WORMHOLE** | Intensity 1-3: RSSI -18 (subtle advantage) • Intensity 4-7: RSSI -22 (moderate advantage) • Intensity 8-10: RSSI -25 (strong advantage) | Advertise false low-latency path between distant regions | Path length anomaly, unusual timing patterns |
| **DENIAL_OF_SLEEP** | Intensity 1: Wake every 10 ticks • Intensity 5: Wake every 5 ticks • Intensity 10: Wake every 2 ticks | Inject spurious Type 255 messages forcing TX/RX cycles | Battery drain rate > normal, continuous activity |
| **SYBIL** | Intensity 1-3: 2-3 fake identities (subtle) • Intensity 4-7: 3-4 identities (moderate) • Intensity 8-10: 5+ identities (aggressive) | Spawn multiple node IDs, stagger HELLO rotation every 10 ticks | Spatial clustering in same region, identical behavior patterns |
| **GRAYHOLE** | Intensity 1-3: ~20% Type 1 drop (subtle) • Intensity 4-7: ~35% Type 1 drop (moderate) • Intensity 8-10: ~50% Type 1 drop (aggressive) | Selective forwarding of Type 1 data only, pass control traffic | Asymmetric packet loss: data drops but control frames pass |




## Integration with Core Protocols

This flowchart integrates:
- **Type 3 (CLIP_CONTROL)**: Distributed consensus voting and anomaly escalation
- **Type 10 (ML_TUNING)**: Adaptive parameter propagation and threshold adjustment
- **Setup Phase**: Initial key exchange and topology establishment
- **Data Transmission**: Normal operation baseline for anomaly detection
