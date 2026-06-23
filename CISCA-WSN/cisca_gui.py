#!/usr/bin/env python
"""Top-level launcher: python cisca_gui.py [logs_dir]"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from cisca.gui.main_window import launch

if __name__ == "__main__":
    # If no explicit dir given, auto-detect the sibling logs/ folder so
    # the GUI opens ready to use without manual Browse every time.
    if len(sys.argv) > 1:
        logs_dir = sys.argv[1]
    else:
        default = Path(__file__).parent.parent / "logs"
        logs_dir = str(default) if default.exists() else None
    launch(logs_dir)
