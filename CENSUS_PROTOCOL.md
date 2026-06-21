# Census / Shutdown / Update Protocol (ML_IDS_PLAN.md Phase 4)

Rule-based, MATLAB-native trust scoring + daisy-chain neighbor polling + blacklist
escalation. No ML model is consulted at runtime — this is the "local tier"
mitigation mechanism, distinct from the offline-trained local/global models in
`ml/` which exist purely to report comparative accuracy metrics.

## Message types and constants (`WSN_Config.m`)

| Type | Name | Subtypes |
|---|---|---|
| 11 | Census | 0=POLL_INITIATE, 1=POLL_YES, 2=POLL_NO, 3=POLL_COMPLETE |
| 12 | Shutdown | 0=SOFT_RESET, 1=HARD_RESET, 2=BLACKLIST |
| 13 | Update | 0=TRUST_DELTA, 1=THRESHOLD_SET (constants defined; not wired to a live sender in this phase — see Scope below) |

Trust thresholds: `TRUST_INITIAL=50`, `TRUST_CENSUS_TRIGGER=20`, `TRUST_DELTA_FAIL_HARD=10`,
`CENSUS_POLL_TIMEOUT=10`, `CENSUS_QUORUM_YES_RATIO=0.6`, `CENSUS_MIN_VOTERS=2`,
`RESET_ESCALATION_COUNT=3`.

## Trust storage

Each tier stores trust differently, matching what already existed before this phase:
- `WSN_Sensor.m` / `WSN_ClusterHead.m`: a `neighborTrust` struct array (`id`, `score`), with `getNeighborTrust`/`updateNeighborTrust`. CH's `neighborTrust` is new in this phase; Sensor's pre-existed as an unused stub and is now live.
- `WSN_Gateway.m` (shared by GWN and `WSN_Sink`): trust lives directly on the existing `neighborTable.TrustScore` field, which was previously only assigned a static per-tier constant at creation and never updated.

## What decrements trust (the only two wired triggers)

1. **CH's own aggregation (5.2) never ACKed** — `WSN_ClusterHead.processSensorAggregation`'s retry-exhaustion branch (`aggRetryCount >= AGG_MAX_RETRIES`) decrements trust in `obj.parent`. This is the primary signal: a Blackhole/Grayhole parent that silently drops 5.2 without ACKing surfaces here.
2. **GWN/CH handshake retry exhaustion** — `WSN_Gateway_Behavior.m` (two sites) and `WSN_ClusterHead.m`'s `CH_MAX_RETRIES` branch decrement trust in the unresponsive recruitment target. **Gated to `t > WSN_Config.SetupTime`** — during initial network formation (boot/recruitment), retries are normal FSM churn, not malicious behavior; without this gate, early testing showed dozens of false-positive `CENSUS_INITIATE` events between t=2 and t=300 purely from bootstrap timing, well before any attack was even active.

Checksum-failure-based decrementing (mentioned as a possibility in the original plan) was **deliberately not wired**: `WSN_Sensor`/`WSN_ClusterHead`/`WSN_Gateway` each override `receive()` directly and check `verifyChecksum()` ad hoc per message type rather than through a shared gatekeeper, so there's no single clean injection point, and checksum corruption isn't actually produced by any of the existing attack types in this simulator — low value for the engineering cost.

## Daisy-chain polling (`checkCensusTriggers`, mirrored in Sensor/CH/Gateway)

1. Any tick, a node scans its own trust store; for any neighbor below `TRUST_CENSUS_TRIGGER` with no already-active poll, it broadcasts `11.0 POLL_INITIATE {suspectID, pollUID, reasonCode}` at TTL=1.
2. Any receiving neighbor that also has an opinion on the suspect (i.e. the suspect is in *their own* trust store) replies `11.1 POLL_YES` or `11.2 POLL_NO` based on their own trust value — unicast back to the initiator. Neighbors with no opinion silently abstain.
3. The initiator collects votes for up to `CENSUS_POLL_TIMEOUT` ticks, then finalizes:
   - `totalVoters < CENSUS_MIN_VOTERS` → **inconclusive** (verdict=2). Trust is left as-is; the node will re-poll on a future tick if still below trigger (the poll is removed from the active list, so the `already`-active check no longer blocks a fresh attempt).
   - `yesCount/totalVoters >= CENSUS_QUORUM_YES_RATIO` → **malicious** (verdict=1). Trust is snapped to `TRUST_MIN`.
   - otherwise → **cleared** (verdict=0). Trust resets to `TRUST_INITIAL` (benefit of the doubt against a false alarm).
4. The initiator sends `11.3 POLL_COMPLETE {suspectID, verdict, yesCount, totalVoters}` uplink to its own parent.

## Nearest-ancestor enforcement (`handlePollComplete`)

POLL_COMPLETE is *not* adjudicated centrally at the Sink. Whichever node receives it checks: is the suspect my own direct child (`children` / `chChildren`)? If yes, only verdict=malicious enforces — look up (or create) a `resetHistory` entry for that suspect and escalate:
- 1st time → `12.0 SOFT_RESET` (peer clears its own trust/poll/queue state, keeps operating).
- After `RESET_ESCALATION_COUNT` soft resets → `12.1 HARD_RESET` (forced back to `STATE_BOOT`, full re-handshake).
- After `RESET_ESCALATION_COUNT` hard resets → `12.2 BLACKLIST` (permanent: `isBlacklisted=true`, removed from `children`, silently dropped at the top of `receive()`/`step()` everywhere).

