"""Node-Level tab for CISCA-WSN GUI.

Layout:
  Left panel: tier-grouped node tree
  Right panel (stacked):
    ┌── TX/RX bar charts (pyqtgraph) ──────────────────────┐
    ├── Battery sparkline + stats row                        │
    ├── Delivery latency table                               │
    ├── HELLO compact section                                │
    ├── Sleep intervals                                      │
    └── Attack victim section (if applicable)                │
"""
from __future__ import annotations

import math
from typing import Optional

import numpy as np
import pyqtgraph as pg
from PySide6.QtCore import Qt
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QFrame, QGroupBox, QHBoxLayout, QLabel, QScrollArea,
    QSizePolicy, QSplitter, QTableWidget, QTableWidgetItem,
    QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget,
)

from cisca.analytics import AnalyticsEngine
from cisca import config

BG_DARK = "#1a1a2e"
BG_PANEL = "#16213e"
BG_CARD = "#0f3460"
ACCENT = "#e94560"
TEXT_MAIN = "#eaeaea"
TEXT_DIM = "#7a7a9a"
BORDER = "#2a2a4a"

pg.setConfigOption("background", BG_PANEL)
pg.setConfigOption("foreground", TEXT_MAIN)

TIER_NAMES = {0: "SINK", 1: "GWN", 2: "CH", 3: "SENSOR"}
TIER_COLOURS = {
    0: "#e94560",   # sink — red
    1: "#4fc3f7",   # gwn  — blue
    2: "#81c784",   # ch   — green
    3: "#ffb74d",   # sensor — amber
}

CARD_STYLE = f"""
    QGroupBox {{
        background: {BG_CARD}; border: 1px solid {BORDER}; border-radius: 5px;
        padding: 6px; margin-top: 4px;
    }}
    QGroupBox::title {{ color: {TEXT_DIM}; font-size: 10px; subcontrol-origin: margin; left: 6px; }}
"""
TABLE_STYLE = (
    f"QTableWidget {{ background: {BG_PANEL}; color: {TEXT_MAIN}; "
    f"gridline-color: {BORDER}; font-size: 11px; border: none; }}"
    f"QHeaderView::section {{ background: {BG_CARD}; color: {TEXT_DIM}; "
    f"padding: 3px; border: none; }}"
)

# ---- colour ramp for bar charts ----
TYPE_COLOURS = [
    "#4fc3f7", "#81c784", "#ffb74d", "#ba68c8",
    "#ef5350", "#26c6da", "#ffa726", "#66bb6a",
    "#ec407a", "#7e57c2",
]


def _make_table(headers: list[str], max_h: int = 160) -> QTableWidget:
    tbl = QTableWidget()
    tbl.setColumnCount(len(headers))
    tbl.setHorizontalHeaderLabels(headers)
    tbl.setStyleSheet(TABLE_STYLE)
    tbl.setMaximumHeight(max_h)
    tbl.horizontalHeader().setStretchLastSection(True)
    tbl.verticalHeader().setVisible(False)
    tbl.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
    return tbl


def _fill_table(tbl: QTableWidget, rows: list[list[str]]):
    tbl.setRowCount(len(rows))
    for r, row in enumerate(rows):
        for c, txt in enumerate(row):
            item = QTableWidgetItem(str(txt))
            item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsEditable)
            tbl.setItem(r, c, item)
    tbl.resizeColumnsToContents()


class _BarChart(pg.PlotWidget):
    """Simple horizontal bar chart built on pyqtgraph BarGraphItem."""

    def __init__(self, title: str, parent=None):
        super().__init__(parent, title=title)
        self.setMaximumHeight(180)
        self.showGrid(x=True, y=False, alpha=0.3)

    def set_data(self, labels: list[str], values: list[float], colours: list[str]):
        self.clear()
        if not labels:
            return
        x = np.arange(len(labels), dtype=float)
        for i, (v, c) in enumerate(zip(values, colours)):
            bar = pg.BarGraphItem(x=[x[i]], height=[v], width=0.7, brush=c)
            self.addItem(bar)
        ax = self.getAxis("bottom")
        ax.setTicks([list(zip(x, labels))])
        self.setLabel("left", "Count")


