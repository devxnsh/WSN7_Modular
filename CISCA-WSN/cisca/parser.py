"""Parses WSN7_Modular combined_t0-*.csv log chunks into a tidy `events` DataFrame.

Grounded in an exhaustive empirical scan of a real 1.1M-line / 73MB run
(8 chunk files) that found 293 distinct (tag-chain, line-shape) pairs with
ZERO unmatched lines under the generic split regex used below -- see
explore_shapes.py / shape_report.txt for the source survey. Two structural
findings from that survey drive this parser's design:

1. GWN/SINK nodes run dual-radio logging (Backbone + Access). Every event
   logged via addLogBackbone()/addLogAccess() (GWN/WSN_Gateway.m:437-457) is
   written to its native BACKBONE/ACCESS channel row AND duplicated into the
   UNIFIED channel verbatim with a "[BB] "/"[AC] " text prefix. Empirically
   confirmed exact: 29398+14593 "[BB] t=.. [PHASE_RX] Listening.." UNIFIED
   rows == 43991 native "[PHASE_RX] Listening.." BACKBONE rows, to the digit.
   So any UNIFIED row whose tag-chain is exactly "[BB]" or "[AC]" is a pure
   duplicate and is dropped, not parsed further.
2. The arrow separator is ASCII "->" almost everywhere but a handful of call
   sites (REJ_PARENT, the BOOT->DISCOVERY STATE line) use the unicode "->"
   glyph (U+2192) instead -- found 6 occurrences in the 1.1M-line survey.
   Regexes that need an arrow match both via a character class.
"""
from __future__ import annotations

import re
from pathlib import Path

import pandas as pd

ARROW = r"(?:->|→)"
HEX = r"[0-9A-Fa-f]{4}|<BCAST>"

# ---------------------------------------------------------------------------
# Stage 1: generic line split -- t / tag-chain / rest. Vectorized, single
# pass, matches all 293 known shapes (0 unmatched in the empirical survey).
# ---------------------------------------------------------------------------
_SPLIT_RE = re.compile(r"^(?:t=(?P<t>\d+) )?(?P<tags>(?:\[[^\]]*\])+)\s?(?P<rest>.*)$")

