# Simulator Performance Evaluation (2026-06-21, updated same day)

## Scope and ground rules

Findings below were traced by directly reading the cited code (not taken on
faith from automated analysis) - marked **VERIFIED** (I read the exact lines
and confirmed the behavior) or **REPORTED** (surfaced by an initial pass,
plausible, but I did not personally re-derive every detail).

**Update**: findings 1a, 2, and 3 were subsequently implemented (see
"Implementation Update" at the bottom) after a follow-up request to apply
everything that could be done safely. 1b and 4 remain documented-only -
both have a concrete, verified mechanism that would let an optimization
silently change simulation behavior, so they were left as-is.

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

**Implemented** (see "Implementation Update" below) - the nested-function
integration concern was resolved by adding the lookup as a plain local
function placed *after* `WSN_Main`'s own closing `end`, taking the map and
the ID as explicit parameters rather than relying on implicit nested-scope
access. This sidesteps the file's specific nesting convention entirely.

---

## Finding 3 (upgraded from REPORTED to VERIFIED, and from "perf nit" to "real bug"): `visualLines` is never pruned in headless mode - unbounded growth, not just reallocation churn

**File**: `Simulator/WSN_Main.m` - `visualLines = [visualLines, vl]` (was
line 449) inside the per-delivery loop.

The original report characterized this as array-concatenation churn (a
preallocation opportunity). On closer reading, it's worse than that:
**construction** of `visualLines` entries was unconditional (ran on every
qualifying message delivery, every tick, regardless of GUI visibility), but
**pruning** by expiry (`visualLines = visualLines([visualLines.expiry] >=
t)`) only happens inside the `if t >= startGUIAt` render block. In headless
mode (`startGUIAt = 1e9`), that render block - and therefore the prune -
never executes, so `visualLines` accumulated an entry for every visualized
message delivery for the *entire run* and was never trimmed. For a long
headless run this is unbounded memory growth, not just avoidable churn.

**Why gating construction behind `t >= startGUIAt` is safe (with one honest
caveat)**: `visualLines` is only ever read inside that same render block.
Almost all pre-reveal entries would already be expired (1-5 tick lifetime)
by the time the first prune runs at `t == startGUIAt`, EXCEPT entries from
the handful of ticks immediately before `startGUIAt` (up to 4 ticks' worth,
since max lifetime is 5) - those would have survived into the first
rendered frame under the old behavior, and do not exist under the new
gated behavior. This is a real, if extremely minor, difference: the very
first frame after the GUI is revealed (or for a partial-headless run, the
first frame after `HeadlessSteps` elapses) may show slightly fewer
in-flight packet lines than before - a sub-5-tick, one-frame cosmetic
difference, not a change to any simulation outcome (no message delivery,
attack logic, or exported data is affected; `visualLines` has no read
access from anywhere except the render block). Flagging this explicitly
rather than overclaiming pixel-identical output. **Implemented and
verified** (parse + multiple successful runs, including a partial-headless
run exercising the GUI-reveal transition - see below).

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
tag swap could silently change this) needs care. **Still not implemented**
after the follow-up pass: this is the one remaining finding where "safely
implementable" genuinely isn't established yet - it would need a per-call-site
audit (there are 6+ call sites across `WSN_Main.m` and `WSN_Physics.m`) to
confirm each one's actual semantics before a tag-based replacement could be
guaranteed behavior-preserving, which is a different scope of work than the
other three findings (each of which had a single, provably-safe substitution).

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

| # | Finding | Verified? | Severity | Risk | Implemented? |
|---|---------|-----------|----------|------|---------------|
| 1a | Cache static `distMat` in `WSN_Physics.updateConnectivity` | Yes | Every tick, O(N²) | LOW | **Yes** |
| 1b | Dirty-track `ranges`/`txP` (DVS-aware) | Yes (risk identified) | Every tick, O(N²) | MEDIUM | No - DVS makes this unsafe without dirty-tracking |
| 2 | O(1) `id2idx` via `containers.Map` | Yes | Every message delivery | LOW | **Yes** |
| 3 | `visualLines` unbounded growth in headless mode (was filed as "preallocate", actually a correctness bug) | Yes (upgraded) | Unbounded memory growth, headless mode | LOW | **Yes** |
| 4 | Cache type tags instead of repeated `isa()`/`isprop()` | No (plausible) | Every tick/delivery | LOW-MEDIUM | No - needs a per-call-site semantics audit first |

---

## Implementation Update (2026-06-21, same day)

Findings 1a, 2, and 3 were implemented after a follow-up request to apply
everything safely implementable. Changes:

- **`Utils/WSN_Physics.m`** (`updateConnectivity`): added a `persistent
  cachedPos`/`cachedDistMat` pair. `distMat` is now computed once and reused
  across ticks, invalidating automatically (via `isequal` on positions) if
  the node set or positions ever differ - covers both the steady-state
  no-mobility case and `WSN_Attack_Demo.m`'s repeated fresh-topology calls.
  The inner link-evaluation loop now reads `d = distMat(i,j)` instead of
  recomputing `norm(...)`. Output values are byte-identical (same formula,
  computed once instead of every tick) - the `ranges`/`txP`/`pl`
  (DVS-dependent) and Rayleigh-fading parts of the function were left
  completely untouched.
- **`Simulator/WSN_Main.m`**: replaced the O(N) `id2idx` closure with a
  `containers.Map` (`hexIDtoIdx`) built once before the simulation loop,
  plus a new local function `lookupNodeIdx(map, hid)` (added after
  `WSN_Main`'s own closing `end`, taking explicit parameters rather than
  relying on nested-scope access - sidesteps the file's existing nested-
  function convention entirely rather than fighting it) that preserves the
  exact `[]`-on-miss behavior of the original `find(...,1)`.
- **`Simulator/WSN_Main.m`**: gated `visualLines` entry construction (the
  `classifyPacket` call and the `vl = struct(...)` / `visualLines =
  [visualLines, vl]` block) behind the same `t >= startGUIAt` condition that
  already gates pruning and rendering - fixing the unbounded-growth issue
  and skipping the per-message classification cost during headless ticks.

**Not implemented**: 1b (DVS-aware range caching) and 4 (`isa()`/`isprop()`
type-tag caching) - both have a verified, concrete mechanism by which a
naive optimization would change simulation behavior (DVS mutating
`controlPower` at runtime; `isa()`'s subclass-matching semantics for
`WSN_Sink < WSN_Gateway`), so neither qualifies as "safely implementable"
without additional design work (dirty-tracking, or a full call-site audit,
respectively) that goes beyond a straightforward substitution.

**Verification**: `meta.class.fromName`/`which` parse checks on all
affected files; a 300-step/100-node headless run with all 7 attack types
active (`SIM_OK`, 528 ground-truth entries, ~76s); a partial-headless run
(`WSN_Launcher('HeadlessSteps', 30, 'SimSteps', 80, ...)`) specifically
exercising the `t >= startGUIAt` GUI-reveal transition that the
`visualLines` gating change touches (`PARTIAL_HEADLESS_OK`, no errors).
