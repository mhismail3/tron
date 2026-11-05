# Causal source auto-revert

Design for #2194 under #2173. The implemented contract and its single enable step are in
[batch.md](../../tools/verify/batch.md);
publication is off by default. Structured failure classes, provenance and repeat tallies
below remain design only.
[Principles P2/P3/P8](../PRINCIPLES.md) own policy. #2176 owns fast affected checks
and asynchronous full-main E2E execution; #2194 owns attribution and source repair.
Feature landing never waits for this pipeline. Production lifecycle, installed
checkpoints, live data, migrations and device smoke remain maintainer-owned.

## Decisions and existing seams

Reuse `scripts/tron verify` and `tools/verify/batch.py`: pinned main ranges, lane
execution, retained reports/logs, case probes, first-parent search, nonwaiting
repository lock and issue-write journal already exist. Reuse ordinary Git for
publication and `scripts/tron work` for guarded GitHub writes. Do not add a landing
service, daemon, webhook, database, queue, health dashboard or second failure ledger.

The existing attribution is not sufficient authority: it requires two-parent
landings, repeats the culprit but not all controls, prepares a local merge revert,
and treats a passing reproduction as needing registry registration. Current batch
coverage can advance on qualified reds. Those semantics must be replaced, not
wrapped or trusted as causal proof. `verify.py` local reports can be overwritten;
freeze copies before probing. Existing caches are hints, never fresh proof.

Automations may wake Home to inspect pending main coverage, using their existing
single-flight/receipt semantics; they do not execute shell commands or grant
maintainer authority. Home dispatches authorized finite verification work through
existing task owners. #2176 owns admission/cadence and eventual configuration;
this design creates no Automation. A red terminal report triggers attribution
immediately in that verification operation, not via a new polling service. After
interruption, the same owner reconciles its journal before accepting more repair
work. Busy resource admission retains pending coverage, never skips it as green.

## Trigger and evidence contract

1. Pin fetched main `H`, last **raw-green** ancestor `G`, source tree, runner and
   dependency identities. A supplied initial anchor is not green. With no proven
   good anchor, diagnose/bootstrap coverage; do not guess a historical culprit.
2. Run all required E2E lanes asynchronously in an owned, clean verification
   worktree. Every landing eventually receives coverage, even if multiple main
   commits are coalesced into a range. Preserve all required outcomes and gaps.
3. A terminal raw failing test triggers one investigation per exact test/signature
   and range. Setup/build/cleanup failure, interruption, zero tests, missing report,
   changed source or required skip triggers unresolved coverage, not a good/bad
   commit vote. No registry match, quarantine or waiver changes the raw verdict.
4. Freeze the first report before any reproduction: `G`, `H`, full test identity,
   exact command/selector, seed, order, concurrent workload, resource preconditions,
   toolchain/dependency hashes, exit, complete failure messages and raw artifacts.
   Store these with existing common-Git `verify/batches/` evidence. Seal a manifest
   of artifact hashes after writers have joined; later mutation invalidates proof.

The existing batch report/journal is the sole machine authority, extended in place
with evidence references and repair transitions; the retained #2196 ledger owns
human root-cause knowledge. Reports say raw red/unresolved until resolved, not
"qualified". Full green requires every required lane, no hidden suppressions.

## Reproduce on demand and distinguish cause

A reproduction command runs the **same shipped runner** and exact case through
its real boundary, in a disposable worktree with owned HOME/TMPDIR/data/ports and
joined children. Record ordinary concurrent load; use existing host slots/leases
for native probes. Never borrow another worker's tree, simulator, data or process.
If the failure requires suite order or interference, preserve that minimal workload
as part of the reproducer. An isolated passing case does not disprove a suite red.
Missing selectors, invalid historical dependencies or unavailable resources are
UNKNOWN, not PASS. No sleeping, retry-to-green or timeout/assertion edits.

A matching failure means exact case and full normalized failure-message digest
(existing checkout-root normalization only), plus the same observed behavioral
failure. Equal exit codes, file names or assertion sites alone prove nothing.
Different signatures branch into separately owned investigations, not one cause.

For automatic repair, use a predeclared deterministic recipe and two independent
fresh executions per polarity at the final controls: original failing `H`, good
first parent `P`, culprit `C`, and repaired current tip. Every requested execution
must agree. These are bounded causal controls, not a claim of statistical certainty
or the 20-pass qualification. Any mixture of pass/fail, signature change or unknown
stops automatic repair. Never sample until the desired answer appears.

- **Causal source regression:** `P` passes, `C` fails identically, and applying only
  the inverse of `P..C` to the tested current tip removes that failure. Independent
  review explains the changed behavior/mechanism and surviving oracle. Harness or
  test-source defects can be source regressions too; do not assume product blame.
