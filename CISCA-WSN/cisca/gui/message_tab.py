"""Message-Level tab for CISCA-WSN GUI.

Left panel:  Filters (type, origin node, time range, compact/expanded toggle)
             + Message list table
Right panel: Path trace tree for selected message
             + HELLO compact section (when type filter = HELLO or Compact)

Message paths are rendered as a QTreeWidget where each stage is a branch:
  Transmitted (type, t=50, src=AA01) ──> CH_HELLO
    Received (t=51) at FF03
      Forwarded (t=51) to FF0D
        Received (t=52) at FF0D
          [Delivered to receivers]
"""
from __future__ import annotations

import math
from typing import Optional

from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QFont
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QGroupBox, QHBoxLayout, QHeaderView,
    QLabel, QLineEdit, QScrollArea, QSizePolicy, QSplitter,
    QTableWidget, QTableWidgetItem, QTreeWidget, QTreeWidgetItem,
    QVBoxLayout, QWidget,
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
TREE_STYLE = (
    f"QTreeWidget {{ background: {BG_PANEL}; color: {TEXT_MAIN}; "
    f"border: 1px solid {BORDER}; font-family: monospace; font-size: 11px; }}"
    f"QTreeWidget::item:selected {{ background: {BG_CARD}; }}"
    f"QTreeWidget::branch {{ background: {BG_PANEL}; }}"
)

# ---- terminal-stage colour coding ----
TERMINAL_COLOURS = {
    "Received":               "#66bb6a",
    "Delivered to receivers": "#66bb6a",
    "Merged into aggregate":  "#4fc3f7",
    "Absorbed at receiver":   "#4fc3f7",
    "Not Received":           "#ef5350",
    "Queued":                 "#ffb74d",
}


def _stage_colour(kind: str) -> str:
    for key, col in TERMINAL_COLOURS.items():
        if kind.startswith(key):
            return col
    if kind == "Transmitted":
        return "#81c784"
    if kind in ("Forwarded", "Clustered/Aggregated", "Received"):
        return "#4fc3f7"
    return TEXT_MAIN


def _format_stage(stage: tuple) -> str:
    """Convert a path stage tuple to a readable string."""
    kind = stage[0]
    t = stage[1]
    node = stage[2] if len(stage) > 2 else ""
    detail = stage[3] if len(stage) > 3 else {}

    if kind == "Transmitted":
        dtype = detail.get("type", "?")
        sub = detail.get("subtype", "")
        dst = detail.get("dst", "?")
        sub_str = f".{sub}" if sub and sub != "0" else ""
        return f"TX  {dtype}{sub_str}  →  {dst}   (t={t})"
    if kind == "Received":
        return f"RX  at {node}   (t={t})"
    if kind == "Received (broadcast)":
        n = detail.get("receiver_count", "?")
        return f"RX (broadcast)  {n} nodes   (t={t})"
    if kind == "Forwarded":
        dst = detail.get("dst", "?")
        return f"FWD  →  {dst}   (t={t})"
    if kind == "Clustered/Aggregated":
        k = detail.get("batch_k_sensors", "?")
        return f"CLUSTERED / AGG  (batch={k} sensors)   (t={t})"
    return f"{kind}   (t={t})"


def _format_terminal(term: tuple) -> str:
    if not term:
        return "— no terminal —"
    kind = term[0]
    t = term[1]
    extra = term[2] if len(term) > 2 else ""
    if kind == "Not Received":
        return f"✗ NOT RECEIVED  — {extra}"
    if kind.startswith("Delivered"):
        return f"✔ {kind}  at  {extra}   (t={t})"
    if kind.startswith("Merged"):
        return f"✔ {kind}  at  {extra}   (t={t})"
    return f"• {kind}   (t={t})   {extra}"


