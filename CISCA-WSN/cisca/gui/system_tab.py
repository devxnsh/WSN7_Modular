"""System-Level tab for CISCA-WSN GUI.

Top section:  summary stat cards (nodes, messages, PDR, latency, battery)
Middle:       pyqtgraph time-series plot with toggleable series
Bottom:       Attack panel (hidden when no attack present)
"""
from __future__ import annotations

import math
from typing import Optional

import numpy as np
import pyqtgraph as pg
from PySide6.QtCore import Qt
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QCheckBox, QFrame, QGridLayout, QGroupBox, QHBoxLayout,
    QLabel, QScrollArea, QSizePolicy, QSpinBox, QSplitter,
    QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget,
)

from cisca.analytics import AnalyticsEngine, AttackNetworkEffect

# ---- colour palette (mirrors main_window) ----
BG_DARK = "#1a1a2e"
BG_PANEL = "#16213e"
BG_CARD = "#0f3460"
ACCENT = "#e94560"
TEXT_MAIN = "#eaeaea"
TEXT_DIM = "#7a7a9a"
BORDER = "#2a2a4a"

pg.setConfigOption("background", BG_PANEL)
pg.setConfigOption("foreground", TEXT_MAIN)

# series colour map
SERIES_COLORS = {
    "n_active_nodes":    "#4fc3f7",
    "n_tx_nodes":        "#81c784",
    "n_rx_nodes":        "#ffb74d",
    "n_sleeping_nodes":  "#ba68c8",
    "n_corrupted_events":"#ef5350",
    "avg_battery":       "#26c6da",
    "pdr":               "#66bb6a",
    "avg_latency_ticks": "#ffa726",
    "attack_active":     "#e94560",
}
SERIES_LABELS = {
    "n_active_nodes":    "Active Nodes",
    "n_tx_nodes":        "TX Nodes",
    "n_rx_nodes":        "RX Nodes",
    "n_sleeping_nodes":  "Sleeping Nodes",
    "n_corrupted_events":"Corrupt Events",
    "avg_battery":       "Avg Battery %",
    "pdr":               "PDR (0-1)",
    "avg_latency_ticks": "Avg Latency (ticks)",
}

CARD_STYLE = f"""
    QGroupBox {{
        background: {BG_CARD}; border: 1px solid {BORDER}; border-radius: 6px;
        padding: 8px; margin-top: 4px;
    }}
    QGroupBox::title {{ color: {TEXT_DIM}; font-size: 10px; subcontrol-origin: margin; left: 8px; }}
"""


def _stat_card(title: str, value: str, colour: str = TEXT_MAIN) -> QGroupBox:
    box = QGroupBox(title)
    box.setStyleSheet(CARD_STYLE)
    lay = QVBoxLayout(box)
    lay.setContentsMargins(4, 4, 4, 4)
    lbl = QLabel(value)
    lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
    lbl.setFont(QFont("Arial", 18, QFont.Weight.Bold))
    lbl.setStyleSheet(f"color: {colour};")
    lay.addWidget(lbl)
    return box


class _StatCard(QGroupBox):
    def __init__(self, title: str, colour: str = TEXT_MAIN, parent=None):
        super().__init__(title, parent)
        self.setStyleSheet(CARD_STYLE)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(4, 4, 4, 4)
        self._lbl = QLabel("—")
        self._lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._lbl.setFont(QFont("Arial", 18, QFont.Weight.Bold))
        self._lbl.setStyleSheet(f"color: {colour};")
        lay.addWidget(self._lbl)

    def set_value(self, v: str):
        self._lbl.setText(v)


