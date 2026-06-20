const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  BorderStyle, WidthType, ShadingType, Table, TableRow, TableCell,
  PageNumber, Footer, PageBreak, UnderlineType
} = require('docx');
const fs = require('fs');

const border = { style: BorderStyle.SINGLE, size: 1, color: "AAAAAA" };
const borders = { top: border, bottom: border, left: border, right: border };

function heading1(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_1,
    spacing: { before: 400, after: 200 },
    children: [new TextRun({ text, bold: true, size: 32, font: "Times New Roman" })]
  });
}

function heading2(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_2,
    spacing: { before: 300, after: 160 },
    children: [new TextRun({ text, bold: true, size: 26, font: "Times New Roman" })]
  });
}

function heading3(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_3,
    spacing: { before: 240, after: 120 },
    children: [new TextRun({ text, bold: true, italics: true, size: 24, font: "Times New Roman" })]
  });
}

function para(text, opts = {}) {
  return new Paragraph({
    alignment: AlignmentType.JUSTIFIED,
    spacing: { before: 0, after: 180, line: 360 },
    indent: { firstLine: 720 },
    children: [new TextRun({ text, size: 24, font: "Times New Roman", ...opts })]
  });
}

function diagramNote(text) {
  return new Paragraph({
    alignment: AlignmentType.LEFT,
    spacing: { before: 160, after: 160 },
    border: {
      top: { style: BorderStyle.SINGLE, size: 2, color: "2E74B5" },
      bottom: { style: BorderStyle.SINGLE, size: 2, color: "2E74B5" },
      left: { style: BorderStyle.THICK, size: 12, color: "2E74B5" },
      right: { style: BorderStyle.SINGLE, size: 2, color: "2E74B5" }
    },
    shading: { fill: "EBF3FB", type: ShadingType.CLEAR },
    indent: { left: 200, right: 200 },
    children: [
      new TextRun({ text: "[Figure / Table Recommendation] ", bold: true, size: 22, color: "2E74B5", font: "Times New Roman" }),
      new TextRun({ text, size: 22, color: "2E74B5", font: "Times New Roman", italics: true })
    ]
  });
}

function spacer() {
  return new Paragraph({ spacing: { before: 0, after: 80 }, children: [new TextRun("")] });
}

