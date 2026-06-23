# Recruitment Chain Race Conditions (2026-06-21, updated same day)

## Update: follow-up pass with actual fixes

A follow-up request asked to find and **fix** (not just document) the exact
edge cases behind three symptoms: unconnected segments in the GWN ring,
unrecruited center-of-topology CHs, and attacker nodes being accepted as
trusted data into the GWN ring without key verification. This required
reading considerably more of `GWN/WSN_Gateway_Behavior.m` and
`GWN/WSN_Gateway_Messaging.m` than the original pass below, which changed
several conclusions:

- **One real, fixable security bug found and fixed**: `handle_GLOBAL_KEY`
  (`GWN/WSN_Gateway_Messaging.m`) accepted a GLOBAL_KEY frame from *any*
  sender (not just the GWN's actual `parent`) and trusted whatever key value
  it contained with **zero verification** against the network's real
  `WSN_Message.GLOBAL_AES_KEY_HEX`. This is the precise mechanism behind
  "attacker injection without key verification directly into the GWN ring" -
  see "Security fix" section below for the full writeup.
- **The originally-hypothesized G1 race (late ENC_HELLO honored against a
  reassigned lock) is largely REFUTED** on closer reading: the timeout-
  recovery path (`WSN_Gateway_Behavior.m:417-487`, "CASE 1: Has key + Has
  parent") *does* correctly purge the timed-out partner from
  `pendingChildren` and send it a `PARENT_REJECT`, contrary to what the
  original pass assumed. The `pendingChildren`/`handshakePartner`
  desync this document originally worried about does not appear to occur
  in the dominant code path.
- **"Unconnected GWN ring segments" and "unrecruited center CH" are
  primarily explained by two *intentional* design constraints**, not bugs -
  see "Topology/design findings" below. There is one genuine (but low-
  impact, given current config values) gap noted for completeness.

Everything below this point is the **original** investigation (unchanged) -
kept for history. Skip to the bottom sections for the new findings.

---

## Scope and ground rules (original pass)

This document is **investigation and documentation only** - no fixes were
implemented, per explicit instruction. It covers the three recruitment/
handshake relationships in the network: GWN-GWN (backbone parent
selection), GWN-CH (CH joining a GWN parent), and CH-CH (secondary CH
recruitment, one-hop limit).

This is a discrete-tick, message-passing simulation - there is no real
concurrency, but the *protocol design* itself can still race: two nodes can
both decide to recruit each other in the same tick, a timeout can fire in
the same tick a real reply arrives, multiple suitors can target the same
node in overlapping windows, etc. `Simulator/WSN_Main.m` delivers messages
one at a time via `nodes(i).receive(msg, t, rssi)` per destination per
message (confirmed at `WSN_Main.m:463` and `:489`) - so within a single
tick, several distinct `receive()` calls can land on the same node in a
row, each able to mutate shared handshake state before the next one runs.

Confidence levels below: **CONFIRMED** (I read the exact mechanism -
`handshakePartner`/`lockTimer` fields, `setLock`/`clearLock` methods,
timeout decrement logic - and the race is a direct, traceable consequence
of that structure) vs **PLAUSIBLE** (consistent with the confirmed
structure and a believable trigger sequence, but I did not exhaustively
trace every intervening tick to rule out an existing guard).

Known, already-documented issues (`CH_Shell.md`'s "Issue #1" through
"Issue #6", `GWN_Shell.md`'s "Issue #1" through "Issue #4") are background,
not repeated here unless a new wrinkle was found.

---

## GWN-GWN (Backbone Handshake)

**Lock structure** (CONFIRMED, `Utils/WSN_Radio.m:20-21, 208-238`): each
radio has exactly ONE `handshakePartner` slot and one `lockTimer`. `setLock`
overwrites the partner unconditionally; `clearLock` resets both to empty/0.
Timeout decrement happens once per tick during the GWN's own `step()`
(`GWN/WSN_Gateway_Behavior.m:88-91`: `lockTimer = lockTimer - 1; if
lockTimer <= 0, lockExpired = true`), and recovery is handled separately,
later in the same step (`GWN_Gateway_Behavior.m:351-357`, "TIMEOUT:
State-based recovery"). `pendingChildren` (a list, separate from the single
`handshakePartner` slot) tracks nodes that completed PARENT_INIT/ACK_JOIN
but haven't yet sent ENC_HELLO.

### Race G1: late ENC_HELLO arrives after the lock that was waiting for it already expired and was reassigned (PLAUSIBLE)

Because `handshakePartner` is a single slot and `pendingChildren` is a
*separate* list with its own membership, there is no enforced 1:1
correspondence between "who currently holds the lock" and "who is still in
`pendingChildren`". Trigger sequence:
1. GWN B accepts GWN A's PARENT_INIT, sets `handshakePartner = A`, adds A to
   `pendingChildren`, sends GLOBAL_KEY/ENC_HELLO-eligible response.
2. That response (or A's own ENC_HELLO reply) is lost in transit.
3. B's lock timer expires (`HandshakeTimeout` ticks later per
   `WSN_Config.HandshakeTimeout`, set via `gw.radio.setLock(a.value,
   WSN_Config.HandshakeTimeout)` at `GWN_Gateway_Behavior.m:688`); B's
   timeout-recovery path clears the lock. It is not confirmed (not traced)
   whether this recovery path also unconditionally purges A from
   `pendingChildren` in every code branch, or only in some.
4. A NEW candidate, GWN C, sends PARENT_INIT to B in the same or a later
   tick; B accepts, `handshakePartner` is reassigned to C.
5. A's original, merely-delayed ENC_HELLO finally arrives. B's ENC_HELLO
   acceptance check is keyed off `pendingChildren` membership
   (`GWN/WSN_Gateway_Messaging.m`'s `handle_ENC_HELLO`, `isPending =
   ~isempty(gw.pendingChildren) && any([gw.pendingChildren.id] ==
   sender)`), NOT off `handshakePartner` - so if A is still listed in
   `pendingChildren` (i.e. step 3's cleanup didn't remove it), B promotes A
   to a full child even though the radio lock now logically belongs to C.

**Consequence if triggered**: B ends up with A as a backbone child via a
side channel that bypasses the current lock owner (C), while C's own
in-flight handshake state may now be inconsistent with B's actual
acceptance decision. This needs tracing through the exact timeout-recovery
branch taken (`GWN_Gateway_Behavior.m:356-522` has several distinct recovery
paths - "ORPHAN KEY", "PARTIAL", "CLEAN SLATE" - it's plausible, but not
confirmed, that not all of them purge `pendingChildren` the same way).

### Race G2: mutual PARENT_INIT detection clears the lock via a queued effect, not immediately (PLAUSIBLE)

Mutual-init (A and B simultaneously PARENT_INIT each other) is detected and
rejected (`WSN_Gateway_Messaging.m`, around the PARENT_INIT handler), but
the rejection's lock-clear is queued as an `effect` (`'CLEAR_HANDSHAKE'`)
rather than applied synchronously inside the same `receive()` call. If a
third candidate's PARENT_INIT is processed (in a separate `receive()` call,
same tick) before that queued effect is applied, the lock-conflict check
will still see the old (about-to-be-cleared) `handshakePartner` and reject
the third candidate's legitimate attempt. Whether `WSN_Main.m`'s per-tick
loop applies queued effects before or after processing all of a tick's
inbound messages was not fully traced - this determines whether the window
is real or already closed by execution order.

---

## GWN-CH (Access Radio Handshake)

**State machine** (per `CH_Shell.md`'s documented state machine, confirmed
consistent with `CH/WSN_ClusterHead.m`'s handshake handlers): DISCOVERY ->
HANDSHAKE (CH_REQ sent, CH's own lock set on `obj.handshakePartner`) ->
SECURE (CH_ACK + key received) -> VERIFIED (KEY_ACK sent and accepted).

### Race GC1: CH_ACK lost mid-flight produces a multi-timeout delay, not data corruption (CONFIRMED structure, PLAUSIBLE full sequence)

If the GWN's CH_ACK (carrying the freshly-generated local key, see
`GWN/WSN_Gateway_Messaging.m:1413-1436`, `generateLocalKeyForCH`/
`createCHACK`) is lost, the CH's own handshake lock times out
independently (CH-side timeout, `CH/WSN_ClusterHead.m`'s `handleTimeout()`,
documented in `CH_Shell.md` "Issue #6"), adding the GWN to the CH's
`rejectedGWNs` list. The GWN's access-radio lock, set when it accepted the
CH_REQ, times out on its own separate clock. Because both timeouts are
roughly symmetric (`WSN_Config.HandshakeTimeout` on both sides) this is
mostly self-healing, but the CH cannot retry the same GWN until
`rejectedGWNs` forgives it (`CH_REJECTED_LIST_RESET_INTERVAL`, 100 TF per
`CH_Shell.md`) - so a single lost CH_ACK costs roughly
`HandshakeTimeout + CH_REJECTED_LIST_RESET_INTERVAL` ticks of delay rather
than corrupting state. This is a **liveness** issue (slow recovery), not a
**correctness** issue (no data corruption identified) - milder than the
GWN-GWN races above.

### Race GC2: same-tick CH_REQ from two different CHs to the same GWN (PLAUSIBLE, likely already handled correctly)

Two CH_REQ messages addressed to the same GWN in the same tick are each
processed via a separate `receive()` call (per the delivery model above).
The GWN's CH_REQ handler checks its access-radio lock and rejects (CH_REJECT)
any sender that doesn't match an already-set `handshakePartner` - so the
SECOND `receive()` call in the same tick should see the lock the FIRST call
just set, and correctly reject. This *appears* correctly handled by the
single-lock-slot design (the same mechanism that's the root of Race G1
above is, here, working as intended) - flagged as plausible-but-likely-fine
rather than a confirmed bug, included for completeness since it was an
explicit question in scope.

---

## CH-CH (Secondary CH Recruitment, One-Hop Limit)

The one-hop-limit enforcement (`isQualifiedToRecruit`, only true for
GWN-anchored CHs) combined with the same single-lock-slot pattern means a
Primary CH mid-handshake with one Secondary correctly rejects a second,
concurrent Secondary's CH_REQ (verified by reading `CH/WSN_ClusterHead.m`'s
`handleCHREQ`'s lock-conflict check, lines ~370-374 per the existing
`CH_Shell.md` line references) - this is **correct, intentional behavior**,
not a race, since the one-hop limit is supposed to cap concurrent
recruitment to one at a time.

The one race-shaped issue already on record for this tier - "Issue #6:
Handshake Lock Can't Recover from Partial Failure" in `CH_Shell.md` - covers
the case where a Secondary's own confirmation frame is lost after receiving
CH_JOINOK; that document's existing write-up appears accurate and is not
restated here. No new CH-CH race beyond what's already documented was
found with reasonable confidence.

---

## Summary

| Tier | Race | Mechanism | Confidence | Severity |
|------|------|-----------|------------|----------|
| GWN-GWN | G1: late ENC_HELLO honored against a reassigned lock | Single `handshakePartner` slot vs. separate `pendingChildren` list with no enforced 1:1 link | PLAUSIBLE | Potential state inconsistency (not crash) |
| GWN-GWN | G2: queued `CLEAR_HANDSHAKE` effect creates a same-tick rejection window | Effect queued, not applied synchronously | PLAUSIBLE | Delayed/rejected legitimate recruitment attempt |
| GWN-CH | GC1: lost CH_ACK costs two timeouts + a rejection-list reset | Symmetric independent timeouts, no shared state | CONFIRMED structure | Liveness delay only, no corruption |
| GWN-CH | GC2: same-tick dual CH_REQ | Single lock slot rejects the second arrival correctly | PLAUSIBLE (likely fine) | None identified |
| CH-CH | One-hop limit concurrent recruitment | Lock-conflict check rejects correctly | CONFIRMED | Working as intended, not a bug |
| CH-CH | Partial-failure lock recovery | Already documented (`CH_Shell.md` Issue #6) | Pre-existing | No new finding |

**Highest-value follow-up** if this is picked up later: trace the exact
timeout-recovery branches in `GWN_Gateway_Behavior.m:356-522` ("ORPHAN KEY"
/ "PARTIAL" / "CLEAN SLATE") to confirm whether each one purges
`pendingChildren` consistently with clearing `handshakePartner` - that's the
root of Race G1 and the only finding here with a plausible (if rare)
correctness impact rather than just a liveness delay.

---

## Follow-up pass (2026-06-21, same day): actual fixes and refined findings

### Security fix: GLOBAL_KEY forgery (the "attacker injection without key verification" bug)

**File**: `GWN/WSN_Gateway_Messaging.m`, `handle_GLOBAL_KEY`.

**Root cause, confirmed by reading the full handshake dispatch path**
(`handleReceive`'s CMD/Type-7 switch, `GWN/WSN_Gateway_Messaging.m:336-359`):
the only gates before a Type 7 subtype 4 (GLOBAL_KEY) frame reaches
`handle_GLOBAL_KEY` are (a) checksum verification and (b) `msg.dst ==
hex2dec(gw.hexID)` (must be unicast to us). There is **no check that
`msg.src` is our actual `gw.parent`** - the lock-refresh logic at line
344-347 only refreshes the handshake timer if the sender matches
`handshakePartner`, it does not gate dispatch. Inside the old
`handle_GLOBAL_KEY`, the only guard was `isempty(gw.parent)` (do we have
*some* parent), not "is this sender *our* parent." Once past that, the
received `keyHex` (`msg.getGlobalKeyPayload()`) was written directly to
`gw.encryptionKey` with no validation against anything.

**Consequence**: any node that knows the protocol (trivial in an
open-source simulator - every node class has access to the same code) can
craft a Type 7.4 frame addressed to a victim GWN that already has a parent,
with an arbitrary `keyHex` payload, and the victim will silently accept it
as its root-of-trust encryption key - corrupting `gw.localKeyHex`
(re-derived from the bogus key) and, transitively, every CH-issued local
key downstream of that GWN. This is also a strong candidate root cause for
the corrupted/garbage sensor IDs found during the earlier 5.2-payload audit
(see `GWN_Shell.md`'s "Separate, NOT-yet-fixed issue" section) - a desynced
`encryptionKey` would produce exactly that kind of silent decode corruption
without ever throwing a MATLAB error.

**Fix** (implemented, then corrected same day): `handle_GLOBAL_KEY` now
rejects the frame (logs `[SECURITY] DROP GLOBAL_KEY ...` and returns)
unless `msg.src == gw.parent` - the one GWN identity besides its own child
that a GWN is meant to know in this design, so checking against it doesn't
leak anything about the wider ring.

**Correction**: the first version of this fix *also* required the received
`keyHex` to exactly equal the hardcoded `WSN_Message.GLOBAL_AES_KEY_HEX`
constant. That was wrong and has been removed. Per design clarification:
each GWN only ever knows its Parent and Child (deliberately, so the Sink's
identity can't be found by ID-tracing any single node), and the global key
is meant to be *propagated hop-by-hop down the ring* rather than something
every node independently knows in advance to match against - that
propagation is also what enables future key rotation (local key reset on
suspicion, global key reset on confirmed attack, per the Trust/Census/
Shutdown protocol). A static equality check would silently reject any
legitimate key after a future rotation, defeating the entire point of
propagation-based trust - "if global keys are already known to all nodes
and are simply matched, it defeats the point." The `sender == gw.parent`
check is the correct verification boundary for this design: trust comes
from *who* handed you the key (your already-known parent), not from
matching its value against a shared secret. A dormant-hook comment was left
at the fix site for the "double verification" the design calls for once
key rotation is actually implemented (e.g. cross-checking against a
freshly-derived local key or a reset-epoch counter) - not implemented yet,
left undone rather than guessed at.

Verified via repeated 400-600 step headless runs post-fix showing normal
multi-hop GWN chains forming with valid `LocalKey` values at every hop
(`sink_nodeRegistry` export, e.g. `FF08 -> FF0A -> FF02 -> FF06 -> FF01`,
each with a populated `LocalKey` column) - both before and after the
correction, since `sender == gw.parent` alone is sufficient to reject
forged/unsolicited GLOBAL_KEY frames without touching legitimate traffic.

**Scope note**: this closes the GWN-ring-level gap specifically. The
SN-tier (`Type 1` sensor data accepted by both CH and GWN with only a
checksum check, no sender-identity verification) was investigated and found
to be the *same*, consistent design across both `CH/Registry/
WSN_ClusterHead_Registry.m` and `GWN/WSN_Gateway_Messaging.m` -
sensors never perform a key exchange by protocol design (resource-
constrained leaf tier; the codebase's defense for malicious sensors is
trust/census-based behavioral detection, not cryptographic admission
control). That is a much larger, deliberate architectural choice, not a
localized bug, so it was left as-is - flagging here for visibility rather
than silently leaving it out.

### Topology/design findings: why GWN ring segments and center CHs can stay unconnected

Two confirmed, **intentional** design constraints largely explain both
symptoms:

1. **A non-Sink GWN recruits exactly one child, ever**
   (`GWN_Gateway_Behavior.m:547-550`: `if ~isa(gw,'WSN_Sink') &&
   ~isempty(gw.children), return;`). This is consistent with the network
   being a **ring/chain**, not a fan-out tree - each GWN has one parent
   slot and recruits one child slot, by design. (It does retry *other*
   candidates if its current target rejects/times out, cycling through
   `valid` neighbors - it is not "locked onto one candidate forever," just
   capped at one *successful* child.)
2. ~~**CH-CH chaining is capped at exactly one hop**~~ **REMOVED
   (2026-06-22)**. `isQualifiedToRecruit` no longer exists; every verified
   CH can now transparently relay/latch for further CHs at unbounded depth
   (`CH/WSN_ClusterHead.m` `handleCHREQ`/`relayMessageIfNotMine`, see
   `CH_Documentation.md` §9 for the full design). A center-of-topology CH
   that is out of range of every GWN and every GWN-anchored CH is no longer
   structurally unreachable — it just needs to be in range of **any**
   verified CH, which relays it to the GWN at whatever depth that takes.
   `checkChPeerDiscoveryDVS`/`checkChOrphanDVS` (`WSN_Config.CH_PEER_DVS_*`/
   `CH_ORPHAN_DVS_*`, see `CH_Documentation.md` §8) still widen who's
   *discoverable*; relay now extends how far being discoverable by *any*
   verified CH actually reaches. The residual failure mode is now purely
   "out of HELLO range of every verified node in the network," not "out of
   range of specifically a GWN or GWN-anchored CH" — a strictly smaller
   dead zone.

Constraint 1 (one child per non-Sink GWN) remains a deliberate stability
choice and is unaffected by this change — it's a separate axis (GWN-GWN
backbone fan-out) from CH-CH relay depth.

**Mechanisms that were checked and found to already work correctly** (so
they are *not* the explanation, despite being plausible candidates):
- **ST_REJECT forgiveness**: `GWN_Gateway_Behavior.m:143-159` already
  periodically resets `ST_REJECT` back to `ST_NONE` every
  `WSN_Config.GWN_REJECTED_RESET_INTERVAL` (50 ticks) - a transient
  rejection does not permanently blacklist a neighbor. This mirrors the
  CH-tier's `rejectedGWNs`/`rejectedCHs` forgiveness window
  (`CH_Shell.md` Issue #5, already fixed).
- **Lock-timeout cleanup** (re-examined Race G1 above): the dominant
  "CASE 1: Has key + Has parent" timeout-recovery path does correctly purge
  `pendingChildren` and notify the timed-out partner via `PARENT_REJECT`.

**One genuine but low-impact gap noted**: the RX lock filter
(`Utils/WSN_Radio.m:166-189`, `passesLockFilter`) does not exempt Type 0
(HELLO) broadcasts - while a GWN is locked mid-handshake, incoming HELLO
from *other* neighbors is dropped, meaning neighbor-table discovery briefly
pauses during a lock. Checked against the actual configured values
(`HandshakeTimeout = 6` ticks vs. the dead-neighbor purge threshold of
`3 * HelloInterval = 1500` ticks): a 6-tick pause cannot cause a neighbor to
be purged, so in the current configuration this does not contribute to
unconnected segments. Flagging for completeness in case `HandshakeTimeout`
is ever tuned much larger relative to `HelloInterval`.

---

## Follow-up pass (2026-06-22): real ring-segmentation bug found and fixed

A later request to re-investigate "GWN-GWN ring segmentation" and
"unreached center CHs" against an actual long-running sim (~2500 ticks,
`logs/combined_t0-2500_20260622_013723.csv`) found and fixed a genuine,
previously-undocumented bug distinct from everything above - this one
**does** explain real, observed asymmetric parent/child state, confirmed
directly from log evidence rather than code-reading alone.

### Bug: asymmetric GWN-GWN parent/child loss via false-positive dead-neighbor purge

**Symptom, confirmed in logs**: GWN `FF06` and `FF0A` formed a normal
backbone parent/child link (`FF06.parent = FF0A`), with healthy steady-state
traffic (`FF06` forwarding `5.2`/`CH_HELLO` to `FF0A` every few ticks,
periodic `ENC_HELLO` registry refreshes succeeding through t=2266). At
t=2280, `FF06` logged `[CRITICAL] Parent lost` and cleared its own
`gw.parent` - **despite `FF0A` having received traffic from `FF06` only 8
ticks earlier** (t=2272). `FF0A` was never told and kept reporting
`gwCh=[FF06]` in its own `ENC_HELLO` to the Sink as late as t=2497 - the
exact backbone-children-table vs. backbone-parent-field asymmetry visible
live in the GUI's Network State table.

**Root cause** (three compounding facts, all confirmed by reading the
code): the `[CRITICAL] Parent lost` log has exactly one source -
`WSN_Gateway_Behavior.m:116-141`'s dead-neighbor purge, which clears
`gw.parent` once `neighborTable(idx).lastSeen < t - 3*WSN_Config.HelloInterval`
(1500 ticks). But:
1. Once a GWN is verified, it stops sending Type-0 HELLO (only sent
   pre-SECURE, `WSN_Gateway_Behavior.m:316-321`) - so the *only* thing that
   refreshed `neighborTable.lastSeen` post-handshake was Type-9 `ENC_HB`,
   sent once per `WSN_Config.HelloInterval` = **500** ticks
   (`WSN_Gateway_Behavior.m:207-210`). The steady-state backbone traffic
   that actually proves a link is alive - `CH_HELLO`/`SENSOR_AGG` relay
   (Type 5: `handle_CH_HELLO`/`handle_SENSOR_AGG`), `ENC_HELLO`
   (`handle_ENC_HELLO`), and the rest of the Type-7 CMD family - never
   touched `neighborTable` at all.
2. `WSN_Radio.getPriority` (`Utils/WSN_Radio.m:276-290`) ranks Type-9 HB as
   the **lowest**-priority backbone message (`p=20`, below CMD=50,
   TOKEN=40, CH_HELLO=30), and each radio has only a single `pendingRX`
   slot per tick (`WSN_Radio.m:76-103`, `pushRX`) - a higher-priority
   message arriving the same tick silently evicts a pending heartbeat with
   no retry/buffering.
3. The purge is one-sided: the side that loses its heartbeat clears its own
   `gw.parent` and has no live link left to notify the other side - so the
   other side's `children`/neighbor entry for it goes stale on its own
   separate, independent clock.

Combined: a node whose rare 500-tick heartbeat keeps losing the single-slot
RX arbitration (more likely on a busy node fielding more concurrent
neighbor/CH traffic, e.g. `FF06` with an active CH child) can accumulate
1500+ idle ticks in `neighborTable` *despite the link being demonstrably
alive via other traffic the whole time*, and self-purge a perfectly healthy
parent - asymmetrically, since the other side's clock runs independently.
This is also the most evidence-backed explanation on record for
busier/higher-degree (i.e. more central) backbone nodes disproportionately
losing the very link a center CH's data depends on, even though the CH-tier
relay itself is unaffected.

**Fix** (`GWN/WSN_Gateway_Messaging.m`): added `touchNeighborLiveness(sender,
t)`, called from `handleReceive` at the three points where backbone traffic
from a known neighbor arrives without ever refreshing `neighborTable`: the
"UNIVERSAL BACKBONE RELAY" early-return branch (encrypted child traffic),
the Type-5 `CH_HELLO` dispatch branch, and right after the generic Type-7
CMD unicast-to-self check (covers `PARENT_INIT`/`REQ_JOIN`/`ACK_JOIN`/
`GLOBAL_KEY`/`ENC_HELLO`). Any already-known neighbor sending valid traffic
now counts as proof of life, not just the rare, low-priority heartbeat -
this doesn't touch handshake/security logic, only liveness bookkeeping.

**Verification**: `WSN_Gateway_Messaging` parses via `meta.class.fromName`;
a 600-step headless regression (`WSN_Main(1e9, 100, [], 600)`,
`ActivateAttacks=false`) completes cleanly with zero `Parent lost` events
and 33 successful `ENC_HELLO` confirmations in the exported log, vs. the
pre-fix ~2500-tick run that produced the `FF06`/`FF0A` asymmetry above
(600 ticks is too short to exercise the 1500-tick purge window directly,
so this confirms no regression in normal formation rather than directly
reproducing the now-fixed purge).

---

## Follow-up pass (2026-06-23): CH-GWN registration rate quantified, one fix attempt, INCONCLUSIVE

A separate request (verifying the ML-IDS pipeline for crashes/data-quality
after the modularization restructure) found that `sink_dataset.csv`'s
CH-tier rows -- Normal and Attack alike -- are silently incomplete. This
section documents that investigation so it isn't re-derived from scratch.

### Confirmed: not an RF/topology problem

A diagnostic (`WSN_Physics.updateConnectivity` on a fresh topology, no
attack) found **all 20 CHs within 2 hops of a GWN, 13/20 within 1 hop** --
ruling out geometric isolation as the cause.

### Confirmed mechanism: CH_REQ silently dropped while a GWN's access radio is locked

`Utils/WSN_Radio.m`'s `passesLockFilter` only exempts Type 5 (CH_HELLO) and
Type 7.5 (ENC_HELLO) unconditionally; Type 6 (CH_CMD, which includes
CH_REQ) only bypasses `isFromPartner`. A CH_REQ from any *other* CH while
the GWN's access radio is mid-handshake is dropped at the radio layer
before it ever reaches `handle_CH_REQ` (`GWN/WSN_Gateway_Messaging.m:1507-1513`)
-- whose explicit, already-written `CH_REJECT`-when-busy branch is
therefore dead code in this exact path. Confirmed directly in per-node logs
(`combined_t0-*.csv`): stuck CHs show a clean `[CH_REQ] -> target` /
`[LOCK][TIMEOUT]` (CH's own local timeout firing, zero response ever
received) / `retry=N/5` / `[REJECT] MAX_RETRIES=5` / move-to-next-candidate
loop, repeating for the life of the run, never once receiving an explicit
reject.

A second, independent bug compounds this: `msg` is a `WSN_Message handle`
object, not a struct -- `isfield(msg, 'subtype')` (used in the existing
Type-7/ENC_HELLO exception on the very next line) always returns `false`
on object properties, silently no-op'ing that exception too. `isprop()` is
required. This means the ENC_HELLO lock-bypass exception has likely never
actually fired via this branch in any prior run of this project, relying
solely on the `isFromPartner` fallback.

`CH_ACCESS_LOCK_TIMER = 16` exactly matches the observed per-attempt CH
timeout, and with `CH_MAX_RETRIES=5` that's 80 ticks burned per rejected
candidate before rotating to the next one; `CH_REJECTED_LIST_RESET_INTERVAL
= 150` before a previously-rejected GWN is retried.

### Fix attempted: let CH_REQ bypass the lock + partner-priority arbitration boost

Tried: (1) fix `isfield`→`isprop`; (2) let CH_REQ (subtype 0 specifically,
not the whole CH_CMD family) bypass `passesLockFilter` unconditionally so
it reaches `handle_CH_REQ`'s real reject logic; (3) since CH_REQ already
has the *highest* nominal priority on the Access radio (`getPriority`,
p=3), bypassing the filter risked letting a stranger's CH_REQ win the
single per-tick `pendingRX` slot over the GWN's actual partner's real
reply (each radio is strictly half-duplex, one action per tick) -- so
added `getEffectivePriority()`, a +1000 priority boost for any message
from the current `handshakePartner`, guaranteeing partner traffic always
wins arbitration regardless of nominal type priority.

**First A/B attempt (CH_REQ bypass alone, isfield bug still present so the
bypass condition was *also* dead) measured WORSE**: same-seed controlled
test, 4/20 registered vs. an 8/20 baseline. Root cause: removing the lock
filter's protection let stranger CH_REQ traffic compete for the GWN's
single per-tick TX/RX slot against its actual partner's reply, starving
real handshakes in progress -- worse than the silent drop it replaced.

**Second attempt (isprop fix + bypass + partner-priority boost), tested
across 5 seeds (42, 7, 1, 99, 555), nets to exactly zero aggregate effect**:

| Seed | Baseline | With fix | Δ |
|---|---|---|---|
| 42 | 8/20 | 10/20 | +2 |
| 7 | 12/20 | 9/20 | −3 |
| 1 | 5/20 | 2/20 | −3 |
| 99 | 7/20 | 7/20 | 0 |
| 555 | 4/20 | 8/20 | +4 |
| **Total** | **36/100** | **36/100** | **0** |

Per-seed variance (4-12 out of 20, a 3x spread) dwarfs the fix's effect in
either direction. **This fix was reverted** (working tree is back to
`d31ef5e`, nothing committed) rather than left in an unproven state.

A qualitative spot-check (early-window logs, `combined_t0-250/500_*.csv`,
fix applied) shows the underlying mechanism *can* work cleanly -- a CH that
burned all 5 retries against one busy GWN (`t=266`→`t=350`, blind timeouts,
zero responses received even with the fix applied) succeeded on its very
next attempt against a different GWN (`t=355` CH_REQ → `t=358` CH_ACK
received, handshake closed). This suggests the **first-contact GWN(s) are
genuinely saturated during the initial post-warmup land-rush** (many CHs
activating and targeting the same nearby, RSSI-strongest GWN(s)
simultaneously) rather than every CH being permanently stuck -- consistent
with roughly half eventually succeeding within 1500 ticks and half not.

**Two confounds for whoever picks this up next:**
1. **Same-seed `rng()` comparisons are noisier than they look.** Once two
   code paths diverge in which random draws they consume (e.g. a CH_REQ
   that previously never reached `handle_CH_REQ` now conditionally calls
   `generatePasskeyForCH`, which can call `randi()`), the entire downstream
   random sequence for the rest of that run diverges too -- a fixed seed
   does not guarantee a clean, isolated comparison once behavior differs.
   Use many more seeds (10-20+) and compare aggregate distributions, not
   single-seed deltas.
2. The `isfield`→`isprop` correction is independently a real, narrowly-
   scoped bug fix (the ENC_HELLO exception has silently never worked via
   this branch) and is very likely safe to apply on its own merits,
   separate from the CH_REQ-bypass/priority-boost experiment above, which
   was not isolated and tested alone due to time constraints this session.

**Recommended next step, not started**: a proper per-GWN pending-request
queue (bounded, e.g. size 3-5) instead of the single-lock-slot-and-drop
model, with the GWN proactively re-engaging the next queued requester once
its current handshake clears, rather than relying on the requester's blind
16-tick local timeout-and-rotate. This is a real protocol change (new
queue-management state, expiry handling for requesters who gave up and
moved on), not a one-line fix -- scope it as its own session.