class AttackPanel(QWidget):
    """Collapsible panel shown only when attack data is present."""

    def __init__(self, parent=None):
        super().__init__(parent)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(4)

        # header
        hdr = QLabel("  ⚠  ATTACK ANALYSIS")
        hdr.setStyleSheet(
            f"background: {ACCENT}; color: white; font-weight: bold; "
            f"font-size: 12px; padding: 4px 8px; border-radius: 4px;"
        )
        lay.addWidget(hdr)

        # info grid
        self._grid = QGridLayout()
        self._grid.setContentsMargins(8, 4, 8, 4)
        self._grid.setSpacing(6)
        lay.addLayout(self._grid)

        # per-attacker table
        self._tbl = QTableWidget()
        self._tbl.setColumnCount(7)
        self._tbl.setHorizontalHeaderLabels([
            "Attacker", "Attack Type", "Start t", "End t",
            "Events", "Top Action", "Intensity/tick",
        ])
        self._tbl.setStyleSheet(
            f"QTableWidget {{ background: {BG_PANEL}; color: {TEXT_MAIN}; "
            f"gridline-color: {BORDER}; font-size: 11px; }}"
            f"QHeaderView::section {{ background: {BG_CARD}; color: {TEXT_DIM}; "
            f"padding: 4px; border: none; }}"
        )
        self._tbl.setMaximumHeight(130)
        self._tbl.horizontalHeader().setStretchLastSection(True)
        self._tbl.verticalHeader().setVisible(False)
        lay.addWidget(self._tbl)

        # network effect summary
        effect_box = QGroupBox("Network Effect")
        effect_box.setStyleSheet(CARD_STYLE)
        eff_lay = QHBoxLayout(effect_box)
        self._eff_cards: dict[str, _StatCard] = {}
        for key, title, colour in [
            ("msgs_dropped",  "Msgs Dropped\n(by attack)",  ACCENT),
            ("victims",       "Victim Nodes",               "#ffb74d"),
            ("pdr_before",    "PDR Before",                 "#66bb6a"),
            ("pdr_during",    "PDR During",                 "#ef5350"),
            ("pdr_after",     "PDR After",                  "#4fc3f7"),
        ]:
            c = _StatCard(title, colour)
            self._eff_cards[key] = c
            eff_lay.addWidget(c)
        lay.addWidget(effect_box)

    def populate(self, engine: AnalyticsEngine):
        infos = engine.get_attack_infos()
        effect = engine.get_attack_effect()

        # fill per-attacker table
        self._tbl.setRowCount(len(infos))
        for r, info in enumerate(infos):
            top_action = max(info.actions, key=info.actions.get) if info.actions else "—"
            cells = [
                ", ".join(info.attacker_hexes),
                info.attack_type_name,
                str(info.start_t),
                str(info.end_t),
                str(info.event_count),
                top_action,
                f"{info.intensity_proxy:.2f}",
            ]
            for c, txt in enumerate(cells):
                item = QTableWidgetItem(txt)
                item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsEditable)
                self._tbl.setItem(r, c, item)
        self._tbl.resizeColumnsToContents()

        # fill effect cards
        if effect:
            self._eff_cards["msgs_dropped"].set_value(str(effect.msgs_dropped_by_attack))
            self._eff_cards["victims"].set_value(str(len(effect.victim_node_hexes)))

            def fmt_pdr(v):
                return f"{v:.1%}" if not (isinstance(v, float) and math.isnan(v)) else "—"

            self._eff_cards["pdr_before"].set_value(fmt_pdr(effect.pdr_before))
            self._eff_cards["pdr_during"].set_value(fmt_pdr(effect.pdr_during))
            self._eff_cards["pdr_after"].set_value(fmt_pdr(effect.pdr_after))


