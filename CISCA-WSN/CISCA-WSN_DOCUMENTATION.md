# CISCA-WSN — Packet Trace Postprocessor
## Complete System Documentation

---

## 1. What Is This?

CISCA-WSN is a **post-processing** tool for WSN7_Modular simulation runs. It reads the CSV log files produced at the end of a completed simulation, reconstructs the full lifecycle of every transmitted message, and presents three levels of analysis through a PySide6/pyqtgraph GUI:

| Level | What it answers |
|---|---|
| **System** | How did the network behave over time? Where did attacks land? |
| **Node** | What did each node send, receive, drop, and how fast did its battery drain? |
| **Message** | Where did this specific packet go, where was it dropped, and why? |

It is a **read-only, offline** tool. It never connects to a running simulation and never modifies any file. The only inputs are the CSVs the simulator already writes to `WSN7_Modular/logs/`.

---

## 2. Repository Layout

```
CISCA-WSN/
├── cisca_gui.py                ← top-level launcher (python cisca_gui.py [logs_dir])
├── requirements.txt
└── cisca/
    ├── __init__.py
    ├── __main__.py             ← python -m cisca [logs_dir]
    ├── config.py               ← tuneable constants
    ├── run_discovery.py        ← groups log chunks into simulation runs
    ├── parser.py               ← CSV → tidy events DataFrame
    ├── reconstruct.py          ← TX/RX pairing → hops table + message traces
    ├── analytics.py            ← AnalyticsEngine (all metrics)
    └── gui/
        ├── __init__.py
        ├── main_window.py      ← QMainWindow, sidebar, background worker
        ├── system_tab.py       ← System Level tab
        ├── node_tab.py         ← Node Level tab
        └── message_tab.py      ← Message Level / trace tab
```

---

## 3. Data Pipeline

```
WSN7_Modular simulation
        │
        ▼  writes to logs/
┌──────────────────────────────────────────────────────────────┐
│  combined_t0-250_YYYYMMDD_HHMMSS.csv   (chunk 1)            │
│  combined_t0-500_YYYYMMDD_HHMMSS.csv   (chunk 2)            │
│  ...                                                         │
│  combined_t0-2000_YYYYMMDD_HHMMSS.csv  (final chunk)        │
│  attack_log_YYYYMMDD_HHMMSS.csv        (if attack was active)│
│  sink_nodeRegistry_t0-2000_*.csv       (optional)            │
└──────────────────────────────────────────────────────────────┘
        │
        ▼  run_discovery.py
  RunFiles(run_id, chunks=[…], attack_log=…)
        │
        ▼  parser.parse_combined(chunks)
  events DataFrame  (~800K rows for a 2000-tick 40-node run)
  Columns: node_hex, node_type, tier, channel, t, tags, tag,
           rest, msgtype, subtype, src, dst, bat, rssi, …
        │
        ▼  reconstruct.pair_hops(events)
  hops DataFrame  (one row per TX event)
  Columns: tx_idx, t, src, msgtype, subtype, dst,
           received, rx_t, rx_node, rx_tag, n_receivers
        │
        ▼  reconstruct.classify_not_received(hops, events, attack_log)
  hops with drop_reason column filled for unmatched TX rows
        │
        ▼  reconstruct.build_message_traces(hops, events)
  traces: list[dict]  — each dict has {msgtype, origin_node,
                         origin_t, path: [stage,…], terminal}
        │
        ▼  analytics.AnalyticsEngine(events, hops, traces, attack_log)
  Engine ready — all GUI queries are O(1) reads from this object
```

---

## 4. Component-by-Component Reference

### 4.1 `config.py`

All tunable constants in one place.

