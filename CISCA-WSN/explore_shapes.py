"""One-off exploration script: sample real log-line 'shapes' from a full run
to ground the parser's regex catalog in actual data, not just source reading.
Not part of the shipped tool.
"""
import re
import sys
from collections import defaultdict

import pandas as pd

CHUNKS = [
    "../logs/combined_t0-250_20260618_042741.csv",
    "../logs/combined_t0-500_20260618_042916.csv",
    "../logs/combined_t0-750_20260618_043210.csv",
    "../logs/combined_t0-1000_20260618_043921.csv",
    "../logs/combined_t0-1250_20260618_045140.csv",
    "../logs/combined_t0-1500_20260618_050814.csv",
    "../logs/combined_t0-1750_20260618_052938.csv",
    "../logs/combined_t0-2000_20260618_055525.csv",
]

TAG_RE = re.compile(r"^(?:t=(\d+) )?((?:\[[^\]]*\])+)\s?(.*)$")


def shape_of(rest: str) -> str:
    # normalize numbers/hex ids to see the line "shape"
    s = re.sub(r"\b[0-9A-Fa-f]{4}\b", "<HEX>", rest)
    s = re.sub(r"-?\d+\.\d+", "<FLOAT>", s)
    s = re.sub(r"\d+", "<N>", s)
    return s


def main():
    out = open("shape_report.txt", "w", encoding="utf-8")
    import builtins
    real_print = builtins.print
    def print(*a, **k):
        k["file"] = out
        real_print(*a, **k)
    tag_examples = defaultdict(list)
    tag_counts = defaultdict(int)
    unmatched = []
    total = 0

    for chunk in CHUNKS:
        df = pd.read_csv(chunk, dtype=str)
        for entry in df["LogEntry"]:
            total += 1
            m = TAG_RE.match(entry)
            if not m:
                unmatched.append(entry)
                continue
            t, tags, rest = m.groups()
            shape = shape_of(rest)
            key = (tags, shape)
            tag_counts[key] += 1
            if len(tag_examples[key]) < 2:
                tag_examples[key].append(entry)

    print(f"Total lines: {total}, distinct (tags,shape): {len(tag_counts)}, unmatched: {len(unmatched)}")
    print()
    for key, cnt in sorted(tag_counts.items(), key=lambda x: -x[1]):
        tags, shape = key
        print(f"[{cnt:>7}] {tags:30s} {shape}")
        for ex in tag_examples[key]:
            print(f"           e.g. {ex}")
    if unmatched:
        print("\n--- UNMATCHED SAMPLES ---")
        for u in unmatched[:20]:
            print(" ", u)


if __name__ == "__main__":
    main()