class SystemTab(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._engine: Optional[AnalyticsEngine] = None
        self._plots: dict[str, pg.PlotDataItem] = {}
        self._checkboxes: dict[str, QCheckBox] = {}
        self._ts_data: Optional[dict] = None

        root = QVBoxLayout(self)
        root.setContentsMargins(8, 8, 8, 8)
        root.setSpacing(8)

        # ---- stat cards row ----
        cards_row = QHBoxLayout()
        self._cards: dict[str, _StatCard] = {}
        for key, title, colour in [
            ("total_nodes",        "Total Nodes",       "#4fc3f7"),
            ("sim_ticks",          "Sim Ticks",         TEXT_MAIN),
            ("total_messages",     "Total Messages",    "#81c784"),
            ("pdr",                "PDR",               "#66bb6a"),
            ("avg_latency",        "Avg Latency\n(ticks)", "#ffb74d"),
            ("avg_final_battery",  "Avg Final\nBattery %",  "#26c6da"),
        ]:
            c = _StatCard(title, colour)
            self._cards[key] = c
            cards_row.addWidget(c)
        root.addLayout(cards_row)

        # ---- splitter: plot + attack panel ----
        splitter = QSplitter(Qt.Orientation.Vertical)
        root.addWidget(splitter)

        # ---- plot area ----
        plot_widget = QWidget()
        plot_lay = QVBoxLayout(plot_widget)
        plot_lay.setContentsMargins(0, 0, 0, 0)
        plot_lay.setSpacing(4)

        # bucket-size control
        ctrl = QHBoxLayout()
        ctrl.addWidget(QLabel("Bucket size (ticks):"))
        self._bucket_spin = QSpinBox()
        self._bucket_spin.setRange(10, 500)
        self._bucket_spin.setSingleStep(10)
        self._bucket_spin.setValue(50)
        self._bucket_spin.setStyleSheet(
            f"background: {BG_CARD}; color: {TEXT_MAIN}; border: 1px solid {BORDER};"
        )
        self._bucket_spin.valueChanged.connect(self._rebuild_plot)
        ctrl.addWidget(self._bucket_spin)
        ctrl.addStretch()

        # series toggle checkboxes
        for key, label in SERIES_LABELS.items():
            cb = QCheckBox(label)
            cb.setChecked(key in ("n_active_nodes", "n_tx_nodes", "n_rx_nodes", "pdr", "avg_battery"))
            cb.setStyleSheet(f"color: {SERIES_COLORS.get(key, TEXT_MAIN)}; font-size: 11px;")
            cb.stateChanged.connect(lambda _state, k=key: self._toggle_series(k))
            self._checkboxes[key] = cb
            ctrl.addWidget(cb)

        plot_lay.addLayout(ctrl)

        # pyqtgraph PlotWidget
        self._plot_widget = pg.PlotWidget(title="System Time Series")
        self._plot_widget.setLabel("bottom", "Simulation Tick")
        self._plot_widget.showGrid(x=True, y=True, alpha=0.3)
        self._plot_widget.addLegend(offset=(10, 10))
        plot_lay.addWidget(self._plot_widget)

        splitter.addWidget(plot_widget)

        # ---- attack panel ----
        self._attack_panel = AttackPanel()
        self._attack_panel.setVisible(False)
        attack_scroll = QScrollArea()
        attack_scroll.setWidget(self._attack_panel)
        attack_scroll.setWidgetResizable(True)
        attack_scroll.setMaximumHeight(300)
        attack_scroll.setStyleSheet(f"border: none; background: {BG_DARK};")
        splitter.addWidget(attack_scroll)
        self._attack_scroll = attack_scroll

        splitter.setStretchFactor(0, 3)
        splitter.setStretchFactor(1, 1)

    # -----------------------------------------------------------------------

    def load(self, engine: AnalyticsEngine):
        self._engine = engine
        st = engine.get_overall_stats()

        def fmt(v, fmt_str="{:.1f}"):
            if isinstance(v, float) and math.isnan(v):
                return "—"
            return fmt_str.format(v)

        self._cards["total_nodes"].set_value(str(st["total_nodes"]))
        self._cards["sim_ticks"].set_value(str(st["sim_ticks"]))
        self._cards["total_messages"].set_value(str(st["total_messages"]))
        self._cards["pdr"].set_value(
            f"{st['pdr']:.1%}" if not math.isnan(st["pdr"]) else "—"
        )
        self._cards["avg_latency"].set_value(fmt(st["avg_latency_ticks"], "{:.1f}"))
        self._cards["avg_final_battery"].set_value(
            fmt(st["avg_final_battery_pct"], "{:.1f}%")
        )

        if st["has_attack"]:
            self._attack_panel.populate(engine)
            self._attack_panel.setVisible(True)
            self._attack_scroll.setVisible(True)
        else:
            self._attack_panel.setVisible(False)
            self._attack_scroll.setVisible(False)

        self._rebuild_plot()

    def _rebuild_plot(self):
        if self._engine is None:
            return
        bsz = self._bucket_spin.value()
        ts = self._engine.get_system_timeseries(bsz)
        self._ts_data = {col: ts[col].values for col in ts.columns}
        t = ts["t"].values

        self._plot_widget.clear()
        self._plots.clear()

        # shade attack windows
        if "attack_active" in ts.columns:
            atk_mask = ts["attack_active"].fillna(False).values.astype(bool)
            in_block = False
            t0 = 0
            for i, active in enumerate(atk_mask):
                if active and not in_block:
                    t0 = t[i]
                    in_block = True
                elif not active and in_block:
                    region = pg.LinearRegionItem(
                        [t0, t[i - 1] + bsz],
                        brush=pg.mkBrush(233, 69, 96, 35),
                        movable=False,
                    )
                    self._plot_widget.addItem(region)
                    in_block = False
            if in_block:
                region = pg.LinearRegionItem(
                    [t0, t[-1] + bsz],
                    brush=pg.mkBrush(233, 69, 96, 35),
                    movable=False,
                )
                self._plot_widget.addItem(region)

        for key, label in SERIES_LABELS.items():
            if key not in self._ts_data:
                continue
            y = self._ts_data[key].astype(float)
            pen = pg.mkPen(color=SERIES_COLORS.get(key, "#ffffff"), width=2)
            curve = self._plot_widget.plot(
                t, y, pen=pen, name=label,
                connect="finite",
            )
            self._plots[key] = curve
            visible = self._checkboxes[key].isChecked()
            curve.setVisible(visible)

    def _toggle_series(self, key: str):
        if key in self._plots:
            self._plots[key].setVisible(self._checkboxes[key].isChecked())
