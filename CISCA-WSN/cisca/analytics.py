"""Post-processing analytics engine for CISCA-WSN.

Computes system-level, node-level, and message-level metrics from a
parsed events DataFrame + pre-paired hop table + message traces.
All computation is done eagerly on construction so the GUI can query
any metric with no further heavy work.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import pandas as pd

from cisca import config

# ---------------------------------------------------------------------------
# Attack-type registry (mirrors WSN_Attack.m constants)
# ---------------------------------------------------------------------------
ATTACK_TYPE_NAMES: dict[int, str] = {
    0: "Normal",
    1: "Hello Flood",
    2: "Panic Flood",
    3: "Sybil",
    4: "Black Hole",
    5: "Wormhole",
    6: "Selective Forwarding",
    7: "Denial of Sleep",
}

TX_TAGS = {"TX", "SENSOR_TX", "HELLO_TX", "PANIC_TX", "PHASE_TX", "5.2_TX", "5.3_TX",
           "CH_REQ", "RECRUIT", "CH_ACK", "KEY_ACK", "PANIC_FWD"}
RX_TAGS = {"RX", "RX_FWD", "SENSOR_RX", "HELLO_RX", "HELLO", "PANIC_RX",
           "5.2_RX", "5.3_RX", "SINK", "CH_ACK"}


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class AttackInfo:
    attack_type: int
    attack_type_name: str
    attacker_idxs: list[int]
    attacker_hexes: list[str]
    start_t: int
    end_t: int
    event_count: int
    actions: dict[str, int]
    intensity_proxy: float          # events / active-tick span


@dataclass
class AttackNetworkEffect:
    msgs_dropped_by_attack: int
    victim_node_hexes: list[str]    # nodes whose messages were dropped
    pdr_overall: float
    pdr_before: float
    pdr_during: float
    pdr_after: float
    atk_start_t: int
    atk_end_t: int


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _battery_series(events: pd.DataFrame, node_hex: str | None = None) -> pd.DataFrame:
    """Return (node_hex, t, bat) from SENSOR_TX / HELLO_TX events."""
    ev = events if node_hex is None else events[events["node_hex"] == node_hex]
    parts = []
    for tag, col in [("SENSOR_TX", "bat"), ("HELLO_TX", "bat"), ("HELLO_TX", "batf")]:
        sub = ev[(ev["tag"] == tag) & ev[col].notna()][["node_hex", "t", col]].copy()
        sub = sub.rename(columns={col: "bat"})
        parts.append(sub)
    if not parts:
        return pd.DataFrame(columns=["node_hex", "t", "bat"])
    df = pd.concat(parts, ignore_index=True)
    df["bat"] = pd.to_numeric(df["bat"], errors="coerce")
    return df.dropna(subset=["bat"]).sort_values(["node_hex", "t"])


def _pdr_in_range(hops: pd.DataFrame, t_lo: int, t_hi: int) -> float:
    sub = hops[(hops["t"] >= t_lo) & (hops["t"] <= t_hi)]
    if sub.empty:
        return float("nan")
    return float(sub["received"].mean())


# ---------------------------------------------------------------------------
# Analytics Engine
# ---------------------------------------------------------------------------

class AnalyticsEngine:
    """Main analytics object.  Constructed once per loaded run; all methods
    are fast reads after the initial build step."""

    def __init__(
        self,
        events: pd.DataFrame,
        hops: pd.DataFrame,
        traces: list[dict],
        attack_log: Optional[pd.DataFrame] = None,
        node_registry: Optional[pd.DataFrame] = None,
    ):
        self.events = events
        self.hops = hops
        self.traces = traces
        self.attack_log = attack_log

        # NodeIdx -> hex mapping from the sink node registry if available
        self._idx_to_hex: dict[int, str] = {}
        if node_registry is not None and not node_registry.empty:
            for col in ("NodeHex", "Hex", "node_hex", "HexID"):
                if col in node_registry.columns:
                    for idx_col in ("NodeIdx", "Idx", "node_idx"):
                        if idx_col in node_registry.columns:
                            for _, row in node_registry.iterrows():
                                try:
                                    self._idx_to_hex[int(row[idx_col])] = str(row[col])
                                except (ValueError, TypeError):
                                    pass
                            break

        # ---- pre-compute battery frame (all nodes) ----
        self._bat_all = _battery_series(events)

        # ---- pre-compute node list ----
        self._node_info = (
            events[["node_hex", "node_type", "tier"]]
            .drop_duplicates("node_hex")
            .copy()
        )
        self._node_info["tier"] = pd.to_numeric(
            self._node_info["tier"], errors="coerce"
        ).fillna(99).astype(int)
        self._node_info = self._node_info.sort_values(
            ["tier", "node_hex"]
        ).reset_index(drop=True)

        # ---- pre-compute system timeseries ----
        self._system_ts: Optional[pd.DataFrame] = None
        self._system_ts_bsz: int = 0

        # ---- pre-explode rx_node for fast per-node RX count queries ----
        # pair_hops() stores rx_node as a list even for unicast (length 1)
        self._rx_exploded: pd.DataFrame
        if hops is not None and not hops.empty and "rx_node" in hops.columns:
            rx_raw = hops[hops["received"]].copy()
            rx_raw["rx_node"] = rx_raw["rx_node"].apply(
                lambda x: x if isinstance(x, list) else ([x] if x is not None else [])
            )
            rx_raw = rx_raw.explode("rx_node").dropna(subset=["rx_node"])
            self._rx_exploded = rx_raw[["rx_node", "msgtype", "subtype", "t"]].copy()
        else:
            self._rx_exploded = pd.DataFrame(
                columns=["rx_node", "msgtype", "subtype", "t"]
            )

        # ---- pre-compute attack summaries ----
        self._attack_infos: list[AttackInfo] = []
        self._attack_effect: Optional[AttackNetworkEffect] = None
        if attack_log is not None and not attack_log.empty:
            self._attack_infos = self._build_attack_infos()
            self._attack_effect = self._build_attack_effect()

    # -----------------------------------------------------------------------
    # Public: node list
    # -----------------------------------------------------------------------

    @property
    def node_list(self) -> list[tuple[str, str, int]]:
        """[(hex, node_type, tier), ...] sorted by tier then hex."""
        return [
            (r.node_hex, r.node_type, int(r.tier))
            for _, r in self._node_info.iterrows()
        ]

    # -----------------------------------------------------------------------
    # Public: system-level
    # -----------------------------------------------------------------------

    def get_system_timeseries(self, bucket_size: int | None = None) -> pd.DataFrame:
        """Per-bucket time series with all system-level metrics.

        Columns: t, n_tx_events, n_rx_events, n_tx_nodes, n_rx_nodes,
                 n_active_nodes, n_sleeping_nodes, n_corrupted_events,
                 avg_battery, pdr, avg_latency_ticks,
                 attack_active, n_attack_events.
        """
        bsz = bucket_size or config.SYSTEM_BUCKET_TICKS
        # cache per bucket size
        if self._system_ts is not None and self._system_ts_bsz == bsz:
            return self._system_ts

        ev = self.events
        t_max = int(ev["t"].max()) if not ev.empty else 0

        # ---- vectorised bucket assignment ----
        def bucket_col(df: pd.DataFrame) -> pd.Series:
            return (df["t"] // bsz) * bsz

        ev2 = ev.copy()
        ev2["bucket"] = bucket_col(ev2)

        bat_df = self._bat_all.copy()
        bat_df["bucket"] = (bat_df["t"] // bsz) * bsz

        tx_ev = ev2[ev2["tag"].isin(TX_TAGS)]
        rx_ev = ev2[ev2["tag"].isin(RX_TAGS)]
        sleep_ev = ev2[ev2["tag"] == "ORPHAN_MODE"]
        corrupt_ev = ev2[ev2["tag"] == "CHK_DROP"]

        # group each sub-frame by bucket
        all_grp = ev2.groupby("bucket")
        tx_grp = tx_ev.groupby("bucket")
        rx_grp = rx_ev.groupby("bucket")
        sleep_grp = sleep_ev.groupby("bucket")
        corrupt_grp = corrupt_ev.groupby("bucket")
        bat_grp = bat_df.groupby("bucket")

        buckets = list(range(0, t_max + bsz, bsz))
        rows = []
        for b in buckets:
            def get(grp, agg):
                return agg(grp.get_group(b)) if b in grp.groups else (0 if agg != float("nan") else float("nan"))

            tx_b = tx_grp.get_group(b) if b in tx_grp.groups else pd.DataFrame(columns=ev2.columns)
            rx_b = rx_grp.get_group(b) if b in rx_grp.groups else pd.DataFrame(columns=ev2.columns)
            all_b = all_grp.get_group(b) if b in all_grp.groups else pd.DataFrame(columns=ev2.columns)
            slp_b = sleep_grp.get_group(b) if b in sleep_grp.groups else pd.DataFrame(columns=ev2.columns)
            cor_b = corrupt_grp.get_group(b) if b in corrupt_grp.groups else pd.DataFrame(columns=ev2.columns)
            bat_b = bat_grp.get_group(b) if b in bat_grp.groups else pd.DataFrame(columns=["bat"])

            rows.append({
                "t": b,
                "n_tx_events": len(tx_b),
                "n_rx_events": len(rx_b),
                "n_tx_nodes": tx_b["node_hex"].nunique(),
                "n_rx_nodes": rx_b["node_hex"].nunique(),
                "n_active_nodes": all_b["node_hex"].nunique(),
                "n_sleeping_nodes": slp_b["node_hex"].nunique(),
                "n_corrupted_events": len(cor_b),
                "avg_battery": float(bat_b["bat"].mean()) if not bat_b.empty else float("nan"),
            })

        ts = pd.DataFrame(rows)

        # ---- PDR and latency from hops ----
        hops = self.hops
        if hops is not None and not hops.empty:
            hp = hops.copy()
            hp["bucket"] = (hp["t"] // bsz) * bsz
            pdr_grp = hp.groupby("bucket").agg(
                n_tx=("received", "count"),
                n_rx=("received", "sum"),
            )
            pdr_grp["pdr"] = pdr_grp["n_rx"] / pdr_grp["n_tx"].replace(0, float("nan"))

            matched = hp[hp["received"] & hp["rx_t"].notna()].copy()
            matched["latency"] = pd.to_numeric(matched["rx_t"], errors="coerce") - matched["t"]
            lat_grp = matched.groupby("bucket")["latency"].mean()

            ts = ts.set_index("t")
            ts["pdr"] = pdr_grp["pdr"].reindex(ts.index)
            ts["avg_latency_ticks"] = lat_grp.reindex(ts.index)
            ts = ts.reset_index()

        # ---- attack activity ----
        ts["attack_active"] = False
        ts["n_attack_events"] = 0
        ts["attack_type_str"] = ""
        if self.attack_log is not None and not self.attack_log.empty:
            atk = self.attack_log.copy()
            atk["Time"] = pd.to_numeric(atk["Time"], errors="coerce").fillna(0).astype(int)
            atk["AttackType"] = pd.to_numeric(
                atk["AttackType"], errors="coerce"
            ).fillna(0).astype(int)
            atk["bucket"] = (atk["Time"] // bsz) * bsz
            atk_grp = atk[atk["AttackType"] > 0].groupby("bucket").agg(
                attack_active=("AttackType", lambda x: True),
                n_attack_events=("AttackType", "count"),
                attack_types=("AttackType", lambda x: ",".join(
                    sorted({ATTACK_TYPE_NAMES.get(v, str(v)) for v in x})
                )),
            )
            ts = ts.set_index("t")
            ts["attack_active"] = atk_grp["attack_active"].reindex(ts.index, fill_value=False)
            ts["n_attack_events"] = atk_grp["n_attack_events"].reindex(ts.index, fill_value=0)
            ts["attack_type_str"] = atk_grp["attack_types"].reindex(ts.index, fill_value="")
            ts = ts.reset_index()

        self._system_ts = ts
        self._system_ts_bsz = bsz
        return ts

    def get_overall_stats(self) -> dict:
        """Single-value summary stats for the whole run."""
        ts = self.get_system_timeseries()
        hops = self.hops
        n_nodes = len(self._node_info)
        n_msg = len(hops) if hops is not None else 0
        n_recv = int(hops["received"].sum()) if hops is not None and not hops.empty else 0
        pdr = n_recv / n_msg if n_msg > 0 else float("nan")
        avg_lat = float("nan")
        if hops is not None and not hops.empty:
            matched = hops[hops["received"] & hops["rx_t"].notna()].copy()
            if not matched.empty:
                avg_lat = float(
                    (pd.to_numeric(matched["rx_t"], errors="coerce") - matched["t"]).mean()
                )
        bat_last = float("nan")
        if not self._bat_all.empty:
            last_bat = self._bat_all.sort_values("t").drop_duplicates("node_hex", keep="last")
            bat_last = float(last_bat["bat"].mean())
        t_max = int(self.events["t"].max()) if not self.events.empty else 0
        return {
            "total_nodes": n_nodes,
            "sim_ticks": t_max,
            "total_messages": n_msg,
            "messages_received": n_recv,
            "pdr": pdr,
            "avg_latency_ticks": avg_lat,
            "avg_final_battery_pct": bat_last,
            "has_attack": bool(self._attack_infos),
        }

    # -----------------------------------------------------------------------
    # Public: attack-level
    # -----------------------------------------------------------------------

    def get_attack_infos(self) -> list[AttackInfo]:
        return self._attack_infos

    def get_attack_effect(self) -> Optional[AttackNetworkEffect]:
        return self._attack_effect

    def _build_attack_infos(self) -> list[AttackInfo]:
        atk = self.attack_log.copy()
        atk["AttackType"] = pd.to_numeric(atk["AttackType"], errors="coerce").fillna(0).astype(int)
        atk["Time"] = pd.to_numeric(atk["Time"], errors="coerce").fillna(0).astype(int)
        atk["NodeIdx"] = pd.to_numeric(atk["NodeIdx"], errors="coerce").fillna(0).astype(int)

        result = []
        for (n_idx, atype), grp in atk[atk["AttackType"] > 0].groupby(["NodeIdx", "AttackType"]):
            actions = grp["Action"].value_counts().to_dict() if "Action" in grp.columns else {}
            start_t = int(grp["Time"].min())
            end_t = int(grp["Time"].max())
            span = max(1, end_t - start_t)
            result.append(AttackInfo(
                attack_type=int(atype),
                attack_type_name=ATTACK_TYPE_NAMES.get(int(atype), f"Type {atype}"),
                attacker_idxs=[int(n_idx)],
                attacker_hexes=[self._idx_to_hex.get(int(n_idx), f"#{n_idx}")],
                start_t=start_t,
                end_t=end_t,
                event_count=len(grp),
                actions=actions,
                intensity_proxy=round(len(grp) / span, 3),
            ))
        return result

    def _build_attack_effect(self) -> AttackNetworkEffect:
        hops = self.hops
        atk = self.attack_log
        drops = 0
        victims: set[str] = set()

        if hops is not None and not hops.empty and "drop_reason" in hops.columns:
            atk_mask = hops["drop_reason"].fillna("").str.startswith("attacker active")
            atk_drops = hops[atk_mask]
            drops = len(atk_drops)
            victims = set(atk_drops["src"].dropna().unique())

        # PDR windows
        atk_start = atk_end = 0
        pdr_before = pdr_during = pdr_after = float("nan")
        pdr_overall = float("nan")
        if hops is not None and not hops.empty:
            pdr_overall = float(hops["received"].mean())
        if atk is not None and not atk.empty and hops is not None and not hops.empty:
            atk_times = pd.to_numeric(atk["Time"], errors="coerce").dropna()
            if not atk_times.empty:
                atk_start = int(atk_times.min())
                atk_end = int(atk_times.max())
                t_max = int(hops["t"].max())
                pdr_before = _pdr_in_range(hops, 0, atk_start - 1)
                pdr_during = _pdr_in_range(hops, atk_start, atk_end)
                pdr_after = _pdr_in_range(hops, atk_end + 1, t_max)

        return AttackNetworkEffect(
            msgs_dropped_by_attack=drops,
            victim_node_hexes=sorted(victims),
            pdr_overall=pdr_overall,
            pdr_before=pdr_before,
            pdr_during=pdr_during,
            pdr_after=pdr_after,
            atk_start_t=atk_start,
            atk_end_t=atk_end,
        )

    # -----------------------------------------------------------------------
    # Public: node-level
    # -----------------------------------------------------------------------

    def get_battery_history(self, node_hex: str) -> pd.DataFrame:
        sub = self._bat_all[self._bat_all["node_hex"] == node_hex][["t", "bat"]]
        return sub.sort_values("t").reset_index(drop=True)

    def get_tx_counts(self, node_hex: str) -> pd.Series:
        """TX event counts by msgtype for node."""
        hops = self.hops
        if hops is None or hops.empty:
            return pd.Series(dtype=int, name="count")
        return (
            hops[hops["src"] == node_hex]
            .groupby("msgtype")
            .size()
            .rename("count")
        )

    def get_rx_counts(self, node_hex: str) -> pd.Series:
        """RX counts by msgtype for messages received AT this node."""
        sub = self._rx_exploded[self._rx_exploded["rx_node"] == node_hex]
        if sub.empty:
            return pd.Series(dtype=int, name="count")
        return sub.groupby("msgtype").size().rename("count")

    def get_drop_stats(self, node_hex: str) -> dict[str, int]:
        """Messages sent by node_hex that were not received, grouped by reason."""
        hops = self.hops
        if hops is None or hops.empty:
            return {}
        missed = hops[(hops["src"] == node_hex) & ~hops["received"]]
        if missed.empty:
            return {}
        if "drop_reason" in missed.columns:
            return missed["drop_reason"].fillna("unknown").value_counts().to_dict()
        return {"not_received": len(missed)}

    def get_delivery_latency(self, node_hex: str) -> pd.DataFrame:
        """(msgtype, count, avg_latency_ticks) for messages sent by node_hex."""
        hops = self.hops
        if hops is None or hops.empty:
            return pd.DataFrame(columns=["msgtype", "count", "avg_latency_ticks"])
        src = hops[(hops["src"] == node_hex) & hops["received"] & hops["rx_t"].notna()].copy()
        if src.empty:
            return pd.DataFrame(columns=["msgtype", "count", "avg_latency_ticks"])
        src["latency"] = pd.to_numeric(src["rx_t"], errors="coerce") - src["t"]
        return (
            src.groupby("msgtype")
            .agg(count=("latency", "count"), avg_latency_ticks=("latency", "mean"))
            .reset_index()
        )

    def get_hello_compact(self, node_hex: str) -> dict:
        """Compact HELLO stats for one node.

        Returns:
            tx_times: list of ticks where this node broadcast HELLO
            rx_summary: {sender_hex: [t, ...]} — HELLO from others received here
            sent_rx_by_t: {t: [receiver_hexes]} — receivers of THIS node's hellos
            total_tx: int
            unique_receivers: list[str]
        """
        ev = self.events
        # HELLOs transmitted by this node
        tx_times: list[int] = (
            ev[(ev["node_hex"] == node_hex) & (ev["tag"] == "HELLO_TX")]["t"]
            .tolist()
        )
        # HELLOs from this node received at other nodes
        hello_rx = ev[
            (ev["tag"].isin(["HELLO_RX", "HELLO"])) & (ev["src"] == node_hex)
        ]
        sent_rx_by_t: dict[int, list[str]] = (
            hello_rx.groupby("t")["node_hex"].apply(list).to_dict()
            if not hello_rx.empty else {}
        )
        unique_receivers = list(hello_rx["node_hex"].unique()) if not hello_rx.empty else []

        # HELLOs from other nodes received by this node
        hellos_recv = ev[
            (ev["node_hex"] == node_hex) & ev["tag"].isin(["HELLO_RX", "HELLO"])
            & ev["src"].notna()
        ]
        rx_summary: dict[str, list[int]] = {}
        for sender, grp in hellos_recv.groupby("src"):
            rx_summary[str(sender)] = grp["t"].tolist()

        return {
            "tx_times": tx_times,
            "sent_rx_by_t": sent_rx_by_t,
            "total_tx": len(tx_times),
            "unique_receivers": unique_receivers,
            "rx_summary": rx_summary,
        }

    def get_sleep_intervals(self, node_hex: str) -> list[tuple[int, int | None]]:
        """[(t_enter_sleep, t_wake_or_None), ...]"""
        ev = self.events
        sleeps = ev[(ev["node_hex"] == node_hex) & (ev["tag"] == "ORPHAN_MODE")]["t"].tolist()
        recoveries = sorted(
            ev[(ev["node_hex"] == node_hex) & (ev["tag"] == "ORPHAN_RECOVERED")]["t"].tolist()
        )
        intervals = []
        for ts in sorted(sleeps):
            wake = next((tr for tr in recoveries if tr >= ts), None)
            intervals.append((ts, wake))
        return intervals

    def get_attack_victim_info(self, node_hex: str) -> dict | None:
        """Attack-related stats for one node. Returns None if not involved."""
        hops = self.hops
        if not self._attack_infos or hops is None or hops.empty:
            return None

        attacker_hexes_upper = {
            h.upper()
            for info in self._attack_infos
            for h in info.attacker_hexes
            if not h.startswith("#")
        }
        is_attacker = node_hex.upper() in attacker_hexes_upper

        if "drop_reason" in hops.columns:
            atk_mask = hops["drop_reason"].fillna("").str.startswith("attacker active")
            msgs_dropped_sent = int(
                ((hops["src"] == node_hex) & atk_mask).sum()
            )
            # approximation: check if this node appears in victim list
            victim_of_atk = node_hex in (self._attack_effect.victim_node_hexes if self._attack_effect else [])
        else:
            msgs_dropped_sent = 0
            victim_of_atk = False

        if not is_attacker and msgs_dropped_sent == 0 and not victim_of_atk:
            return None

        role = "Attacker" if is_attacker else "Victim"
        atk_type_names = (
            [i.attack_type_name for i in self._attack_infos if node_hex.upper() in
             [h.upper() for h in i.attacker_hexes]]
            if is_attacker else []
        )

        # attack log entries for this attacker
        actions: dict[str, int] = {}
        if is_attacker and self.attack_log is not None:
            atk_log = self.attack_log
            atk_log = atk_log.copy()
            atk_log["AttackType"] = pd.to_numeric(
                atk_log["AttackType"], errors="coerce"
            ).fillna(0).astype(int)
            for info in self._attack_infos:
                if node_hex.upper() in [h.upper() for h in info.attacker_hexes]:
                    actions.update(info.actions)

        return {
            "role": role,
            "attack_types": atk_type_names,
            "msgs_tx_dropped_by_attack": msgs_dropped_sent,
            "actions": actions,
            "is_attacker": is_attacker,
        }

    # -----------------------------------------------------------------------
    # Public: message traces
    # -----------------------------------------------------------------------

    def get_traces(
        self,
        node_hex: str | None = None,
        msg_type: str | None = None,
        t_lo: int | None = None,
        t_hi: int | None = None,
        compact_types: set[str] | None = None,
    ) -> list[dict]:
        """Filtered trace list. compact_types traces are excluded (shown separately)."""
        cmp = compact_types if compact_types is not None else config.COMPACT_TYPES
        result = []
        for tr in self.traces:
            if tr["msgtype"] in cmp:
                continue
            if node_hex and tr["origin_node"] != node_hex:
                continue
            if msg_type and tr["msgtype"] != msg_type:
                continue
            t = tr["origin_t"]
            if t_lo is not None and t < t_lo:
                continue
            if t_hi is not None and t > t_hi:
                continue
            result.append(tr)
        return result

    def get_available_msg_types(self) -> list[str]:
        cmp = config.COMPACT_TYPES
        seen: set[str] = set()
        for tr in self.traces:
            if tr["msgtype"] not in cmp:
                seen.add(tr["msgtype"])
        return sorted(seen)