| Constant | Default | Meaning |
|---|---|---|
| `HOP_MATCH_WINDOW_TICKS` | 60 | Max ticks between a TX and its paired RX |
| `AGG_LINK_WINDOW_TICKS` | 120 | Window to link a SENSOR_RX to the CH's next AGG batch |
| `SYSTEM_BUCKET_TICKS` | 50 | Default time-bucket size for system timeseries |
| `COMPACT_TYPES` | `{HELLO, HB, TOKEN}` | Message types shown as vectors, not individual traces |
| `COMPACT_TAGS` | `{PHASE, PHASE_TX, …}` | Log tags treated as scheduling chatter, not data messages |
| `MSG_TYPE_NAMES` | `{0:HELLO, 1:SENSOR, …}` | Integer type → name mapping |
| `TIER_NAMES` | `{0:SINK, 1:GWN, 2:CH, 3:SENSOR}` | Tier number → label |
| `RUN_TERMINAL_TOLERANCE_SECONDS` | 90 | How close in wall-time an attack_log must be to its run's last chunk |

---

### 4.2 `run_discovery.py`

**Problem it solves:** A single simulation does not produce one log file. `WSN_Main.m` clears its in-memory log buffer every `AUTOLOG_INTERVAL` (250 ticks by default) and writes a new chunk file with a monotonically-increasing tick number in its name. Multiple separate runs (different seeds, different attack configs) leave interleaved files in the same directory.

**How it works:**
1. Collects all `combined_t0-NNN_TIMESTAMP.csv` files, sorts chronologically.
2. Walks the list; when the tick number does not strictly increase (e.g., `t0-2000` followed by another `t0-250`), a new run starts.
3. For the terminal files (`attack_log_*`, `local_features_*`, `sink_features_*`) it matches the file whose timestamp falls within `RUN_TERMINAL_TOLERANCE_SECONDS` after the run's last chunk — because these are written a few seconds after the final chunk.
4. Sink node/sensor registries use an **exact timestamp match** since multiple completed runs can share the same final tick count.

**Output:** `list[RunFiles]` sorted newest-first, each with `.combined_chunks`, `.attack_log`, `.sink_node_registry`, etc.

---

### 4.3 `parser.py`

Converts raw CSV rows into a structured, deduplicated `events` DataFrame. Key design points:

**Stage 1 — generic line split (vectorised, single regex pass):**
Every log line is of the form `t=NNN [TAG1][TAG2]... rest` (or `[TAG1][TAG2]... rest` for lines with no timestamp). The split regex extracts `t`, the bracket chain, and `rest` for every one of the ~800K rows in one vectorised `.str.extract()` call. Zero unmatched lines were found across the full empirical survey (`shape_report.txt`).

**GWN/SINK dual-radio deduplication:**
GWN and SINK nodes log each event twice — once to their native `BACKBONE`/`ACCESS` channel, and once to a `UNIFIED` channel with a `[BB]`/`[AC]` prefix. The parser drops all `UNIFIED` rows whose tag chain is exactly `[BB]` or `[AC]`, eliminating the duplicate without losing any information.

**Stage 2 — per-tag structured extraction:**
`TAG_PATTERNS` maps 40+ primary tags to compiled regexes with named capture groups (e.g., `TX` → `msgtype, subtype, dst`; `HELLO_TX` → `bat, nbr`). Each pattern is applied once as a vectorised `.str.extract()` on its matching subset. Tags without a registered pattern are retained as `(tag, rest)` pairs for raw event timelines.

**Timestamp inference:**
Radio lock lines (`[LOCK][SET]`, `[DROP][LOCK]`) are logged via `logLocal()` with no `t=` prefix. Their timestamps are filled forward within each `(node_hex, channel)` block using `ffill()` after sorting by append-order (`row_order`).

---

### 4.4 `reconstruct.py`

**TX normalisation:**
Builds a unified TX frame from seven distinct log tag families (`TX`, `PHASE_TX`, `SENSOR_TX`, `HELLO_TX`, `PANIC_TX`, `5.2_TX`, `5.3_TX`), each with slightly different field layouts, into a common schema `(idx, t, src, msgtype, subtype, dst, is_broadcast)`.