# ---------------------------------------------------------------------------
# Stage 2: per-tag structured extraction on `rest`. Each entry: tag chain
# (first bracket, or first+second for the [LOCK] family) -> compiled regex
# with named groups. Only tags relevant to message-lifecycle reconstruction,
# drop/queue accounting, and node lifecycle/battery get full structured
# extraction; everything else still survives as (tag, rest) for the raw
# per-node event timeline.
# ---------------------------------------------------------------------------
TAG_PATTERNS: dict[str, re.Pattern] = {
    # --- TX / RX core ---
    "TX": re.compile(rf"^(?P<msgtype>\w+)\.(?P<subtype>\d+) {ARROW} (?P<dst>{HEX})$"),
    "RX": re.compile(
        rf"^(?:(?P<msgtype>\w+)(?:\.(?P<subtype>\d+))? <- (?P<src>{HEX})(?: RSSI=(?P<rssi>-?\d+\.?\d*))?"
        rf"|PARENT_REJECT from (?P<rej_src>[0-9A-Fa-f]{{4}}); trying next)$"
    ),
    "RX_FWD": re.compile(
        rf"^Encrypted (?P<msgtype>\w+)\.(?P<subtype>\d+) from Child (?P<child>[0-9A-Fa-f]{{4}}) "
        rf"{ARROW} Queue for Parent (?P<parent>{HEX})$"
    ),
    "SENSOR_TX": re.compile(
        rf"^val=(?P<val>\d+) bat=(?P<bat>\d+)% pri=(?P<pri>\d+) {ARROW} (?P<dst>{HEX})$"
    ),
    "SENSOR_RX": re.compile(
        r"^(?P<action>NEW|UPDATE) (?P<src>[0-9A-Fa-f]{4}) val=(?P<val>\d+) bat=(?P<bat>\d+)%"
        r"(?: \(table=(?P<table>\d+) sensors\))?$"
    ),
    "HELLO_TX": re.compile(
        r"^(?:bat=(?P<bat>\d+)% nbr=(?P<nbr>\d+)|bcast battery=(?P<batf>\d+\.?\d*)%)$"
    ),
    "HELLO_RX": re.compile(
        r"^NEW (?P<src>[0-9A-Fa-f]{4}) tier=(?P<tier>\d+)\((?P<tiername>\w+)\) "
        r"verified=(?P<verified>\d) rssi=(?P<rssi>-?\d+\.?\d*)$"
    ),
    "HELLO": re.compile(r"^NEW (?P<src>[0-9A-Fa-f]{4}) tier=(?P<tier>\d+) verified=(?P<verified>\d)$"),
    "PANIC_TX": re.compile(
        rf"^(?:type=(?P<ptype>\d+) sev=(?P<sev>\d+) val=(?P<val>\d+) {ARROW} (?P<dst>{HEX})"
        rf"|LINK_LOSS broadcast)$"
    ),
    "PANIC_RX": re.compile(
        r"^(?:\*\*\* ANOMALY \*\*\* sev=(?P<sev>\d+) from=(?P<src>[0-9A-Fa-f]{4}) orig=(?P<orig>[0-9A-Fa-f]{4}) val=(?P<val>\d+)"
        r"|sev=(?P<sev2>\d+) from=(?P<src2>[0-9A-Fa-f]{4}) TTL=(?P<ttl2>\d+)"
        r"|\*\*\* EMERGENCY \*\*\* orig=(?P<orig3>[0-9A-Fa-f]{4}) sev=(?P<sev3>\d+))$"
    ),
    "PANIC_FWD": re.compile(
        rf"^(?:{ARROW} parent (?P<parent>[0-9A-Fa-f]{{4}}) \(TTL=(?P<ttl>\d+)\)"
        rf"|{ARROW} broadcast \(TTL=(?P<ttl2>\d+)\)"
        rf"|orig=(?P<orig>[0-9A-Fa-f]{{4}}) val=(?P<val>\d+) {ARROW} parent TTL=(?P<ttl3>\d+))$"
    ),
    "PANIC_DROP": re.compile(
        r"^(?:TTL expired from (?P<src>[0-9A-Fa-f]{4})|Low trust \((?P<trust>-?\d+\.?\d*)\) from (?P<src2>[0-9A-Fa-f]{4}))$"
    ),
    # --- phase-scheduled TX/RX (GWN dual-radio relay) ---
    "PHASE_TX": re.compile(
        rf"^(?:Sent (?P<msgtype>\w+)\.(?P<subtype>\d+) {ARROW} (?P<dst>{HEX}) \(Q_fwd=(?P<qfwd>\d+); Q_local=(?P<qlocal>\d+)\)"
        rf"|IDLE \(queues empty\))$"
    ),
    "PHASE_RX": re.compile(r"^Listening \(Q_fwd=(?P<qfwd>\d+); Q_local=(?P<qlocal>\d+)\)$"),
    # --- aggregation pipeline (CH-side cluster/encrypt, GWN-side merge) ---
    "AGG": re.compile(
        r"^(?:Creating (?P<msgtype>5\.\d) with (?P<n>\d+) sensors"
        r"|(?P<msgtype2>5\.\d) queued: frag (?P<frag>\d+)/(?P<fragn>\d+); (?P<n2>\d+) sensors; (?P<bytes>\d+) bytes \(double-encrypted\)"
        r"|Next aggregation at t=(?P<nextt>\d+)"
        r"|Cleared sensorTable \((?P<n3>\d+) sensors\) - ready for next collection period"
        r"|Initialized: period=(?P<period>\d+); first TX at t=(?P<firstt>\d+))$"
    ),
    # 5.2_RX has many low-value diagnostic shapes (NEW sensor/Aggregated/REROUTED
    # group-quality breakdowns); only the two shapes relevant to hop pairing
    # (who sent the fragment, ACK scheduling) get full field extraction here,
    # the rest keep their tag + raw rest text.
    "5.2_RX": re.compile(
        r"^from (?P<src>[0-9A-Fa-f]{4}) frag (?P<frag>\d+)/(?P<fragn>\d+); sending (?P<ack>5\.\d) ACK$"
    ),
    "5.2_DROPPED": re.compile(r"^seq=(?P<seq>\d+) after (?P<retries>\d+) retries$"),
    "5.2_TX": re.compile(rf"^(?P<n>\d+) sensors in (?P<frag>\d+) fragments {ARROW} (?P<dst>{HEX})$"),
    "5.3_TX": re.compile(rf"^ACK {ARROW} (?P<dst>{HEX})$"),
    "5.3_RX": re.compile(
        r"^(?:ACK from (?P<src>[0-9A-Fa-f]{4})"
        r"|ACK for fragment (?P<frag>\d+)/(?P<fragn>\d+)"
        r"|ACK for seq=(?P<seq>\d+)"
        r"|All (?P<n>\d+) fragments ACKed)$"
    ),
    # --- queueing / drops ---
    "Q_FWD": re.compile(
        r"^(?:Queued (?P<msgtype>\w+)\.(?P<subtype>\d+) \(size=(?P<size>\d+)/(?P<max>\d+)\)"
        r"|Purged (?P<purged>\d+) oldest \(overflow\))$"
    ),
    "Q_LOCAL": re.compile(
        r"^(?:Queued (?P<msgtype>\w+)\.(?P<subtype>\d+) \(size=(?P<size>\d+)/(?P<max>\d+)\)"
        r"|Purged (?P<purged>\d+) oldest \(overflow\))$"
    ),
    "DEQUEUE": re.compile(r"^From (?P<queue>Q_fwd|Q_local) \(waited (?P<waited>\d+) TFs\)$"),
    "CHK_DROP": re.compile(r"^From (?P<src>[0-9A-Fa-f]{4})$"),
    "SECURITY": re.compile(r"^DROP (?P<msgtype>\w+) from (?P<src>[0-9A-Fa-f]{4}) - (?P<reason>.+)$"),
    # --- handshake / CH recruitment / parent management ---
    "CH_REQ": re.compile(rf"^\((?P<attempt>\d+)/(?P<max>\d+)\) {ARROW} (?P<dst>{HEX})$"),
    "CH_ACK": re.compile(
        rf"^(?:{ARROW} (?P<dst>[0-9A-Fa-f]{{4}}) \(sending key\)|Received key from (?P<src>[0-9A-Fa-f]{{4}}))$"
    ),
    "CH_REJECT": re.compile(r"^from (?P<src>[0-9A-Fa-f]{4})$"),
    "CH_JOINED": re.compile(r"^(?P<child>[0-9A-Fa-f]{4}) added to children$"),
    "CH_JOINOK": re.compile(rf"^(?:{ARROW} (?P<dst>[0-9A-Fa-f]{{4}})|from (?P<src>[0-9A-Fa-f]{{4}}))$"),
    "CHILD_ADDED": re.compile(r"^(?P<child>[0-9A-Fa-f]{4})$"),
    "KEY_ACK": re.compile(r"^->\s?(?P<dst>[0-9A-Fa-f]{4}) \(encrypted\)$"),
    "RECRUIT": re.compile(rf"^INIT\((?P<attempt>\d+)/(?P<max>\d+)\) {ARROW} (?P<dst>{HEX})$"),
    "REJ_PARENT": re.compile(rf"^{ARROW} (?P<dst>[0-9A-Fa-f]{{4}})$"),
    "PARENT_CHANGE": re.compile(rf"^(?P<old>[0-9A-Fa-f]{{4}}) {ARROW} (?P<new>[0-9A-Fa-f]{{4}})$"),
    "PARENT": re.compile(rf"^Set parent {ARROW} (?P<dst>[0-9A-Fa-f]{{4}})$"),
    "TIMEOUT": re.compile(
        r"^(?:Sent CH_REJECT to orphaned (?P<orphan>[0-9A-Fa-f]{4})"
        r"|partner=(?P<partner>[0-9A-Fa-f]{4}) retry=(?P<retry>\d+)/(?P<retrymax>\d+)"
        r"|Attempt (?P<attempt>\d+)/(?P<attemptmax>\d+) for (?P<target>[0-9A-Fa-f]{4}) - will retry"
        r"|Pending child (?P<pending>[0-9A-Fa-f]{4}) timed out.*"
        r"|Will exhaust (?P<exhaust>\d+) retries for (?P<exhaustid>[0-9A-Fa-f]{4}) - REJECTED"
        r"|Purged (?P<purged>[0-9A-Fa-f]{4}) from pendingChildren"
        r"|Sent PARENT_REJECT to pending (?P<pendrej>[0-9A-Fa-f]{4})"
        r"|CLEAN SLATE - returning to DISCOVERY)$"
    ),
    "REJECT": re.compile(
        r"^(?:(?P<id1>[0-9A-Fa-f]{4}) MAX_RETRIES=(?P<max>\d+)"
        r"|Neighbor (?P<id2>[0-9A-Fa-f]{4}) marked REJECT)$"
    ),
    "VERIFIED": re.compile(
        r"^parent=(?P<ptype>GWN|CH) (?P<parent>[0-9A-Fa-f]{4}) "
        r"\((?P<enc_desc>localKey set; encrypted comms|no localKey; unencrypted comms)\)$"
    ),
    "ORPHAN_MODE": re.compile(r"No CH/GWN found - entering extended sleep(?: \((?P<pct>\d+)%\))?"),
    "ORPHAN_RECOVERED": re.compile(r"^Found target (?P<target>[0-9A-Fa-f]{4})$"),
    "CRITICAL": re.compile(r"^Parent lost$"),
    # Arrow spacing is inconsistent across call sites ("DISCOVERY -> HANDSHAKE"
    # vs "BOOT->DISCOVERY (neighbors=N)" vs unicode "BOOT→DISCOVERY") --
    # tolerate both spaced and unspaced forms.
    "STATE": re.compile(rf"^(?P<from_>\w+)\s*{ARROW}\s*(?P<to>\w+)(?: \(neighbors=(?P<nbr>\d+)\))?$"),
    "DISCO": re.compile(r"^Found verified GWN (?P<gwn>[0-9A-Fa-f]{4})$"),
    # --- SINK terminal events ---
    "SINK": re.compile(
        r"^(?:Received encrypted (?P<msgtype>\w+)\.(?P<subtype>\d+) from child (?P<child>[0-9A-Fa-f]{4}) - TERMINATING"
        r"|ENC_HELLO from (?P<src>[0-9A-Fa-f]{4}) \(parent=(?P<parent>[0-9A-Fa-f]{4})\): sn=(?P<sn>\d+).*"
        r"|FORWARDED ENC_HELLO: orig=(?P<orig>[0-9A-Fa-f]{4}) via (?P<via>[0-9A-Fa-f]{4})"
        r"|CH_HELLO: CH (?P<ch>[0-9A-Fa-f]{4}) joined via GWN (?P<gwn>[0-9A-Fa-f]{4})"
        r"|Promoted (?P<promoted>[0-9A-Fa-f]{4}) to children.*"
        r"|Boot complete.*|Recruitment targets.*|Recruitment complete.*|Terminal:.*"
        r"|PARENT_REJECT from (?P<rej>[0-9A-Fa-f]{4}).*)$"
    ),
    "SINK_TIMEOUT": re.compile(
        r"^(?:Purged (?P<purged>[0-9A-Fa-f]{4}) from children"
        r"|Sent PARENT_REJECT"
        r"|Exhausted (?P<retries>\d+) retries for (?P<target>[0-9A-Fa-f]{4}) - REJECTED"
        r"|Attempt (?P<attempt>\d+)/(?P<max>\d+) for (?P<target2>[0-9A-Fa-f]{4}) - will retry)$"
    ),
    # --- handshake/lock bookkeeping (no t= prefix; timestamp inferred) ---
    "ENC_HELLO": re.compile(
        r"^(?:TX: gwCh=(?P<gwch>\d+); chCh=(?P<chch>\d+); sn=(?P<sn>\d+) \(encrypted\)"
        r"|Retry (?P<retry>\d+)/(?P<retrymax>\d+) sent \(next at t=(?P<nextt>\d+)\)"
        r"|Registry refresh #(?P<refresh>\d+) sent \(next at t=(?P<nextt2>\d+)\))$"
    ),
    "HANDSHAKE": re.compile(
        r"^(?:Lock set with (?P<partner1>[0-9A-Fa-f]{4}) \(timer=(?P<timer>\d+)\)"
        r"|Lock cleared \(was with (?P<partner2>[0-9A-Fa-f]{4})\)"
        r"|(?P<child>[0-9A-Fa-f]{4}) added to pendingChildren \(awaiting ENC_HELLO\)"
        r"|(?P<child2>[0-9A-Fa-f]{4}) promoted to children \(ENC_HELLO received\))$"
    ),
    "CENSUS_INITIATE": re.compile(
        r"^suspect=(?P<suspect>[0-9A-Fa-f]{4}) trust=(?P<trust>-?\d+\.?\d*) pollUID=(?P<polluid>\d+)$"
    ),
    "CENSUS_COMPLETE": re.compile(
        r"^suspect=(?P<suspect>[0-9A-Fa-f]{4}) verdict=(?P<verdict>\d+) \((?P<yes>\d+)/(?P<total>\d+) votes\)$"
    ),
    "PHY": re.compile(r"^Neighbou?r count[:=] ?(?:(?P<old>\d+)->(?P<new>\d+)|(?P<n>\d+))$"),
}