- **Environmental:** positively identified resource/toolchain/service failure,
  reproduced without the candidate source change and corrected by a controlled
  environmental intervention. Correlated load, a passing parent once, or "base
  also red" is insufficient. Remains uncovered/red evidence until root-fixed.
- **Nondeterministic or unresolved:** inconsistent controls, unexplained missing
  artifact, unforced race, or no decisive intervention. Refuse the revert, retain
  every attempt, notify Home and assign a root-cause issue. A possible product race
  remains a bug, not an exemption. Resume only with a new explained recipe; retain
  the failed recipe and new evidence, never silently reclassify the original run.

## Structured failure, provenance and repeat evidence

Harvest failure classes, correlated provenance and repeat accounting from the
external-ideas shortlist (tester-army/e2e); **reject that runner/dependency**,
model assertions, replay/self-heal, probabilistic selection and flaky-as-success.
Keep native XCUITest/real Gateway and the existing deterministic selectors. The
following are proposed report fields in existing verification owners, not a new
runtime store, telemetry backend or claim that these fields already exist.

Every raw red, including setup/cleanup/incomplete coverage, carries a typed
`failureClass`: `product_regression | test_defect | environment | infra | unknown`.
Default `unknown`. Also record `ruleId`, referenced structured observations, their
artifact digests and causal-control references. The owner computes the class from
validated runner/process/xcresult facts and control outcomes, never agent prose,
LLM judgement, log-keyword matching or exit code alone:

| Class | Required distinguishing evidence | Automatic source repair |
|---|---|---|
| `product_regression` | Valid behavioral oracle, source transition and inverse controls above, observed production effect/crash causally tied to it | Only with full proof + ACCEPT |
| `test_defect` | Same source controls; traced fixture/oracle violates established intended contract, with surviving faithful oracle explicitly reviewed | Only with full proof + ACCEPT |
| `environment` | Recorded external resource/toolchain/service condition and controlled intervention independent of candidate source | Refused; diagnose/root-fix |
| `infra` | Structured runner/lease/report/owned-process lifecycle failure; no proved source transition | Refused; diagnose/root-fix |
| `unknown` | Missing, contradictory or insufficient evidence for any rule above | Refused; investigate |

An assertion is an observation, not automatically a product regression; an app
crash, timeout or killed child is not automatically infrastructure. Record who
initiated a fault injection and its process receipt. Conflicting observations
resolve to `unknown`, not a precedence guess. A later causal proof may supersede
an initial infra/unknown diagnosis with a source class; retain both evidence-linked
classification events. Class never substitutes for causal proof or makes a red
green. Rule validation checks referenced control bindings; a reviewed contract
explanation supplements those facts, never overrides a failing/missing control.

Bind a machine-readable provenance chain in the existing report:
`landing {commit, firstParent, tree} -> verify {runId, head, recipeDigest, reportDigest}
-> worker {taskId, sessionRef}`. Separate the **landing author task** from the
**verification executor task**; coalesced runs list all covered landing commits,
not a fabricated one-to-one relationship. Read Git history and existing canonical
task/worker receipts; a commit trailer is only a join hint until corroborated.
Each edge includes its evidence reference or explicit `unavailable` and reason.
Do not infer worker identity from author name, timestamps or branch names, copy
session content into reports, or build a second session database. Historical
missing worker identity does not negate proven source causality: the revert still
names exact culprit/parent, original red run, repair run, ACCEPT and available task
IDs, marking the missing edge unavailable rather than inventing it. Missing exact
landing/run/control bindings, unlike a missing author task, forbids publication.

For #2196, expose a directly readable, derived `repeatTallies` array in existing
verify evidence: `{testId, recipeDigest, sourceIdentity, loadEvidenceRefs,
attemptRefs, executed, passed, failed, incomplete, consecutivePasses, eligible}`.
`attemptRefs` point to unique ordered original runner receipts (run/attempt IDs,
SHA, full test selector, raw outcome/counts, toolchain/runtime and actual workload).
Derive counters from those receipts, never worker-supplied totals or mutable tally
increments. Count a pass only for exactly executed required case coverage, joined
cleanup and recorded normal concurrent load. Failure, skip, zero execution,
interruption, missing receipt/load proof or changed recipe/dependency identity
breaks the streak; duplicates never increment it. Retain the broken prefix and
all failure classes. Invalidate carried evidence when source/dependencies change
unless an explicit reviewed unchanged-input proof binds it. Twenty consecutive
eligible passes is the per-test component, never full-green or ledger closure.
A tally is a disposable report projection, not another qualification authority;
#2196 reads it and retains root-cause/qualification decisions in its existing ledger.

## Bisect the landed change, not the nearest author commit