**RX normalisation:**
Similarly for `RX`, `RX_FWD`, `SENSOR_RX`, `HELLO_RX`, `HELLO`, `PANIC_RX`, `5.2_RX`, `5.3_RX`.

**Hop pairing — the core algorithm:**

Since no message carries a logged unique ID (`msg.uid` is in-memory only and never written to CSV), pairing relies on structural uniqueness:

- **Unicast:** `pd.merge_asof(rx, tx, on="t", by=["msgtype","subtype","src","dst"], direction="backward", tolerance=HOP_MATCH_WINDOW_TICKS)` — each RX is matched to the nearest prior unconsumed TX on the same `(type, subtype, src, dst)` tuple within the window. For retry sequences, this correctly attributes an RX to the most recent attempt, not an abandoned earlier one.
- **Broadcast:** Same join but without the `dst` key, so one TX row may match multiple RX rows (fan-out).
- **Unicast dedup:** A single-delivery unicast TX keeps only its earliest matching RX; broadcast keeps all.

**Drop reason classification:**
For every TX row without a matched RX, `classify_not_received()` checks, in priority order:
1. Was the attacker active at the intended receiver around that tick? (`attack_log`)
2. Did the receiver log a `CHK_DROP` (checksum fail) near that tick?
3. Did the receiver have a radio lock contention (`[DROP][LOCK]`) near that tick?
4. Was the receiver in `ORPHAN_MODE` (asleep/disconnected) near that tick?
5. Otherwise: "unknown (out of range / fade)".

**Message trace building:**
`build_message_traces()` chains hop-pairs into end-to-end paths:
- Each TX hop is a potential chain start.
- `RX_FWD` → look for the next outbound TX of the same type at the receiving node within `AGG_LINK_WINDOW_TICKS` (relay continuation).
- `SENSOR_RX` → link to that CH's next `AGG "Creating"` event (aggregation absorption).
- All other RX → terminal.
- Max chain depth: 6 hops (configurable via `MAX_HOPS`).

---

### 4.5 `analytics.py — AnalyticsEngine`

Wraps the events/hops/traces into a queryable object. All heavy computation happens at construction time; GUI queries are fast reads.

**Precomputed structures (built once at `__init__`):**

| Structure | What it is |
|---|---|
| `_bat_all` | Battery readings from all nodes (SENSOR_TX/HELLO_TX bat fields), sorted by (node_hex, t) |
| `_node_info` | Unique (node_hex, node_type, tier) table sorted by tier then hex |
| `_rx_exploded` | Hops frame exploded on `rx_node` (handles list-valued broadcast receivers), enables O(1) per-node RX count queries |
| `_system_ts` | Per-bucket system timeseries (cached, keyed on `_system_ts_bsz`) |
| `_attack_infos` | `list[AttackInfo]` — one per (attacker, attack_type) pair |
| `_attack_effect` | `AttackNetworkEffect` — PDR before/during/after + victim count + drops |

**Public API:**

```python
engine.node_list                              # [(hex, type, tier)]
engine.get_system_timeseries(bucket_size)     # DataFrame with 13 columns
engine.get_overall_stats()                    # dict: PDR, latency, battery, …
engine.get_attack_infos()                     # list[AttackInfo]
engine.get_attack_effect()                    # AttackNetworkEffect | None
engine.get_battery_history(node_hex)          # DataFrame: t, bat
engine.get_tx_counts(node_hex)                # Series: msgtype → count
engine.get_rx_counts(node_hex)                # Series: msgtype → count (fast)
engine.get_drop_stats(node_hex)               # dict: reason → count
engine.get_delivery_latency(node_hex)         # DataFrame: msgtype, count, avg_latency_ticks
engine.get_hello_compact(node_hex)            # dict: tx_times, sent_rx_by_t, rx_summary
engine.get_sleep_intervals(node_hex)          # [(t_in, t_out_or_None)]
engine.get_attack_victim_info(node_hex)       # dict | None
engine.get_traces(node_hex, msg_type, t_lo, t_hi, compact_types)  # list[dict]
engine.get_available_msg_types()              # list[str]
```