class NodeDetailPanel(QScrollArea):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWidgetResizable(True)
        self.setStyleSheet(f"border: none; background: {BG_DARK};")

        self._inner = QWidget()
        self.setWidget(self._inner)
        lay = QVBoxLayout(self._inner)
        lay.setContentsMargins(8, 8, 8, 8)
        lay.setSpacing(8)

        # ---- node header ----
        self._header = QLabel("Select a node")
        self._header.setFont(QFont("Arial", 14, QFont.Weight.Bold))
        self._header.setStyleSheet(f"color: {TEXT_MAIN}; padding: 4px;")
        lay.addWidget(self._header)

        # ---- summary cards row ----
        cards_row = QHBoxLayout()
        self._sum_cards: dict[str, QLabel] = {}
        for key, title in [
            ("tx_total", "Messages TX"),
            ("rx_total", "Messages RX"),
            ("dropped",  "Dropped (sent)"),
            ("pdr",      "Delivery Rate"),
            ("avg_lat",  "Avg Latency\n(ticks)"),
            ("bat_last", "Last Battery %"),
        ]:
            grp = QGroupBox(title)
            grp.setStyleSheet(CARD_STYLE)
            gl = QVBoxLayout(grp)
            gl.setContentsMargins(2, 2, 2, 2)
            lbl = QLabel("—")
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lbl.setFont(QFont("Arial", 14, QFont.Weight.Bold))
            lbl.setStyleSheet(f"color: {TEXT_MAIN};")
            gl.addWidget(lbl)
            self._sum_cards[key] = lbl
            cards_row.addWidget(grp)
        lay.addLayout(cards_row)

        # ---- TX / RX bar charts ----
        charts_row = QHBoxLayout()
        self._tx_chart = _BarChart("Messages Transmitted (by type)")
        self._rx_chart = _BarChart("Messages Received (by type)")
        charts_row.addWidget(self._tx_chart)
        charts_row.addWidget(self._rx_chart)
        lay.addLayout(charts_row)

        # ---- drop stats ----
        drop_box = QGroupBox("Drop Reasons (messages sent by this node, not received)")
        drop_box.setStyleSheet(CARD_STYLE)
        drop_lay = QVBoxLayout(drop_box)
        self._drop_tbl = _make_table(["Reason", "Count"], 120)
        drop_lay.addWidget(self._drop_tbl)
        lay.addWidget(drop_box)

        # ---- delivery latency table ----
        lat_box = QGroupBox("Delivery Latency (immediate next-hop)")
        lat_box.setStyleSheet(CARD_STYLE)
        lat_lay = QVBoxLayout(lat_box)
        self._lat_tbl = _make_table(["Message Type", "Count", "Avg Latency (ticks)"], 140)
        lat_lay.addWidget(self._lat_tbl)
        lay.addWidget(lat_box)

        # ---- battery sparkline ----
        bat_box = QGroupBox("Battery % Over Time")
        bat_box.setStyleSheet(CARD_STYLE)
        bat_lay = QVBoxLayout(bat_box)
        self._bat_plot = pg.PlotWidget()
        self._bat_plot.setMaximumHeight(150)
        self._bat_plot.setLabel("bottom", "Tick")
        self._bat_plot.setLabel("left", "%")
        self._bat_plot.showGrid(x=True, y=True, alpha=0.3)
        self._bat_plot.setYRange(0, 105)
        bat_lay.addWidget(self._bat_plot)
        lay.addWidget(bat_box)

        # ---- HELLO compact ----
        self._hello_box = QGroupBox("HELLO Beacon Summary")
        self._hello_box.setStyleSheet(CARD_STYLE)
        hello_lay = QVBoxLayout(self._hello_box)
        self._hello_lbl = QLabel()
        self._hello_lbl.setWordWrap(True)
        self._hello_lbl.setStyleSheet(f"color: {TEXT_DIM}; font-size: 11px; font-family: monospace;")
        hello_lay.addWidget(self._hello_lbl)
        self._hello_rx_tbl = _make_table(["Sender Hex", "# HELLOs Received", "First t", "Last t"], 120)
        hello_lay.addWidget(self._hello_rx_tbl)
        lay.addWidget(self._hello_box)

        # ---- sleep intervals ----
        self._sleep_box = QGroupBox("Sleep/Orphan Intervals")
        self._sleep_box.setStyleSheet(CARD_STYLE)
        sleep_lay = QVBoxLayout(self._sleep_box)
        self._sleep_tbl = _make_table(["Enter Sleep (t)", "Recovered (t)", "Duration"], 120)
        sleep_lay.addWidget(self._sleep_tbl)
        lay.addWidget(self._sleep_box)

        # ---- attack victim section ----
        self._atk_box = QGroupBox("⚠  Attack Involvement")
        self._atk_box.setStyleSheet(
            CARD_STYLE.replace(BG_CARD, "#3d0000")
        )
        atk_lay = QVBoxLayout(self._atk_box)
        self._atk_lbl = QLabel()
        self._atk_lbl.setWordWrap(True)
        self._atk_lbl.setStyleSheet(f"color: {ACCENT}; font-size: 12px;")
        atk_lay.addWidget(self._atk_lbl)
        self._atk_box.setVisible(False)
        lay.addWidget(self._atk_box)

        lay.addStretch()

    def load_node(self, node_hex: str, engine: AnalyticsEngine):
        tier = next(
            (t for h, _ty, t in engine.node_list if h == node_hex), 99
        )
        tier_name = TIER_NAMES.get(tier, f"Tier {tier}")
        colour = TIER_COLOURS.get(tier, TEXT_MAIN)
        self._header.setText(f"Node  {node_hex}  [{tier_name}]")
        self._header.setStyleSheet(f"color: {colour}; font-weight: bold; font-size: 14px;")

        # TX / RX counts
        tx = engine.get_tx_counts(node_hex)
        rx = engine.get_rx_counts(node_hex)
        drops = engine.get_drop_stats(node_hex)
        n_tx = int(tx.sum()) if not tx.empty else 0
        n_rx = int(rx.sum()) if not rx.empty else 0
        n_drop = sum(drops.values())
        pdr_str = f"{(n_tx - n_drop) / n_tx:.1%}" if n_tx > 0 else "—"

        # battery
        bat_hist = engine.get_battery_history(node_hex)
        bat_last = f"{bat_hist['bat'].iloc[-1]:.1f}%" if not bat_hist.empty else "—"

        # latency
        lat = engine.get_delivery_latency(node_hex)
        avg_lat = (
            f"{lat['avg_latency_ticks'].mean():.1f}"
            if not lat.empty else "—"
        )

        self._sum_cards["tx_total"].setText(str(n_tx))
        self._sum_cards["rx_total"].setText(str(n_rx))
        self._sum_cards["dropped"].setText(str(n_drop))
        self._sum_cards["pdr"].setText(pdr_str)
        self._sum_cards["avg_lat"].setText(avg_lat)
        self._sum_cards["bat_last"].setText(bat_last)

        # TX bar chart
        tx_labels = list(tx.index)
        tx_vals = [float(v) for v in tx.values]
        tx_cols = [TYPE_COLOURS[i % len(TYPE_COLOURS)] for i in range(len(tx_labels))]
        self._tx_chart.set_data(tx_labels, tx_vals, tx_cols)

        # RX bar chart
        rx_labels = list(rx.index)
        rx_vals = [float(v) for v in rx.values]
        rx_cols = [TYPE_COLOURS[i % len(TYPE_COLOURS)] for i in range(len(rx_labels))]
        self._rx_chart.set_data(rx_labels, rx_vals, rx_cols)

        # drop table
        _fill_table(self._drop_tbl, [[r, str(c)] for r, c in drops.items()])

        # latency table
        if not lat.empty:
            _fill_table(self._lat_tbl, [
                [row["msgtype"], str(row["count"]), f"{row['avg_latency_ticks']:.2f}"]
                for _, row in lat.iterrows()
            ])
        else:
            _fill_table(self._lat_tbl, [])

        # battery sparkline
        self._bat_plot.clear()
        if not bat_hist.empty:
            pen = pg.mkPen(color="#26c6da", width=2)
            self._bat_plot.plot(bat_hist["t"].values, bat_hist["bat"].values, pen=pen)

        # HELLO compact
        hello = engine.get_hello_compact(node_hex)
        n_tx_h = hello["total_tx"]
        n_rcvrs = len(hello["unique_receivers"])
        # summarise TX times compactly
        tx_times = hello["tx_times"]
        if tx_times:
            if len(tx_times) <= 10:
                tx_str = ", ".join(str(t) for t in tx_times[:10])
            else:
                tx_str = (
                    f"{tx_times[0]}, {tx_times[1]}, … {tx_times[-2]}, {tx_times[-1]}"
                    f"  ({len(tx_times)} total)"
                )
        else:
            tx_str = "none"
        self._hello_lbl.setText(
            f"TX: {n_tx_h} hellos  |  Sent at ticks: {tx_str}\n"
            f"Received by {n_rcvrs} unique node(s): {', '.join(hello['unique_receivers'][:12])}"
        )
        # HELLO RX table (other nodes' hellos received HERE)
        rx_sum = hello["rx_summary"]
        rx_rows = []
        for sender, times in sorted(rx_sum.items()):
            rx_rows.append([sender, str(len(times)), str(min(times)), str(max(times))])
        _fill_table(self._hello_rx_tbl, rx_rows)

        # sleep intervals
        sleeps = engine.get_sleep_intervals(node_hex)
        sleep_rows = []
        for t_in, t_out in sleeps:
            dur = "ongoing" if t_out is None else str(t_out - t_in)
            sleep_rows.append([str(t_in), str(t_out) if t_out else "—", dur])
        _fill_table(self._sleep_tbl, sleep_rows)
        self._sleep_box.setVisible(bool(sleeps))

        # attack victim
        atk = engine.get_attack_victim_info(node_hex)
        if atk:
            role_str = f"[{atk['role']}]"
            if atk["is_attacker"]:
                types_str = ", ".join(atk["attack_types"]) or "Unknown"
                actions_str = "  ".join(
                    f"{a}: {c}" for a, c in atk["actions"].items()
                )
                text = (
                    f"{role_str}  Attack type(s): {types_str}\n"
                    f"Actions logged: {actions_str or '—'}"
                )
            else:
                text = (
                    f"{role_str}  Messages sent by this node dropped due to active attack: "
                    f"{atk['msgs_tx_dropped_by_attack']}"
                )
            self._atk_lbl.setText(text)
            self._atk_box.setVisible(True)
        else:
            self._atk_box.setVisible(False)