Enumerate `G..H` on main's first-parent chain. A fast-forward single-parent commit
is a landing unit; a two-parent integration merge is one unit with parent 1 as
main. Probe that exact integrated tree, not the feature branch's intermediate
commits. Reject ambiguous/octopus history and non-ancestral anchors.

Reuse case-only binary search to find a candidate transition. UNKNOWN stops search;
no `git bisect skip` that invents certainty. Binary search proposes, never proves:
its monotonic assumption may fail when changes cancel or interact. Freshly execute
adjacent `P` and `C` controls and the `H` control above. If more than one landing is
needed to reproduce or undo, do not bulk-revert a guessed set. Open a bounded
interaction investigation. Multiple failed cases require separate proof; one
repaired case cannot erase another red. Cached probes only reduce discovery work;
final controls are fresh and pin the same recipe and environment.

## Reviewer gate and plain-Git publication

One verification owner serializes repair attempts using the existing nonwaiting
repository lock, not feature landings. Keep durable evidence **before** each
effect: investigation identity, culprit/parent, fetched tip, inverse patch hash,
candidate tree/commit, control results, reviewer identity and decision, and push
intent/outcome. Bound attempts; cancellation joins only owned work and preserves
uncertain state. Crash recovery reads artifacts and remote Git before new effects.

1. Fetch main into the owner's private `FETCH_HEAD`; call the exact tip `T`.
   Require `C` in its first-parent ancestry and recheck whether it was already
   repaired/reverted. On `T`, freshly reproduce the red before building a revert;
   a later fix means stale result, no revert. Inconsistent proof means unresolved.
2. In the dedicated repair worktree, create the inverse with `git revert --no-edit C`
   for one parent or `git revert --no-edit -m 1 C` for a two-parent integration.
   Preserve conflicts for diagnosis, never auto-resolve, revert a revert blindly,
   rewrite history or modify a foreign branch. Revert only that landing's delta.
3. Run fresh repaired-tip controls and ordinary affected verification on the exact
   candidate. Other known reds remain raw reds, not exemptions. If affected checks
   fail, do not publish; a full main E2E is asynchronous after publication, not a
   new full-suite pre-merge requirement.
4. Obtain a **non-author agent reviewer ACCEPT**, not a maintainer queue. Review
   binds `C`, `P`, `T`, candidate commit/tree/patch, evidence manifest and recipe.
   Reviewer must verify source causality, meaningful surviving oracles, no unrelated
   removals, and reversibility. BLOCK, missing/uncertain review or stale bindings
   cannot authorize Git. An ACCEPT is evidence; a typed validation in the existing
   owner checks those exact bindings, not free-text keyword matching.
5. Publish the tested descendant with plain `git push origin <candidate>:main`.
   No force, reset, deploy, installation, credentials change or production RPC.
   This is a fast-forward update of the remote ref even when the reverted landing
   was a merge. Ordinary feature landings remain concurrent.
6. On non-fast-forward, preserve the candidate, fetch current main and repeat tip
   reproduction, inverse construction, affected checks and reviewer binding for
   the new candidate. Never push the stale tree or reuse stale ACCEPT. One race
   may be retried in-operation; further races leave pending repair for a later
   owned invocation, without stopping other landings.
7. A failed/disconnected push can have succeeded. Persist candidate identity before
   dispatch; read `ls-remote`, fetch the exact remote head and test ancestry. If the
   candidate is reachable, mark published even if main advanced. If positively not
   reachable and remote remains `T`, recheck all bindings before an explicit retry.
   If remote advanced, follow step 6. Unreadable/rewritten/ambiguous history stays
   uncertain, with no automatic replay. Push exit status alone settles nothing.

Use stable investigation identity `(repository, H, test, signature)` and a repair
identity `(repository, C, inverse delta)` across overlapping ranges. The journal
and Git ancestry/trailers together prevent duplicate repairs; a trailer alone is
not proof of the patch. Competing repair candidates lose the ordinary push race
and reconcile before doing anything else. A crash after accepted push but before
local acknowledgement discovers the exact commit remotely, never creates another
revert. Human/manual repairs are checked by current-tip controls and diff review;
if a revert was later intentionally relanded, old investigations stay terminal.
A new red needs new causal proof, not a perpetual suppression keyed by culprit.

Source-only authority excludes migration/data reversal, source changes incompatible
with already-migrated stores, security/trust/privacy changes requiring a native tap,
and production/device actions. Reviewer checks these boundaries; uncertainty
refuses auto-publication and escalates a concrete required decision without
blocking feature work. A code revert is not authority to undo effects already run.

## Notification, ledger and green

