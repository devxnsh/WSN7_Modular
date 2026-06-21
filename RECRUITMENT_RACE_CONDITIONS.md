# Recruitment Chain Race Conditions (2026-06-21)

## Scope and ground rules

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