---

### 4.6 GUI — `main_window.py`

**Background parse worker (`_ParseWorker`):**
Loading a run with 8 chunk files and ~800K rows takes ~30–60 seconds on a typical machine (measured: 32.56s at 24,701 rows/s in the empirical run). The worker runs in a `QThreadPool` thread so the GUI never freezes. It emits three signals:
- `progress(str)` → shown in the status bar
- `done(AnalyticsEngine)` → triggers all three tabs to load
- `error(str)` → shows a QMessageBox and re-enables the sidebar

**Run selector sidebar:**
- Browse button opens a `QFileDialog` to pick a `logs/` directory.
- `discover_runs()` finds all runs; they appear in a list newest-first with `⚠ ` prefix if an attack log was found.
- `[Load Selected Run]` dispatches the background worker.

---

### 4.7 GUI — `system_tab.py` (System Level)

**Summary cards (top row):**
Total Nodes | Sim Ticks | Total Messages | PDR | Avg Latency (ticks) | Avg Final Battery %

**Time series chart (centre):**
pyqtgraph `PlotWidget` with one `PlotDataItem` per metric. Each series is toggle-able via a checkbox row.

| Series | Colour | Default on |
|---|---|---|
| Active Nodes | Blue | ✓ |
| TX Nodes | Green | ✓ |
| RX Nodes | Amber | ✓ |
| Sleeping Nodes | Purple | ✗ |
| Corrupt Events | Red | ✗ |
| Avg Battery % | Cyan | ✓ |
| PDR (0–1) | Green | ✓ |
| Avg Latency (ticks) | Orange | ✗ |

Attack-active time windows are shaded red-transparent via `LinearRegionItem`. Bucket size is adjustable (10–500 ticks) via a spinner; the timeseries is recomputed and redrawn when it changes.

**Attack panel (bottom, hidden if no attack):**
- Per-attacker table: attacker hex/index, attack type, start/end ticks, event count, most common action, events-per-tick intensity.
- Network effect cards: Messages Dropped (by attack), Victim Nodes, PDR Before / During / After.

---

### 4.8 GUI — `node_tab.py` (Node Level)

**Left: tier-grouped node tree**
Nodes are organised under tier headers (SINK / GWN / CH / SENSOR), each in its tier colour. Clicking a node loads the detail panel.

**Right: `NodeDetailPanel` (scrollable)**

In order top to bottom:
1. **Node header:** `Node  AABB  [SENSOR]` in tier colour.
2. **Summary cards:** Messages TX, Messages RX, Dropped (sent), Delivery Rate, Avg Latency, Last Battery %.
3. **TX/RX bar charts:** Two side-by-side `BarGraphItem` pyqtgraph charts showing counts by message type.
4. **Drop reasons table:** What caused this node's transmitted messages to be undelivered.
5. **Delivery latency table:** Per message type: count and average latency to immediate next hop.
6. **Battery sparkline:** Line plot of battery % vs. tick.
7. **HELLO compact section:**
   - Summary line: total TX count, tick range summary, unique receivers list.
   - Table of HELLOs **received** at this node from other senders: sender hex, count, first/last tick.
8. **Sleep/Orphan intervals:** Table of enter/exit times and durations.
9. **Attack involvement section** (hidden unless applicable): Shows role (Attacker / Victim), attack types, action breakdown for attackers, or drop count for victims.

---

### 4.9 GUI — `message_tab.py` (Message Level)

**Left: filter controls**
- Message type dropdown (populated from `get_available_msg_types()`).
- Origin node hex filter (free text).
- Time range (t_lo / t_hi).
- Checkbox: "Show compact messages as HELLO section" — when enabled, HELLO/HB/TOKEN are excluded from the main trace list and shown in the compact panel instead.

**Message list table:** Columns: `t | Origin | Type | Destination | Terminal`. Terminal stage is colour-coded (green = delivered, red = not received, amber = queued/partial).

