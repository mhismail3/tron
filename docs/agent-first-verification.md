# Agent-first verification and parallel integration

Status: measured design, not an executable policy or new landing requirement.
Research: #1255; accepted documentation slice: #1256; snapshot fix: #1258. Baseline: #1253 removal
through `894427767`, inspected at `b2d998567` on 2026-10-17. The current
[worker workflow](../tools/work/README.md) remains authoritative. Nothing in this
design registers a gate, queue, hosted check, receipt, post-merge job or revert.
The maintainer subsequently selected three **observational, nonblocking** pilots:
#1259 (shadow selection), #1260 (bounded owner alerts), and #1262 (offline merges
and simulator timing). Their protocol and results are recorded below; selection
for measurement is not authorization to make any pilot a landing requirement.

## Decision

Optimize **time to a demonstrated requested outcome**, not time to a green badge.
The worker selects direct checks at the changed behavior's real boundary, inspects
what a concurrent integration changed, and pushes without force. Evidence is a
short claim with a reproducible observation, not permission issued by a service.
Git arbitrates ref updates; the worker owns semantic integration. Home should not
have to assign merge turns, retry rejected pushes, or reconcile routine conflicts.

Keep the existing Git/rerere and per-worktree resource owners. Do not resurrect
removed machinery just because it could automate a step. A new mechanism earns
its place only if matched measurements show saved end-to-end worker time beyond
noise, with independently checked correctness, false positives and missed cases.
The initial implementation was a small ownership correction to the existing
optional landing helper: fetch a worktree-private snapshot instead of contending
on the shared tracking ref. The follow-up pilots below measure additional ideas
without adding checks, retry orchestrators or services to landing.

## 1. Evidence and measurement boundaries

Private reproducible research is retained under
`~/.tron/workspace/files/agent-checks/`; the original snapshots remain under
`~/.tron/workspace/files/strip-gates/`. These are research artifacts, not inputs to
builds or landing. Reproduce the normalized history and iOS aggregates with:

```bash
python3 ~/.tron/workspace/files/agent-checks/analyze-flow.py
python3 ~/.tron/workspace/files/agent-checks/analyze-ios.py
```

The first reads the frozen original snapshots; the second reads retained local
Xcode run evidence. The JSON outputs retain input hashes/process hashes and
population counts. Local Xcode retention can change the latter population.
Percentiles here use nearest rank. Summed concurrent step/queue seconds are
**worker-stage cost**, never elapsed calendar time or causal savings.

### Historical costs

The gate metric snapshot contains 3,142 rows: 2,956 pass, 118 fail, 20 timeout,
48 cancelled. Execution sums to 222,731.5 s (61.87 h). Queue fields survive on
1,976 rows: 66,711.3 s (18.53 h). Runs include 205 work summaries and 80 benchmark
summaries (20,425.6 s); metric rows cannot be joined losslessly to those purposes.
Dropping just the ten `before:` rows does **not** produce a clean worker sample.
The appendix therefore reports all rows, explicitly mixed. An affected-shard
median of 115.2 s versus full-shard 82.8 s is not a matched selector comparison.

| Removed coordination | Observations | Recorded cost | What it proves |
| --- | ---: | ---: | --- |
| Heavy admission | 1,011 acquisitions | 70,825.5 s queued; median 0.7, p90 220.4, max 1,270.3 s | Waiting, not defects prevented; overlaps gate queue fields |
| Direct-command heavy admission subset | 171 acquisitions | 40,792.2 s queued; median 101.7, p90 635.4 s | Even direct validation paid for the shared queue |
| Landing turn | 34 timed turns | 28,569.6 s waited; median 0, p90 3,243.6, max 6,159.3 s | A serialized turn can dominate a short change |
| Landing verification | 59 results, 52 true / 7 false | 74,115.4 s execution | Not a queue total or seven proven product bugs |
| Post-merge checker | 16 starts, 14 passes, one stop/revert, one unresolved | Completed pass intervals about 6,055 s | One observed automatic blame/revert was wrong |
| Hosted CI | bounded last 100: 56 success / 44 failure | start-to-last-update median 157.5 s, p90 200 s | Approximate lifecycle interval, not isolated execution time; 44% is not defect precision |

Do not add overlapping heavy/gate waiting, or add concurrency sums and call the
result calendar time. Historical land events show three merge conflicts across
65 starts (4.6% observed starts), not a current conflict probability. No confirmed
push rejection is identifiable in those failed rows: a heuristic that searches
for “push” mislabels “privacy guard refused … nothing was pushed” as a push race.
Git history preserves accepted commits, **not rejected pushes or edit-starts**.
A production rejection rate or historical edit-to-push distribution cannot be
reconstructed from commit timestamps. Controlled measurements below fill only
the explicitly stated synthetic workload, not that missing production denominator.

### What actually caught something

Define separately: failure frequency = failed invocations / all invocations;
precision = attributable real candidate defects / investigated failures;
sensitivity = known defects detected / known defects introduced. None is the
other. A timeout, assertion, or nonzero exit is not itself candidate attribution.

Only 47/186 non-pass metric rows carry a cause tag (36 setup, ten assertion,
one timeout); 139 have none. Only 662/2,983 referenced receipt logs survived.
For **every appendix check**, candidate-defect precision and sensitivity are
unidentified, not zero and not its failure percentage. Cause-tag coverage is
shown instead. No defensible per-check true-positive point estimate survives.

A separate audit of 60 failed invocation logs confirms one trivial candidate
whitespace defect; four invalid invocations, three stale-product protective
refusals, one busy exact-resource lease and one missing Gateway build are clearly
not runtime regressions. Fifty other failures remain unattributed, including
assertions/timeouts and failures in the checking machinery. Do not treat this
bounded, non-random surviving-log sample as a precision estimate for all checks.