const doc = new Document({
  styles: {
    default: { document: { run: { font: "Times New Roman", size: 24 } } },
    paragraphStyles: [
      {
        id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 32, bold: true, font: "Times New Roman", color: "1F3864" },
        paragraph: { spacing: { before: 400, after: 200 }, outlineLevel: 0 }
      },
      {
        id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 26, bold: true, font: "Times New Roman", color: "2E74B5" },
        paragraph: { spacing: { before: 300, after: 160 }, outlineLevel: 1 }
      },
      {
        id: "Heading3", name: "Heading 3", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 24, bold: true, italics: true, font: "Times New Roman", color: "2E74B5" },
        paragraph: { spacing: { before: 240, after: 120 }, outlineLevel: 2 }
      }
    ]
  },
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 },
        margin: { top: 1440, right: 1260, bottom: 1440, left: 1440 }
      }
    },
    footers: {
      default: new Footer({
        children: [
          new Paragraph({
            alignment: AlignmentType.CENTER,
            children: [
              new TextRun({ text: "Chapter 2 | Literature Review    ", size: 18, color: "888888", font: "Times New Roman" }),
              new TextRun({ children: [PageNumber.CURRENT], size: 18, color: "888888", font: "Times New Roman" })
            ]
          })
        ]
      })
    },
    children: [

      // ─── CHAPTER HEADING ───────────────────────────────────────────────────────
      new Paragraph({
        alignment: AlignmentType.LEFT,
        spacing: { before: 0, after: 80 },
        border: { bottom: { style: BorderStyle.THICK, size: 8, color: "1F3864" } },
        children: [
          new TextRun({ text: "Chapter 2", size: 28, bold: false, color: "2E74B5", font: "Times New Roman" })
        ]
      }),
      new Paragraph({
        alignment: AlignmentType.LEFT,
        spacing: { before: 120, after: 480 },
        children: [
          new TextRun({ text: "Literature Review", size: 48, bold: true, color: "1F3864", font: "Times New Roman" })
        ]
      }),

      // ─── CHAPTER INTRO ─────────────────────────────────────────────────────────
      para("This chapter surveys the foundational body of knowledge underlying the proposed secure, machine-learning-enforced architecture for Wireless Sensor Networks. The review is organized thematically across the structural and adversarial dimensions of WSN design. It opens with an overview of WSN fundamentals, canonical application domains, and the principal classes of vulnerability that motivate the proposed framework. Subsequent sections address the backhaul architectures that constitute the communications substrate, encryption standards viable within the low-power constraints of sensor hardware, dual-radio architectural patterns that resolve the range-versus-power trade-off, and the application of machine learning to attack detection and mitigation. Where relevant, specific table and diagram recommendations are provided to assist editorial placement."),
      spacer(),

      // ─── BASICS OF WSN ─────────────────────────────────────────────────────────
      new Paragraph({
        heading: HeadingLevel.HEADING_1,
        spacing: { before: 320, after: 200 },
        children: [new TextRun({ text: "Basics of Wireless Sensor Networks, General Applications, Points of Weakness, and Types of Attacks", bold: true, size: 32, font: "Times New Roman" })]
      }),

      para("A Wireless Sensor Network (WSN) is a spatially distributed collection of autonomous devices, each equipped at minimum with a sensing transducer, a microcontroller, a wireless radio, and a power source. At the most fundamental level, each node converts a physical-world observable — temperature, pressure, motion, ambient light — into a digital measurement and communicates it toward a designated sink, from which the data may be consumed by an application or a human operator. The operating standard for low-power, short-range WSN communication is IEEE 802.15.4, which specifies the Physical and MAC layers across 27 ISM-band channels distributed across three frequency bands: 868 MHz, 915 MHz, and 2.4 GHz. This standard, and the ZigBee application-layer stack built upon it, represents the dominant communication substrate for terrestrial sensor deployments, providing AES-128 link encryption and support for star, tree, and mesh topologies."),

      para("The general architecture of a sensor node reflects a deliberate minimalism: a small microcontroller handles sensing and control logic, a transceiver manages radio communication, a power management subsystem extends battery life through aggressive sleep scheduling, and optional flash memory enables local data buffering. This architecture places hard constraints on all aspects of software design — models must be compact, cryptographic overhead must be bounded, and communications must be infrequent. In large-scale deployments, the flat topology of isolated sensor nodes is typically organized into a hierarchical structure of Cluster Heads (CHs) and Gateway Nodes (GWNs), which aggregate, encrypt, and relay sensor readings upstream toward the network sink."),

      para("WSNs have found application across an exceptionally broad range of domains. Environmental monitoring — air quality, water quality, wildfire detection, seismic activity — exploits the ability of WSNs to instrument large, otherwise inaccessible terrain. Agricultural deployments use WSNs for precision irrigation, soil condition monitoring, and crop health surveillance. Industrial applications span structural health monitoring of bridges and pipelines, predictive maintenance in manufacturing facilities, and supply-chain asset tracking. Healthcare applications include patient monitoring in hospital wards, wearable physiological sensors, and smart-home monitoring for elderly populations. At the high end of criticality, defense and border-surveillance deployments exploit WSNs for perimeter monitoring, battlefield sensor grids, and aerospace ground-support infrastructure, environments in which network compromise carries consequences far beyond data loss. It is this last class of deployment — adversarially contested, unattended, and operationally critical — that motivates the architecture described in this thesis."),

      diagramNote("Recommend a two-column comparison table here (Table 2.1): WSN Application Domains vs. Key Constraints, listing Environment, Agriculture, Healthcare, Industrial, and Defense/Surveillance rows against columns such as Typical Node Count, Acceptable Latency, Acceptable Data Loss, Physical Security Level, and Required Operational Life. This contextualizes why defense-oriented deployments impose the strictest constraints on the framework."),

      para("Despite their utility, WSNs carry structural vulnerabilities that are the direct consequence of their design philosophy. The broadcast nature of the RF medium means every transmission is inherently exposed to passive interception. Nodes are physically deployed in uncontrolled or hostile environments, making hardware capture trivially executable by an adequately resourced adversary. The energy and memory budgets preclude the cryptographic mechanisms taken for granted in infrastructure networks: full PKI handshakes, frequent re-keying, and computationally intensive authentication schemes are impractical at the sensor level. MAC-layer protocols that use token passing or duty cycling introduce predictable timing patterns that adversaries can exploit. Centralized anomaly detection cannot respond within the temporal bounds of fast-evolving attacks such as flooding or coordinated sinkhole formation. These structural constraints together define the threat surface that any serious WSN security framework must address."),

      para("Attacks on WSNs are broadly partitioned into two classes: destructive and extractive. Destructive attacks degrade or eliminate network functionality. Flooding saturates neighboring radios with excessive packets, causing collisions and accelerating battery drain on surrounding nodes. Blackhole nodes silently discard all packets routed through them, while Grayhole nodes selectively drop a configurable fraction based on implied packet priority, making their presence statistically harder to distinguish from legitimate channel loss. Sinkhole attacks advertise falsely strong routes to attract and then discard upstream traffic, corrupting the routing topology. Denial-of-Sleep attacks exploit knowledge of node duty cycles to inject wakeup messages immediately before a node enters its sleep state, draining battery reserves without causing immediately visible disruption. Wormhole attacks tunnel packets between distant network regions through a private out-of-band channel, creating phantom links and distorting the topological map maintained by the network. Extractive attacks, in contrast, operate without disrupting normal data flow: eavesdropping intercepts, duplicates, or silently reroutes received packets to unintended destinations, while Sybil attacks fabricate multiple virtual identities to poison neighbor tables and subvert routing and cluster-formation decisions. These attacks may be deployed in combination, at varying intensities, and with varying detectability — the most dangerous variant being one whose activity is statistically indistinguishable from stochastic channel variation."),

      diagramNote("Recommend a taxonomy diagram here (Figure 2.1): a hierarchical tree of WSN Attack Classes branching into Destructive (Flooding, Blackhole, Grayhole, Sinkhole, Denial-of-Sleep, Wormhole) and Extractive (Eavesdropping, Sybil, Man-in-the-Middle). Each leaf node should carry a one-line description of the primary visible network effect. An alternative is a 3-column table (Table 2.2): Attack Name | Attack Layer | Visible Network Effect, which is directly reusable as a reference table in the implementation chapter."),
      spacer(),

      // ─── 2.1 BACKHAUL ARCHITECTURES ────────────────────────────────────────────
      new Paragraph({
        heading: HeadingLevel.HEADING_2,
        spacing: { before: 360, after: 180 },
        children: [new TextRun({ text: "2.1  Backhaul Architectures", bold: true, size: 28, font: "Times New Roman" })]
      }),

      para("The backhaul of a WSN refers to the communication substrate that carries aggregated data from cluster-level collection points upstream toward the network sink. The design of this channel fundamentally governs the latency, reliability, energy consumption, and adversarial resilience of the entire network. In low-risk, short-range deployments, the backhaul is often implemented on the same IEEE 802.15.4 radio used for intra-cluster access communication. However, this single-radio approach conflates two traffic classes with distinct requirements: short-range, high-frequency sensor reporting on one hand, and long-distance, aggregated data forwarding on the other. Under this conflation, contention between the two classes degrades the performance of both, and a compromised access-tier node can directly affect backbone traffic."),

      para("The IEEE 802.15.4 standard, and its application-layer extension ZigBee, constitute the dominant short-range WSN substrate. ZigBee supports mesh routing and AES-128 link-layer encryption, and it provides a well-defined three-device model: Coordinators, Routers, and End Devices. However, its static cluster formation and limited heterogeneous interoperability expose it to topology disruption attacks in dense or adversarially contested environments. The absence of a distinct backhaul channel means that a flooding or Sinkhole attack against a Router-tier node can degrade both access and backbone traffic simultaneously. LoRaWAN extends the communication range to several kilometers and provides a physically distinct long-range channel suitable for backbone use, but its strict duty-cycle constraints — as low as 1% in some regulatory regions — prevent its application to real-time, event-driven WSN scenarios. The trade-off between range and duty cycle therefore cannot be resolved within a single-radio architecture."),

      para("Heterogeneous WSN architectures address this fundamental trade-off by equipping gateway-tier nodes with two independent transceivers operating on distinct frequency bands. One radio, typically a short-range access radio such as an IEEE 802.15.4 or BLE interface, handles intra-cluster traffic. A second, long-range radio — most commonly a LoRa or LoRaWAN module — manages backbone communication between cluster heads and the sink. Ayele et al. demonstrated this pairing in the context of wildlife monitoring, showing that BLE and LoRa can be combined to produce a system that meets both short-range high-frequency requirements and long-distance forwarding requirements without duty-cycle violations, provided the two traffic classes are managed by independent MAC layers. The decoupling of access and backbone traffic eliminates cross-tier interference and allows each radio's MAC to be optimized independently."),

      diagramNote("Recommend a comparison table here (Table 2.3): Backhaul Technology Comparison — columns: Technology | Frequency Band | Range | Data Rate | Duty Cycle Constraint | Typical WSN Role | Primary Limitation. Rows should include IEEE 802.15.4, ZigBee, LoRa, LoRaWAN, BLE, and 6LoWPAN. This table directly supports the architectural justification for dual-radio gateway nodes in the proposed framework."),

      para("Beyond the physical radio layer, the backhaul architecture must also specify routing and MAC protocols. Token-passing MAC protocols such as the Multi-Token MAC-cum-Routing Protocol eliminate MAC-layer flooding and collision attacks by granting transmission rights exclusively to the valid token holder, allowing collision-free parallel transmissions from immediate parent nodes. However, token-passing introduces its own vulnerabilities: replay attacks and token theft, where a compromised node retains or duplicates the token to starve legitimate nodes of transmission opportunities. Hierarchical routing protocols such as LEACH introduced probabilistic cluster-head rotation to balance energy load across the network, but random election produces topologically suboptimal clusters and is vulnerable to CH-impersonation attacks. The proposed architecture addresses these limitations by using the local key's final bit to calculate each gateway node's transmission phase, creating an alternating Tx-Rx chain that resolves backpressure naturally without explicit token management and without the replay vulnerabilities that token-based schemes introduce."),

      diagramNote("Recommend a protocol state-diagram or sequence diagram here (Figure 2.2) illustrating the alternating Tx-Rx chain mechanism across gateway nodes in a U-shaped funnel topology. Alternatively, a topology diagram showing the convex-hull boundary of gateway nodes with annotated backbone links would be appropriate at this location, cross-referencing Figure 1 of the preliminary work."),
      spacer(),

      // ─── 2.2 ENCRYPTION ────────────────────────────────────────────────────────
      new Paragraph({
        heading: HeadingLevel.HEADING_2,
        spacing: { before: 360, after: 180 },
        children: [new TextRun({ text: "2.2  Encryption in WSN", bold: true, size: 28, font: "Times New Roman" })]
      }),

      para("Cryptography is the primary tool available to WSN designers for ensuring data confidentiality, integrity, and authenticity. However, classical cryptographic primitives impose energy and computational costs that scale poorly with the resource constraints of leaf-tier sensor nodes. Public-Key Infrastructure (PKI) handshakes, which underpin most infrastructure-network security protocols, require modular exponentiation or elliptic-curve point multiplication operations whose energy cost can exceed that of transmitting hundreds of data packets. Full PKI is therefore unworkable at the leaf-node level, though it may be feasible at gateway or sink nodes where compute is not the limiting constraint. The fundamental tension in WSN encryption design is therefore not whether to use cryptography but how to select, layer, and distribute cryptographic responsibilities across tiers with radically different resource profiles."),

      para("Symmetric key cryptography represents the primary viable option at the sensor level. AES-128, adopted by IEEE 802.15.4 for link-layer encryption, provides a 128-bit block cipher with a key schedule whose computational cost is well within the reach of modern low-power microcontrollers running at 16–32 MHz. Lightweight block ciphers such as HIGHT, which operates on a 64-bit block with a 128-bit key using a GFS (Generalized Feistel Structure), have been proposed specifically for resource-constrained embedded environments and achieve substantially lower energy consumption per encryption operation than AES-128 while maintaining adequate security margins against known attacks. The trade-off between cipher strength and energy cost has been the subject of extensive analysis in the WSN security literature, and the consensus is that AES-128 represents an acceptable balance for most deployment scenarios, particularly when hardware-accelerated AES engines are available on the target microcontroller family."),

      diagramNote("Recommend a bar chart or energy-cost table here (Table 2.4): Energy Consumption per Cryptographic Operation, comparing AES-128, AES-256, HIGHT, PRESENT, and RSA-1024 across Encryption Energy (mJ), Key Schedule Energy (mJ), and Relative Computation Time. This quantitatively motivates the selection of lightweight symmetric schemes for leaf nodes and clarifies the cost of asymmetric alternatives."),

      para("Key management presents a challenge at least as significant as cipher selection. If a single global network key is distributed to all nodes, the compromise of any single node exposes the entire network's traffic to decryption. Hierarchical Key Management schemes address this by pre-distributing tier-specific pairwise keys and deleting the global network key from nodes after initialization, thereby localizing the impact of any single-node compromise to the cluster in which that node resides. The EAHKM+ scheme, for example, pre-distributes hierarchically partitioned pairwise keys and provides a rekeying mechanism that operates without requiring re-distribution of global keying material. ID-based aggregate signature schemes further reduce the bandwidth cost of per-node authentication by allowing cluster heads to aggregate signatures from multiple child nodes into a single compact message before forwarding upstream."),

      para("The proposed architecture implements a layered key structure: a global key is held only by the sink and distributed through a structured five-step locking handshake during network setup. Gateway nodes derive local keys from the global key; cluster heads receive only the local key of their parent gateway node; and leaf sensor nodes operate without cryptographic key material of their own, transmitting plaintext to their cluster head which encrypts using both local and global keys before forwarding. This dual-encryption model confines any breach to a single cluster for any single compromised node. The final bit of each gateway node's local key is additionally repurposed to encode the node's transmission phase in the alternating Tx-Rx chain, eliminating the need for a separate scheduling broadcast and making the backhaul phase schedule cryptographically bound to the key distribution itself. Key validation failures at any tier are immediately visible as trust score events and trigger the daisy-chained polling mechanism described in the attack-detection section."),

      diagramNote("Recommend a hierarchical key distribution diagram here (Figure 2.3): a tree showing the Sink at the root holding the Global Key, branching to Gateway Nodes holding Local Keys, then to Cluster Heads holding CH Keys, and finally to Leaf Nodes (no key material). Annotate with the handshake step numbers (5-step GWN handshake, 3-step CH recruitment, 2-step CH-to-CH). This is a critical explanatory diagram for the cryptographic architecture chapter."),
      spacer(),

      // ─── 2.3 DUAL-RADIO ────────────────────────────────────────────────────────
      new Paragraph({
        heading: HeadingLevel.HEADING_2,
        spacing: { before: 360, after: 180 },
        children: [new TextRun({ text: "2.3  Dual-Radio Architectures", bold: true, size: 28, font: "Times New Roman" })]
      }),

      para("Single-radio WSN architectures face a fundamental design trade-off: the physical properties that enable long-range communication — typically higher transmit power and lower data rates — are in direct tension with the energy efficiency required for intra-cluster, high-frequency sensor reporting. Radios optimized for short-range, high-throughput access communication cannot simultaneously serve as long-range backbone links without incurring prohibitive energy expenditure or unacceptable duty-cycle constraints. Dual-radio architectures resolve this impasse by equipping gateway-tier or cluster-head-tier nodes with two independent transceivers, each selected and configured for its specific traffic class, and decoupling their MAC layers entirely so that contention in one channel does not degrade the other."),

      para("The combination most extensively studied in the literature pairs a short-range IEEE 802.15.4 or Bluetooth Low Energy (BLE) transceiver for intra-cluster access traffic with a LoRa or LoRaWAN transceiver for long-range backbone forwarding. This pairing appears in diverse domains: Ayele et al. demonstrated a BLE-LoRa dual-radio node for wildlife monitoring that exploited BLE for data collection from nearby sensors and LoRa for forwarding aggregated records to a distant base station. The system demonstrated that the two radios could operate concurrently without mutual interference and that the duty-cycle constraint on the LoRa channel did not degrade access-tier performance because the two MAC layers are entirely independent. A related application of dual-radio architectures is the US Patent US10582358B1, which describes a wireless coded communication (WCC) device architecture with dual-radio functions specifically designed to support heterogeneous backhaul and access traffic simultaneously."),

      diagramNote("Recommend a two-panel architecture diagram here (Figure 2.4): Panel (a) showing a single-radio node architecture with a shared RF front-end servicing both access and backbone traffic, and Panel (b) showing the dual-radio node architecture with dedicated access and backbone transceivers connected to independent MAC layers but sharing a common microcontroller and power management subsystem. Annotate the two radios with representative specifications (e.g., IEEE 802.15.4 at 2.4 GHz / 250 kbps and LoRa at 868 MHz / 0.3–50 kbps)."),

      para("The heterogeneous WSN study by Liu et al. demonstrated a ZigBee–LoRa hybrid communication system combining two ZigBee sensor clusters and two LoRa sensor clusters through ZigBee-to-LoRa converter nodes managed by a central LoRa gateway. Token ring protocol governed ZigBee cluster access, while a polling mechanism was applied to the LoRa backbone, demonstrating that hybrid MAC architectures are not only feasible but can achieve packet loss rates below 1% and communication ranges exceeding 3.7 km on the backbone channel — performance characteristics unattainable with any single-radio protocol operating within ISM-band regulatory constraints. This architecture demonstrates that the two traffic classes can be served simultaneously with distinct MAC protocols without mutual degradation, a central design principle of the proposed framework's gateway-node architecture."),

      para("Hardware constraints on the gateway and cluster-head tiers are substantially more demanding than those on leaf nodes as a direct consequence of the dual-radio requirement. The gateway node must manage two independent radio stacks, run both access and backbone MAC protocols concurrently, perform cryptographic operations on upstream data, and execute real-time machine learning inference — all within a power budget that may be supplemented by energy harvesting but must remain sustainable for an unattended operational lifetime. These requirements mandate a processing or co-processing architecture capable of preemptive multithreading via an RTOS, a microcontroller with hardware-accelerated AES support, a large-capacity battery supplemented by a photovoltaic or other energy-harvesting circuit, and dual-radio modules with high-gain external antennas for the backbone link. Leaf nodes, which constitute the majority of any deployment, require none of this specialization: any commercial low-power microcontroller with adequate sleep-scheduling control and memory for the compressed local trust model suffices."),

      diagramNote("Recommend a hardware block diagram here (Figure 2.5) showing the internal architecture of a dual-radio gateway node: MCU with RTOS, hardware AES accelerator, and inference engine at the center; BLE/IEEE 802.15.4 radio module on the access side; LoRa/LoRaWAN module with high-gain antenna on the backbone side; battery and solar/energy-harvesting circuit on the power side. A companion simpler block diagram for a leaf node (MCU, single access radio, battery) emphasizes the hardware tiering of the proposed architecture."),
      spacer(),

      // ─── 2.4 MACHINE LEARNING ──────────────────────────────────────────────────
      new Paragraph({
        heading: HeadingLevel.HEADING_2,
        spacing: { before: 360, after: 180 },
        children: [new TextRun({ text: "2.4  Use of Machine Learning Models for Attack Detection and Prevention", bold: true, size: 28, font: "Times New Roman" })]
      }),

      para("Machine learning has emerged as the most promising approach to WSN intrusion detection because rule-based systems and threshold monitors cannot adapt to the stochastic variation of attack intensities, the gradual drift of node behavior over time, or the combinatorial diversity of multi-attack scenarios. The behavioral signatures of WSN attacks manifest across multiple protocol layers simultaneously: a Flooding attack elevates MAC-layer queue depth, increases retransmission counts, and drains neighboring node batteries; a Sinkhole attack suppresses CH re-election frequency while distorting perceived hop-count distances; a Denial-of-Sleep attack produces residual energy asymmetry inconsistent with the node's reported duty cycle. These multi-layer, correlated signatures are precisely the type of pattern that supervised classifiers excel at learning from labeled historical data, provided a sufficiently rich feature vector is available."),

      para("The multi-layer feature set necessary for WSN attack classification spans four protocol layers. At the Physical layer, received signal strength (RSSI), link quality indicator (LQI), signal-to-noise ratio (SNR), bit error rate (BER), and packet error rate (PER) characterize channel fidelity and signal degradation. At the MAC layer, packet delivery ratio (PDR), end-to-end latency, queue depth, duty cycle, and token holding time expose medium-access efficiency anomalies. At the Network layer, hop count, neighbor count, residual energy, CH re-election frequency, and retransmission counts indicate topological health and energy depletion patterns. At the Security layer, key overhead, rekeying frequency, intrusion event rate, and packet injection count quantify adversarial interaction and network stress. Each parameter maps to a specific attack signature: RSSI drops indicate jamming; anomalous token holding time exposes Blackhole nodes; CH re-election spikes are characteristic of Sinkhole attacks advertising false routes; and residual energy asymmetry across nodes is the fingerprint of Denial-of-Sleep exploitation."),

      diagramNote("Recommend the reproduction of a multi-layer feature table here (Table 2.5): analogous to Table I of the preliminary work — Layer | Parameters (Features) | Analytical Significance — but expanded with additional entries drawn from the Kasasbeh WSN-DS dataset's 23-feature schema, annotating which features contribute to which attack class as established by the RFC feature importance analysis (Figure 5 of the preliminary work). This table serves as a direct reference for the implementation chapter's feature engineering decisions."),

      para("The deployment of machine learning on resource-constrained hardware introduces a critical practical constraint: the full 23-feature vector is infeasible for real-time inference on leaf-tier microcontrollers operating at 16–32 MHz with kilobyte-scale RAM. The literature on embedded machine learning — surveyed in depth by Sakr et al. and by Branco et al. — demonstrates that a compressed feature subset can capture both channel state and behavioral anomaly at negligible runtime overhead, provided the selected features are chosen to maximize discriminative power per computation cycle. For leaf-tier inference, a subset of RSSI, PDR, retransmission count, residual energy, token holding time, and queue depth has been shown to approximate the classification performance of the full-feature model on the dominant attack classes, while fitting within the memory and compute constraints of typical ARM Cortex-M0 or M4 devices. Techniques such as network pruning, fixed-point quantization, and decision tree compression further reduce the memory footprint of the inference model to levels compatible with the 2–32 KB of SRAM available on representative leaf-node MCUs."),

      para("At the global, sink-level inference tier, the compute constraint is lifted and richer models become appropriate. Decision Tree Classifiers (DTC) and Random Forest Classifiers (RFC) have both been evaluated on the Kasasbeh WSN-DS dataset, which logs 23 per-node operational parameters across five behavioral classes: Normal, Blackhole, Grayhole, Flooding, and Scheduling Attack. The DTC achieved 99.48% overall accuracy; the RFC achieved 99.68%. The RFC was selected as the deployed sink-level model because its ensemble of 100 trees eliminates the instability of any individual tree — particularly important under the severe class imbalance present in this dataset, where normal traffic exceeded 90% of samples and the Flooding minority ratio exceeded 100:1 — and its internal feature importance scores provide an interpretable audit trail unavailable from single-tree classifiers without restrictive depth limits. RFC feature importance analysis ranked ADV_S (advertisement send count, 18.3%) as the dominant discriminator, followed by Expended Energy (14.8%), Is_CH flag (12.9%), Data_Sent_To_BS (10.2%), and SCH_S (8.0%), confirming that attack classes are most distinguishable at the control-plane level rather than through raw data throughput."),

      diagramNote("Recommend reproducing the RFC vs. DTC per-class F1 score bar chart here (Figure 2.6), analogous to Fig. 6 of the preliminary work, alongside the RFC feature importance scores (Fig. 5 of the preliminary work). Positioning these figures at this location provides the literature survey with its own empirical grounding and removes the need to forward-reference the results chapter for basic model performance characteristics. Additionally, recommend a confusion matrix table (Table 2.6) for the RFC alone, displaying per-class accuracy figures: Blackhole 99.4%, Flooding 98.1%, Grayhole 98.7%, Normal 99.9%, Scheduling 93.6%, to anchor the quantitative claims made in this section."),

      para("The dual-inference strategy — a lightweight local model at the node level and a comprehensive global model at the sink — addresses the temporal limitations of centralized detection while retaining the statistical power of global network visibility. Local models provide rapid anomaly flagging within the communication round during which the attack occurs, enabling the daisy-chained polling mechanism that isolates and resets suspect nodes before significant data loss accumulates. The global model, continuously updated and recalibrated by the sink, addresses the long-term drift that afflicts any static embedded classifier as the network's normal operating statistics evolve over time with node aging, environmental change, and topology adaptation. This continuous recalibration loop — in which the global model pushes updated local decision boundaries to constrained nodes over the backbone channel — is a critical differentiator of the proposed architecture from prior work that deploys static, training-time-frozen models at the edge and offers no mechanism for in-service adaptation."),
      spacer(),

      // ─── CHAPTER SUMMARY ───────────────────────────────────────────────────────
      new Paragraph({
        heading: HeadingLevel.HEADING_2,
        spacing: { before: 360, after: 180 },
        children: [new TextRun({ text: "Chapter Summary", bold: true, size: 28, font: "Times New Roman", color: "1F3864" })]
      }),

      para("This chapter has established the technical and adversarial context within which the proposed architecture operates. The fundamentals of WSN design reveal a set of structural constraints — broadcast RF medium, uncontrolled physical deployment, energy and memory scarcity — that define the threat surface. The survey of attack classes identifies the specific behavioral signatures that the machine learning models must learn to distinguish. The review of backhaul architectures demonstrates that a dual-radio, hierarchically tiered approach is necessary to decouple access and backbone traffic and eliminate cross-tier interference. The review of encryption standards establishes that hierarchical key management with lightweight symmetric ciphers is the only cryptographically sound and practically feasible approach at the sensor tier. The review of dual-radio architectural patterns confirms the viability of BLE/IEEE 802.15.4 and LoRa pairings for simultaneous access and backbone service. And the review of machine learning for attack detection establishes that a tiered inference architecture — lightweight compressed models at constrained nodes, full Random Forest ensembles at the sink — with continuous recalibration is both necessary and achievable within the hardware constraints of deployable WSN hardware. The proposed architecture integrates these strands into a coherent, self-reconfigurable framework, the design of which is detailed in Chapter 3."),
      spacer(),

    ]
  }]
});

Packer.toBuffer(doc).then(buf => {
  fs.writeFileSync('/home/claude/chapter2_literature_review.docx', buf);
  console.log('Done.');
});