**Right: Path trace tree (`PathTree`)**
On selecting a message:
```
TX  CH_HELLO.1  →  FF0D   (t=228)
  RX  at FF03   (t=228)
    FWD  →  FF0D   (t=228)
      RX  at FF0D   (t=231)
        ✔ Received   (t=231)   FF0D
```
Each stage is a QTreeWidget item colour-coded by kind. The full tree is auto-expanded.

**HELLO compact panel (`HelloCompactPanel`)**
When the compact toggle is on and an origin node is filtered:
- Summary line: total HELLOs, unique receiver count, receiver hex list.
- Table: per time-bucket (configurable), HELLOs sent and unique receivers reached.

---

## 5. How to Run

### Install dependencies
```
pip install pandas>=2.0 numpy>=1.24 pyside6>=6.5 pyqtgraph>=0.13
```

### Launch
```
# Option A: from the CISCA-WSN/ directory
python cisca_gui.py ..\logs

# Option B: as a module
python -m cisca ..\logs

# Option C: no argument — use Browse in the GUI
python cisca_gui.py
```

### Workflow
1. Run a simulation in WSN7_Modular (GUI or headless via `WSN_Attack_Demo.m`).
2. Open CISCA-WSN, Browse to `WSN7_Modular/logs/`.
3. Select a run from the list — runs with attacks show `⚠`.
4. Click **Load Selected Run** and wait (~30–60s for a 2000-tick run).
5. Navigate System / Node / Message tabs.

---

## 6. Strengths

### S1 — Zero instrumentation required
The tool derives everything from logs the simulator already writes. No changes to WSN7_Modular's MATLAB code are needed, and no special logging mode must be enabled. Any completed simulation run is automatically analysable.

### S2 — Complete message type coverage
All message types are tracked — not just sensor data packets, but also HELLO beacons, PANIC alerts, CH_HELLO aggregations, handshake commands (CH_REQ/CH_ACK/KEY_ACK), census polls, and shutdown/update control messages. The hop-pairing engine normalises seven different TX/RX log tag families into one unified schema.

### S3 — Dynamically built message paths
Paths are not hardcoded to expected routes. The reconstruct engine follows relay chains (`RX_FWD`), aggregation absorption (`SENSOR_RX` → `AGG`), and direct delivery independently, so unusual or attack-disrupted paths are captured correctly without any prior assumptions about network topology.

### S4 — Drop reason classification
Undelivered messages are not just counted — they are attributed to one of five cause categories (attacker active, checksum corruption, radio lock contention, receiver asleep/orphaned, unknown/fade). This is done by cross-referencing the attack log and the receiver's event stream around the transmission tick.

### S5 — PDR before/during/after attack
For runs with an attack log, the engine computes three distinct PDR values using the attack's start/end ticks as boundaries. This quantifies network degradation directly attributable to the attack window.

### S6 — HELLO compact display
With hundreds of thousands of HELLO broadcast events in a typical run, showing them individually would be unusable. CISCA-WSN groups them into per-bucket vectors (count sent, unique receivers reached) and into per-sender reception tables, preserving all information in a usable form.

### S7 — Non-blocking GUI
All parsing and reconstruction work runs in a `QThreadPool` background thread with progress signals. The GUI remains responsive while loading 70+ MB log files. The main window is re-enabled as soon as the `AnalyticsEngine` is ready.

### S8 — Dual-radio GWN/SINK log deduplication
GWN and SINK nodes write every event to both their native channel (BACKBONE/ACCESS) and a UNIFIED mirror. The parser automatically detects and drops the duplicates using the `[BB]`/`[AC]` prefix convention, ensuring event counts are accurate without any configuration.

### S9 — Multi-run awareness
The run discovery engine correctly handles multiple simulation runs sharing the same `logs/` directory, including runs with the same final tick count, by using exact timestamp matching for registry files and a time-window heuristic for terminal exports.