# tag-chain dispatch for the bracket-chained [LOCK]/[DROP] radio-layer family
# (no t= prefix -- see "[LOCK][SET] partner=.." in the survey).
LOCK_PATTERN = re.compile(r"^partner=(?P<partner>[0-9A-Fa-f]{4})(?: timeout=(?P<timeout>\d+))?$")
DROP_LOCK_TX_PATTERN = re.compile(
    r"^type=(?P<msgtype>\d+) dst=(?P<dst>[0-9A-Fa-f]{4}) partner=(?P<partner>[0-9A-Fa-f]{4})$"
)

# Tags whose TX-side semantics matter for hop reconstruction.
TX_TAGS = {"TX", "SENSOR_TX", "HELLO_TX", "PANIC_TX", "PHASE_TX", "CH_REQ", "RECRUIT",
           "CH_ACK", "KEY_ACK", "PANIC_FWD"}
# Tags whose RX-side semantics matter for hop reconstruction.
RX_TAGS = {"RX", "RX_FWD", "SENSOR_RX", "HELLO_RX", "HELLO", "PANIC_RX", "5.2_RX", "5.3_RX",
           "SINK", "CH_ACK"}


def _read_chunks(paths: list[str | Path]) -> pd.DataFrame:
    frames = []
    for p in paths:
        df = pd.read_csv(p, dtype=str, keep_default_na=False)
        frames.append(df)
    return pd.concat(frames, ignore_index=True)


