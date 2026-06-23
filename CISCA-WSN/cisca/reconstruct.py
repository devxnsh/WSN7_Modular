"""TX/RX hop pairing and message-lifecycle (PATH) reconstruction.

Scope decision (deliberate, see CISCA-WSN plan): only tags that carry a
direct (msgtype, subtype, src, dst) wire-level transmission/reception are
hop-paired into MessageTrace objects -- TX, PHASE_TX("Sent" variant),
SENSOR_TX, HELLO_TX, PANIC_TX, 5.2_TX, 5.3_TX against RX, RX_FWD,
SENSOR_RX, HELLO_RX, HELLO, PANIC_RX, 5.2_RX, 5.3_RX. Handshake/identity
annotation tags (CH_REQ, CH_ACK, KEY_ACK, HANDSHAKE, VERIFIED, SINK,
CENSUS_*, SECURITY, REJECT family) are NOT double-counted as separate
messages -- the underlying wire event for all of those is already present
as a plain TX/RX CMD.N entry at the same tick; the semantic tags remain
visible in each node's raw event timeline for context but aren't
hop-paired a second time.

No message carries a logged unique id (msg.uid is in-memory only -- see
parser.py docstring and the project's research notes), so pairing uses
deterministic ordered (FIFO-respecting) matching on (msgtype, subtype,
src, dst) within a bounded time window. The sim is a single-threaded
discrete-event loop -- no reordering within one (src,dst,type,subtype)
flow -- so backward-nearest-neighbor matching from each RX to its most
recent unconsumed TX is the correct semantic for retry sequences (a
retried send's RX correctly credits the latest attempt, not an earlier
abandoned one).
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from cisca import config

# Tags representing a genuine outbound transmission attempt.
TX_SOURCE_TAGS = {"TX", "SENSOR_TX", "HELLO_TX", "PANIC_TX", "5.2_TX", "5.3_TX"}
# PHASE_TX is split: only the "Sent ..." variant (msgtype not null) is a TX.
# Tags representing a genuine inbound reception.
RX_SOURCE_TAGS = {"RX", "RX_FWD", "SENSOR_RX", "HELLO_RX", "HELLO", "PANIC_RX", "5.2_RX", "5.3_RX"}

# Tags whose RX side implies the message was absorbed for relay (continue
# the chain by looking for the next outbound hop of the same type/subtype
# at the receiving node).
RELAY_RX_TAGS = {"RX_FWD"}
# Tags whose RX side implies cluster/aggregate absorption at a CH (link to
# that node's next AGG "Creating" batch instead of a literal next hop).
AGGREGATE_RX_TAGS = {"SENSOR_RX"}


def _normalize_tx(df: pd.DataFrame) -> pd.DataFrame:
    """Builds the unified TX-event frame: idx, t, src, msgtype, subtype, dst."""
    parts = []

    tx = df[df["tag"] == "TX"]
    parts.append(pd.DataFrame({
        "idx": tx.index, "t": tx["t"], "src": tx["node_hex"],
        "msgtype": tx["msgtype"], "subtype": tx["subtype"], "dst": tx["dst"],
    }))

    pt = df[(df["tag"] == "PHASE_TX") & df["msgtype"].notna()]
    parts.append(pd.DataFrame({
        "idx": pt.index, "t": pt["t"], "src": pt["node_hex"],
        "msgtype": pt["msgtype"], "subtype": pt["subtype"], "dst": pt["dst"],
    }))

    st = df[df["tag"] == "SENSOR_TX"]
    parts.append(pd.DataFrame({
        "idx": st.index, "t": st["t"], "src": st["node_hex"],
        "msgtype": "SENSOR", "subtype": "0", "dst": st["dst"],
    }))

    ht = df[df["tag"] == "HELLO_TX"]
    parts.append(pd.DataFrame({
        "idx": ht.index, "t": ht["t"], "src": ht["node_hex"],
        "msgtype": "HELLO", "subtype": "0", "dst": "<BCAST>",
    }))

    pa = df[df["tag"] == "PANIC_TX"]
    parts.append(pd.DataFrame({
        "idx": pa.index, "t": pa["t"], "src": pa["node_hex"],
        "msgtype": "PANIC", "subtype": pa.get("ptype"), "dst": pa["dst"].fillna("<BCAST>"),
    }))

    for tag in ("5.2_TX", "5.3_TX"):
        sub = df[df["tag"] == tag]
        parts.append(pd.DataFrame({
            "idx": sub.index, "t": sub["t"], "src": sub["node_hex"],
            "msgtype": tag.split("_")[0], "subtype": "0", "dst": sub["dst"],
        }))

    out = pd.concat(parts, ignore_index=True).dropna(subset=["t", "src"])
    out["is_broadcast"] = out["dst"].isin(["<BCAST>", None]) | out["dst"].isna()
    out["subtype"] = out["subtype"].fillna("0")
    out = out.sort_values("t").reset_index(drop=True)
    return out


def _normalize_rx(df: pd.DataFrame) -> pd.DataFrame:
    """Builds the unified RX-event frame: idx, t, rx_node, msgtype, subtype, src."""
    parts = []

    rx = df[(df["tag"] == "RX") & df["msgtype"].notna()]
    parts.append(pd.DataFrame({
        "idx": rx.index, "t": rx["t"], "rx_node": rx["node_hex"],
        "msgtype": rx["msgtype"], "subtype": rx["subtype"], "src": rx["src"], "rtag": "RX",
    }))

    rf = df[df["tag"] == "RX_FWD"]
    parts.append(pd.DataFrame({
        "idx": rf.index, "t": rf["t"], "rx_node": rf["node_hex"],
        "msgtype": rf["msgtype"], "subtype": rf["subtype"], "src": rf["child"], "rtag": "RX_FWD",
    }))

    sr = df[df["tag"] == "SENSOR_RX"]
    parts.append(pd.DataFrame({
        "idx": sr.index, "t": sr["t"], "rx_node": sr["node_hex"],
        "msgtype": "SENSOR", "subtype": "0", "src": sr["src"], "rtag": "SENSOR_RX",
    }))

    for tag in ("HELLO_RX", "HELLO"):
        h = df[df["tag"] == tag]
        parts.append(pd.DataFrame({
            "idx": h.index, "t": h["t"], "rx_node": h["node_hex"],
            "msgtype": "HELLO", "subtype": "0", "src": h["src"], "rtag": tag,
        }))

    pr = df[df["tag"] == "PANIC_RX"]
    src = pr["src"].fillna(pr.get("src2"))
    parts.append(pd.DataFrame({
        "idx": pr.index, "t": pr["t"], "rx_node": pr["node_hex"],
        "msgtype": "PANIC", "subtype": pd.NA, "src": src, "rtag": "PANIC_RX",
    }))

    for tag, mtype in (("5.2_RX", "5.2"), ("5.3_RX", "5.3")):
        sub = df[(df["tag"] == tag) & df["src"].notna()]
        parts.append(pd.DataFrame({
            "idx": sub.index, "t": sub["t"], "rx_node": sub["node_hex"],
            "msgtype": mtype, "subtype": "0", "src": sub["src"], "rtag": tag,
        }))

    out = pd.concat(parts, ignore_index=True).dropna(subset=["t", "rx_node", "src"])
    out = out.sort_values("t").reset_index(drop=True)
    return out


def pair_hops(events: pd.DataFrame) -> pd.DataFrame:
    """Returns one row per TX event: matched RX info if found (within the
    configured window), else NaN (caller classifies these as not-received).
    """
    tx = _normalize_tx(events)
    rx = _normalize_rx(events)
    if tx.empty:
        return tx.assign(matched_rx_idx=pd.NA, rx_t=pd.NA, rx_node=pd.NA, rx_tag=pd.NA)

    window = config.HOP_MATCH_WINDOW_TICKS

    # Unicast: each RX matched backward to its nearest unconsumed TX with the
    # same (msgtype, subtype, src, dst==rx_node). merge_asof's `by` grouping
    # handles this as a single vectorized pass (no per-group Python loop).
    uni_tx = tx[~tx["is_broadcast"]].copy()
    uni_rx = rx.rename(columns={"rx_node": "dst"}).copy()
    uni_tx = uni_tx.sort_values("t")
    uni_rx = uni_rx.sort_values("t")
    uni_match = pd.merge_asof(
        uni_rx, uni_tx, on="t", by=["msgtype", "subtype", "src", "dst"],
        direction="backward", tolerance=window, suffixes=("_rx", "_tx"),
    )
    uni_match = uni_match.rename(columns={"t": "t_rx"})  # `on` col keeps the left (rx) frame's name

    # Broadcast: any receiver counts -- no dst constraint, multiple RX rows
    # may legitimately match the same broadcast TX (fan-out).
    bcast_tx = tx[tx["is_broadcast"]].copy().sort_values("t")
    bcast_rx = rx.sort_values("t")
    bcast_match = pd.merge_asof(
        bcast_rx, bcast_tx, on="t", by=["msgtype", "subtype", "src"],
        direction="backward", tolerance=window, suffixes=("_rx", "_tx"),
    )
    bcast_match = bcast_match.rename(columns={"t": "t_rx"})

    # idx_tx / idx_rx columns identify which original event rows matched.
    uni_pairs = uni_match.dropna(subset=["idx_tx"])[["idx_tx", "idx_rx", "t_rx", "dst", "rtag"]]
    uni_pairs = uni_pairs.rename(columns={"dst": "rx_node"})
    bcast_pairs = bcast_match.dropna(subset=["idx_tx"])[["idx_tx", "idx_rx", "t_rx", "rx_node", "rtag"]]
    all_pairs = pd.concat([uni_pairs, bcast_pairs], ignore_index=True)

    # For unicast, a TX should only be "received" by its first matching RX
    # (one wire delivery); keep the earliest. Broadcast TX legitimately keeps
    # all distinct receivers.
    uni_first = (
        all_pairs[all_pairs["idx_tx"].isin(uni_pairs["idx_tx"])]
        .sort_values("t_rx")
        .drop_duplicates("idx_tx", keep="first")
    )
    bcast_all = all_pairs[all_pairs["idx_tx"].isin(bcast_pairs["idx_tx"])]
    matches = pd.concat([uni_first, bcast_all], ignore_index=True)

    grouped = matches.groupby("idx_tx").agg(
        rx_t=("t_rx", "min"),
        rx_node=("rx_node", lambda s: list(s)),
        rx_tag=("rtag", lambda s: list(s)),
        rx_idx=("idx_rx", lambda s: list(s)),
        n_receivers=("rx_node", "size"),
    )

    tx = tx.set_index("idx")
    tx = tx.join(grouped, how="left")
    tx["received"] = tx["n_receivers"].fillna(0) > 0
    return tx.reset_index().rename(columns={"idx": "tx_idx"})


def classify_not_received(hops: pd.DataFrame, events: pd.DataFrame,
                           attack_log: pd.DataFrame | None) -> pd.DataFrame:
    """For unmatched TX rows, fills a `drop_reason` column with a best-effort
    cause, checked in priority order: active attack against the intended
    receiver, receiver-side corruption (CHK_DROP), radio lock contention,
    receiver asleep/orphaned, else unknown (out of range / fade).
    """
    hops = hops.copy()
    hops["drop_reason"] = pd.NA
    miss = ~hops["received"]
    if not miss.any():
        return hops

    # Pre-process attack log: normalise Time to int and identify the node-hex
    # column (exported as "NodeHex" in some versions, absent in others where
    # only "NodeIdx" is present).
    _atk: pd.DataFrame | None = None
    _atk_hex_col: str | None = None
    if attack_log is not None and not attack_log.empty:
        _atk = attack_log.copy()
        _atk["Time"] = pd.to_numeric(_atk["Time"], errors="coerce").fillna(0).astype(int)
        for _col in ("NodeHex", "Hex", "node_hex"):
            if _col in _atk.columns:
                _atk_hex_col = _col
                break

    chk_drop = events[events["tag"] == "CHK_DROP"][["node_hex", "t", "src"]].copy()
    lock_drop = events[(events["tag"] == "DROP") & (events["tag2"] == "LOCK")][["node_hex", "t"]].copy()
    orphan = events[events["tag"] == "ORPHAN_MODE"][["node_hex", "t"]].copy()

    def reason_for(row) -> str:
        dst = row["dst"]
        t = row["t"]
        window = config.HOP_MATCH_WINDOW_TICKS

        if _atk is not None and pd.notna(dst):
            if _atk_hex_col is not None:
                hit = _atk[
                    (_atk[_atk_hex_col] == dst)
                    & (_atk["Time"] >= t)
                    & (_atk["Time"] <= t + window)
                ]
            else:
                # No per-node hex column (only NodeIdx available) — fall back
                # to any attack action in the time window as a proxy.
                hit = _atk[
                    (_atk["Time"] >= t)
                    & (_atk["Time"] <= t + window)
                ]
            if not hit.empty:
                atype = hit.iloc[0].get("AttackTypeName", hit.iloc[0].get("AttackType", "unknown"))
                return f"attacker active ({atype})"

        if pd.notna(dst):
            ck = chk_drop[(chk_drop["node_hex"] == dst) & (chk_drop["t"] >= t) & (chk_drop["t"] <= t + window)]
            if not ck.empty:
                return "corrupted (checksum fail at receiver)"

            lk = lock_drop[(lock_drop["node_hex"] == dst) & (lock_drop["t"] >= t) & (lock_drop["t"] <= t + window)]
            if not lk.empty:
                return "radio busy (lock contention at receiver)"

            orp = orphan[(orphan["node_hex"] == dst) & (orphan["t"] <= t + window) & (orphan["t"] >= t - window)]
            if not orp.empty:
                return "receiver asleep/orphaned"

        return "unknown (out of range / fade)"

    hops.loc[miss, "drop_reason"] = hops.loc[miss].apply(reason_for, axis=1)
    return hops


def build_message_traces(hops: pd.DataFrame, events: pd.DataFrame) -> list[dict]:
    """Chains hop-pairs into end-to-end message lifecycles.

    Each trace is a dict: {msgtype, subtype, origin_node, origin_t, path:
    [stage,...], terminal}. `path` stages are (kind, t, node, detail) tuples.
    Relay chains (RX_FWD -> next outbound hop at the same node) are followed
    up to a depth cap; sensor->CH absorption is linked to that CH's next AGG
    batch-creation event rather than fabricating a literal continuation past
    a genuine many-to-one merge point.
    """
    MAX_HOPS = 6
    agg_events = events[(events["tag"] == "AGG") & events["n"].notna()][["node_hex", "t", "n"]]
    hops_by_key = hops.set_index("tx_idx")

    traces = []
    # An originating hop is one whose message type is a genuine source event
    # (sensor data, panic, or a first protocol TX) -- i.e. every TX hop is a
    # potential chain start; we walk forward from each one that isn't itself
    # reached via a relay continuation already covered by a previous trace's
    # walk (tracked via `consumed`).
    consumed_tx = set()

    for tx_idx, row in hops.iterrows():
        if row["tx_idx"] in consumed_tx:
            continue
        path = [("Transmitted", row["t"], row["src"],
                 {"type": row["msgtype"], "subtype": row["subtype"], "dst": row["dst"]})]
        cur = row
        depth = 0
        terminal = None

        while True:
            depth += 1
            if not cur["received"]:
                terminal = ("Not Received", cur["t"], cur.get("drop_reason", "unknown"))
                break

            rx_node = cur["rx_node"][0] if isinstance(cur["rx_node"], list) else cur["rx_node"]
            rx_tag = cur["rx_tag"][0] if isinstance(cur["rx_tag"], list) else cur["rx_tag"]
            rx_t = cur["rx_t"]
            n_recv = cur.get("n_receivers", 1) or 1
            if n_recv > 1:
                path.append(("Received (broadcast)", rx_t, rx_node,
                              {"receiver_count": int(n_recv), "receivers": cur["rx_node"]}))
                terminal = ("Delivered to receivers", rx_t, f"{int(n_recv)} nodes")
                break

            path.append(("Received", rx_t, rx_node, {}))

            if rx_tag in AGGREGATE_RX_TAGS:
                batch = agg_events[(agg_events["node_hex"] == rx_node)
                                    & (agg_events["t"] >= rx_t)
                                    & (agg_events["t"] <= rx_t + config.AGG_LINK_WINDOW_TICKS)]
                if not batch.empty:
                    b = batch.iloc[0]
                    path.append(("Clustered/Aggregated", b["t"], rx_node,
                                 {"batch_k_sensors": int(float(b["n"]))}))
                    terminal = ("Merged into aggregate batch", b["t"], rx_node)
                else:
                    terminal = ("Absorbed at receiver", rx_t, rx_node)
                break

            if rx_tag in RELAY_RX_TAGS and depth < MAX_HOPS:
                nxt_candidates = hops[
                    (hops["src"] == rx_node) & (hops["msgtype"] == cur["msgtype"])
                    & (hops["subtype"] == cur["subtype"]) & (hops["t"] >= rx_t)
                    & (hops["t"] <= rx_t + config.AGG_LINK_WINDOW_TICKS)
                ]
                if not nxt_candidates.empty:
                    nxt = nxt_candidates.iloc[0]
                    consumed_tx.add(nxt["tx_idx"])
                    path.append(("Forwarded", nxt["t"], rx_node,
                                 {"dst": nxt["dst"]}))
                    cur = nxt
                    continue
                terminal = ("Queued for forward, not observed leaving", rx_t, rx_node)
                break

            terminal = ("Received", rx_t, rx_node)
            break

        traces.append({
            "msgtype": row["msgtype"], "subtype": row["subtype"],
            "origin_node": row["src"], "origin_t": row["t"],
            "path": path, "terminal": terminal,
        })

    return traces