### S10 — Attack attacker/victim classification
The Node tab automatically identifies whether a node is an attacker, a direct victim (messages it sent were dropped due to attack), or uninvolved, and renders a dedicated panel only when relevant.

---

## 7. Weaknesses and Known Limitations

### W1 — No unique message ID in logs (core limitation)
**Impact: HIGH — affects all trace accuracy**

`msg.uid` exists in memory during simulation but is never written to any log file. Hop pairing therefore relies on `(msgtype, subtype, src, dst)` + time proximity (`HOP_MATCH_WINDOW_TICKS`). In normal network conditions this is sufficient because the simulator is single-threaded and FIFO-ordered within any `(src, dst, type)` flow.

However, in high-collision scenarios — notably during Flooding or Panic-Flood attacks that send many messages of the same type to the same destination in rapid succession — multiple TX events may have identical keys within the window. The merge_asof will pair each RX with the nearest prior TX, which is correct for the most-recent-attempt semantics but cannot distinguish whether two different messages with identical signatures crossed in the air. Trace accuracy degrades proportionally to flooding intensity.

**Fix:** Add a `uid` column to `WSN_Main.m`'s combined-log export (one line change). This would make hop pairing exact.

---

### W2 — Attacker-to-hex mapping depends on sink registry availability
**Impact: MEDIUM — affects attack panel display**

`attack_log_*.csv` records `NodeIdx` (MATLAB 1-based array index), not the node's hex address. The hex mapping is only available if `sink_nodeRegistry_t0-*.csv` is present in the logs and contains matching index/hex columns. When the registry is absent (partial run, registry not yet exported), attackers appear as `#1`, `#2`, etc. in the attack panel rather than by hex address.

No automated lookup or fallback synthesis is attempted.

---

### W3 — Drop reason classification is best-effort
**Impact: MEDIUM — affects "Not Received" attribution accuracy**

`classify_not_received()` checks the receiver's event stream within `HOP_MATCH_WINDOW_TICKS` of the TX tick. This is a correlation heuristic, not a causal chain. Specific gaps:
- A CHK_DROP at the receiver might be from a *different* message than the unmatched TX.
- Radio lock contention is detected from `[DROP][LOCK]` tags, but these have `t_inferred` (no explicit timestamp) and may be off by up to one tick.
- "Receiver asleep" only detects sleep via `ORPHAN_MODE`; a node that stopped transmitting due to battery death has no such tag.
- Rayleigh fading / out-of-range (the actual physical drop) cannot be directly inferred from logs — it always falls through to "unknown (out of range / fade)".

---

### W4 — Battery data missing for GWN and SINK nodes
**Impact: LOW-MEDIUM — affects battery sparkline and avg_battery system chart**

Battery readings are extracted from `SENSOR_TX` and `HELLO_TX` log tags which carry `bat=N%` fields. GWN and SINK nodes do not emit `SENSOR_TX` and emit HELLO via a different code path. Their battery history may be sparse or absent in the sparkline and the `avg_battery` system series.

---

### W5 — Aggregation chains are one level deep
**Impact: MEDIUM — affects sensor message traces**

When a sensor's data arrives at a CH, the trace appends a "Clustered/Aggregated (batch=K sensors)" stage and terminates. The subsequent CH→GWN→SINK path for that batch is **not** chained back into the same trace — because the 5.2 fragment carries no reference to its constituent sensor readings. The hop-pairing engine correctly traces the 5.2 fragment as its own separate trace (CH origin → GWN → SINK), but the two traces are not linked.

A full end-to-end sensor-to-sink path — `SENSOR TX → CH RX → Aggregated → 5.2 TX → GWN RX → 5.2 TX → SINK RX → Terminated` — is therefore split across two separate trace objects in the Message tab.

---

### W6 — System timeseries is not fully vectorised (per-bucket Python loop)
**Impact: LOW — 1–3 second recompute when user adjusts bucket size**