def parse_combined(paths: list[str | Path]) -> pd.DataFrame:
    """Returns a tidy events DataFrame, one row per (deduplicated) log line.

    Columns: node_hex, node_type, tier, channel, row_order, t, t_inferred,
    tags (raw bracket chain string), tag (primary), rest (free text after
    the tag chain), plus tag-specific extracted columns (msgtype, subtype,
    src, dst, val, bat, rssi, ...) where applicable -- NaN where not.
    """
    raw = _read_chunks(paths)
    raw["row_order"] = raw.index  # preserve file append-order for t ffill / FIFO pairing

    split = raw["LogEntry"].str.extract(_SPLIT_RE)
    df = pd.concat(
        [raw[["NodeID", "NodeType", "Tier", "RadioType", "row_order"]], split], axis=1
    )
    df.columns = ["node_hex", "node_type", "tier", "channel", "row_order", "t", "tags", "rest"]

    # Drop dual-radio UNIFIED duplicates: [BB]/[AC]-prefixed rows are exact
    # copies of the native BACKBONE/ACCESS row (see module docstring).
    dup_mask = (df["channel"] == "UNIFIED") & df["tags"].isin(["[BB]", "[AC]"])
    df = df.loc[~dup_mask].copy()

    df["t"] = pd.to_numeric(df["t"], errors="coerce")
    df["t_inferred"] = df["t"].isna()
    # Carry forward last-known t within each node+channel's append-ordered
    # block (radio LOCK lines have no t= of their own -- WSN_Radio.m logs
    # them via logLocal(), not the t-stamped node.addLog() path).
    df = df.sort_values(["node_hex", "channel", "row_order"])
    df["t"] = df.groupby(["node_hex", "channel"])["t"].ffill()
    df["t"] = df["t"].fillna(0).astype(int)

    # tag-chain -> primary tag, secondary tag (for [LOCK][CLEAR][reason] etc.)
    chain = df["tags"].str.findall(r"\[([^\]]*)\]")
    df["tag"] = chain.str[0]
    df["tag2"] = chain.str[1]
    df["tag3"] = chain.str[2]

    _extract_structured_fields(df)

    df = df.sort_values(["t", "row_order"]).reset_index(drop=True)
    return df