class PathTree(QWidget):
    """Displays one message trace as a collapsible QTreeWidget."""

    def __init__(self, parent=None):
        super().__init__(parent)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)

        self._hdr = QLabel("Select a message to trace its path")
        self._hdr.setWordWrap(True)
        self._hdr.setStyleSheet(
            f"color: {TEXT_DIM}; font-size: 11px; padding: 4px; font-family: monospace;"
        )
        lay.addWidget(self._hdr)

        self._tree = QTreeWidget()
        self._tree.setHeaderHidden(True)
        self._tree.setStyleSheet(TREE_STYLE)
        lay.addWidget(self._tree)

    def load_trace(self, trace: dict):
        self._tree.clear()
        mtype = trace.get("msgtype", "?")
        sub = trace.get("subtype", "")
        orig = trace.get("origin_node", "?")
        t0 = trace.get("origin_t", "?")
        sub_str = f".{sub}" if sub and sub not in ("0", None) else ""
        self._hdr.setText(
            f"Trace:  {mtype}{sub_str}   origin={orig}   t={t0}"
        )

        path = trace.get("path", [])
        terminal = trace.get("terminal")

        prev_item = None
        for stage in path:
            kind = stage[0]
            colour = _stage_colour(kind)
            label = _format_stage(stage)
            item = QTreeWidgetItem([label])
            item.setForeground(0, QColor(colour))
            if prev_item is None:
                self._tree.addTopLevelItem(item)
            else:
                prev_item.addChild(item)
            item.setExpanded(True)
            prev_item = item

        if terminal:
            kind_t = terminal[0]
            colour_t = _stage_colour(kind_t)
            label_t = _format_terminal(terminal)
            t_item = QTreeWidgetItem([label_t])
            t_item.setForeground(0, QColor(colour_t))
            t_item.setFont(0, QFont("monospace", 11, QFont.Weight.Bold))
            if prev_item is None:
                self._tree.addTopLevelItem(t_item)
            else:
                prev_item.addChild(t_item)

        self._tree.expandAll()


