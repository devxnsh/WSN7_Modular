"""Groups files in a WSN7_Modular logs/ folder into discrete simulation "runs".

A single run's combined-log history is NOT one file: WSN_Main.m's autolog
exporter (Simulator/WSN_Main.m:776) clears each node's in-memory log buffer
after every export, so combined_t0-250_*, combined_t0-500_*, ... combined_t0-2000_*
are sequential CHUNKS of the same run (chunk N covers ticks (N-1) onward),
identified by a monotonically increasing tick number across closely-spaced
timestamps. A run ends either at its final chunk (tick count == sim duration)
or wherever the chain is cut short (GUI closed early, crash, etc); the chain
breaks when the next combined_t0-* file's tick number is NOT greater than the
previous one in time order -- that marks the start of the next run.

The run's terminal exports (attack_log_*, local_features_*, sink_features_*)
share no exact timestamp with the last combined chunk (they're written
moments later by a separate export call) so they're matched as the nearest
file of each kind with a timestamp shortly after the chain's last chunk.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from cisca.config import RUN_TERMINAL_TOLERANCE_SECONDS

_TS_RE = re.compile(r"(\d{8}_\d{6})")
_COMBINED_RE = re.compile(r"combined_t0-(\d+)_(\d{8}_\d{6})\.csv$")


def _parse_ts(ts: str) -> datetime:
    return datetime.strptime(ts, "%Y%m%d_%H%M%S")


@dataclass
class RunFiles:
    run_id: str  # timestamp of the run's last combined chunk, used as the stable id
    combined_chunks: list[Path] = field(default_factory=list)  # ordered by tick
    sink_node_registry: Path | None = None     # matches last chunk's timestamp
    sink_sensor_registry: Path | None = None   # matches last chunk's timestamp
    attack_log: Path | None = None
    local_features: Path | None = None
    sink_features: Path | None = None

    @property
    def final_tick(self) -> int:
        if not self.combined_chunks:
            return 0
        m = _COMBINED_RE.search(self.combined_chunks[-1].name)
        return int(m.group(1)) if m else 0

    @property
    def total_size_bytes(self) -> int:
        return sum(p.stat().st_size for p in self.combined_chunks if p.exists())

    def label(self) -> str:
        return (f"{self.run_id}  (t=0-{self.final_tick}, "
                f"{len(self.combined_chunks)} chunks, "
                f"{self.total_size_bytes / 1e6:.1f} MB)")


def discover_runs(logs_dir: str | Path) -> list[RunFiles]:
    logs_dir = Path(logs_dir)
    combined_files = []
    for p in logs_dir.glob("combined_t0-*.csv"):
        m = _COMBINED_RE.search(p.name)
        if m:
            combined_files.append((int(m.group(1)), _parse_ts(m.group(2)), p))
    combined_files.sort(key=lambda x: x[1])  # chronological

    # Walk the chronological list, breaking the chain whenever tick count
    # does not strictly increase relative to the previous file.
    runs: list[RunFiles] = []
    current: list[tuple[int, datetime, Path]] = []
    prev_tick = -1
    for tick, ts, p in combined_files:
        if current and tick <= prev_tick:
            runs.append(current)
            current = []
        current.append((tick, ts, p))
        prev_tick = tick
    if current:
        runs.append(current)

    other_files = {
        "sink_nodeRegistry": list(logs_dir.glob("sink_nodeRegistry_t0-*.csv")),
        "sink_sensorRegistry": list(logs_dir.glob("sink_sensorRegistry_t0-*.csv")),
        "attack_log": list(logs_dir.glob("attack_log_*.csv")),
        "local_features": list(logs_dir.glob("local_features_*.csv")),
        "sink_features": list(logs_dir.glob("sink_features_*.csv")),
    }

    def find_registry(kind: str, tick: int, ts: datetime) -> Path | None:
        # Exact match required: multiple runs can share the same final tick
        # (e.g. several runs all completing at t0-2000), so only the
        # timestamp -- shared exactly with the last combined chunk of THIS
        # run -- disambiguates which registry snapshot belongs to it.
        exact = f"{kind}_t0-{tick}_{ts.strftime('%Y%m%d_%H%M%S')}.csv"
        for p in other_files[kind]:
            if p.name == exact:
                return p
        return None

    def find_terminal(kind: str, after_ts: datetime) -> Path | None:
        best, best_dt = None, None
        for p in other_files[kind]:
            m = _TS_RE.search(p.name)
            if not m:
                continue
            ts = _parse_ts(m.group(1))
            delta = (ts - after_ts).total_seconds()
            if 0 <= delta <= RUN_TERMINAL_TOLERANCE_SECONDS:
                if best_dt is None or delta < best_dt:
                    best, best_dt = p, delta
        return best

    result = []
    for chain in runs:
        last_tick, last_ts, last_path = chain[-1]
        rf = RunFiles(
            run_id=last_ts.strftime("%Y%m%d_%H%M%S"),
            combined_chunks=[p for _, _, p in chain],
        )
        rf.sink_node_registry = find_registry("sink_nodeRegistry", last_tick, last_ts)
        rf.sink_sensor_registry = find_registry("sink_sensorRegistry", last_tick, last_ts)
        rf.attack_log = find_terminal("attack_log", last_ts)
        rf.local_features = find_terminal("local_features", last_ts)
        rf.sink_features = find_terminal("sink_features", last_ts)
        result.append(rf)

    result.sort(key=lambda r: r.run_id, reverse=True)
    return result


def find_run_by_id(logs_dir: str | Path, run_id: str) -> RunFiles | None:
    for r in discover_runs(logs_dir):
        if r.run_id == run_id:
            return r
    return None
