import sys
import time

sys.path.insert(0, ".")
from cisca.parser import parse_combined, TAG_PATTERNS, LOCK_PATTERN, DROP_LOCK_TX_PATTERN

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

out = open("validate_report.txt", "w", encoding="utf-8")
def p(*a):
    print(*a, file=out)
    print(*a)

t0 = time.time()
df = parse_combined(CHUNKS)
t1 = time.time()
p(f"Parsed {len(df)} rows from {len(CHUNKS)} chunks in {t1-t0:.2f}s ({len(df)/(t1-t0):.0f} rows/s)")
p(f"t_inferred rows: {df['t_inferred'].sum()} ({100*df['t_inferred'].mean():.2f}%)")
p()

dispatch = dict(TAG_PATTERNS)
dispatch_lock = {"LOCK": LOCK_PATTERN}

p("=== Per-tag fullmatch failure check (regex matched the WHOLE rest string?) ===")
total_fail = 0
for tag, pattern in TAG_PATTERNS.items():
    sub = df[df["tag"] == tag]
    if len(sub) == 0:
        continue
    fm = sub["rest"].str.fullmatch(pattern)
    n_fail = (~fm.astype(bool)).sum()
    total_fail += n_fail
    if n_fail > 0:
        p(f"  {tag}: {n_fail}/{len(sub)} did NOT fullmatch")
        examples = sub.loc[~fm.astype(bool), "rest"].head(5).tolist()
        for e in examples:
            p(f"      e.g. {e!r}")

lock_sub = df[df["tag"] == "LOCK"]
if len(lock_sub):
    fm = lock_sub["rest"].str.fullmatch(LOCK_PATTERN)
    n_fail = (~fm.astype(bool)).sum()
    total_fail += n_fail
    p(f"  LOCK: {n_fail}/{len(lock_sub)} did NOT fullmatch")
    if n_fail:
        for e in lock_sub.loc[~fm.astype(bool), "rest"].head(5).tolist():
            p(f"      e.g. {e!r}")

droplock_sub = df[(df["tag"] == "DROP") & (df["tag2"] == "LOCK")]
if len(droplock_sub):
    fm = droplock_sub["rest"].str.fullmatch(DROP_LOCK_TX_PATTERN)
    n_fail = (~fm.astype(bool)).sum()
    total_fail += n_fail
    p(f"  DROP.LOCK: {n_fail}/{len(droplock_sub)} did NOT fullmatch")

p()
p(f"TOTAL fullmatch failures across all patterned tags: {total_fail}")
p()

p("=== Tags with NO registered pattern (raw rest text only) ===")
patterned_tags = set(TAG_PATTERNS.keys()) | {"LOCK", "DROP"}
unpatterned = df[~df["tag"].isin(patterned_tags)]["tag"].value_counts()
p(unpatterned.to_string())
p()

p("=== node_type x channel row counts (post-dedup) ===")
p(df.groupby(["node_type", "channel"]).size().to_string())