class HelloCompactPanel(QGroupBox):
    """Compact summary of HELLO beacons for a given origin node."""

    def __init__(self, parent=None):
        super().__init__("HELLO Compact Vector", parent)
        self.setStyleSheet(CARD_STYLE)
        lay = QVBoxLayout(self)

        self._info_lbl = QLabel()
        self._info_lbl.setWordWrap(True)
        self._info_lbl.setStyleSheet(
            f"color: {TEXT_DIM}; font-size: 11px; font-family: monospace;"
        )
        lay.addWidget(self._info_lbl)

        lbl2 = QLabel("TX times (coverage per bucket):")
        lbl2.setStyleSheet(f"color: {TEXT_DIM}; font-size: 10px;")
        lay.addWidget(lbl2)

        self._tbl = QTableWidget()
        self._tbl.setColumnCount(3)
        self._tbl.setHorizontalHeaderLabels(["Tick range", "Hellos sent", "Unique receivers"])
        self._tbl.setStyleSheet(TABLE_STYLE)
        self._tbl.setMaximumHeight(160)
        self._tbl.horizontalHeader().setStretchLastSection(True)
        self._tbl.verticalHeader().setVisible(False)
        self._tbl.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        lay.addWidget(self._tbl)

    def load(self, hello: dict, bucket_size: int = 50):
        tx_times = hello["tx_times"]
        sent_rx = hello["sent_rx_by_t"]
        n_tx = hello["total_tx"]
        unique = hello["unique_receivers"]

        self._info_lbl.setText(
            f"Total HELLOs transmitted: {n_tx}    "
            f"Unique nodes that received: {len(unique)}    "
            f"Receivers: {', '.join(unique[:20]) or '—'}"
        )

        # bucket TX times
        if not tx_times:
            self._tbl.setRowCount(0)
            return
        t_min = min(tx_times)
        t_max = max(tx_times)
        buckets = range(
            (t_min // bucket_size) * bucket_size,
            ((t_max // bucket_size) + 1) * bucket_size,
            bucket_size,
        )
        rows = []
        for b in buckets:
            b_end = b + bucket_size
            sent_in = [t for t in tx_times if b <= t < b_end]
            rcvrs: set[str] = set()
            for t in sent_in:
                rcvrs.update(sent_rx.get(t, []))
            if sent_in:
                rows.append([f"t={b}-{b_end}", str(len(sent_in)), str(len(rcvrs))])
        self._tbl.setRowCount(len(rows))
        for r, row in enumerate(rows):
            for c, txt in enumerate(row):
                item = QTableWidgetItem(txt)
                item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsEditable)
                self._tbl.setItem(r, c, item)
        self._tbl.resizeColumnsToContents()


class MessageTab(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._engine: Optional[AnalyticsEngine] = None
        self._filtered_traces: list[dict] = []

        root = QHBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        root.addWidget(splitter)

        # ================================================================
        # LEFT: filter controls + message list
        # ================================================================
        left = QWidget()
        left.setFixedWidth(420)
        left_lay = QVBoxLayout(left)
        left_lay.setContentsMargins(6, 6, 6, 6)
        left_lay.setSpacing(6)

        # ---- filter box ----
        fbox = QGroupBox("Filters")
        fbox.setStyleSheet(CARD_STYLE)
        flay = QVBoxLayout(fbox)
        flay.setSpacing(4)

        # type dropdown
        row_type = QHBoxLayout()
        row_type.addWidget(QLabel("Msg Type:"))
        self._type_combo = QComboBox()
        self._type_combo.setStyleSheet(
            f"background: {BG_CARD}; color: {TEXT_MAIN}; border: 1px solid {BORDER};"
        )
        self._type_combo.currentIndexChanged.connect(self._apply_filters)
        row_type.addWidget(self._type_combo)
        flay.addLayout(row_type)

        # node filter
        row_node = QHBoxLayout()
        row_node.addWidget(QLabel("Origin Node:"))
        self._node_edit = QLineEdit()
        self._node_edit.setPlaceholderText("hex or blank for all")
        self._node_edit.setStyleSheet(
            f"background: {BG_CARD}; color: {TEXT_MAIN}; border: 1px solid {BORDER}; padding: 3px;"
        )
        self._node_edit.textChanged.connect(self._apply_filters)
        row_node.addWidget(self._node_edit)
        flay.addLayout(row_node)

        # time range
        row_t = QHBoxLayout()
        row_t.addWidget(QLabel("t  from:"))
        self._t_lo = QLineEdit("0")
        self._t_lo.setFixedWidth(60)
        self._t_lo.setStyleSheet(
            f"background: {BG_CARD}; color: {TEXT_MAIN}; border: 1px solid {BORDER}; padding: 3px;"
        )
        self._t_lo.textChanged.connect(self._apply_filters)
        row_t.addWidget(self._t_lo)
        row_t.addWidget(QLabel("to:"))
        self._t_hi = QLineEdit()
        self._t_hi.setPlaceholderText("max")
        self._t_hi.setFixedWidth(60)
        self._t_hi.setStyleSheet(
            f"background: {BG_CARD}; color: {TEXT_MAIN}; border: 1px solid {BORDER}; padding: 3px;"
        )
        self._t_hi.textChanged.connect(self._apply_filters)
        row_t.addWidget(self._t_hi)
        flay.addLayout(row_t)

        # compact-type toggle
        self._show_compact = QCheckBox("Show compact messages (HELLO/HB/TOKEN) as HELLO section")
        self._show_compact.setChecked(True)
        self._show_compact.setStyleSheet(f"color: {TEXT_DIM}; font-size: 10px;")
        self._show_compact.stateChanged.connect(self._apply_filters)
        flay.addWidget(self._show_compact)

        left_lay.addWidget(fbox)

        # ---- result count ----
        self._count_lbl = QLabel("0 messages")
        self._count_lbl.setStyleSheet(f"color: {TEXT_DIM}; font-size: 10px;")
        left_lay.addWidget(self._count_lbl)

        # ---- message list table ----
        self._msg_tbl = QTableWidget()
        self._msg_tbl.setColumnCount(5)
        self._msg_tbl.setHorizontalHeaderLabels(
            ["t", "Origin", "Type", "Destination", "Terminal"]
        )
        self._msg_tbl.setStyleSheet(TABLE_STYLE)
        self._msg_tbl.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self._msg_tbl.setSelectionMode(QTableWidget.SelectionMode.SingleSelection)
        self._msg_tbl.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self._msg_tbl.horizontalHeader().setStretchLastSection(True)
        self._msg_tbl.verticalHeader().setVisible(False)
        self._msg_tbl.itemSelectionChanged.connect(self._on_msg_selected)
        left_lay.addWidget(self._msg_tbl)

        splitter.addWidget(left)

        # ================================================================
        # RIGHT: path trace + HELLO compact
        # ================================================================
        right_scroll = QScrollArea()
        right_scroll.setWidgetResizable(True)
        right_scroll.setStyleSheet(f"border: none; background: {BG_DARK};")

        right = QWidget()
        right_lay = QVBoxLayout(right)
        right_lay.setContentsMargins(8, 8, 8, 8)
        right_lay.setSpacing(8)

        lbl = QLabel("MESSAGE PATH TRACE")
        lbl.setFont(QFont("Arial", 12, QFont.Weight.Bold))
        lbl.setStyleSheet(f"color: {ACCENT}; padding: 4px;")
        right_lay.addWidget(lbl)

        self._path_tree = PathTree()
        self._path_tree.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding
        )
        right_lay.addWidget(self._path_tree)

        sep = QLabel()
        sep.setFrameStyle(QLabel.Shape.HLine)
        sep.setStyleSheet(f"color: {BORDER};")
        right_lay.addWidget(sep)

        self._hello_panel = HelloCompactPanel()
        self._hello_panel.setVisible(False)
        right_lay.addWidget(self._hello_panel)

        right_lay.addStretch()
        right_scroll.setWidget(right)
        splitter.addWidget(right_scroll)
        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)

    # -----------------------------------------------------------------------

    def load(self, engine: AnalyticsEngine):
        self._engine = engine

        # Populate type combo
        self._type_combo.blockSignals(True)
        self._type_combo.clear()
        self._type_combo.addItem("All types")
        for mt in engine.get_available_msg_types():
            self._type_combo.addItem(mt)
        self._type_combo.blockSignals(False)

        # Set max t
        if not engine.events.empty:
            t_max = int(engine.events["t"].max())
            self._t_hi.setText(str(t_max))

        self._apply_filters()

    def _apply_filters(self):
        if self._engine is None:
            return

        mt = self._type_combo.currentText()
        msg_type = None if mt == "All types" else mt
        node_hex = self._node_edit.text().strip().upper() or None

        try:
            t_lo = int(self._t_lo.text())
        except ValueError:
            t_lo = None
        try:
            t_hi = int(self._t_hi.text())
        except ValueError:
            t_hi = None

        compact_types: set[str] | None = (
            config.COMPACT_TYPES if self._show_compact.isChecked() else set()
        )

        self._filtered_traces = self._engine.get_traces(
            node_hex=node_hex,
            msg_type=msg_type,
            t_lo=t_lo,
            t_hi=t_hi,
            compact_types=compact_types,
        )

        self._count_lbl.setText(f"{len(self._filtered_traces)} message(s)")
        self._populate_table()

        # Show HELLO compact section when compact types visible
        if self._show_compact.isChecked() and node_hex:
            hello = self._engine.get_hello_compact(node_hex)
            if hello["total_tx"] > 0:
                self._hello_panel.load(hello)
                self._hello_panel.setVisible(True)
            else:
                self._hello_panel.setVisible(False)
        else:
            self._hello_panel.setVisible(False)

    def _populate_table(self):
        traces = self._filtered_traces
        self._msg_tbl.clearSelection()
        self._msg_tbl.setRowCount(len(traces))

        for r, tr in enumerate(traces):
            term = tr.get("terminal")
            term_kind = term[0] if term else "—"
            term_colour = QColor(_stage_colour(term_kind))

            mtype = tr["msgtype"]
            sub = tr.get("subtype", "")
            sub_str = f".{sub}" if sub and sub not in ("0", None) else ""
            type_str = f"{mtype}{sub_str}"

            dst = ""
            if tr.get("path"):
                first_stage = tr["path"][0]
                if len(first_stage) > 3:
                    dst = first_stage[3].get("dst", "")

            cells = [
                str(tr.get("origin_t", "")),
                str(tr.get("origin_node", "")),
                type_str,
                dst,
                term_kind,
            ]
            for c, txt in enumerate(cells):
                item = QTableWidgetItem(txt)
                item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsEditable)
                item.setData(Qt.ItemDataRole.UserRole, r)
                if c == 4:
                    item.setForeground(term_colour)
                self._msg_tbl.setItem(r, c, item)

        self._msg_tbl.resizeColumnsToContents()

    def _on_msg_selected(self):
        items = self._msg_tbl.selectedItems()
        if not items:
            return
        r = items[0].data(Qt.ItemDataRole.UserRole)
        if r is None or r >= len(self._filtered_traces):
            return
        self._path_tree.load_trace(self._filtered_traces[r])