| Check/mechanism | Positive or negative control actually supported | Disposition |
| --- | --- | --- |
| Whitespace | One surviving log identifies a new blank line at EOF in `connection-owner.ts`; three metric failures overall | Cheap diagnostic; not task acceptance |
| Gateway lint | #1175 documents seven duplicate-key/optional-chain findings; all six retained local lint metrics pass | Useful syntactic findings, not seven demonstrated user incidents; optional direct lint remains |
| iOS source policy | #1173's injected raw-sheet fixture is rejected; eight real metrics all pass | Known-bad synthetic control, not a new historical production catch |
| Non-hosted device compile | #1061 exposed `HostedClosedTerminal` escaping `HOSTED_TEST`, fixed in `238f52075` | Real configuration defect motivated the check; 74 later passing runs do not prove 74 catches |
| Automatic revert | `44ce65fe2` was blamed for missing fixture `dist`/`MODULE_NOT_FOUND`; restoration in `1f612970f` documents the environment error (#1211/#1213) | Confirmed false attribution; no automatic revert |
| Hosted reporter/paths | Sampled logs and #1253 analysis show reporter-output assertions and missing documentation anchors | Split harness failures from genuine documentation defects; remaining failure set unknown |
| Gate/selector/queue tests | Surviving logs include cancellation-group assertions, selector-oracle failures and queue-order assertions | Some may expose real tooling defects; they do not establish product protection worth their machinery |

The one-step diagnostic that was missing is **command + exact candidate/base +
failing assertion/phase + original log** in the worker's result. Do not recreate
a shared failure ledger to obtain it. Preserve it with the command's existing
artifact owner and include the first causal error, not only the last timeout.

### Where iOS time goes

Read-only sample: 2,664 retained real run directories, excluding the `latest`
symlink; 1,057 build and 1,494 test process records. Builds: 897 exit zero,
160 nonzero; tests: 1,082 exit zero, 412 nonzero. These heterogeneous historical
runs are not matched cold/warm comparisons and nonzero does not mean product bug.

| Measured phase/population | n | median / p90 wall s | total s |
| --- | ---: | ---: | ---: |
| Build process, all exits | 1,057 | 28.861 / 212.992 | 76,262.061 |
| Successful builds with `SwiftCompile` in timing summary | 760 | 42.460 / 249.657 | 66,772.164 |
| Successful builds with no `SwiftCompile` in timing summary | 137 | 4.948 / 14.391 | 944.823 |
| Test process, all exits | 1,494 | 26.320 / 123.876 | 81,076.782 |
| Nonempty exit-zero tests paired to XCTest interval | 1,065 | 25.175 / 101.973 | 49,380.106 |
| XCTest interval, same pairs | 1,065 | 20.470 / 96.963 | 44,708.129 |
| Process time outside XCTest interval, same pairs | 1,065 | 3.504 / 7.711 | 4,671.977 |

Seventeen historical exit-zero test processes had zero tests. They are not valid
acceptance; today's runner already validates a nonempty passing summary. The
XCTest interval includes automation/framework activity, not just test-body CPU.
Across 897 successful build summaries, Swift compile task-seconds total
413,292.568 and module emission 31,894.638, versus linking 912.320 and signing
718.127. Tasks overlap, so these are attribution hints, not additive wall time.
The large build tail is associated with compilation; it is not evidence that
signing, a simulator pool or a merge queue is the bottleneck.

**Boot/sweep/provision and cleanup wall time are not recorded in process.json.**
The runner provisions before creating the run owner, starts process timing later,
and releases its simulator after process evidence. We cannot assign the residual
to boot or claim a warm-pool saving. No simulator was booted for this audit.
See the [existing lifecycle contract](../packages/ios-app/docs/development.md#simulator-lifecycle).

### Current direct checks and parallel Git experiments

Replay local Git experiments (no production remote mutation):

```bash
python3 ~/.tron/workspace/files/agent-checks/measure/measure_land.py
python3 ~/.tron/workspace/files/agent-checks/measure/paired_fetch.py
```

The first uses independent clones, local bare remotes, Git 2.50.1, isolated
HOME/TMPDIR, three rounds per concurrency shape. Checks independently inspect
accepted-head ancestry, final file content and preserved conflict candidates.
No hooks, network, GitHub policy or real arrival distribution is modeled. Round
time starts at the barrier, not at initial source edits/commits. Final linked
worktree experiments alternate baseline/candidate order for six eight-worker
staggered rounds; nonoverlap/overlap controls use three rounds per size.

| Distinct-file independent clones | Accepted / intended | Push attempts | Ref-race rejects / pushes | Round median / max s |
| --- | ---: | ---: | ---: | ---: |
| 2 simultaneous workers × 3 rounds | 6/6 | 9 | 3/9 (33.3%) | 0.179 / 0.199 |
| 4 simultaneous workers × 3 rounds | 12/12 | 30 | 18/30 (60.0%) | 0.407 / 0.433 |
| 8 simultaneous workers × 3 rounds | 24/24 | 108 | 84/108 (77.8%) | 1.251 / 2.058 |
| 8 workers, seeded 0–100 ms stagger × 3 | 24/24 | 95 | 71/95 (74.7%) | 1.373 / 1.533 |

These are deliberately adversarial arrival windows, **not production rejection
rates**. Identical-file nonoverlapping edits also all land at 2/4/8 workers.
Same-line edits correctly accept one winner per round and preserve 3/9/21
conflicting candidates over three rounds at 2/4/8 workers, rather than choosing
a winner's semantics for the losers. No accepted intended content is lost.
Remote CAS rejection can say “cannot lock ref … is at X but expected Y”; distinguish
that moved-ref result from an actual held lock. No global queue is needed.

**Separate clones hid a real linked-worktree problem.** Repeating with linked
worktrees found four fetch failures among 24 staggered eight-worker candidates,
because their fetches updated shared `origin/main`. A deterministic real-CLI
test with a sibling-owned tracking-ref lock failed before the fix and passed
after it; it verifies both writers' remote content, a private FETCH_HEAD path,
and preservation of the sibling's lock/tracking ref.

| Linked worktrees, eight staggered workers × six alternating rounds | Baseline shared tracking fetch | Final private snapshot fetch |
| --- | ---: | ---: |
| Intended workers accepted | 43/48 | 48/48 |
| Local fetch integration failures | 5/48 workers | 0/48 |
| Push attempts / ref-race rejects | 155 / 112 | 193 / 145 |
| Round median / max wall s | 0.904 / 1.043 | 1.143 / 1.416 |
| All accepted content/ancestry checks | pass | pass |
| Separate same-file controls at 2/4/8 | all nonoverlap content correct; conflicts preserved | same |

Baseline wall time stops early for failed workers, so the candidate's 0.239 s
higher median is **not a slowdown for the same completed outcome** or a throughput
speedup. The tradeoff observed is all 48 workers completing versus five stopping
for a local-ref ownership error. Across the complete paired controls, fetches
failed 5/382 before versus 0/415 after. The implementation retains the same three
Git operations per attempt: empty-refmap fetch, merge FETCH_HEAD, push. An initial
candidate resolved the SHA with another subprocess (516 lookups, median 15.5 ms);
that unnecessary lookup was removed before landing. The worker is the sole writer
within its own worktree; Git resolves that private FETCH_HEAD when merging.
Normal push arbitration/conflicts are unchanged; the helper still does not retry.

The measurement harness's bounded loop is experimental, not installed automation
or proof that semantic conflicts resolve automatically. Real CLI coverage runs
the actual helper, including conflict/race/dirty/dry-run preservation. The final
focused result and exact real-remote edit-to-push timing are attached to #1255's
closure/report. The previous #1253 real remote scratch measured 28.555 s edit-to-push
including a 3.390 s direct test and 2.613 s fetch/merge/push. That is one sample,
not a production distribution. Synthetic current edit→push without a pre-push
behavioral test is 0.109 s median (five samples); it is **not** a worker completion
time or a network timing claim.

Rerere's repeated-identical-conflict control (three repetitions × five conflicts)
needed manual content authoring 15/15 times disabled versus 3/15 enabled; twelve
recorded resolutions reapplied with independently correct final content. Merge
still returned a conflict status requiring review/add/commit. Existing rerere is
already enabled; no new global config or autostaging is required.

Current direct-command measurements: documentation policy 0.57/0.43/0.44 s;
agent policy 0.35/0.16 s; existing four-case real-Git landing suite about 3.8 s.
The full privacy scan correctly rejected an untracked research script containing
local paths; that task-owned script was moved outside the repo before final
validation. Committed-HEAD scan passed. Gateway lint/typecheck could not be timed:
dependencies are absent in this worktree and Oxlint is absent in the primary's
installed tree. No installs or cross-checkout dependency borrowing were done;
the “seconds” TS/lint figures above are historical, not freshly verified.

## 2. Worker checks: select a proof, not a ritual

The following is a proposed taxonomy and selection contract, **not newly wired
mandatory commands**. Existing privacy/security and resource ownership remain
in force; they are not landing verification services.

| Layer | When and why | Cost and measurement | Rejected alternative |
| --- | --- | --- | --- |
| Task behavioral acceptance | Before declaring the requested outcome complete; run the named real E2E, integration boundary only where necessary | Exact command/test count/result artifact; time the chosen journey, including setup; historical iOS journey median 72.6 s is a planning hint only | Passing unrelated suites, a screenshot alone, a reviewer saying “looks good”, or a list of edits |
| Affected regression tests | Before push, in the worker's own tree; protect changed contracts and adjacent consumers | Selection time + selected test wall + fallback share + known-bad recall; no skipped unknown edges | An import graph or coverage cache treated as a complete specification |
| Fast static diagnostics | Changed owning package: typecheck; narrow high-confidence lint; docs navigation for docs changes; shell syntax for scripts | Historical TS median 2.8 s/p90 14.4; lint 0.9/1.3 s; report current setup failures separately | Building/simulating everything for a prose edit; lint-port revival without precision evidence |
| Cross-configuration compile | Conditional compilation, plist/project, module, protocol or packaging changes: choose the real non-hosted/consumer build | Device compile historical median 124.1 s/p90 263.7; measure separately from hosted UI build | Requiring a device build for every worker or pretending HOSTED_TEST proves device compilation |
| Independent review | Contract/security/ownership/UI risk or brief explicitly asks; inspect patch and oracle independence | Reviewer elapsed and actionable findings, not another blanket pass | Mandatory reviewer authority on every trivial edit, or self-review presented as independent |
| Maintenance/diagnostics | Broad suites, dependency audit, performance studies, experimental lint, hosted checks if explicitly requested | Own bounded task and budget; neither delays an unrelated worker nor supplies a landing receipt | Full suites, benchmark runs, formatting churn or a remote badge as universal admission |

### Dependency map with fail-closed expansion

The map's unit is an **owned behavior/contract**, not a filename-to-test guess.
Each entry needs source roots, transitive consumers, non-import inputs (files,
subprocesses, registration, generated code), executable test commands and a known
bad control. Begin with the conservative owner table below. It is the conservative production guidance, not a complete automated dependency map.
The private shadow-map pilot below is an experiment, not a production selector.

| Change owner/input | Starting selection | Broader fallback |
| --- | --- | --- |
| Gateway production TS with fully known import and resource edges | Named task boundary plus related integration/E2E files; include default/nested/Mac-terminal owners as applicable | Owning Gateway default and nested suites; add scripts/Mac-terminal consumers if their contracts can be reached |
| Gateway setup/config/toolchain/dependency lock, protocol, shared test support, runtime registration, dynamic imports, fs resources or child entrypoints | Known global/consumer suites, not `related` alone | All potentially consuming Gateway passes/scripts and relevant iOS/Mac boundary journeys; unknown cross-package reach expands across packages |
| iOS feature source | Incremental UI-validation build, named native journey and shared component consumers | Relevant broader UI smoke/presentation journeys; all UI-validation journeys if ownership/consumer edges are unknown |
| iOS project/module/plist/conditional compile | Hosted build + non-hosted compile and real boundary if transport changes | All affected build configurations and consumer journeys; no inference from hosted-only success |
| Work/tooling scripts | Run the script end-to-end in disposable repos/process fixtures, including concurrent/failure paths | All real-boundary tooling tests that execute the shared helper; unknown dynamic callers expand to the tooling family |
| Documentation-only | Navigation/path policy, diff/privacy; verify documented commands used by the change | Relevant command's real boundary when instructions change behavior or selection; don't silently classify executable guidance as inert prose |
| Deleted/renamed/unmapped file, missing/ambiguous base, stale graph, unknown extension or empty related result for a production edit | Explain the unknown edge | Full consuming owner, or all plausible packages if owner cannot be established; never “no tests affected” |

Algorithm: diff using NUL-delimited paths with rename/delete awareness; evaluate
both old and new ownership; compute reverse dependency closure plus explicit
non-import edges; union the task's named acceptance and relevant changed tests.
Any missing input or unknown edge expands, never omits. An empty selection needs
an explicit non-executable-change explanation. A manually reviewed owner table
is safer now than a new cache claiming exhaustive dependency knowledge.

The pinned Gateway uses Vitest **5.0.3**. `related` is advisory: static imports do
not cover variable imports, filesystem reads, spawned scripts, or every separate
Vitest configuration. Do not enable newer `recordDependencies` from latest docs
(5.0.4+) or revive the retired #1110 observer; no false-negative/speed comparison
in this task justifies it. The selected follow-up pilot runs only in shadow alongside broader runs on the
*same* candidates, with seeded resource, dynamic, child-process, deletion and
global-config defects. Retain only with zero missed
known-bad controls, measured selection cost below saved execution, and a bounded
maintenance owner. The broad run is the measurement oracle, not a new gate.

## 3. Acceptance evidence belongs to the task

A brief should name observable success before implementation:

> Given [real initial state], when [user/domain action], observe [requested
> result and preserved invariant], including [failure/cancellation edge].
> Command: [existing journey or the regression to extend]. Artifact: [runner's
> stable result/log path]. Known bad: [original bug or counterexample].

The worker's final result is compact: requirement → observation/test → artifact,
base/head, actual command/result/nonempty count, and unresolved scope. Preserve
red-before-fix evidence for bugs and a known-good control. No summary file is
required by landing, and no new receipt authority validates this statement.
For UI, drive the actual interaction and shared presentation owner, including
identity, keyboard/focus, scroll, accessibility and error behavior when relevant;
show useful screenshots as visual evidence, not substitutes for the interaction.
Simulator, fixture, installed and physical-device evidence must be labeled.

Completion means the outcome was observed, the changed boundary was validated,
and residual uncertainty was returned. “I committed”, “all tools exited zero”,
coverage percentage, elapsed work or token spend are activity, not acceptance.
A tool/setup failure retains partial results and the first error; one diagnosed
rerun is different from rerunning until green. An unexecuted/empty/skipped
journey cannot prove the outcome.

## 4. Lockless parallel integration

One worker owns one branch/worktree; small coherent commits include code, tests
and owning docs. Publish checkpoints to that task branch. Claims describe issue,
contract and predicted paths before editing; they are advisory overlap signals,
not locks. Negotiate a shared owner change with its implementer instead of editing
another tree. Prefer a small shared-contract commit followed by independent
consumers over simultaneous rewrites. Preserve unpublished checkpoints and never
use the repository-wide stash.

Use the existing plain-Git protocol:

```bash
git config rerere.enabled true
git fetch origin
git rebase origin/main                 # or merge --no-edit origin/main
# Inspect integrated changes; run only invalidated relevant validation.
git push origin HEAD:main              # never force
```

A normal push accepts only a fast-forward. Competing candidates cannot silently
overwrite one another. On non-fast-forward rejection, the **same worker** fetches
and integrates again; unrelated workers continue. Authentication, network,
privacy and hook errors are not CAS races and must not be retried blindly.
Linked worktrees share remote-tracking refs: a fetch ref-lock race needs a fresh
read/retry of that exact fetch, not deleting locks, resetting another branch, or
introducing a global merge lock.

Record the last validated tree/base. For each integration, inspect the incoming
old-base → new-main changes **and the actual old-tested → integrated tree diff**,
including conflict resolutions. Intersect those with the task's dependency closure
and test infrastructure. Rerun invalidated acceptance/regressions and any changed
tests; retain unaffected observations as evidence, not as issued pass receipts.
Unknown dependency reach means broader runs. Merely recomputing the feature diff
against its new base misses a changed imported helper in main. A source-identical
rebase does not require all suites again; a clean textual merge does not prove
semantic independence.

Bound automatic worker retries (for example three attempts per tool invocation),
checkpoint on continued churn, then continue in the same task with the new tip.
This is not a wait for Home or an admission turn. For a true conflict, inspect both
intents in the worker's own tree, ask the other owner only for a genuine contract
ambiguity, resolve, inspect reused hunks, rerun the affected behavioral oracle,
then push normally. Never auto-choose ours/theirs or stage/push a rerere resolution
without reviewing it. Keep `rerere.autoupdate` off unless deliberately chosen;
recorded textual resolutions are not correctness proofs.

`work land` enables rerere and performs fetch/merge/push with no tests or
retries. The measured #1258 correction uses an empty-refmap fetch into Git's
worktree-private FETCH_HEAD, then merges that snapshot, rather than updating or
reading the shared remote-tracking ref during integration. It deliberately
returns conflicts/rejections to the owning worker. A new
blind retry helper would save a command invocation while risking an untested
cross-file integration; it is not selected. The agent can execute the bounded
loop above without a human shepherd. A future helper must expose invalidation
and stop at uncertain semantic integration, not become a second check service.

Mergiraf is a potential conflict reducer, not a checker. It is not installed or
registered here. Supported-language/parse/ordering assumptions still need semantic
validation. Pilot only on a representative saved conflict corpus with independent
final-content/behavior oracles, comparing conflict rate, resolution time and wrong
clean merges. The offline follow-up evaluation below does not register a merge driver;
its content-oracle and manual-work limits remain part of the adoption decision.

### Separation of concerns

| Concern | Authority and handoff | Must not do |
| --- | --- | --- |
| Implementer | Own intent, patch, task acceptance and adjacent regressions; resolve integration conflicts in its own tree | Delegate responsibility to a green badge; edit another worker's tree |
| Reviewer | Independently challenge outcome/oracle/contract; report concrete defects and uncertainty | Become a serialized landing permission owner; silently change the patch it reviewed |
| Landing | Git performs ref arbitration; worker integrates and reevaluates invalidated evidence | Queue workers, rerun everything, force-push main or auto-revert |
| Contract owner | Clarify actual semantic disagreements with affected implementers | Serialize unrelated edits just because paths overlap |
| Home | Dispatch bounded tasks and surface genuine decisions | Assign merge turns or repeatedly retry routine worker pushes |

The roles can be phases of one worker for a small change; when independence is
requested or justified by risk, use a fresh-context reviewer with a read-only
handoff. Separate concerns do not require three permanent agents/services.

## 5. After merge and resource sharing

No post-merge service exists or is added. Proposed cheap non-blocking diagnostics,
if the maintainer opts in: a fetched-main static/type/doc pass for the changed
owner, isolated from live sessions, with a result sent to the originating worker's
issue/session. An alert names main SHA, exact command, first error, original
artifact and owner; report unknown ownership rather than blaming the latest
committer. Coalesce obsolete tips for disposable diagnostics, never accepted
domain work. Do not require the worker to stay alive for an alert, a green badge
before reporting, or a main receipt before future builds. Notification failure
cannot affect landing. No automatic revert, broad iOS run or hosted CI by default.

The finite owner-alert pilot below measured this without installing a service.
It found no confirmed distinct real catch and dropped ongoing alerts. The
historical false revert remains evidence against automatic blame or rollback;
a passing diagnostic does not establish incremental value.

Resource policy uses **exclusive ownership only where the resource is exclusive**:

- Keep current per-worktree simulator lanes and one simulator job per worktree;
  different lanes run concurrently. Exact simulator/device leases prevent two
  writers to that device, not general CPU admission. Busy is an explicit resource
  result, not a global wait queue. Command owners join children and release on all
  exits; only their owning tools sweep or clean resources.
- Keep source-identified worktree-local Xcode products/DerivedData. A shared mutable
  products directory risks source/compile-flag corruption. Read-only toolchain and
  dependency artifacts keyed by actual inputs are useful; existing compiler-cache
  seeding is not evidence for reviving shared test-pass receipts or warm machinery.
- Batch adjacent UI selectors into one existing build/test invocation; reuse valid
  products without building for every journey. `--keep-booted` is an explicit tight
  loop option with owned cleanup, not a permanent pool. Current data cannot price
  its boot saving. Never erase app/Keychain data to make a run pass.
- Observe swap, live owner/PID, per-run peak resource use and failures. Stop only
  resources owned by this task. Do not add a memory/CPU gate because historical
  waiting exists; first measure contention-caused failures in controlled test
  processes, not by loading the whole Mac.

A warm simulator pool/shared build cache is rejected for now: its avoided setup
cost, correctness across source/toolchain identities, idle memory, cleanup and
cross-worker interference have not been measured. Existing lane ownership is a
pool of independent resources without a central scheduler. Measure any candidate
against it, not against an invented serial baseline.

## 6. Dispositions and retained constraints

The maintainer selected the three bounded measurements below; Home authorized
adopt/drop decisions from their data without waiting for further input. None is
a landing prerequisite or authorization to restore blocking machinery.

| Decision | Options and recommendation | Evidence and experiment/cost needed |
| --- | --- | --- |
| New blocking checks or a global queue | Keep absent (recommended); or explicitly authorize a scoped experiment, not blanket restoration | Heavy waiting 19.67 worker-hours; landing turns 7.94; no attributable catch rate justifies restoring either |
| Automated affected selector | Drop automated selection; keep manual conservative owner selection | Initial map missed 3/3 dynamic/fs/child controls; corrected fallback selects all and saves no test execution |
| Post-merge owner alerts | Drop ongoing runtime after the bounded pilot | Zero distinct real catches in the replay; all seeded findings duplicated pre-push checks; never revert |
| Syntax-aware merge driver | Drop Mergiraf adoption; keep Git + rerere | 16 fewer unresolved content files but two inspected bad clean Swift outputs where Git was exact; no merge config/attributes change |
| Warm simulator pool/shared cache | Drop new reuse/pool machinery; keep existing independent lanes/products | Phase measurements held for host load; no separate boot/provision/cleanup or valid matched warm-saving estimate |
| Parked lint/caching work | Leave #1176 (`997ba5d98`), #1225 and #1228 parked (recommended) | Optional lint was subsecond historically; no precision/latency evidence requires reviving the port or deleted admission/receipt architecture |

Use a small value model rather than ceremony: measured defects avoided and useful
diagnostic latency versus invocation time, false-failure investigation, queueing,
maintenance and context-switch costs. Price only attributable incremental catches;
separate known-bad synthetic controls, real candidate defects and unknowns.
Missing data is a reason to narrow a claim or propose an experiment, not a reason
to install another orchestrator.

## Appendix: every retained metric check

Grouped shard/bracket suffixes; named experimental rows are retained, not
mistaken for worker savings. Execution/queued sums are stage-seconds. A zero
queue count means missing data, not measured zero waiting. “Cause-tagged” is
coverage, **not true-positive precision**; precision/sensitivity are unknown for
every row for the attribution reasons above. Failure percentages exclude timeout
and cancellation; those counts remain visible separately.

| Check | n | fail / timeout / cancel | fail % | median / p90 s | execution sum s | queued sum s (n) | cause-tagged nonpass |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| ios.journeys | 887 | 12 / 0 / 3 | 1.35 | 72.6 / 146.1 | 79,724.5 | 36,855.0 (677) | 5/15 |
| tooling.tests | 379 | 32 / 3 / 8 | 8.44 | 30.0 / 181.3 | 24,301.3 | 0.0 (272) | 21/43 |
| gateway.nested | 190 | 7 / 4 / 5 | 3.68 | 111.8 / 203.7 | 23,590.0 | 299.7 (101) | 1/16 |
| gateway.full | 178 | 20 / 3 / 10 | 11.24 | 82.8 / 193.2 | 17,730.4 | 1,752.5 (71) | 1/33 |
| ios.build | 175 | 11 / 0 / 6 | 6.29 | 42.6 / 276.1 | 16,396.3 | 8,873.0 (101) | 9/17 |
| gateway.affected | 112 | 11 / 1 / 5 | 9.82 | 115.2 / 190.7 | 11,766.6 | 2,836.9 (72) | 4/17 |
| journey | 121 | 6 / 2 / 1 | 4.96 | 65.4 / 209.0 | 10,394.4 | 2,269.1 (36) | 2/9 |
| ios.gateway-boundary | 66 | 2 / 0 / 1 | 3.03 | 130.1 / 253.4 | 10,192.8 | 497.0 (29) | 1/3 |
| gateway.scripts | 78 | 4 / 5 / 5 | 5.13 | 89.0 / 335.5 | 10,005.2 | 5,534.8 (43) | 0/14 |
| ios.device-compile | 74 | 0 / 0 / 0 | 0.00 | 124.1 / 263.7 | 9,568.2 | 429.7 (44) | 0/0 |
| mac.test | 9 | 1 / 0 / 0 | 11.11 | 143.9 / 212.2 | 1,433.8 | 0.0 (0) | 0/1 |
| mac.build | 7 | 0 / 0 / 0 | 0.00 | 93.2 / 281.6 | 971.2 | 0.0 (0) | 0/0 |
| gateway.full-nested | 4 | 0 / 1 / 0 | 0.00 | 176.8 / 386.6 | 779.6 | 0.0 (0) | 0/1 |
| ios.journeys-TronHomeSheetsUITests | 1 | 0 / 0 / 0 | 0.00 | 643.7 / 643.7 | 643.7 | 0.0 (0) | 0/0 |
| before:gateway.vitest-nested-verbose | 1 | 1 / 0 / 0 | 100.00 | 620.4 / 620.4 | 620.4 | 0.0 (0) | 0/1 |
| gateway.payload | 6 | 1 / 1 / 0 | 16.67 | 22.4 / 421.1 | 525.8 | 146.8 (4) | 1/2 |
| mac.replace-e2e | 8 | 0 / 0 / 1 | 0.00 | 68.9 / 78.1 | 491.5 | 169.0 (4) | 0/1 |
| before:gateway.scripts | 1 | 0 / 0 / 0 | 0.00 | 473.5 / 473.5 | 473.5 | 0.0 (0) | 0/0 |
| before:gateway.vitest-nested | 1 | 0 / 0 / 0 | 0.00 | 472.7 / 472.7 | 472.7 | 0.0 (0) | 0/0 |
| gateway.typecheck | 84 | 5 / 0 / 0 | 5.95 | 2.8 / 14.4 | 449.0 | 0.0 (47) | 0/5 |
| repo.privacy | 239 | 0 / 0 / 0 | 0.00 | 1.3 / 3.0 | 413.6 | 0.0 (145) | 0/0 |
| ios.build-cold | 1 | 0 / 0 / 0 | 0.00 | 328.7 / 328.7 | 328.7 | 0.0 (0) | 0/0 |
| before:gateway.vitest-full | 1 | 0 / 0 / 0 | 0.00 | 260.1 / 260.1 | 260.1 | 0.0 (0) | 0/0 |
| gateway.deps | 80 | 0 / 0 / 2 | 0.00 | 0.3 / 3.5 | 139.5 | 4,462.0 (49) | 0/2 |
| ios.journeys-smoke | 1 | 0 / 0 / 0 | 0.00 | 138.1 / 138.1 | 138.1 | 0.0 (0) | 0/0 |
| gateway.integration | 1 | 0 / 0 / 0 | 0.00 | 134.5 / 134.5 | 134.5 | 0.7 (1) | 0/0 |
| ios.source-policy-test | 6 | 0 / 0 / 0 | 0.00 | 18.6 / 39.7 | 128.1 | 0.0 (6) | 0/0 |
| repo.rules.boundaries | 4 | 0 / 0 / 0 | 0.00 | 26.8 / 31.7 | 108.4 | 0.0 (4) | 0/0 |
| mac.build-cold | 1 | 0 / 0 / 0 | 0.00 | 89.0 / 89.0 | 89.0 | 0.0 (0) | 0/0 |
| repo.rules.gate | 3 | 0 / 0 / 0 | 0.00 | 23.9 / 39.9 | 80.6 | 0.0 (3) | 0/0 |
| gateway.pi-sdk-rollback | 4 | 0 / 0 / 0 | 0.00 | 12.6 / 28.1 | 59.5 | 0.7 (1) | 0/0 |
| repo.whitespace | 239 | 3 / 0 / 0 | 1.26 | 0.1 / 0.4 | 45.3 | 0.0 (145) | 1/3 |
| ios.build-warm | 1 | 0 / 0 / 0 | 0.00 | 35.2 / 35.2 | 35.2 | 0.0 (0) | 0/0 |
| mac.build-warm | 1 | 0 / 0 / 0 | 0.00 | 31.0 / 31.0 | 31.0 | 0.0 (0) | 0/0 |
| before:gateway.payload | 1 | 0 / 0 / 0 | 0.00 | 28.1 / 28.1 | 28.1 | 0.0 (0) | 0/0 |
| repo.syntax | 109 | 0 / 0 / 0 | 0.00 | 0.2 / 0.4 | 24.0 | 0.0 (70) | 0/0 |
| ios.source-policy | 8 | 0 / 0 / 0 | 0.00 | 1.8 / 5.4 | 19.6 | 0.0 (8) | 0/0 |
| gateway.build | 4 | 0 / 0 / 0 | 0.00 | 5.0 / 5.9 | 19.5 | 219.8 (3) | 0/0 |
| repo.agent-policy | 28 | 0 / 0 / 0 | 0.00 | 0.5 / 1.6 | 19.0 | 0.0 (21) | 0/0 |
| repo.rules | 4 | 0 / 0 / 0 | 0.00 | 5.1 / 5.3 | 18.6 | 0.0 (4) | 0/0 |
| ios.journeys-TronSmokeUITests | 1 | 1 / 0 / 0 | 100.00 | 14.8 / 14.8 | 14.8 | 0.0 (0) | 0/1 |
| gateway.coverage-observer | 6 | 1 / 0 / 1 | 16.67 | 2.2 / 5.6 | 14.3 | 2,364.0 (6) | 1/2 |
| relay.check | 1 | 0 / 0 / 0 | 0.00 | 13.1 / 13.1 | 13.1 | 0.6 (1) | 0/0 |
| before:gateway.typecheck-warm | 1 | 0 / 0 / 0 | 0.00 | 9.3 / 9.3 | 9.3 | 0.0 (0) | 0/0 |
| before:gateway.typecheck | 1 | 0 / 0 / 0 | 0.00 | 8.9 / 8.9 | 8.9 | 0.0 (0) | 0/0 |
| before:relay.check | 1 | 0 / 0 / 0 | 0.00 | 6.1 / 6.1 | 6.1 | 0.0 (0) | 0/0 |
| gateway.lint | 6 | 0 / 0 / 0 | 0.00 | 0.9 / 1.3 | 5.1 | 0.0 (6) | 0/0 |
| before:gateway.npm-ci-cold | 1 | 0 / 0 / 0 | 0.00 | 2.9 / 2.9 | 2.9 | 0.0 (0) | 0/0 |
| before:gateway.npm-ci-warm | 1 | 0 / 0 / 0 | 0.00 | 2.6 / 2.6 | 2.6 | 0.0 (0) | 0/0 |
| repo.policy | 2 | 0 / 0 / 0 | 0.00 | 1.3 / 1.3 | 2.6 | 0.0 (1) | 0/0 |
| protocol.contract | 2 | 0 / 0 / 0 | 0.00 | 0.2 / 0.2 | 0.4 | 0.0 (1) | 0/0 |
| gateway.deps-check-warm | 1 | 0 / 0 / 0 | 0.00 | 0.1 / 0.1 | 0.1 | 0.0 (0) | 0/0 |


## Implementation and repeatable validation

The initial #1255 implementation changed only `tools/work/land.py`, its real-Git
CLI journey, this design and its owning workflow documentation. Follow-up pilot
findings update this design while keeping rejected experiment code/data private.
No agent-policy file, production app/runtime, installed dependency, parked branch,
or another worker's source is modified.

```bash
scripts/tron test tooling scripts/test-work-land.py
python3 scripts/check-documentation-policy.py
scripts/personal-info-guard.sh
git diff --check
```

The landing suite has five real-boundary journeys: independent integration,
conflict preservation, dirty/dry-run behavior, sibling tracking-ref ownership,
and remote push CAS refusal without retry/force. The new ownership case is
recorded red before the fix; all five pass afterward. Timings and logs are
research evidence, never required receipts. Final integration reruns the affected
CLI suite and documentation/privacy checks; unrelated concurrent Gateway changes
do not justify rerunning a Gateway suite for this helper/documentation change.

## Follow-up observational pilots (#1259, #1260, #1262)

These experiments never select what a worker must run, delay a push, admit work,
retry commands, install a merge driver, revert main, or register hosted CI. Their
private reproducible evidence lives beside the original research under
`~/.tron/workspace/files/agent-checks/pilots/`. Production and parked work remain
unchanged. The finite pilot owns its scratch processes and cleans them up; no
background diagnostic survives the task.

Before results, the questions and stop rules were fixed:

- **Shadow selector:** compute conservative old/new dependency ownership and
  expand unknown dynamic, filesystem, child-process and cross-package edges.
  Replay recent committed candidates and compare selected versus broader runs,
  including known-bad controls. Count seeded and real misses separately. Zero
  misses is necessary, not sufficient: full fallback has perfect recall without
  saving time. Matched execution cost must include map overhead.
- **Owner alerts:** explicitly invoke a cheap one-shot committed-byte diagnostic
  after observed pushes, not from a hook or service. Record original error, exact
  base/head, author hint, local owner log, latency and prior-check overlap. An
  author hint is not integration blame. Retain ongoing alerts only with a
  confirmed distinct real catch and positive incremental value; otherwise drop
  the runtime, preserving only private measurement/reproduction evidence.
- **Offline merge and timing:** reconstruct real historical merge conflicts and
  rerere cases in isolated Git fixtures. Compare exact resolved content and
  inspect differing clean output rather than equating no markers with correctness.
  Measure provisioning/boot, build/test and release through existing per-worktree
  simulator ownership. Separate matched measurements, upper-bound estimates and
  unavailable phases. No shared simulator pool, merge configuration or queue.

### Bounded owner-alert result (#1260)

The private one-shot research diagnostic checked committed diffs for whitespace,
compiled changed Python bytes without executing them, and ran `bash -n` on
changed shell bytes. It was explicitly invoked after pushes, never wired to a
hook, a worker, or landing. It writes a local owner log; author identity is only
an attribution hint. Renames use the new committed path; deletions have no bytes
to compile. Other languages and semantic integration defects are out of scope.

Replay of 30 recent first-parent main commits ending at `1edda295b` produced
**zero alerts**, costing 8.802 s in total (median 0.236 s per commit). Thus real
precision and real false-alarm rate are **unidentified**, not 100% precision.
There were zero demonstrated distinct real incremental catches. Prior worker
checks for this historical population are unknown; no overlap is invented.

Four actual pushes to a local bare main supplied a clean control plus whitespace,
Python-syntax and shell-syntax defects: **3/3 bad candidates detected**, no alert
on the clean control, and the accepted remote heads remained unchanged. Workers
ran the same diagnostic before each push: all post-push findings duplicated those
known pre-push findings, adding 0.351 s versus the worker's 0.427 s. Repeating the
same tips added another 0.479 s and no distinct catch. Local push-return to
finished-diagnostic latency was 0.059–0.114 s; this excludes human reaction and
network notification delivery and is not production latency. Raw per-command
results are in `alerts/history.json`, `alerts/seeded.json`, and
`alerts/summary.json` within the private pilot evidence directory.

The first real main checkpoint (`b59ed791d`) also received an explicit post-push
local diagnostic: no alert, 0.235 s execution and 8.877 s push-return to diagnostic
observation, including agent/tool dispatch. That single passing observation is
not evidence of a catch. **Drop ongoing owner alerts**: no real incremental value
was demonstrated. No diagnostic runtime, watcher, hook, hosted job or schedule
was added to the repository, so none survives; only private reproducer/data and
this outcome remain. A future bounded extension would need real attributable
integration defects and worker-check evidence, not more passing rechecks.

### Simulator timing result (#1262; measurements held)

Home stopped further simulator measurements because the shared Mac was slowing;
existing phase evidence was shared with resource-management issue #1263. The pilot
did not wait for another worker or add admission. It stopped its exact measurement
wrapper and test lease holder gracefully, verified idle lease/Shutdown state,
retained the run artifacts, then used the owning helper's `clean` command to
remove its simulator, products and original run directories. No other worker's
process or lane was touched.

One source-identified helper build completed: **740.627 s outer wall**, versus
**673.431 s** in its build-process evidence, exit zero. The **67.196 s residual**
includes provisioning/boot, sweep, project generation, cache seeding, metadata,
release and other wrapper work; these phases were **not separately timed**.
Concurrent worker builds and the runner's existing compiler-cache seeding prevent
calling this an isolated cold-build benchmark. The following smoke run reached
XCTest but was deliberately interrupted (exit −15, 43.906 s process interval),
with no passing summary. It is excluded from successful-test timings.

There is **no matched cold/warm or nonempty passing test sample**, no separate
boot/provision/cleanup measurement, and therefore no defensible numerical reuse
saving. The build residual is at most a loose ceiling on all non-build work in
that one invocation, not an expected saving. Swap was 831.19 MiB before/after;
reported system free memory was 72%/69%. Those snapshots do not isolate a causal
contention effect.

**Drop the external measurement wrapper and do not adopt a warm/reused simulator
change.** Keep the existing per-worktree owner and explicit tight-loop option;
no new pool, queue or runtime instrumentation was added. The rejected wrapper is
retained privately only for audit/reproduction, not registered or shipped.
Complete phase measurement remains unproved rather than silently marked done.
Raw logs, `run-1/report.json`, retained original process/metadata artifacts under
`timing/retained-runs/`, `timing/home-hold-cleanup.json`, and final owner cleanup
logs live in the private pilot evidence directory. No tool/app installer,
Gateway restart, deployment or Stable change was performed.

### Offline merge result (#1262)

The corpus freezes 265 real two-parent merges through `1edda295b`; 129 have
content decisions, including **525 both-content paths** and 13 modify/delete
paths. Git arms replay real merges in an isolated clone with explicit diff3 and
rerere settings. Mergiraf **0.20.0** runs from a scratch release binary per
base/left/right path; it is not registered as a driver. The historical resolved
content is an independent byte-level oracle **proxy**, not proof that every
historical resolution was semantically correct.

| Same 525 content decisions | Clean exact to historical resolution | Clean different | Unresolved content files |
| --- | ---: | ---: | ---: |
| Git, rerere disabled | 357 | 20 | 148 |
| Git + rerere, initially empty cache | 357 | 20 | 148 |
| Git + rerere, existing-cache replay | 357 | 20 | 148 |
| Mergiraf, per-path emulation | 362 | 31 | 132 |

Mergiraf leaves 16 fewer unresolved content files (10.8%), but increases differing
clean outputs by 11. **Different is not automatically wrong**: some historical
merge commits contain intentional extra edits absent from either parent. Manual
inspection does find two concrete bad clean results where Git was exact, both in
`e596f0b4`: a duplicate `showLocalErrorDetail` declaration in
`SheetCoordinator.swift`, and a duplicate `.localErrorDetail` switch arm in
`ChatSheetContent.swift`. Their original/oracle/Mergiraf bytes and diffs are
retained. These are inspected text-level defects, not a claimed Swift build run.

Of 363 syntax-supported paths, unresolved files fall from 128 to 113; among 162
unsupported fallback paths, from 20 to 19. **Swift is unsupported** by this
version. Whole-merge outcomes are not comparable: the Mergiraf arm lacks Git's
index/rename context and handles modify/delete outside the content driver.
It does not establish a full successful-merge rate.

Initially empty rerere reused one recorded resolution exactly. The optimistic
existing-cache arm reapplied 84 resolutions: 82 exact and two different (one
trailing blank line, one stale benchmark value). Its cache includes future
resolutions relative to historical commits, so 84 is **not** a historical causal
saving. Rerere leaves the index unmerged for review/add; an automatic textual
reuse is not a correctness receipt. On the same content paths, conflict-marker
hunks were 263 without rerere, 262 initially empty, 107 seeded, and 231 with
Mergiraf. These are mechanical editing proxies, **not human resolution time**.
One-time summed arm execution was 105.856/108.572/134.601/239.876 s respectively,
in fixed order on a contended host; it is neither CPU time nor a matched
human-productivity comparison. No manual-time saving is invented.

**Drop Mergiraf adoption; keep existing Git + rerere and inspect reused hunks.**
No repository merge configuration or attributes changed. The scratch binary,
archive and 1.8 GiB clone were deleted. Reproducer code stays private rather
than shipping a one-off evaluator to main. Raw corpus, arm JSONL, corrected
summary, inspected diffs, provenance and hashes are under
`corpus/{runs,inspect,reproducer}/` in the private pilot directory. The release
archive SHA256 is
`641b8a0c379d56b8b4b61070e60c3dac6e1a2fba5b59edd374a9e795b992ee5b`.
The original seeded cache was hashed; an additional after-run cache snapshot is
retained for reuse but is not independently proven byte-identical to that seed.

### Shadow-selector result (#1259)

The initial read-only prototype extracted imports and literal/resource references
from both Git trees, expanded reverse references, and retained old/new paths for
renames/deletions. It was **not safe**: computed paths were approximated by
same-directory siblings. A changed target with a known static consumer could
therefore omit an unknown computed consumer in another directory. The pilot
never executed tests on a worker's behalf or supplied a landing decision.

Independent real-Git/process controls exposed **3/3 seeded misses (100%)**:
variable module loading, filesystem resource reads, and spawned child entrypoints.
In each disposable repository both baseline process journeys passed; after the
seed the statically known existence check still passed, while the omitted
computed consumer failed. These are realistic edge mechanisms in bounded
fixtures, not three historical production incidents. Original candidate bytes,
base/head IDs, process errors and the counterexample harness are retained.

The initial candidate did include the detector for **one replayed real defect**:
restoring pre-#1258 fetch behavior made the sibling tracking-ref regression fail
while the same test passed on the fixed base. That is **0/1 real replay misses**,
not a production miss-rate estimate. The actual broader tooling sweep had 15
executable entries and cost 430.01 s on the contended host; 11 selected entries
summed to 404.02 s, plus 6.677 s selector cost. Its tempting projected 19.313 s
(4.5%) saving is **rejected**, because the same unsafe map missed all three seeded
edge defects. This is a sum-of-observed-suite-times projection, not an independent
selected-run speed comparison. The 15 entries are not the whole repository:
Gateway/default/nested and iOS/Mac consumer runs were not established by this
sweep, and unexecuted owners are reported rather than treated as passing.

The corrected candidate explicitly marks production owner closure as incomplete:
its static graph is advisory, **all consuming owners fall back broadly**, and
unexecuted owners remain unknown. Regex detection cannot prove completeness.
It passes **all three controls (0/3 seeded misses)** by selecting the full
two-entry fixture workload, costing 0.099–0.455 s with zero gross execution saving.
Replay over six recent real main commits plus an older rename-bearing commit
selected **15/15 executable tooling entries every time (100%)**. It retained
both sides of two renames and 43 deletion records across the two relevant
candidates. Final replay selector cost was median **7.679 s**, range **2.755–12.094 s**;
projected gross saving is zero and net saving is negative. On the real #1258
replay, reusing the observed broader-suite costs projects **8.966 s added**, not
saved.
No broad Gateway/iOS/Mac pass is implied by this small replay or its entry count.
Additional full-repository defect recall is unmeasured; zero misses in three
controls cannot justify adoption.

**Drop automated selection; retain manual conservative owner selection.** The
unsafe narrowing result is a useful failed experiment, not a partial production
selector. No map cache, automatic test runner or selection authority ships.
Private evidence is under `selector/`: `results/controls-real.json`,
`parent-review/counterexamples-initial.json`,
`corrected-review/counterexamples-corrected.json`, frozen scripts and replay data.
The first delegated run hit its 30-minute limit; its partial source was preserved,
no orphaned test process remained, and a bounded same-protocol continuation
finished the corrected observations. No failure was retried automatically by a
new runtime mechanism.

## Sources

- [Git push](https://git-scm.com/docs/git-push): fast-forward refusal and explicit
  lease semantics. Main landing uses no force/force-with-lease.
- [Git rerere](https://git-scm.com/docs/git-rerere): reuse of recorded resolutions;
  inspect the worktree/index rather than equating reuse with correctness.
- [Vitest related](https://vitest.dev/guide/cli#vitest-related): static dependency
  limitations. Check the pinned version before adopting latest features.
- [Vitest experimental](https://vitest.dev/config/experimental): newer dependency
  recording is not a complete dynamic/resource dependency specification.
- [Mergiraf conflict behavior](https://docs.rs/crate/mergiraf/latest/source/doc/src/conflicts.md)
  and [usage](https://docs.rs/crate/mergiraf/latest/source/doc/src/usage.md): syntax,
  parsing and ordering limits, not a local performance result.
- Repository owners: [testing/ownership](../AGENTS.md),
  [direct tooling/landing](../tools/work/README.md),
  [focused iOS testing](../packages/ios-app/docs/development.md#efficient-focused-tests),
  [Gateway](../packages/gateway/README.md).
