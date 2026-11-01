# Causal source auto-revert

Design for #2194 under #2173; **not implemented or enabled** by this document.
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

## Minimal first implementation

Start hardware-free in the existing `batch.py` attribution owner and
`scripts/test-tron-verify-batch.py` real-Git fixture. Support one deterministic
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
