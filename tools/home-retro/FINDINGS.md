# Home process diagnosis

## Scope and confidence

Read-only window: **[2026-10-28 09:09Z, 2026-10-31 09:09Z)**. Source baseline
`cc6400b58`; running Stable observed separately at `8818377ed`, runtime epoch
`0a60f1ef-5d6b-427f-bb0e-f43d01c8a574`. Repository changes are not deployed fixes.
Task files were individually revision/hash fenced; transcript prefixes were size/hash
pinned and subsequently rechecked. This is not a transactional cross-file snapshot.
Mutable outcomes/spend are observations after cutoff, not historical versions.
Case timings are retained worker measurements, not newly reproduced runs.

Sources were discovered through `home-task-store.ts:125–128` (task namespace),
`home-owner.ts:162–215` (chapter designation), `tron-workspace.ts:34–39` and
`profile-store.ts:161–186` (Profile). No owner/runtime was opened on live data.
Home chapter 21 is `afa34923-1bb8-4266-a7a7-506e2de3e017`; entry IDs below refer
to its canonical parent branch unless identified as worker reports.

Private reproducibility packet: internal workspace
`files/home-self-improvement/2026-10-31T090900Z/`: `per-task.json` has every
in-window operation, blocker text, admitted resume link, direct accepted steer count,
report locator, tokens and explicit missing fields; `source-manifest.json` pins reads;
`canonical-usage.json` pins worker-only usage. Raw reports/profile evidence stay private.
This document contains only engineering-process excerpts, not personal profile content.

## Measured outcomes

- **127 operation records / 59 root lineages**: 53 new roots, 74 admitted resumes;
  30 lineages had no in-window resume; two long-running roots had 10 and 11.
- Observed records: 63 final, 35 progress, **23 needs-input**, 3 interrupted, 3 active.
  Final is a worker outcome, not a landed slice. One final report arrived 11 seconds
  after cutoff; it is excluded from in-window report-latency statistics.
- **150 accepted direct Home steers**; 69 unique attention check-ins attributed to
  these operations, using canonical accepted results plus deduplicated snapshots.
  Summing copied snapshots instead produces 139 attention-marked rows: not 139 events.
  Older nested check-ins can age out; these are not complete event-history counts.
- Creation→canonical report: **120 samples; median 42.77 min, p90 129.97 min**
  (nearest rank). This is operation/report time, **not delegate→landed time**.
  The latter is unavailable without explicit publication joins; no commit-clock proxy.
- Stored counters: 27,141,439 input; 1,846,613,054 cache-read;
  2,261,018 cache-write; 7,827,373 output tokens. Two null spends remain unavailable;
  legacy missing cache counters are not reinterpreted as fresh input.
- Canonical in-window worker assistant records: 11,303, with recorded model-price
  estimates totalling **$379.17**, not billed cash. Excludes Home, summarization and
  child sessions; no inclusive/child double counting. Task records store tokens only.
- 124 settled-record wakes were acknowledged at observation. That does **not** prove
  timely action, user receipt, or absence of an earlier delivery defect. No missed-wake
  or lossy-summary incident was causally reproduced in this investigation.

## Case chains

Numbers are in-window admitted resumes / accepted steers / unique attention events /
needs-input reports. Operation→report minutes exclude unreported active operations.
All exact delegate→landed and reviewer/lock wait durations remain unavailable.