If the suspect is *not* a direct child, the message is relayed further uplink unchanged. If it reaches the Sink with no parent and the suspect still isn't a child, the Sink just records an anomaly tick in `globalTrustRegistry` for visibility — there's no guaranteed multi-hop downlink path to forcibly reach an arbitrary distant node in this codebase's existing routing, so enforcement is deliberately scoped to "whichever ancestor actually has the suspect as a direct child," not "the Sink, always."

## GUI

`WSN_GUI_SinkAnalytics.m`'s sensor-registry Trust column now reads real, dynamically-updated values instead of a static 50, and renders `BLACKLISTED` in place of a numeric score once `globalTrustRegistry(...).isBlacklisted` is set.

## Verification performed, and an honest finding

Verified via two long headless runs (Blackhole attacker = the GWN with the most nearby CH children, intensity 1, attack active from t=450, 1200 ticks total):

- **Before the SetupTime gate**: `CENSUS_INITIATE` fired from t=2 onward against multiple GWNs, all false positives from normal handshake-retry churn during boot — confirmed the gate was necessary and fixed it.
- **After the gate**: trust decay and poll initiation/timeout/finalization all function correctly; votes *are* successfully cast and counted (`CENSUS_COMPLETE` lines like `(1/1 votes)` confirm the cast→count→quorum-check pipeline works end-to-end). However, **no poll in this run ever reached `CENSUS_MIN_VOTERS=2`** — TTL=1 single-hop broadcast plus this topology's density meant an initiator's polled neighbors only occasionally had an opinion on the same suspect, and never more than one at a time. Verdicts stayed "inconclusive" and enforcement (`ENFORCE`/`SHUTDOWN`) was never triggered in this specific run.

This is a real characteristic of a sparse daisy-chain design, not a code defect — every mechanical step up to and including quorum *counting* is proven correct; only the quorum *threshold being met* depends on topology density and was not observed in this particular randomized run. If reliable enforcement matters more than topology realism for a future demo, the easiest tunables (in priority order) are: lower `CENSUS_MIN_VOTERS` to 1, increase the POLL_INITIATE TTL beyond 1 hop, or target denser clusters (more CH children per GWN, as this test already tried to do).

## Update (2026-06-19): three real bugs found and fixed, not just topology density

Deeper verification after the above (see `AI_ENGINE_DEBUG_PROMPT.md`'s "ML-IDS Phase 1-4 Updates" section for full detail) found that "topology density" was only one of three independent, compounding problems — and not even the most important one:

1. **`neighborTable.TrustScore` field-reuse bug (fixed).** `WSN_Gateway.m`'s trust code originally read/wrote the pre-existing `neighborTable.TrustScore` field, which already had a different meaning (Hello/Heartbeat verification confidence, `[10 30 60 100]` by tier/subtype, never updated after creation). An unverified heartbeat assigned `TrustScore=10` — already below `TRUST_CENSUS_TRIGGER=20` at creation, causing ~6500 false-positive polls per 1500-tick run, all GWN-vs-GWN noise unrelated to any real attack. Fixed by giving `WSN_Gateway` its own dedicated `neighborTrust` store (mirroring Sensor/CH), seeded at `TRUST_INITIAL=50`.

2. **GWN:CH ratio was inverted (fixed).** `WSN_TopologyGenerator.m` generated more GWNs (12-15%) than CHs (6-10%), so no GWN could structurally have more than 1-2 CH children — capping the voter pool regardless of RF range (actual GWN-CH link distances measured well within physics range; population count, not connectivity, was the bottleneck). Fixed: GWN 10-13%, CH 16-20%.

3. **Neither original trigger actually catches Blackhole/Grayhole (fixed with a new detector).** Both attacks fake-ACK their own children before silently dropping the relay upward (`WSN_ClusterHead.m`'s `handleSensorAgg`, "send ACK (appears normal), but no forward") — so the child's own retry-failure trigger never fires; from the child's perspective everything looks fine. The only place the attack is visible is the attacker's *own parent*, who simply stops receiving periodic reports. Added a parent-side reporting-silence detector (`WSN_Gateway.chLastAggSeen`/`chAggSilenceFlagged`, checked in `checkCensusTriggers`) that flags a CH child silent for more than `AGG_PERIOD_MAX * SILENCE_GRACE_MULTIPLIER` (30 ticks) and decrements trust. Verified firing correctly (real gap/threshold values) across multiple runs; a single fully-clean injected-attacker-to-BLACKLIST trace is still pending, blocked by unrelated topology-formation variance (the random attacker sometimes never finishes its own GWN handshake within the test window).

With all three fixes applied, `CENSUS_MIN_VOTERS=2` was left unchanged (not loosened to 1) — the original three tunables suggested above are no longer the recommended path now that the actual root causes are fixed.
