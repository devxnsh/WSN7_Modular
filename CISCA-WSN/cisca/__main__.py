"""python -m cisca [logs_dir]"""
import sys
from cisca.gui.main_window import launch

if __name__ == "__main__":
    launch(sys.argv[1] if len(sys.argv) > 1 else None)