The current `get_system_timeseries()` implementation assigns bucket IDs with pandas vectorised operations but then iterates over bucket values in a Python `for` loop, performing one `groupby.get_group()` per bucket per sub-frame. For a 2000-tick simulation at default bucket size 50 (40 buckets), this is negligible. At very small bucket sizes (e.g., 10) on large logs it can take 2–4 seconds.

A fully vectorised version using `.groupby("bucket").agg(...)` on the entire frame would eliminate this loop. The current version was chosen for clarity; the loop is the natural bottleneck to replace if responsiveness at small bucket sizes becomes a requirement.

---

### W7 — Message trace depth capped at 6 hops
**Impact: LOW in current network, MEDIUM in larger networks**

`build_message_traces()` follows relay chains up to `MAX_HOPS = 6` levels deep (hardcoded in `reconstruct.py`). For the current 40-node, 4-tier network this is generous — practical paths are 3–4 hops at most (Sensor→CH→GWN→SINK). In a larger multi-hop network where CHs relay through multiple GWNs, traces may be truncated with terminal "Queued for forward, not observed leaving" if the chain exceeds 6 links. Increasing `MAX_HOPS` in `reconstruct.py` is safe but linearly increases trace build time.

---

### W8 — No delivery-to-sink latency
**Impact: MEDIUM — a key requested metric is absent**

The `get_delivery_latency()` method reports only the **immediate next-hop** latency (TX tick → first RX tick at the next node). End-to-end latency from the originating sensor to the SINK, summed across all hops, is not computed, primarily because the aggregation chain split (W5) makes it non-trivial to link a sensor reading to the SINK's eventual acknowledgement. Average per-hop latency is a reasonable proxy but understates true end-to-end delay.

---

### W9 — No export or report generation
**Impact: LOW — post-session work is manual**

There is no "Export CSV", "Save PDF", or "Copy to clipboard" functionality. All analysis must be done interactively within the GUI window. Screenshots are the only way to capture findings.

---

### W10 — No multi-run comparison
**Impact: LOW — comparison across attack intensities is manual**

Each loaded run replaces the previous one in all three tabs. Comparing PDR across a grid of attack intensities (as `WSN_Attack_Demo.m` produces) requires loading each run individually and recording observations manually. A comparison mode (select two runs, diff their system timeseries) does not exist.

---

### W11 — `5.2_RX` diagnostic lines not hop-paired
**Impact: LOW — affects aggregate fragment trace completeness**

65% of `5.2_RX` log lines are "Aggregated N sensors from..." diagnostics that do not match the hop-pairing regex (as confirmed in `validate_report.txt`). Only the "from XXXX frag N/M; sending ACK" variant is hop-paired. The diagnostic lines are retained as raw events (usable for per-node raw timelines) but contribute nothing to the 5.2-fragment trace chain.

---

## 8. Data Structures Reference

### `events` DataFrame columns (post-parse)

| Column | Type | Description |
|---|---|---|
| `node_hex` | str | 4-char hex node address |
| `node_type` | str | CH / GWN / SENSOR / SINK |
| `tier` | int | 0=SINK 1=GWN 2=CH 3=SENSOR |
| `channel` | str | UNIFIED / BACKBONE / ACCESS |
| `t` | int | Simulation tick (ffilled for lock lines) |
| `t_inferred` | bool | True if t was ffilled (no explicit t= prefix) |
| `tag` | str | Primary tag (e.g. TX, HELLO_RX, AGG) |
| `tag2`, `tag3` | str | Secondary/tertiary tags in bracket chain |
| `rest` | str | Raw text after the tag chain |
| `msgtype` | str | Extracted message type name |
| `subtype` | str | Extracted subtype number |
| `src`, `dst` | str | Source/destination hex |
| `bat`, `batf` | str | Battery percentage (HELLO_TX, SENSOR_TX) |
| `rssi` | str | RSSI value |
| `val` | str | Sensor value |
| … | … | Additional tag-specific fields |

### `hops` DataFrame columns (post-pair_hops + classify)

