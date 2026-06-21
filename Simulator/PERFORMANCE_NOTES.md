# Simulator Performance Evaluation (2026-06-21)

## Scope and ground rules

This is an evaluation, not a changelog. Per the explicit constraint given for
this pass ("no change in functionality or visualization is preferred"), the
findings below are **documented but not implemented** unless noted
otherwise. Each finding below was traced by directly reading the cited code
(not taken on faith from automated analysis) - findings are marked
**VERIFIED** (I read the exact lines and confirmed the behavior) or
**REPORTED** (surfaced by an initial pass, plausible, but I did not
personally re-derive every detail).

Risk ratings:
- **LOW-RISK**: mechanical change (caching an already-computed value,
  preallocation) with no plausible path to changing simulation output.
- **MEDIUM/HIGHER-RISK**: requires restructuring logic; real chance of
  subtly changing connectivity, timing, or RNG draw order if done carelessly
  (and this codebase visibly cares about RNG-driven realism - Rayleigh
  fading, attack randomization, etc. - so draw-order changes are not safe to
  treat as "just a refactor").

---

## Finding 1 (VERIFIED, top priority): O(N²) physics recompute every tick, with non-cacheable parts mixed into cacheable parts

**File**: `Utils/WSN_Physics.m`, `updateConnectivity(nodes)`, lines 4-97.
**Called from**: `Simulator/WSN_Main.m:151`, unconditionally every tick
regardless of GUI visibility ("Rayleigh fading on physAdj means links can
change each timestep" - existing comment at WSN_Main.m:150).

Every tick, this function re-runs a full `N×N` nested loop (`Utils/
WSN_Physics.m:38-96`) that recomputes, for every ordered pair `(i,j)`:
- `d = norm(nodes(i).pos - nodes(j).pos)` (line 42) - **this is genuinely
  static across ticks**, since this simulator has no node mobility (no code
  path writes `nodes(i).pos` after topology generation, confirmed by
  grep - position is set once in `WSN_TopologyGenerator`).
- `txP`/`pl` (path-loss exponent) selection via tier/`isprop(nodes(i),
  'controlPower')` branching (lines 52-65) - **NOT safely cacheable**: GWN
  `controlPower` changes at runtime via the DVS (dynamic power scaling)
  mechanism described in `GWN_Shell.md` ("DVS Power Boost Doesn't Reset").
  A naive "compute once at init" cache would go stale the first time a GWN's
  DVS adjusts power, silently changing which links are/aren't reachable -
  exactly the kind of functionality change this pass is asked to avoid.
- The Rayleigh fading roll (`exprnd(...)`, line 86) - inherently per-tick,
  must stay per-tick.

**What's safe to cache**: only the distance matrix `distMat` itself (no
mobility => `norm(nodes(i).pos - nodes(j).pos)` never changes after init).
Caching `distMat` once and reusing it every tick would cut roughly a third
of the inner loop's work (the `norm()` call plus its containing branch)
without touching anything RNG- or DVS-dependent.

**What's NOT safe to cache without extra work**: `ranges(i)` (lines 19-35)
and the per-pair `txP`/`pl` selection, because both depend on
`controlPower`, which is mutable. A correct optimization here would need
dirty-tracking (recompute `ranges(i)` only for GWNs whose `controlPower`
changed since the last tick) rather than blind caching - this is a real
optimization opportunity but is **MEDIUM-RISK**, not the "mechanical, no
behavior change" category, and was not implemented in this pass.

**Estimated impact**: this is the single largest per-tick cost in the
simulator (O(N²) with N up to 100+, every tick, both GUI and headless
modes). The safe sub-piece (caching `distMat`) is a meaningful but partial
win; the full win requires the dirty-tracking work above.

---

## Finding 2 (VERIFIED): `id2idx` hex-ID-to-array-index lookup is O(N) per call, called multiple times per tick

**File**: `Simulator/WSN_Main.m:115-116`:
```matlab
id2idx = @(hid) find(arrayfun(@(n) hex2dec(n.hexID) == hid, nodes), 1);
idx2id = @(idx) hex2dec(nodes(idx).hexID);
```
**Call sites** (all confirmed via grep): `WSN_Main.m:238`, `:271`, `:289`
(inside the per-message delivery loop - so this runs once per destination
per message, not just once per tick), and `:505` (feature export flush).

`id2idx` rebuilds a full `arrayfun(@(n) hex2dec(n.hexID)==hid, nodes)`
boolean array over **every node** on every call. With potentially hundreds
of message deliveries per tick, this is the most frequently-repeated O(N)
operation in the file.