The existing issue-write journal and guarded `work comment|issue` dedupe public
updates. Notify Home durably on first red, refusal/uncertainty, and publication:
report/test/SHAs, root owner, artifact references, exact revert or blocker. Use
existing checkin/report delivery, with push notification only for useful attention;
notification success is not publication or receipt proof. Failed notification is
retained and reconciled independently; it must not repeat a Git effect. Public
text passes the privacy guard; never copy private fixtures or credentials.

Send evidence to the **existing ledger owner**, not a second ledger writer. A revert
can restore a behavior but does not erase the failure or prove its underlying root
fix. Record first failure, recipe/mechanism, culprit, reviewer, revert, residual
failures and root-fix/reland issue. Require causal fail-before/pass-after and
independent review before relanding. #2196 still requires every row root-fixed,
20 consecutive passes of each former red/flake under normal concurrent load, then
one complete raw-green Gateway/nested/iOS-UI run on one commit. Preserve every
attempt; any new red reopens its row and invalidates affected qualification. Port
prior per-test evidence only with explicit unchanged dependency/recipe proof;
the final full green always names its single exact commit. A targeted repair pass,
revert push or historical green anchor does not meet that bar or permit promotion.

## Open maintainer decisions: release-loop conflicts

The external release-loop proposal is input, not authority. Two policy conflicts
remain **open maintainer decisions**, not resolved by this design:
- Automatic internal TestFlight upload versus AGENTS.md safety 1–2 and P1: current
  rules prohibit automated production/device release. Whether any exact tap-gated
  or standing internal-upload exception is desired must be decided explicitly;
  until then only authorized artifact/evidence preparation and notification apply.
- A fix-forward-on-red worker loop versus P2's causal revert-first, root-fix-before-
  reland contract: whether to change that contract is the maintainer's decision.
  Until then retain revert-first for proved reversible source causes; unresolved
  attribution never authorizes a guessed revert or a fix-forward policy exception.

No release diagram, research report or source class grants installs, promotions,
live-data reversal, production control or permission to clear an unresolved red.
#2176 still owns trigger choice; reuse of Home wake is an option, not a second
scheduler or a settled cadence decision. No new release loop is implemented here.

## Minimal first implementation

Start hardware-free in the existing `batch.py` attribution owner and
`tools/verify/tests/test-verify-batch.py` real-Git fixture. Support one deterministic
Gateway case, ordinary commit and integration-merge landing, through reviewer-gated
publication to a disposable bare remote. No Automation/schema/service addition.
Extend existing progress/push evidence rather than create a second store. Explicitly
refuse unsupported lanes/history, mixed results and irreversible boundaries; they
remain unresolved, never green. Keep rollout disabled until #2196/#2195 prerequisites
and #2176 raw async execution/no-exemption alignment land. No live main revert in
this slice. Follow-on native/order-dependent support must use the same owner.

Fail-before/pass-after tests invoke shipped CLI/owner logic and real Git processes:
- deterministic bad landing after good parent -> exact inverse published, case
  green; prove the same for single-parent and two-parent mainline-1 history;
- innocent concurrent landing survives; stale ACCEPT refuses until new-tip proof
  and fresh ACCEPT; repeated race stops boundedly, leaving evidence;
- duplicate and overlapping reports, restart before push and crash after remote
  acceptance -> exactly one inverse commit, including lost push acknowledgement;
- stale red after a fix -> no revert; mixed pass/fail, changed signature, absent
  selector, setup failure, skipped/zero coverage or bad parent -> unresolved/no push;
- conflict, reviewer BLOCK/wrong tree, migration/security boundary or missing
  authority -> no push and preserved work; immutable first evidence survives;
- seeded structured assertion/crash, injected runner/lease failure and ambiguous
  observations derive the required class/evidence references; contradictory or
  prose-only claims stay unknown. Both source classes need the same causal gate;
- provenance joins real Git landing/report/task receipts; missing worker edges
  explicitly unavailable, missing causal edges refuse; coalesced runs stay truthful;
- ordered per-test receipts yield exactly 20 only after 20 eligible normal-load
  passes; red/incomplete/load gap breaks streak, duplicates cannot inflate it;
- targeted green never advances full-green/qualification; notifications failing
  cannot duplicate publication. Use a controlled reviewer boundary, and a real
  independent ACCEPT for the implementation/test edits themselves.

Preserve the first failing test run against current code (missing/refused publication
or unsupported single-parent proof), then the passing run and exact counts. Do not
reinterpret existing local-revert tests as auto-publication proof. Add only binding
validation and publication/recovery transitions missing from the existing owner;
justify each production addition by one acceptance failure. Remove replaced
merge-only, registry-qualification and blanket source-revert prohibitions atomically
across `scripts/tron`, verify/work READMEs, charter and work skill; retain every
production/irreversible boundary. #2176 coordinates shared-file ownership. This
design adds no runtime lines, changes no tests and authorizes no current deployment.