class NodeTab(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._engine: Optional[AnalyticsEngine] = None

        root = QHBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        root.addWidget(splitter)

        # ---- node tree (left) ----
        tree_widget = QWidget()
        tree_lay = QVBoxLayout(tree_widget)
        tree_lay.setContentsMargins(4, 4, 4, 4)
        tree_lay.setSpacing(4)

        lbl = QLabel("Nodes by Tier")
        lbl.setStyleSheet(f"color: {TEXT_DIM}; font-size: 10px; font-weight: bold;")
        tree_lay.addWidget(lbl)

        self._tree = QTreeWidget()
        self._tree.setHeaderHidden(True)
        self._tree.setStyleSheet(
            f"QTreeWidget {{ background: {BG_PANEL}; color: {TEXT_MAIN}; "
            f"border: 1px solid {BORDER}; font-family: monospace; font-size: 11px; }}"
            f"QTreeWidget::item:selected {{ background: {BG_CARD}; }}"
        )
        self._tree.itemSelectionChanged.connect(self._on_node_selected)
        tree_lay.addWidget(self._tree)

        tree_widget.setFixedWidth(210)
        splitter.addWidget(tree_widget)

        # ---- detail panel (right) ----
        self._detail = NodeDetailPanel()
        splitter.addWidget(self._detail)
        splitter.setStretchFactor(1, 1)

    def load(self, engine: AnalyticsEngine):
        self._engine = engine
        self._tree.clear()

        # Group nodes by tier
        tier_items: dict[int, QTreeWidgetItem] = {}
        for node_hex, node_type, tier in engine.node_list:
            if tier not in tier_items:
                tier_name = TIER_NAMES.get(tier, f"Tier {tier}")
                grp = QTreeWidgetItem([f"▸ {tier_name}"])
                grp.setForeground(0, pg.mkColor(TIER_COLOURS.get(tier, TEXT_MAIN)))
                grp.setFont(0, QFont("Arial", 10, QFont.Weight.Bold))
                grp.setExpanded(True)
                self._tree.addTopLevelItem(grp)
                tier_items[tier] = grp

            child = QTreeWidgetItem([node_hex])
            child.setData(0, Qt.ItemDataRole.UserRole, node_hex)
            child.setForeground(0, pg.mkColor(TIER_COLOURS.get(tier, TEXT_MAIN)))
            tier_items[tier].addChild(child)

    def _on_node_selected(self):
        if self._engine is None:
            return
        items = self._tree.selectedItems()
        if not items:
            return
        node_hex = items[0].data(0, Qt.ItemDataRole.UserRole)
        if node_hex is None:
            return
        self._detail.load_node(node_hex, self._engine)