def _extract_structured_fields(df: pd.DataFrame) -> None:
    """In-place: applies TAG_PATTERNS per primary tag (vectorized per group)
    plus the bracket-chain [LOCK]/[DROP] family, writing extracted columns
    directly onto df. Lines under tags without a registered pattern keep
    their raw `rest` text only (still usable for per-node raw timelines).
    """
    # Pre-collect (mask, pattern) jobs, including the bracket-chain families.
    jobs = [(df["tag"] == tag, pattern) for tag, pattern in TAG_PATTERNS.items() if pattern.groupindex]
    jobs.append((df["tag"] == "LOCK", LOCK_PATTERN))
    jobs.append(((df["tag"] == "DROP") & (df["tag2"] == "LOCK"), DROP_LOCK_TX_PATTERN))

    # All extracted column names across every pattern, pre-allocated once so
    # each job can assign its slice directly with .loc -- avoids the
    # concat+groupby('index').first()+per-column-reindex pattern, which is
    # the dominant cost at this row count (profiled: ~16s vs <2s here).
    all_cols: list[str] = []
    seen = set()
    for _, pattern in jobs:
        for name in pattern.groupindex:
            if name not in seen:
                seen.add(name)
                all_cols.append(name)
    for col in all_cols:
        df[col] = pd.Series(pd.NA, index=df.index, dtype="object")

    for mask, pattern in jobs:
        if not mask.any():
            continue
        ex = df.loc[mask, "rest"].str.extract(pattern)
        df.loc[mask, ex.columns] = ex.values
