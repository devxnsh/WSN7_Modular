"""CISCA-WSN main application window.

Layout:
  ┌─ left sidebar ─────────────────────────────────────────┐
  │  logs-dir label + [Browse] button                       │
  │  Run list (QListWidget, newest first)                   │
  │  [Load Selected Run] button                             │
  └─────────────────────────────────────────────────────────┘
  ┌─ centre (QTabWidget) ───────────────────────────────────┐
  │  System | Node | Message                                │
  └─────────────────────────────────────────────────────────┘
  Status bar with parse progress.
"""
from __future__ import annotations

import sys
import traceback
from pathlib import Path
from typing import Optional

import pandas as pd
from PySide6.QtCore import (
    QObject, QRunnable, QThread, QThreadPool, Qt, Signal, Slot
)
from PySide6.QtGui import QColor, QFont, QPalette
from PySide6.QtWidgets import (
    QApplication, QFileDialog, QHBoxLayout, QLabel, QListWidget,
    QListWidgetItem, QMainWindow, QPushButton, QSizePolicy, QSplitter,
    QStatusBar, QTabWidget, QVBoxLayout, QWidget, QProgressBar, QFrame,
)

from cisca.run_discovery import discover_runs, RunFiles
from cisca.parser import parse_combined
from cisca.reconstruct import pair_hops, classify_not_received, build_message_traces
from cisca.analytics import AnalyticsEngine

# Tabs (imported lazily to keep startup fast)
from cisca.gui.system_tab import SystemTab
from cisca.gui.node_tab import NodeTab
from cisca.gui.message_tab import MessageTab

# ---------------------------------------------------------------------------
# Colour palette (dark)
# ---------------------------------------------------------------------------
BG_DARK = "#1a1a2e"
BG_PANEL = "#16213e"
BG_CARD = "#0f3460"
ACCENT = "#e94560"
TEXT_MAIN = "#eaeaea"
TEXT_DIM = "#7a7a9a"
BORDER = "#2a2a4a"

STYLE_MAIN = f"""
QMainWindow, QWidget {{ background: {BG_DARK}; color: {TEXT_MAIN}; }}
QSplitter::handle {{ background: {BORDER}; }}
QListWidget {{
    background: {BG_PANEL}; border: 1px solid {BORDER}; color: {TEXT_MAIN};
    font-family: monospace; font-size: 11px;
}}
QListWidget::item:selected {{ background: {BG_CARD}; color: white; }}
QPushButton {{
    background: {BG_CARD}; color: {TEXT_MAIN}; border: 1px solid {ACCENT};
    border-radius: 4px; padding: 5px 10px; font-size: 12px;
}}
QPushButton:hover {{ background: {ACCENT}; color: white; }}
QPushButton:disabled {{ background: {BG_PANEL}; color: {TEXT_DIM}; border-color: {BORDER}; }}
QTabWidget::pane {{ border: 1px solid {BORDER}; background: {BG_PANEL}; }}
QTabBar::tab {{
    background: {BG_PANEL}; color: {TEXT_DIM}; padding: 6px 16px;
    border: 1px solid {BORDER}; border-bottom: none; border-radius: 4px 4px 0 0;
}}
QTabBar::tab:selected {{ background: {BG_CARD}; color: white; }}
QStatusBar {{ background: {BG_PANEL}; color: {TEXT_DIM}; }}
QLabel {{ color: {TEXT_MAIN}; }}
QProgressBar {{
    background: {BG_PANEL}; border: 1px solid {BORDER}; height: 8px;
    text-align: center; color: {TEXT_MAIN};
}}
QProgressBar::chunk {{ background: {ACCENT}; border-radius: 3px; }}
"""


# ---------------------------------------------------------------------------
# Background parse worker
# ---------------------------------------------------------------------------

class _ParseSignals(QObject):
    progress = Signal(str)   # status message
    done = Signal(object)    # AnalyticsEngine
    error = Signal(str)      # error string