| Root task (omit common `tron-` prefix) | R/S/A/P | Operation→report min | Evidence |
|---|---:|---|---|
| `2132-main-green-2112-root-fix-20261031-1` | 2/5/1/0 | 105.07; 78.11; open | worker reports `28a32823`, `1965d4a6` |
| `2132-apps-2137-and-profile-2138-20261031-1` | 2/8/4/2 | 101.65; 32.06; open | `bac4f25f`, `06f940bd`; attention `3d2ab7ef` |
| `2132-routine-ui-2140-primitives-2147-20261031-1` | 1/5/2/0 | 122.52; later report censored | `a587aa1f`; attention `534210de` |
| `2135-health-scorecard-build-20261030-1` | 1/2/1/0 | 80.85; 43.25 | `2d8a7982`, `26279b11`; attention `ca85df0f` |
| `2132-knowledge-to-files-2131-2143-20261030-1` | 3/4/2/0 | 91.84; 121.05; interrupted; 130.01 | report `2131-2143-landed-854ff032` |
| `speed-tax-green-main-fast-tests-20261030-1` (#2158) | 0/4/1/0 | 112.94 | worker report `5164b8cc` |

#2158 illustrates a discovery pitfall: searching task IDs for an issue number misses
its differently named root. The full census, not an issue-number sample, is the denominator.

## Top five causes and fix categories

1. **Brief-imposed proof multiplication — Home brief/ruling defect (1).**
   #2112 says: “Gate: verify --changed green, one full Gateway run, compare reds
   against main. Independent reviewer ACCEPT on exact SHA”; also “Fail-before/pass-after
   for each fix.” #2138 repeats the full-run/exact-SHA gate. These are additional
   pre-land obligations, not the selector's affected-now/post-land contract.
   #2138 also requires “Net production LOC must drop”; LOC must remain diagnostic.
   Worker `06f940bd` records four 720-case ABBA runs, **891.118 seconds of suite
   execution**, then parks inconclusive. That is measured execution, not inferred idle
   waiting. Fix: affected checks plus required test/security review; Home owns broad
   checkpoint evidence. Keep causal bug proofs, not ritual reruns for every edit.
   Do not turn every integration race into a fresh-review ceremony.

2. **Load-sensitive wall-clock oracles and concurrent heavy runs — tooling (2).**
   Worker `1965d4a6` records #2112 at 12.002s with 193/199 results, about 7.481s
   synchronous API wall, a different quiet sample at 6.210s, and an affected gate
   overlapping its own baseline full. `06f940bd` reports a foreign #2112 full starting
   ~6s after the paired run's clean-start check. `a587aa1f` records a mandatory full
   reaching the 900s tool ceiling. Home entry `12c6364a` then adds a shared full-suite
   lock. Fix: repair the actual test/fixture/IO owner and reduce duplicate full runs;
   no new global queue or arbitrary timeout increase. Missing sharding is a hypothesis,
   not proven here. Per-task lock/reviewer idle duration cannot be reconstructed.

3. **Workers bounce objective gates back upward — brief/ruling defect (1), guidance (4).**
   #2138 attention `fbd3baff` asks whether fixture preparation can be separately bounded
   while preserving the 15s behavioral/96MiB refusal oracle; `bac4f25f` later records
   reviewer acceptance that this is not a disguised timeout increase. #2140 attention
   `1e1568f1` requests a base-red gate disposition, not subjective design.
   Fix: Home promptly rules on evidence and ownership; workers may justify intended
   golden/assertion/timeout changes with non-author review, without maintainer test-text
   approval. Do **not** generalize this to irreversible storage/authority decisions:
   #2138 attention `3d2ab7ef` names real immutable-revision consumers and deserves a
   consumer-contract decision, not silent deletion of provenance/Undo.

4. **Durable decisions exist, but brief consistency is not enforced — architecture (3), guidance (4).**
   `home-profile.ts:16–25,30–38` already owns standing decisions; the Home index is
   discovery metadata, not an automatic instruction injector. `tron-home-extension.ts`
   explicitly leaves relevance and worker context to Home. Entry `a51ff1b4` re-reads
   “No ceremony: run the tests the change affects, then do a plain-Git merge to main”
   after the heavier briefs. Current Profile retains the affected-before/full-after
   merge rule; the older “assertions…still need approval” note is retired, not active.
   `AGENTS.md:83–86,102–110` agrees with the newer ruling; line counts are not gates.
   Fix: reuse exact Profile decision revisions/provenance in brief composition and
   contradictory-rule checks; do not add a second rulings database or infer confirmation.
   This proves application drift, **not** a specific summarizer deletion of a decision.

5. **Outcomes have no joined, typed feedback surface — architecture (3).**
   `home-task-store.ts:26–76` has operations, capped progress, token counters and wake
   state, but no publication endpoint, control-event history or typed wait intervals.
   `home-task-history.ts:14–17,65–91` explains canonical history and aged-out nested gaps.
   `tools/verify/health-design.md` already leaves missing joins unavailable; #2158's
   remaining scope names those gaps. Fix: this slice exposes the existing records
   read-only; later Home Automation consumes it and proposes owner-scoped changes.
   Wakes must be diagnosed through existing inbox/receipt evidence, not a polling worker.

## Immediate Home habits

Use affected-now evidence, not worker full-suite ABBA/locks. Read relevant standing
decisions before composing a brief; quote their exact scope, not a harsher paraphrase.
Resolve reversible objective questions at the next check-in; escalate only genuinely
subjective or irreversible/authority calls. Reuse workers and existing primitives.
Keep parked scope/consumer decisions distinct from red-test ownership. Never treat
ACK, final, absent metrics, or a quiet sample as success/zero/causal repair.