**Why this is genuinely safe to fix (and the highest-value/lowest-risk item
on this list)**: node membership and `hexID` are fixed for the life of a run
(no code path adds/removes/renames nodes mid-simulation - confirmed: `nodes`
is only assigned once before the loop, at `WSN_Main.m:64-69`). A
`containers.Map` from `hex2dec(hexID)` to array index, built once before the
loop, would make every one of these lookups O(1) with **zero change in
return value** for any input (same hit/miss behavior as the current
`find(...,1)`, which returns `[]` on no match - the replacement needs an
explicit `isKey()` check to preserve that exact miss behavior rather than
letting `containers.Map` throw on a missing key).

**Not implemented in this pass**: `WSN_Main.m` uses MATLAB nested functions
(`classifyPacket` at line 545, `autoExportLogs` at line 713, both defined
inside `WSN_Main`'s body and sharing its workspace - confirmed via grep for
`^    function `). Mixing a new helper function into a nested-function file
correctly (matching this file's specific `end`-handling convention) needs
care I did not want to rush given the "no functionality/visualization
change" constraint - a mistake here is a parse-breaking risk, not just a
behavior risk. Documenting as the clear top candidate for hand-implementation
with testing, rather than implementing under time pressure.

---

## Finding 3 (REPORTED, plausible): visualization line array grows by repeated concatenation

**File**: `Simulator/WSN_Main.m:439` area - `visualLines = [visualLines, vl]`
inside the per-delivery loop, pruned later (~line 513) by expiry. MATLAB
array concatenation in a loop reallocates on every append; for runs with
many deliveries per tick this is avoidable churn. Preallocating to a
generous fixed size and tracking a "next free slot" index would remove the
reallocation cost. This only matters when the GUI is visible (the array
feeds rendering), so it has zero effect on headless-mode throughput.
**LOW-RISK** if implemented (pure internal storage change, output rendering
identical) but not verified line-by-line in this pass.

---

## Finding 4 (REPORTED, plausible): repeated `isa()`/`isprop()` checks in hot paths

Both the per-node tick loop and the per-message delivery loop call
`isa(nodes(i), 'WSN_Gateway')`, `isa(nodes(i), 'WSN_Sink')`, and
`isprop(nodes(i), 'controlPower')`-style checks repeatedly per tick. These
are string-based lookups and are individually cheap, but at 100+ nodes ×
thousands of ticks the cumulative cost is non-trivial. Caching a per-node
type tag (e.g., a `tier` or `nodeType` enum already exists per
`WSN_Node.m`) and using that instead of repeated `isa()` would be
**LOW-RISK** mechanically, but auditing every call site to confirm none of
them rely on `isa()`'s subclass-matching semantics (e.g. `WSN_Sink <
WSN_Gateway`, so `isa(sinkNode, 'WSN_Gateway')` is also `true` - a naive tier
tag swap could silently change this) needs care. Not implemented.

---

## What I deliberately did not chase further

GUI-mode-only costs (throttling effectiveness of `WSN_Config.ActiveRefresh`,
`drawnow` cost, etc.) were surfaced as a category but not verified in depth -
the existing gating at `WSN_Main.m:154` (`if t >= startGUIAt && mod(t,
ActiveRefresh) == 0`) already looks correct for the table/inspector/sink
analytics updates, and going further would mean profiling actual GUI
rendering cost, which needs a real display and is outside what could be
verified by reading code alone.

## Summary table

| # | Finding | Verified? | Severity | Risk if implemented | Implemented this pass? |
|---|---------|-----------|----------|---------------------|------------------------|
| 1a | Cache static `distMat` in `WSN_Physics.updateConnectivity` | Yes | Every tick, O(N²) | LOW | No |
| 1b | Dirty-track `ranges`/`txP` (DVS-aware) | Yes (risk identified) | Every tick, O(N²) | MEDIUM | No |
| 2 | O(1) `id2idx` via `containers.Map` | Yes | Every message delivery | LOW (needs careful nested-function integration) | No |
| 3 | Preallocate `visualLines` | No (plausible) | Every delivery, GUI-mode only | LOW | No |
| 4 | Cache type tags instead of repeated `isa()`/`isprop()` | No (plausible) | Every tick/delivery | LOW-MEDIUM (subclass semantics caveat) | No |

Nothing in this document was applied to `WSN_Main.m` or `WSN_Physics.m` -
all four findings are documented for a deliberate follow-up pass with
before/after simulation-output diffing to confirm zero behavior change.