class _ParseWorker(QRunnable):
    def __init__(self, run_files: RunFiles):
        super().__init__()
        self.run_files = run_files
        self.signals = _ParseSignals()

    @Slot()
    def run(self):
        rf = self.run_files
        try:
            self.signals.progress.emit(
                f"Parsing {len(rf.combined_chunks)} chunk(s)…"
            )
            events = parse_combined([str(p) for p in rf.combined_chunks])

            self.signals.progress.emit("Pairing TX→RX hops…")
            # Load attack log for drop-reason classification
            attack_log: Optional[pd.DataFrame] = None
            if rf.attack_log and rf.attack_log.exists():
                try:
                    attack_log = pd.read_csv(rf.attack_log, dtype=str, keep_default_na=False)
                except Exception:
                    attack_log = None

            hops = pair_hops(events)
            hops = classify_not_received(hops, events, attack_log)

            self.signals.progress.emit("Building message traces…")
            traces = build_message_traces(hops, events)

            # Load optional registries
            node_registry: Optional[pd.DataFrame] = None
            if rf.sink_node_registry and rf.sink_node_registry.exists():
                try:
                    node_registry = pd.read_csv(
                        rf.sink_node_registry, dtype=str, keep_default_na=False
                    )
                except Exception:
                    node_registry = None

            self.signals.progress.emit("Building analytics…")
            engine = AnalyticsEngine(
                events=events,
                hops=hops,
                traces=traces,
                attack_log=attack_log,
                node_registry=node_registry,
            )
            self.signals.done.emit(engine)

        except Exception as exc:
            self.signals.error.emit(
                f"{type(exc).__name__}: {exc}\n{traceback.format_exc()}"
            )


# ---------------------------------------------------------------------------
# Sidebar widget
# ---------------------------------------------------------------------------

class RunSelector(QWidget):
    run_selected = Signal(object)  # RunFiles

    def __init__(self, parent=None):
        super().__init__(parent)
        self._runs: list[RunFiles] = []
        self._logs_dir: Optional[Path] = None

        layout = QVBoxLayout(self)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(6)

        # ---- header ----
        hdr = QLabel("CISCA-WSN")
        hdr.setFont(QFont("Arial", 14, QFont.Weight.Bold))
        hdr.setStyleSheet(f"color: {ACCENT}; padding: 4px;")
        hdr.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(hdr)

        sub = QLabel("Packet Trace Analyser")
        sub.setAlignment(Qt.AlignmentFlag.AlignCenter)
        sub.setStyleSheet(f"color: {TEXT_DIM}; font-size: 10px;")
        layout.addWidget(sub)

        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.HLine)
        sep.setStyleSheet(f"color: {BORDER};")
        layout.addWidget(sep)

        # ---- logs dir ----
        self._dir_label = QLabel("No directory")
        self._dir_label.setWordWrap(True)
        self._dir_label.setStyleSheet(f"color: {TEXT_DIM}; font-size: 10px; padding: 2px;")
        layout.addWidget(self._dir_label)

        browse_btn = QPushButton("Browse logs/…")
        browse_btn.clicked.connect(self._browse)
        layout.addWidget(browse_btn)

        # ---- run list ----
        lbl = QLabel("Simulation Runs")
        lbl.setStyleSheet(f"color: {TEXT_DIM}; font-size: 10px; font-weight: bold;")
        layout.addWidget(lbl)

        self._run_list = QListWidget()
        self._run_list.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding
        )
        layout.addWidget(self._run_list)

        # ---- load button ----
        self._load_btn = QPushButton("Load Selected Run")
        self._load_btn.setEnabled(False)
        self._load_btn.clicked.connect(self._load_selected)
        layout.addWidget(self._load_btn)

        self._run_list.itemSelectionChanged.connect(
            lambda: self._load_btn.setEnabled(bool(self._run_list.selectedItems()))
        )
        self._run_list.itemDoubleClicked.connect(lambda _item: self._load_selected())

    def _browse(self):
        d = QFileDialog.getExistingDirectory(self, "Select WSN7_Modular/logs/ directory")
        if d:
            self.set_logs_dir(Path(d))

    def set_logs_dir(self, path: Path):
        self._logs_dir = path
        self._dir_label.setText(str(path))
        self._refresh_runs()

    def _refresh_runs(self):
        self._run_list.clear()
        self._runs = []
        if self._logs_dir is None or not self._logs_dir.exists():
            return
        try:
            self._runs = discover_runs(self._logs_dir)
        except Exception as exc:
            self._dir_label.setText(f"Error scanning: {exc}")
            return
        for rf in self._runs:
            has_attack = "⚠ " if rf.attack_log else ""
            item = QListWidgetItem(f"{has_attack}{rf.label()}")
            item.setData(Qt.ItemDataRole.UserRole, rf)
            self._run_list.addItem(item)
        if self._runs:
            self._run_list.setCurrentRow(0)
            self._load_selected()  # auto-load most recent run

    def _load_selected(self):
        items = self._run_list.selectedItems()
        if not items:
            return
        rf: RunFiles = items[0].data(Qt.ItemDataRole.UserRole)
        self.run_selected.emit(rf)


# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

class CiscaWindow(QMainWindow):
    def __init__(self, logs_dir: Optional[Path] = None):
        super().__init__()
        self.setWindowTitle("CISCA-WSN — Packet Trace Analyser")
        self.resize(1400, 860)
        self.setStyleSheet(STYLE_MAIN)

        self._pool = QThreadPool.globalInstance()
        self._engine: Optional[AnalyticsEngine] = None

        # ---- central layout ----
        central = QWidget()
        self.setCentralWidget(central)
        root = QHBoxLayout(central)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        root.addWidget(splitter)

        # ---- sidebar ----
        self._sidebar = RunSelector()
        self._sidebar.setFixedWidth(260)
        self._sidebar.run_selected.connect(self._on_run_selected)
        splitter.addWidget(self._sidebar)

        # ---- tabs ----
        self._tabs = QTabWidget()
        splitter.addWidget(self._tabs)
        splitter.setStretchFactor(1, 1)

        self._system_tab = SystemTab()
        self._node_tab = NodeTab()
        self._message_tab = MessageTab()

        self._tabs.addTab(self._system_tab, "System")
        self._tabs.addTab(self._node_tab, "Node")
        self._tabs.addTab(self._message_tab, "Messages")

        # ---- status bar ----
        self._status = QStatusBar()
        self._progress = QProgressBar()
        self._progress.setRange(0, 0)   # indeterminate
        self._progress.setFixedWidth(160)
        self._progress.setVisible(False)
        self._status.addPermanentWidget(self._progress)
        self.setStatusBar(self._status)
        self._status.showMessage("Ready — select a logs/ directory to begin.")

        if logs_dir:
            self._sidebar.set_logs_dir(logs_dir)

    # -----------------------------------------------------------------------
    # Slots
    # -----------------------------------------------------------------------

    @Slot(object)
    def _on_run_selected(self, run_files: RunFiles):
        self._status.showMessage(f"Loading run {run_files.run_id} …")
        self._progress.setVisible(True)
        self._sidebar.setEnabled(False)
        self._tabs.setEnabled(False)

        worker = _ParseWorker(run_files)
        worker.signals.progress.connect(self._on_parse_progress)
        worker.signals.done.connect(self._on_parse_done)
        worker.signals.error.connect(self._on_parse_error)
        self._pool.start(worker)

    @Slot(str)
    def _on_parse_progress(self, msg: str):
        self._status.showMessage(msg)

    @Slot(object)
    def _on_parse_done(self, engine: AnalyticsEngine):
        self._engine = engine
        self._progress.setVisible(False)
        self._sidebar.setEnabled(True)
        self._tabs.setEnabled(True)

        st = engine.get_overall_stats()
        atk_str = " | ⚠ ATTACK ACTIVE" if st["has_attack"] else ""
        self._status.showMessage(
            f"Loaded: {st['total_nodes']} nodes | {st['total_messages']} messages "
            f"| PDR {st['pdr']:.1%} | {st['sim_ticks']} ticks{atk_str}"
        )

        self._system_tab.load(engine)
        self._node_tab.load(engine)
        self._message_tab.load(engine)

    @Slot(str)
    def _on_parse_error(self, err: str):
        self._progress.setVisible(False)
        self._sidebar.setEnabled(True)
        self._tabs.setEnabled(True)
        self._status.showMessage(f"Error: {err[:120]}")
        from PySide6.QtWidgets import QMessageBox
        QMessageBox.critical(self, "Parse Error", err)


# ---------------------------------------------------------------------------
# Launch helper
# ---------------------------------------------------------------------------

def launch(logs_dir: str | Path | None = None):
    app = QApplication.instance() or QApplication(sys.argv)
    win = CiscaWindow(Path(logs_dir) if logs_dir else None)
    win.show()
    sys.exit(app.exec())