| Column | Type | Description |
|---|---|---|
| `tx_idx` | int | Index of the TX row in `events` |
| `t` | int | TX tick |
| `src` | str | Transmitting node hex |
| `msgtype`, `subtype` | str | Message type/subtype |
| `dst` | str | Intended destination (or `<BCAST>`) |
| `is_broadcast` | bool | True for broadcast transmissions |
| `received` | bool | Whether a matching RX was found |
| `rx_t` | float | Tick of first matching RX (NaN if not received) |
| `rx_node` | list[str] | Receiving node(s) (list for broadcast fan-out) |
| `rx_tag` | list[str] | RX tag(s) used for matching |
| `n_receivers` | int | Number of receivers (broadcasts) |
| `drop_reason` | str | Filled only when `received=False` |

### `AttackInfo` fields

| Field | Description |
|---|---|
| `attack_type` | Integer type (mirrors WSN_Attack.m constants 1–7) |
| `attack_type_name` | Human readable: "Black Hole", "Sybil", etc. |
| `attacker_idxs` | MATLAB NodeIdx list for this (node, type) group |
| `attacker_hexes` | Hex addresses (or `#N` if registry unavailable) |
| `start_t`, `end_t` | First and last tick in attack log for this attacker |
| `event_count` | Total ground-truth entries logged |
| `actions` | `{action_string: count}` (e.g. `{"DROP": 412, "INJECT": 55}`) |
| `intensity_proxy` | `event_count / (end_t - start_t)` — events per active tick |

### `AttackNetworkEffect` fields

| Field | Description |
|---|---|
| `msgs_dropped_by_attack` | TX hops where drop_reason starts with "attacker active" |
| `victim_node_hexes` | Sorted list of nodes whose messages were dropped |
| `pdr_overall` | PDR across entire simulation |
| `pdr_before` | PDR in ticks [0, atk_start) |
| `pdr_during` | PDR in ticks [atk_start, atk_end] |
| `pdr_after` | PDR in ticks (atk_end, t_max] |
| `atk_start_t`, `atk_end_t` | Attack window boundaries from the attack log |

---

## 9. Attack Type Reference

| ID | Name | Tier | What it does to the network |
|---|---|---|---|
| 1 | Hello Flood | SENSOR | Broadcasts excessive HELLO beacons, draining neighbours' radios |
| 2 | Panic Flood | SENSOR | Injects false PANIC alerts, congesting the panic relay chain |
| 3 | Sybil | SENSOR/CH/GWN | Claims multiple identities to manipulate routing decisions |
| 4 | Black Hole | CH | Accepts all traffic, silently drops all forwarded data |
| 5 | Wormhole | CH | Tunnels packets between two distant colluding nodes |
| 6 | Selective Forwarding | CH | Forwards some fraction of packets, drops others (gray hole) |
| 7 | Denial of Sleep | CH | Keeps target sensors awake via repeated traffic, draining battery |

---

## 10. Extension Points

| What to add | Where to change |
|---|---|
| New message type from MATLAB | Add regex to `TAG_PATTERNS` in `parser.py`; add to `TX_SOURCE_TAGS`/`RX_SOURCE_TAGS` in `reconstruct.py` |
| New drop reason | Add check in `classify_not_received()` in `reconstruct.py`, before the final `return "unknown"` |
| New node-level metric | Add a `get_*()` method to `AnalyticsEngine`; wire into `NodeDetailPanel.load_node()` |
| New attack type | Add entry to `ATTACK_TYPE_NAMES` in `analytics.py` |
| Export to CSV/PNG | Add a toolbar button + `QFileDialog` in `system_tab.py`/`node_tab.py`; `pg.exporters.ImageExporter` for charts |
| Multi-run comparison | Add a second `RunFiles` slot in the sidebar; pass two engines to a new `CompareTab` |
| Fix unique message ID | Add `uid` to `WSN_Main.m`'s log export; parser extracts it; `pair_hops()` can then use it directly |
