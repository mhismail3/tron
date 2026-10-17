# Work tooling

`scripts/tron work` coordinates parallel agents on Tron. Issues and the Tron Project
say who owns which work; branches and worktrees keep the edits apart; `land` merges
them. The tooling adds no review or hosted-check gate. The gate is a local [gate](#gate) run of
the exact commit being merged. Policy is in [AGENTS.md](../../AGENTS.md#work-tracking);
the agent procedure is the [tron-work skill](../../.agents/skills/tron-work/SKILL.md).
Repository settings (labels, Project fields, claim and cleanup rules, the gate
prelude and privacy guard) are in [`.github/work.json`](../../.github/work.json).

## Commands

| Command | Does |
| --- | --- |
| `start <issue> [--area PATH]... [--integration] [--base REMOTE-BRANCH]` | Claims an open, unclaimed issue: pushes a canonical claim commit to `claim.remote`, sets Status In progress, comments the claim, and creates its worktree under `../tron-worktrees/`. Ordinary start excludes epics; maintainer-approved epic integration uses `--integration`. `--base` selects a branch on the configured remote; its name is recorded as `Work-Claim-Base` and the claim commit's parent pins the exact starting commit. Without it the configured base is used. A session resumes its own claim from that immutable creation receipt, including after handoff or a base advance. Closed issues and open blockers remain refused. Never create manual ownerless epic/custom-base branches. This is not adoption: unknown/live claims must go through supported handoff. |
| `handoff <issue> --reason TEXT [--session ID] [--force-maintainer]` | Transfers an existing claim in place; preserves the registered worktree and dirty files. Automatic transfer requires authoritative terminal settlement evidence from `packages/gateway/dist/client/work-owner-status.js`; unknown `no-report` work is eligible only when the Gateway's `ownerSettlement` proof validates its canonical task marker, invocation start/terminal receipts, and successful subagent settlement for the same task, session, and operation (including a successful join with zero stops), or when the Gateway reconciled the task from its canonical file (`settlement-failed`, `cold-no-report`; see Owner status). The helper rechecks task identity, lifecycle, operation and proof before accepting. A terminal task with zero projected live runs is not independent settlement proof. This requires both a rebuilt helper and a Gateway running the updated Home status projection; an older Gateway omits the proof and therefore fails closed. Prepare the helper with `scripts/tron-node exec npm --prefix packages/gateway run build`. The helper defaults `TRON_GATEWAY_HOST` to the local Tailscale address, matching terminal chat. Set `TRON_GATEWAY_HOST=127.0.0.1` when querying a loopback-bound development Gateway, or set it to a literal IP assigned to this Mac; it refuses other hosts before reading the local credential or opening a socket. Maintainer override requires a real TTY and exact typed confirmation. A legacy claim with no owner is `unknown`, never automatically transferable; this includes both a claim commit with no owner trailer and an established claim-style remote branch with no claim commit or claim trailers at all. The branch name plus the matching registered worktree and exact local/remote head identify the existing claim; they do not invent an old session identity. A maintainer can recover it only with `--force-maintainer` and the exact prompt `HANDOFF #<issue> FROM unknown`. This records `unknown` as the prior owner; it does not invent an identity or liveness result. The public audit includes old/new owner, reason, and exact transition commit SHA. Local and remote claim heads must match exactly (except a verified partial handoff retry); an unpushed or divergent local head is refused even with force. Only a clean descendant candidate with a settled owner can use `recover` below before ordinary handoff. |
| `recover <issue> --expected-local SHA --expected-remote SHA --reason TEXT` | Publishes an exact clean descendant candidate as **unverified work**, without transferring ownership or changing local history. Requires the same known claim at both full commit IDs and canonical owner/children settlement; there is no force override. See [candidate recovery](#candidate-recovery). |
| `release <issue> --reason TEXT [--force-maintainer]` | Gives up a stale claim on an **open** issue: preserves the claim's work, deletes the remote claim branch with an exact lease, posts an audited comment, sets Status back to Ready and removes the worktree and local branch. The issue stays open and unclaimed. Refuses a live or indeterminate owner; an idle Gateway session or a legacy owner needs the maintainer's `--force-maintainer`. See [`release`](#release). |
| `release --stale [--dry-run]` | Sweeps every open-issue claim idle for more than 72 h and releases, through the same path, each one whose owner is `absent`. See [stale sweep](#stale-sweep). |
| `land --summary-file <md> [--title T] [--tests CMD]... [--ready] [--dry-run] [--repair-main]` | Checks the branch's own tree (the [gate](#gate) plan, or its [receipt](#landing)), pushes the branch, opens or updates its pull request (title = `--title` or the issue title; body = the summary file, verbatim) and, holding only the merge lock, squash-merges it at the checked commit if Git merges it cleanly onto the current base. It then starts the [post-merge check](#landing), deletes the remote branch and closes the issue as completed with Status Done. Refuses while landing is stopped; `--repair-main` lands a fix then. A draft pull request refuses before the merge unless `--ready`, which marks it ready for review only after the check and the exact-head publication, re-reads it, and merges nothing if it is still a draft. An issue with open sub-issues (an epic) is left open and `land` lists them: close each fulfilled child with `work issue close`, then the epic. Prints `merged: <commit>`. |
| `land --status` | The post-merge check of main: whether landing is open, the last main that passed, the merges checked now and its current step (same as `scripts/tron gate status`). |
| `land --publish-only --summary-file <md> [--tests CMD]...` | Runs the same branch check, pushes and opens/updates the PR, but does not merge, close issues or delete the branch. Use when a task explicitly requires hosted evidence before landing; normal `land` remains the merge owner. Incompatible with `--dry-run` and `--ready`. |
| `status [--area PATH]... [--json]` | Requested Home work view: merges in flight, whether landing is open and the last main that passed, live heavy queue counts, the previous complete UTC day’s gate digest, and fresh claim-overlap advice. No scheduler, cache or admission authority. |
| `comment <issue> --body-file F` | Privacy-checks, then posts a public issue comment. |
| `issue create\|edit\|labels\|close\|reopen\|parent\|block` | Files issues and changes labels and links; see [filing](#filing). `edit <issue> [--title T] [--body-file F]` replaces a title or body (privacy-checked). `close` posts a comment, closes, and sets Status Done. Epics may close only when all linked children are closed (every page is checked before any write, for either close reason). `reopen <issue> --comment-file F` requires the reason as a non-empty, privacy-checked comment, posts it with an audit marker, reopens, and sets Status In progress when the issue is claimed (claims are left as they are) or Ready otherwise; it refuses an open issue it did not reopen, and a re-run finishes a partial reopen without a second comment. `parent --replace-parent` moves a task from its current epic to another. |
| `project add\|set` | Adds an issue to the Project, or sets Status (Ready, Blocked) and Priority. |
| `auth setup` / `auth status` | The agents' GitHub token: the maintainer's one-time Terminal setup, or its login, scopes and expiry (never the token). See [GitHub access](#github-access). |
| `bootstrap [--apply [--prune]]` | Plans or converges labels and the Project fields to `.github/work.json`. Labels, custom Project fields and Status/Priority options on GitHub that the file does not declare are reported as `drift:` lines (exit 2). `--apply` adds and updates; `--apply --prune` also deletes drifted labels that no open issue carries, options no Project item uses, and undeclared custom fields with their values. Labels and options still in use stay reported until migrated. |

## Home work coordination

Declare predicted literal repo-relative path prefixes with `start --area tools/work --area scripts`.
The creation commit owns `Work-Claim-Areas`; resume and handoff preserve it. Public claim
metadata passes the configured privacy guard **before the remote push**, and the exact claim
comment is guarded before posting. To resume an old/unknown declaration, omit `--area`; it
never silently replaces the creation prediction. At most 16
prefixes are accepted; traversal, absolute paths and globs refuse before claiming. `.`
means the whole repository. Missing or damaged declarations are **unknown**, not disjoint.
Refined scope belongs in the issue/check-in rather than rewriting historical claim metadata.

`start` advises about equal or ancestor/descendant prefixes in other claims (not string-prefix
siblings such as `tools/workshop`). These are predictions, not locks or proof of worker liveness:
a parked claim still appears. Advice never blocks admission; unavailable remote evidence is
reported, not treated as no conflict. Before additional dispatch, Home can have an existing
worker run `work status --area <planned-prefix>` and pass its timestamped view in a check-in.
Home compares it with live task state and avoids overlapping **mutations**, not concurrent
research/thinking. Unknown scope needs inspection. The heavy queue and the post-merge check still admit work;
there is no new worker cap or scheduler.

`work status` composes existing owner reads (`work_status.py`), not another queue registry.
Land counts cover this repository; heavy counts cover this user on this host. Those owners
may prune ended tickets when read. A failed owner read returns null plus its error class;
other owners remain visible, and missing evidence is never displayed as an empty queue.
Fresh advice fetches remote-tracking refs and reads each claim history; the digest scans
ledger history. This is an on-demand worker command, not a cheap UI polling endpoint. The digest covers the previous complete UTC day and is
computed only on request: no timer, automatic wake or stored daily report. The report owner
uses inclusive boundaries, so the daily window ends one microsecond before the next midnight.
It uses the same default exclusions as `gate report`; apply explicit baseline exclusions when
making the separate historical comparison. For other windows,
use `gate report --since 3d --digest` (or `--json` for the full evidence). A worker can pass one
line on the next Home activation; an inactive Home does not wake merely to produce a digest.
This is a worker-supplied work snapshot, not the native Home host-pressure row.

## Filing

Every issue is filed with `issue create`; the repository has no GitHub issue templates.

- A task needs exactly one declared `kind:` label (`--kind`) and at least one declared
  `area:` label (`--area`, repeatable). An epic (`--type epic`) gets only the `epic`
  label. The type, kind and area are labels, so titles carry no `[Task]:`-style prefix;
  such a prefix is refused.
- The command adds the issue to the Project with Status Ready (or `--status Blocked`)
  and an optional `--priority`. All checks run before the first write; if the Project
  write fails after the issue exists, the error names the `project add`/`set` to finish.
- An issue that waits for the next failure or a recurrence needs an exit:
  `--exit-by YYYY-MM-DD` appends `Exit by: <date>. Close as not planned if it has not
  recurred by then.` A body that says it waits for a recurrence without one is refused.
  The dashboard lists open issues past their exit date.
- Status is Ready (open, claimable), In progress (claimed), Blocked (reason in the latest
  comment) or Done. Priority is optional.
- When partial progress lands or an audit finds some of the scope done, replace the body's
  remaining scope with `issue edit` instead of appending a comment, so the next reader
  does not re-derive it.

Every GitHub write goes through `scripts/tron work`, which appends it to a private,
bounded audit log at `<git common dir>/work/github-writes.jsonl` without its body.
Reads are plain `gh` reads.

Do not create manual ownerless epic/custom-base branches. Explicit `start --integration`
creates the canonical owner claim; `--base` records the exact configured-remote
branch, not a guessed `main`. This selects the starting tree, not a different merge
target: the gate and `land` still use the configured base (normally `main`).
Creation is not adoption: existing local-only branches refuse without publication,
and unknown/live remote claims still require supported `handoff`. Unknown-owner maintainer recovery requires a real
terminal and exact `HANDOFF #<issue> FROM unknown` confirmation. Before continuation
writes, verify old/new owner, pre/transition heads, unchanged tree, local/remote match,
public audit and normal `work start` admission. Durable receipts include issue, branch,
worktree, owner, head/tree, PR, exact test commands with actual pass/fail results and
the next slice; historical failed gates remain failed.

## Gate

Every change reaches `main` through one deterministic, gated pipeline (#1022).
[`gate-catalog.json`](gate-catalog.json) is its single source of truth: for each step
its id, trigger (paths, or a selector over the change), exact command, cache inputs,
time budget and hard timeout, resource class (`light` or `heavy`, with its expected
peak RSS), artifacts, pass criteria and the gate it unlocks. `scripts/tron gate`
(`gate.py`) is the only runner; agents run verification steps through it, never by
hand-copying their commands.

| Command | Does |
| --- | --- |
| `gate plan [--tests CMD]... [--json]` | Classifies the change (the worktree, dirty or committed, against its merge base with `origin/main`) and prints the ordered shards it needs, each marked `pending` or `reusable pass`. |
| `gate run [STEP...] [--tests CMD]... [--force]` | Runs the plan, or the named steps (with their planned prerequisites), in catalog order. |
| `gate next` | Runs only the next shard without a valid pass, then stops. |
| `gate submit [run args]` / `jobs` / `wait JOB` / `cancel JOB` | Hands a run (with any `gate run` arguments, such as `--tests CMD`, validated before it starts) to the background and returns at once, so the session keeps working; `jobs` shows each job's live state, heavy-queue position and last line; `wait` streams it and returns its result; `cancel` stops it and its running step. |
| `gate report [--json]` / `gate catalog` | Median and max wall time and peak RSS per shard from every recorded run; the catalog as a table. |
| `gate report --since T [--until T] [--exclude-worktree GLOB]... [--json]` | The [window digest](#report) for any time window (`T` is an ISO time or a span back from now: `90m`, `12h`, `3d`). |

**Hosted CI.** `ciSteps` in the catalog owns the four public `scripts/tron ci`
step names. Each delegates to `gate run --base HEAD --force <id>`, including its
transitive prerequisites in catalog order, so it also works in a shallow hosted
checkout. Failure annotations retain `Reproduce: scripts/tron ci <step>`; there
are no retries. Dedicated GitHub VMs bypass only the shared Mac heavy queue,
never the catalog's hosted-safety check. `gateway.integration` invokes
`vitest.hosted.config.ts`; that config alone owns the hosted test selection.
`gateway.full`, `gateway.affected` and `gateway.nested` remain local-only because
of the hosted timing failures documented in #1026. No local tests are removed.

**Pi and connection boundaries.** The graph comparator examines the merge base
and the candidate Git tree, including dirty edits, without installing packages.
An actual Pi family dependency-closure delta selects `gateway.pi-sdk-rollback`
and `ios.gateway-boundary[build,resilience,lan]`; unrelated lock churn does not.
The catalog also lists the connection/LAN and harness owners that select the
iOS boundary without rollback. These steps are local-only heavy work. The iOS
shards build once, run serially, and stop their private Gateway on exit. The
rollback matrix is networked and installs its historical SDK in a temporary
fixture; it is not a no-install check. The iOS shard budgets are 300 seconds,
with a 900-second hard bound for cold Xcode/fixture work; gate metrics expose
actual durations rather than claiming these new steps have been measured.

**Plans.** Plan order is catalog order, so the same change always gets the same
plan. Markdown never starts a build. Representative plans:

- docs only: `repo.privacy`, `repo.whitespace`;
- Gateway TypeScript: `gateway.deps` (verifies the install against the lock and
  repairs drift with `npm ci`, the #1011 guard) → `gateway.typecheck` → the related
  vitest files in 3 shards, two at a time (`gateway.affected`) → the nested-SDK pass in
  four named shards run one at a time, balanced by measured file time (`gateway.nested`; it has no
  affected-only form, and new nested files land in its `[rest]` shard);
- Gateway lockfile, package, vitest config, test support or `.node-version`: the
  whole default suite in 6 shards, two at a time (`gateway.full`, which supersedes
  `gateway.affected`) plus `gateway.scripts` (three named shards);
- iOS Swift: the light L0 `ios.source-policy` first (managed presentation,
  shared sheet loading, Foundation-only Core, orientation and bundled resources),
  then one `ios.build` (build-for-testing), then `ios.device-compile` (the
  shipped `Tron Device` + `LocalDevice` app compiled unsigned for arm64 devices, which
  the `HOSTED_TEST` simulator build cannot stand in for), then `ios.journeys`, which
  runs the changed UI test classes (or the smoke set) with test-without-building, two
  test methods per shard, from the same stamped products. A changed file selects every
  method XCTest runs that it declares in an `XCTestCase` subclass or its extension,
  whatever its attributes (`@MainActor`, `@available`) or modifiers. A class that needs
  a harness the plain runner does not start declares it on its own line,
  `// gate-journey: scripts/<harness>` (`TronMacTerminalUITests`: a real sshd and
  shell host), and runs through that command as a `journey` shard instead;
- Mac: `mac.build` (build-for-testing; it stages the Gateway payload, so it precedes
  every Gateway step) → `mac.test` (test-without-building); replacement scripts add
  `mac.replace-e2e`;
- protocol (`config/GatewayProtocol.json`): `protocol.contract`, `mac.build`, the full
  Gateway suite and `ios.build`;
- tooling (`tools/work`, `scripts/test-*.py`): `repo.syntax` and one `tooling.tests`
  shard per affected suite; large unittest suites run one class per shard,
  including every direct and indirect TestCase subclass. The Mac replacement suite stays
  exclusively with `mac.replace-e2e`, even when its test file changes: running it as a
  second light tooling shard would count heavy-queue wait against its timeout.
  Source-line grouping
  could pack unrelated costs past the timeout; class shards keep completed work
  reusable without raising any limit. `--tests` commands become `journey` shards.

`ios.source-policy` runs before tooling tests and builds, including when an iOS
build step is selected by name. It checks the whole iOS source tree in seconds,
without a simulator or heavy-queue lease, and uses the ordinary input-keyed
receipts. Its inputs include the policy scripts, project generator and toolchain
pins; Markdown-only changes do not select it. It requires the already-provisioned
pinned XcodeGen and setting presets (`scripts/install-ci-tools.sh xcodegen` is
an explicit setup action), never installs tools itself, and is local-only until
hosted jobs provision that toolchain. The separate local-only L1
`ios.source-policy-test` runs `scripts/test-gate.py --source-policy` against a
temporary Git tree: clean pass, raw-sheet file:line failure before builds,
receipt reuse after restoring the source, and rejection of missing tool presets.
It resolves the real checkout's provisioned tools rather than the fixture's empty
tool directory. Evidence is `test-results/ios-source-policy.json`; the default
gate CLI journeys remain portable and write `test-results/gate.json`.

**Shards and cache.** Each shard's cache key hashes its expanded command and the
git tree of its declared inputs, its catalog entry and transitive `after` prerequisites
(including their input trees/toolchain identities), and any inferred command owners.
Independent catalog entries do not invalidate each other. Unknown command ownership or
unexpanded prerequisite commands retain whole catalog/repository scope; nonexistent
prerequisite names are invalid catalogs and refuse before execution. Global catalog rules, the actual
execution prelude, tracked verifier implementation, and its pinned-Node bootstrap
(`scripts/tron-node` and `.node-version`) bind every pass. Catalog entries are keyed
separately from implementation files; Markdown documentation is not verifier code.
A changed relevant execution contract invalidates a pass even when application inputs
are unchanged. A code step (`trigger.code`) leaves Markdown out of
both its trigger and its key (`codeExclude: **/*.md`), so a docs-only landing neither
starts nor invalidates it; a non-Markdown file under `docs/` (the iOS parity assets are
UI-test resources) is a code input like any other. A `--tests` journey
(`inputsFromCommand`) keys on the inputs of the catalog steps that launch the same way
(`cd packages/gateway && ...`, or the same repository script), or on the whole
repository when none does (#1104) (`keyExtra: xcode` adds the Xcode version;
`cacheScope: worktree` binds steps whose products live in the worktree; `cacheScope: source`
also binds the exact commit and tree, for `ios.build`, whose stamped test products
`scripts/tron-ios-test run` refuses after any commit). A passing
shard is recorded under `<git common dir>/work/gate/results/`; a rerun reuses every
pass whose key still matches and reruns only failed or invalidated shards. Tests are
never skipped or weakened to meet a budget: a slow step is split into shards or
narrowed to affected files.

Landing uses that same cache. A branch's receipt (see [landing](#landing)) names the
shard keys of its whole plan; reuse proves input equivalence, not a new execution or a
screenshot/result bundle captured at the current commit. Source-stamped products still
rebuild for a new commit. iOS journeys declare all of `packages/ios-app`: unrelated
*features* within it are not proven-disjoint inputs by path. The only narrowing is
[module-scoped journeys](#module-scoped-journeys), which rests on compiler and coverage
evidence, never on path advice or a blanket reuse exemption.

**Progress and failure.** Each shard prints a start line with its class, budget,
hard limit and log path (`<git dir>/work/logs/<head12>/`), a heartbeat every 15 s
with elapsed time, live tree RSS and the log's last line, and a result line with
wall time, peak tree RSS and CPU. The first failing shard stops the run, prints the
end of its log and names the step and how many later shards did not start; a failure
that is quarantined or classified as a flake is settled first ([Flakes](#flakes)). A shard past its hard timeout is
stopped with its whole process tree and reported as `TIMEOUT <shard> exceeded its hard
limit`. The tree is every process seen descending from the shard, including ones in
their own session or process group (the iOS lane lease holder's command, `xcodebuild`)
and ones launchd adopted after their parent died. Each gets SIGTERM and 45 s for its
own cleanup, so the lease holder releases its simulator lane, then SIGKILL; the log
records how many were stopped, which needed SIGKILL and any that survived it. A
cancelled shard and anything a passing shard left running are stopped the same way.
`gate cancel` requests cancellation from the runner only, never its sampler's process
group. `gate jobs` shows `cancelling` and `gate wait` keeps waiting until the runner
has joined cleanup and atomically published exit 130; only then is the job `cancelled`.
The runner publishes its own PID after installing signal handlers, before `submit`
returns. A missing exit receipt is not settled cancellation. Old shell-owned jobs
remain readable, but cancellation from this revision refuses them: let them finish
or use their original gate revision. No new shell-owned jobs are created.
The log's `cancellation requested; joining step cleanup` line distinguishes a request
from completion; `scripts/test-gate.py` holds a real sampler and a TERM cleanup handler
to prove both boundaries. Every finished shard appends to `<git common dir>/work/gate/metrics.jsonl`.

**Heavy steps.** A `heavy` shard waits in the host-wide heavy queue
(`heavy.py`, `scripts/tron-heavy status`;
[host load management](../../packages/gateway/docs/host-load.md#1-heavy-queue-work-tooling))
with its catalog `expectedRssMb` and `expectedCores` (and `coresMin` when it can build
with fewer cores; `pool: xcode` when it runs xcodebuild or a simulator, `pool: serial`
for timing-sensitive real-process suites that slow each other beyond CPU), so admission
accounts for memory, CPU, those pools and the number of gate runs with heavy work in
flight: a run takes a gate job slot at its first heavy shard and keeps it until it ends.
While a shard waits it prints its position, what it waits for and the host's CPU and
memory now. Its budget and hard limit start when it is admitted: queue time never counts
toward a timeout, and the result line and metrics record it (`queuedSeconds`). The
shard's tree holds the lease descriptor and inherits it (`TRON_HEAVY_LEASE_HELD`), so a
journey that runs `scripts/tron-ios-test` does not wait on itself, plus its core grant
(`TRON_HEAVY_CORES`), which xcodebuild steps pass as `-jobs` and Gateway vitest shards
as their worker count. Each shard's CPU is
sampled from its process tree and the simulator it names; `metrics.jsonl` records
`cpuSeconds`, `peakCores` (busiest 10 s) and `loadAtEnd`, and `gate report` prints peak
cores next to `expectedCores`. Light shards never wait.

`land` runs the whole plan on the branch's committed tree (`gate.branch_check`) and
refuses a dirty worktree or a tree that changed while steps ran. `python3 -B
scripts/test-gate.py` exercises the real CLI in temporary repositories: the plan for
each change kind, an injected failure that stops at its shard, a retry that reuses
passing shards, input invalidation, a hard timeout, background submit/cancel/wait (including a submitted plan with `--tests`), a
source-scoped step rerunning after an unrelated commit,
and the dirty-tree refusal. It also exercises the real `tron ci` wrapper in a
shallow fixture checkout (prerequisites, fail-first annotation, local-only refusal),
Pi versus unrelated lock deltas, transport/LAN plans and complete inherited-suite
sharding; evidence is `test-results/gate.json`.

**Tiers.** Every step names its rung on the verification ladder in `tier`, and
the catalog loader refuses a step without one: `L0` static, type and build checks;
`L1` self-contained tool suites; `L2` contract checks on shared fixtures; `L3`
real-boundary Gateway, script and Mac E2E with a faux model; `L4` simulator
journeys. `tierRules` lets a step whose shards cross different boundaries
(`journey`) name the higher tier for matching commands. Real-model evals (L5) never
gate a merge. Verify at the lowest tier that can detect the failure; `gate report`
publishes each tier's p50/p90 wall time so a tier that grows is visible.

### Module-scoped journeys

A step may declare `moduleScopes`: Swift modules whose sources live under one path and
that the rest of its inputs reach only through the module's interface. `ios.journeys`
declares the Swift-app engine (`packages/ios-app/SwiftAppEngine`, target
`TronSwiftAppEngine`, #1153). A journey pass that ran none of a module's code also holds
for a change confined to that module's `.swift` sources while the module's printed
package and public interface is unchanged:

- **Execution** comes from the shard's coverage. `scripts/tron-ios-test` builds and runs
  UI validation with code coverage; Xcode writes the app's counters in continuous mode,
  so a launch the test kills still records what it ran. After a passing run it writes
  `coverage.json` (covered and executable lines per repository file) and prints
  `iOS coverage: <path>`. The test plan reports the app and the engine. A report with no
  covered app line lost its counters (every journey runs app code), so it proves nothing;
  that, no report, or no instrumented file of the module is *unknown* and gets no scoped
  pass.
- **Surface.** The gate compiles the module alone from the exact tree with library
  evolution (`sdk` and `swiftFlags` in the scope) and hashes its `.swiftinterface` and
  `.package.swiftinterface` (a compile over 120 s proves nothing), cached per source listing under
  `<git common dir>/work/gate/surfaces/` together with the gate code that judged it.
  Function bodies, internal and private
  declarations do not change it; client code compiles the same against it and can only
  behave differently by running the module's code, which coverage counts. Layout-only
  effects of private stored properties are not observable behavior.
- **What the interface omits** has no proof, so the scope keeps the whole-input key: a
  package or public static or global stored property (its initial value runs uncounted),
  an enum raw value, synthesized decoding, `@objc` (other than the `@objc deinit` every
  class prints), `@_cdecl`, `@_silgen_name`,
  `@_section` or `@_used`. A module that does not compile on its own is unproven too.
  The engine therefore exposes constants as computed properties.
- **UI test targets.** A `testTarget` scope is a UI test bundle that nothing links, so it
  has no surface: a shard runs it exactly when its `--only-testing` selectors name that
  target; a shard without selectors runs the runner's default set and is unknown.
  `ios.journeys` declares `TronSwiftAppUITests` (`packages/ios-app/SwiftAppUITests`), the
  Swift-app journeys, so a change to them leaves other targets' passes valid.
- **Keys.** On a pass the gate also records it under a key that leaves out the
  unexecuted modules' sources from the step's and its prerequisites' listings and adds
  their surfaces. Lookup tries the full key first, then each such key. The reuse line
  names the module (`it ran none of TronSwiftAppEngine, whose surface is unchanged`);
  the record keeps its original head, tree, log and `moduleExecution`.

Everything else reruns: a change outside the scopes, a surface change, a pass that ran the
module or whose execution is unknown. `scripts/test-gate-modules.py` compiles a real module with
`swiftc` and drives the CLI through body, internal-declaration, interface, outside,
executed, unknown, lost-counter, static-stored (with and without modifiers) and
non-compiling cases. The iOS source policy keeps both
folders compiled only by their own targets ([iOS architecture](../../packages/ios-app/docs/architecture.md#modules)).

### Flakes

Fidelity outranks speed: a green gate must mean correct and a red one broken, and a
check that changes outcome without a code change is an outage (#1102, #1106). Every
failed shard records its `failureClass` (`timeout`, `assertion` when named tests
failed, `setup` when it failed before any test reported) and `failedTests`, read from
its vitest JSON report, XCTest `Test Case ... failed` lines or `node --test` marks
(`flakes.py`). Nothing is retried to green:

- A plain failure stops the gate, with no rerun.
- A timeout, or a failure of a test with flake evidence (it failed and later passed on
  an unchanged key), gets **one isolated rerun that only classifies it**. If the rerun
  fails, the gate stops: a real failure. If it passes, the failing tests are quarantined
  that day in `<git common dir>/work/gate/quarantine.json`, with an owner issue filed
  through `work issue create` and an exit date 7 days out (1 day if filing failed), and
  the gate prints `FLAKY` with the owner. A timeout with no failing test that passes
  alone prints `INFRA`: load, not code, counted by `gate report` for admission.
- Quarantined tests still run and report. A shard whose only failures are quarantined
  passes, printing `QUARANTINED` with the owners, and its pass is reusable only while
  those entries are active. An expired entry excuses nothing: its failures block again.
- `gate quarantine list | add TEST --issue N [--days D] | remove TEST` is the owners'
  hand on the store; `work dashboard` lists expired and unowned entries, and
  `gate report` lists failure classes, infra timeouts and each test's flake count.

### Ledgers

Three append-only JSONL ledgers under `<git common dir>/work/` (`ledger.py`), plus the
host-wide heavy ledger (`/tmp/tron-heavy-runs-<uid>/events.jsonl`: one row per heavy
admission and release, with the holder's kind, `gate` or `direct`), record what
verification cost. Each row carries its time, owner session (`WORK_SESSION_ID` or
`PI_SESSION_ID`), worktree path and `purpose`:

- `gate/metrics.jsonl`: one row per finished shard (and per classification rerun,
  `classifyRerun`), with outcome, `failureClass` and `failedTests`, wall seconds,
  `queuedSeconds` (heavy admission wait, not part of the wall time), peak RSS, CPU,
  `peakCores`, `loadAtEnd`, tier, cache key, tree and head; an `ios.journeys` shard
  also records summed serial XCTest case time (`testSeconds`).
- `gate/runs.jsonl`: one row per `gate run`, `next` or landing verify, with its
  shard count and how many ran and were reused.
- `land/events.jsonl`: one row per landing event (`start`, `verified` with its
  ran/reused counts or the reused receipt, `merged` with `mergeWaitSeconds`,
  `finished`, `failed`), with issue, branch and head.
- `main/events.jsonl`: the post-merge check (`baseline`, `check-start`, `passed`,
  `stopped`, `bisect`, `reverted`, `revert-flagged`, `notified`). `check-start.verifier`
  identifies the commit whose verifier is actually loaded, not just the checked-out tree.

A benchmark or other measurement run sets `TRON_GATE_PURPOSE=benchmark` so its rows
are counted apart rather than mixed into real work. In the 10-15 baseline, 110 rows
came from benchmark worktrees of this clone (`/tmp/tron-bench/wt-*`, `gate-e2e-*`)
that had no such tag. `scripts/test-gate.py`'s fixtures are separate repositories
and write only their own ledgers.

### Report

`--digest` with `--since` renders one line from the same report, including reuse, measured
versus inferred heavy-queue waits, flakes and landings; it is mutually exclusive with `--json`.
Merged receipts also retain `mainSyncs` before squash/cleanup removes branch history. This
uses the baseline PR-subject rule: named main merges and generic merge commits whose named
commit is an ancestor of the integrated main tip. `landing.mainSyncs` reports the measured
and unmeasured denominators and `toolLandingsShareTwoOrMore` for the share needing at least
two syncs among measured tool-landed receipts—not all GitHub PRs. Missing older values
are unknown, never zero; non-main landings are unmeasured. It is a subject-based measure,
not all merge commits. A three-day acceptance comparison must audit receipt
coverage against actual PR landings (including external merges) using the baseline method.

`gate report --since T` rebuilds, for any window, the tables the multi-agent study
(#1102) measured by hand:

- shard time by step, by tier and by why each shard ran. The reasons are
  `new-shard`, `inputs:branch`, `inputs:main-only`, `inputs:mixed`,
  `inputs:docs-only`, `rerun-same-key`, `duplicate-key`, `worktree-scope` and
  `first-ever`. They are recomputed from each row's recorded tree and the step's
  inputs, so they are exact for any row, including rows written before the digest
  existed.
- outcomes, the share of time that produced no pass, and over-budget runs;
- cache keys that failed or timed out and later passed unchanged, which is flake or
  load evidence, never code;
- heavy-queue wait from `queuedSeconds`, or for older rows the gaps inside
  background jobs. This includes the share of wait spent while no gate heavy shard
  was running, plus the gate's heavy concurrency;
- `ios.journeys` overhead: wall time minus summed serial XCTest case time, p50 and
  p90, excluding heavy-queue wait. This measures work outside the cases, including
  boot, install and xcodebuild start-up; it is not valid for parallel case execution.
  On 2026-10-16 a retained-log replay of 66 `ios.journeys` shards measured 19.6 s
  p50 / 25.8 s p90, meeting #1109's target, so no warm-simulator pool was built.
  Reopen #1109 if the p50 rises above 20 s;
- reuse (shards reused against shards run) and landing (merges, start to merge,
  and the merge-lock wait).

An empty queue or landing sample has null percentiles in JSON and `unknown` in text,
not a measured zero-second wait; the queue maximum is likewise null without a sample.

To reproduce the baseline:
`gate report --since 2026-10-15T06:00Z --until 2026-10-15T23:41Z --exclude-worktree 'wt-*' --exclude-worktree 'gate-e2e-*'`.

## `land`

### Landing

Landings do not wait for each other (#1190, `mainline.py`); three owners keep that safe:

1. **Branch check.** A branch is checked once, on its own tree, outside any landing lock;
   heavy admission still applies. `gate run` (the whole plan on a committed tree) or
   `land` itself records a receipt in `<git common dir>/work/gate/receipts/<tree>.json`:
   the tree, lockfile blob IDs, the shard keys of the plan that passed, and the time. A
   rebase or squash that leaves the tree unchanged reuses it (`receipt for tree ... covers
   all N shards; nothing to run`); any content change needs the plan again, which reuses
   whatever shards it still can. A receipt is used only while every key of the current
   plan is in it and still a valid pass.
2. **Merge.** `land` publishes the head, then holds `<git common dir>/work/land/merge.lock`
   only while it refetches the base, checks with `git merge-tree` that the head merges
   cleanly onto it, and asks GitHub to squash-merge the checked head. No gate runs inside
   the lock, so a merge takes seconds. A head that does not merge cleanly is refused
   with its conflicting paths: merge the base in on the branch, resolve, commit, and land
   again; the new tree is checked like any other.
3. **Post-merge check.** Each merge starts `scripts/tron gate main-check` in the
   background. One runner checks main at a time, in its own detached worktree
   (`<git common dir>/work/main/worktree`), with main's own tooling and catalog. It runs
   the plan for everything changed since the last main that passed, so merges that land
   while it runs are covered together by its next run; a second waiter is never started.
   A pass records the new last main that passed. A failure stops landing at once. The
   failing shard (with its prerequisites) then runs again on the last main that passed,
   in the same worktree and ignoring recorded passes: if it fails there too, the failure
   predates the range (the check's environment or the check itself, #1211), so no merge
   is blamed or reverted and landing stays stopped until a rerun passes. Otherwise it bisects
   the first-parent merges in the range on the failing shard (with its prerequisites; a
   shard the range up to a merge does not select passes there), names the culprit,
   reverts it through a pull request that it squash-merges under the merge lock, and
   reopens the culprit's claimed issue with the failure (`work issue reopen`'s path). A
   culprit whose revert is already in the range is not reverted again: the stop is
   flagged, since another merge still breaks the shard. Landing reopens when a check of
   main passes, normally the reverted tip. A revert that does not apply or merge leaves
   landing stopped: `land` refuses with the reason, and a fix lands with
   `--repair-main`.

Build source admission belongs to `gate build-source` (#1216): main builds select the
last main that passed, validated as an existing commit in the configured remote main.
Missing/malformed evidence, unavailable ancestry, divergent local main or uncommitted
files on main refuse (files are preserved); they never fall back to unchecked HEAD. Detached main revisions have
the same protection; explicit task branches (and detached non-main revisions) remain
development sources. The command returns JSON with head, selected revision and warning;
`--require-current` refuses when the checkout differs from that revision.

`scripts/tron mac replace` uses that revision and its existing full detached-source
build when the quick source-update path cannot build it. Direct Quick Rebuild,
`scripts/tron-ios-device share`, and `scripts/tron dev start|restart` require the
current checkout: unchecked main refuses before build/publish/Debug lifecycle effects.
The refusal names the passed SHA and `gate status`; resume an interrupted check with
`gate main-check`, or use an explicit task branch for development. Direct Quick Rebuild
also names Mac Replace as the passed-source build path. No separate worktree store,
warning-only bypass or automatic wait is added. `test-work-mainline.py` drives the
real CLI/Git/payload-directory boundaries, including malformed/missing evidence,
detached main, absent refs, unrelated history and explicit branch iteration.

`scripts/tron gate status` (or `work land --status`) prints the last main that passed and
how far main is ahead of it, the range and merges the check covers now, its phase, loaded
verifier SHA and last step, whether landing is stopped and why, and any merge in flight. State is
`<git common dir>/work/main/state.json`, events `work/main/events.jsonl`, and the runner's
output `work/main/check.log`. A runner that crashed or was killed shows as interrupted;
`scripts/tron gate main-check` resumes it, and the gate reuses every shard that already
passed. With no recorded state, the first landing records the base it merges onto as the
last main that passed.

Before checking a newly coalesced tip, the runner re-executes that tip's verifier while
retaining its kernel lock and PID. It cannot key new source with an older imported
selection/execution policy. The selected verifier stays pinned for that range's baseline
confirmation and bisect probes; the next tip (including a revert) reloads it. The real
Git/CLI `reload_verifier` journey holds the first check at a shard barrier, advances main
with a newly required verifier check, and proves it executes under the same runner.

`land` refuses a detached HEAD, a base branch, a dirty worktree, a merge or rebase in
progress, and a branch with no commits beyond the base. The privacy guard runs on the
title and summary before anything is pushed or posted. A head that a pull request already
merged is refused, so a repeat run cannot open a second one. Other refusals stop `land`
with nothing merged. `scripts/test-work-mainline.py` lands two disjoint branches at once
on their receipts, catches a semantic conflict after merge (coalesced range, bisect,
revert pull request, reopened issue), refuses landing while a revert cannot merge until a
`--repair-main` fix, blames nothing for a failure that also happens on the last main that
passed, reuses a receipt across a message-only amend but not a content
change, and resumes a killed check with its passed shards, against a bare remote whose
fake GitHub really squash-merges.

Claim handoff serializes through a read-only descriptor on the pre-existing common Git directory (it creates no lock file), checks operation markers in the selected worktree's private Git directory (including linked-worktree merge/rebase/cherry-pick/revert state), and rechecks local and remote heads before changing a ref. An exact accepted transition commit can repair local ref state after a partial push; unrelated or malformed remote objects are never treated as proof. A local head that differs from the remote claim head is not accepted merely because it is unpushed or has the same tree: use the explicit candidate recovery path for a clean settled-owner descendant, or stop and preserve the conflicting state. Force confirmation does not bypass this expected-head fence.

## Candidate recovery

Use only when the former owner and its children are authoritatively settled and
a clean registered task worktree contains unpublished commits strictly descending
from its remote claim head:

```bash
scripts/tron work recover <issue> --expected-local <full-candidate-SHA> \
  --expected-remote <full-remote-ancestor-SHA> --reason "<reason>"
scripts/tron work handoff <issue> --reason "<reason>"
```

Recovery is not approval: it publishes the preserved candidate to its existing
task branch, leaves ownership unchanged, and audits the exact ancestor/candidate
pair. It does not reset, replace files, create a new claim, open a PR, mark tests
passed, merge, or close an issue. Review and full exact-head `land` gates remain
required after ordinary handoff.

Both heads must name the same original claim commit/owner. Divergence, changed
claims, missing worktrees, unknown/live owners or children, dirty tracked/untracked
files, pending Git operations and competing Git writers refuse. Recovery holds
the common repository lock plus temporary Git HEAD/branch/index locks, repeats
settlement and head checks immediately before publication, and uses an exact
remote expected-head lease **only after proving strict fast-forward ancestry**.
The lease is compare-and-swap protection, never authorization for a history rewrite.
A remote move at publication is rejected; local candidate history is not rewritten.
Arbitrary filesystem editors do not honor Git locks: a late dirty edit is detected
after publication and reported as partial, never discarded or called success.

If the push succeeds but audit publication fails, rerun the **same exact command**.
Only the unchanged local candidate and that exact remote candidate admit this
audit-repair path; current settlement is still required. The audit marker makes
repeats idempotent. Inspect other partial/racing states instead of changing refs
manually. Run commands from the checkout containing the landed tooling.

## `release`

`release` is for a claim whose owner is gone while its issue stays open (`cleanup` handles
closed issues; `handoff` transfers a claim). It fails closed at every step, so a refusal
leaves the claim, refs, worktree and GitHub unchanged:

1. **Claim.** Exactly one remote claim branch for the issue, the issue OPEN, and that
   branch only claim/handoff commits beyond the base (no file changes). Published work
   is refused: land, hand off or recover it instead.
2. **Owner.** The newest `Work-Claim-Session` on the branch, checked with the owner helper
   ([owner status](#owner-status)). Only `settled` or `absent` admits a release; `live`
   and `indeterminate` refuse with the helper's reason, and `idle` refuses unless the
   maintainer forces it ([maintainer release](#maintainer-release)). A claim without an
   owner refuses.
3. **Local.** The registered claim worktree (if any) must not be locked, mid merge/rebase,
   the working directory of another process or hold a file another process has open.
4. **Preserve first.** The worktree's whole state (tracked edits, staged files, untracked
   files and non-regenerable ignored files such as `progress.md`) is captured as a
   snapshot commit through a private temporary index, so the worktree and its index are
   untouched. The remote head, local head and snapshot are kept under
   `refs/work-release/<issue>/<head12>/` and bundled with a manifest and binary patch in
   `<git common dir>/work/releases/<issue>-<head12>/` (`claim.bundle`, `worktree.patch`,
   `manifest.json`). The bundle is verified before anything else changes. Regenerable
   ignored output (`cleanup.regenerableIgnored`) is not preserved. A nested checkout with
   local data refuses.
5. **Release.** `cleanup.releaseCommands` run, then the owner, head, snapshot tree and
   processes are re-proven (a forced `idle` owner must still be `idle`). Any change refuses
   with the work still preserved. The remote
   branch is deleted with a lease on its exact head, the audit comment (marker keyed by
   branch and head; privacy-checked) names the old owner and its evidence, the releasing
   session, the reason and the released head. Status returns to Ready, the worktree is
   force-removed (its exact state is in the bundle) and the local branch is deleted at
   its preserved head. A record is appended to `work/releases/log.jsonl`.

### Stale sweep

`release --stale` lists every remote claim branch, skips closed issues (`cleanup` owns those)
and any claim with a claim-branch commit or issue comment in the last 72 hours, and asks the
owner helper about the rest. Only an `absent` owner is released, through the ordinary steps
above with a reason naming the idle time; every other state, including `settled`, is kept and
printed with its verdict. A settled Home task's claim passes to its successor through `start`
(#929) and can be a maintainer's paused continuation, so the sweep never takes it. A refusal
inside one release (published work, a busy worktree, an owner that changed) keeps that claim
and the sweep continues. `--dry-run` prints the same decisions without any write. The
dashboard's Stale claims section (48 h without activity) names this command.

### Maintainer release

Two owners can never become `settled` or `absent` on their own, so only the maintainer
releases them, with `release <issue> --reason TEXT --force-maintainer` from a real terminal,
typing exactly `RELEASE #<issue> FROM <owner>`:

- **An idle Gateway session** (#1001): an ordinary chat that claimed the issue and went idle.
  The helper answers `idle` only when the Gateway lists the session with no turn, subagent or
  user wait and no Home task is bound to it. It could still be resumed, so the maintainer
  confirms it is abandoned. The verdict is re-read right before the remote delete; a session
  that became live keeps its claim.
- **A legacy owner**: a missing owner trailer (type `unknown`), or an id that is not a Gateway
  session id (for example `reliability-364`), which no Gateway can report live or settled.

Everything else is unchanged: work is preserved first, the worktree must have no process
inside or holding a file open, and `live` refuses before any prompt. A Gateway-shaped
`indeterminate` owner (a delegated session or Home chapter, a Home task that ended without
settlement proof, an unreadable Gateway) is never forced. An interrupted `warm` clone's
`packages/*/.tron-warm-*/` staging directory holds only `node_modules`, so it is regenerable
output that neither blocks the release nor enters the bundle.

If a step after the remote delete fails (for example the comment), rerun the same command:
it finds the manifest in phase `remote-released` and finishes the comment, Status and
local removal once. To restore preserved work, fetch the bundle's
`refs/work-release/*` into any clone and check out `…/worktree`.

### Owner status

`packages/gateway/dist/client/work-owner-status.js <session>` (built with
`npm --prefix packages/gateway run build`) prints one JSON verdict `{state, reason}`
within a 20-second overall budget; every request gets only what remains of it:

- `live`: the Gateway lists the session as active, or its Home task is not terminal.
- `settled`: its Home task is terminal with settlement proof (as `handoff` requires). A task
  the Gateway reconciled from the canonical file after its operation ended
  (`unknown` with `settlement-failed` or `cold-no-report`) counts, because every async run is
  proven ended there; `evidence-unavailable` does not.
- `absent`: the id has Gateway session shape, `session.list` (user scope, including
  archived) has no row for it, and no file or folder name under the Gateway's session
  root carries it. The root is trusted only if it holds every idle listed session. This
  covers delegated sessions and Home chapters, which the listing omits. A session that
  could have made a claim commit has run tools, so it was persisted.
- `idle`: `session.list` lists the session with no active turn, subagent or user wait, and
  the whole Home task list binds no task to it. It can still be resumed.
- `indeterminate`: everything else, including a session whose Home task ended without
  settlement proof, an unlisted session with a file (a delegated session or Home chapter),
  an id that is not a Gateway session id, a mismatched root and a deadline. The
  reason names the cause, for example `home.taskList did not answer within the 20s
  owner-status deadline`.

Only `release` accepts `absent` (and `release --stale` accepts only `absent`), and only a
maintainer-forced `release` accepts `idle`; `handoff` and `recover` still require `settled`.

The tooling builds the helper it runs: the build is stamped with the Git tree of
`packages/gateway/src` it came from, and a missing, stale or uncommitted-source build is
rebuilt under a lock before use (#924), so a stale helper is never read as an
indeterminate owner. `work-owner-status.js --home-task <session>` prints `{state: "live",
reason, taskId}` when a non-terminal Home task is bound to the session, else
`{state: "none", reason}`.

**Settled-owner successors (#929).** `start` on an issue claimed by another session hands
the claim over automatically, with the ordinary audited `handoff` (claim trailer and issue
comment), when the owner is `settled` and the caller runs a live Home task. Any other owner
state refuses with its verdict; a settled owner and a caller that runs no Home task refuse
with the `handoff` command to use. A task resumed in place keeps its session, so it keeps
its claim with no transfer. Claim identity comes from `--session`, `WORK_SESSION_ID` or
`PI_SESSION_ID`; a terminal opened from a chat inherits that chat's `PI_SESSION_ID`, so a
maintainer running `handoff` from Home's terminal once claimed for Home's own chapter
session. `handoff --force-maintainer` therefore requires `--session` (or `WORK_SESSION_ID`)
and refuses an identity inherited only from `PI_SESSION_ID`.
`home.taskList` used to cost O(catalog) per row (#905): live rows built a whole session
snapshot to read the worker name, and settled rows rebuilt the catalog acquisition. On
the Stable Gateway a 50-row page took 6.3 s against the helper's old 4 s per-request cap,
so every owner check timed out. A Gateway built from #905 or later answers in
milliseconds. On an older one the helper still answers `live`/`absent` from the listing
and the session root, but a Home-task lookup may end `indeterminate` at the deadline.

## `cleanup`

A worktree is removed only when its head is proven done and nothing local would be
lost: no uncommitted or untracked files, no non-regenerable ignored files, no operation in
progress, no process working inside it or holding a file there open. Release commands from `cleanup.releaseCommands`
run first (`scripts/ios-gateway-e2e-test clean`, `scripts/tron-ios-test clean`). Removal
deletes the local branch and the remote branch with a lease on the proven head.
`--dry-run` changes nothing.

## GitHub access

Agents reach GitHub with one dedicated classic token in the maintainer's login Keychain
(generic password, service `tron-work-github`), never through the interactive `gh auth`
state. A re-login there can swap the stored credential or narrow its scopes for every
agent at once. A classic token is required: user-owned Projects are unreachable from
fine-grained tokens and GitHub Apps.

- **Setup, once:** `scripts/tron work auth setup` in a real Terminal. It prints a
  prefilled token page (scopes `repo`, `project`, `workflow`), reads the token hidden,
  checks it against GitHub, and stores it through `security -i`, so the token never
  appears in process arguments. In a shell outside the login GUI session (SSH, a
  detached tmux) the login keychain reads as locked; setup then lets `security unlock-keychain`
  ask for the macOS login password itself and retries. It then reads the item back the
  way agents do. Pick any
  expiry; replacing the token is the same command.
- **Every command:** `gh.py` reads the item, checks it with one `gh api --include /user`
  (it must be valid and hold every required scope), and passes it to each gh call as
  `GH_TOKEN`. A token inherited from the environment never wins. A missing, invalid,
  revoked, expired or under-scoped token stops the command before any other GitHub
  request, with the setup command. A token that expires within 14 days still works and
  warns with the same command.
- **Fixtures:** `WORK_GH` substitutes the whole CLI and owns its own credentials, so it
  gets no token. `TRON_WORK_KEYCHAIN` names an explicit keychain file instead of the
  login search list.
- `python3 scripts/test-work-auth.py` proves this through the real CLI, a real isolated
  keychain file (an isolated `HOME` leaves the user's search list alone) and a gh found on
  `PATH`: refusal before any request when unset; setup refusing an under-scoped token and
  storing a valid one without echoing it, including through a locked keychain; the Keychain token winning over an inherited
  `GH_TOKEN`; revoked and under-scoped tokens refused before any write; and the expiry
  warning. Evidence: `test-results/work-auth.json`.

## Failure modes this protects

- **A claim is taken twice.** The claim is a remote branch created without force; the
  smallest branch name wins the race and the loser deletes only its own ref. `handoff`
  appends the new owner trailer using an exact remote expected-head lease and updates
  the local branch only at its expected old head. The audit marker is keyed by the exact handoff commit.
- **A foreign session's claim is changed.** `issue close` refuses when another session
  holds a claim on the issue.
- **Public text leaks personal data.** Issues, comments, and pull request text pass the
  privacy guard first; a refusal prints no matching line.
- **An interactive gh re-login breaks every agent.** Agents use their own Keychain token,
  checked before the first request; see [GitHub access](#github-access).
- **A conflict is merged by hand.** `land` aborts a conflicting merge and names the files.
- **Unverified code is merged.** The squash merge names the verified branch commit, so GitHub
  refuses it if the branch changed. A moving base is composed by the clean-merge check;
  the resulting main range is verified by the post-merge owner, not by rechecking the branch.
  After publishing, land checks the remote branch and, when the PR response is stale,
  re-reads the PR at most twice (three observations including publication). A different remote SHA is a foreign branch move;
  an unchanged expected remote SHA paired with a persistently stale PR is reported as
  uncertain and must be observed again by rerunning land. Neither path weakens the
  exact-SHA merge request. A base that moves in the instant between the final check and
  GitHub's merge call is not caught; the merge still composes the base with the verified branch.
- **Unmerged work is removed.** `cleanup` needs a merged pull request at the local head,
  or a closed issue whose branch holds only its empty claim commit.
- **A closed or blocked issue is claimed.** `start` refuses a closed issue, an excluded
  label (epics), or an issue blocked by an open issue.

## Tests

For an explicitly requested multi-run hosted check, publish with `land --publish-only`,
observe the PR run, then use `work ci-dispatch` for each additional fresh run. Count
only successful first attempts on the exact same head; changing the candidate
invalidates that acceptance evidence. Dispatch is not a required gate for ordinary
landings and does not change repository settings. The real-CLI `test-work-land.py`
journeys cover publication without merging/closing, one audited dispatch, and
refusal of unpublished or dirty heads before writing.

The tooling has no unit tests. Changes are validated by running the real commands: a
`scripts/tron gate run` or `land --dry-run` on the branch, and an integration run against a temporary
repository when a change touches Git, GitHub or cleanup behavior.

`python3 scripts/test-work-start.py` exercises real CLI/Git creation, custom-base
contents and canonical ownership, idempotent resume, and fixture-only interactive
handoff followed by ordinary successor admission. It verifies that the creation
base survives handoff and a later base advance, and that closed/blocked/excluded
issues, foreign/unknown claims, invalid/missing bases and local-only branch collisions
refuse without publishing changes. Ordinary task creation remains covered. The
process-level GitHub fixture uses isolated `HOME` and `TMPDIR`; evidence is written
to `test-results/work-start.json`, and temporary repositories are removed on exit.
The diagnostic signal for an ownerless integration branch is the absence of a
`Work-Claim-Session` claim receipt: a branch name or clean worktree is not owner proof.

`python3 scripts/test-work-land.py` exercises land through the real CLI, temporary Git
remote, and process-level GitHub fixture. It covers a base advance followed by a stale
PR PATCH response and fresh PR observation, refusal of a genuine remote branch move,
and truthful uncertainty when the PR projection remains stale or the remote ref cannot
be read. It also covers draft pull requests: a draft refuses without `--ready` with nothing
merged; `--ready` marks it ready (audited as a GraphQL write) before the exact-SHA merge, and
a refused or unconfirmed ready transition merges nothing. An issue with an open sub-issue is
left open after its merge. Evidence is written to
`test-results/work-land.json`; the fixture repository, home, and temporary files are
removed on exit.

`python3 scripts/test-work-cleanup.py` exercises merged cleanup against real temporary
Git repositories and linked worktrees, checking exact-head evidence retention, 30-day
pruning, and remote-branch/worktree removal. Evidence is written to
`test-results/work-cleanup.json`; the temporary repositories are removed on exit.

`python3 scripts/test-work-bootstrap.py` runs `bootstrap` through the real CLI against a
process-level gh fixture holding undeclared labels, a Status option still in use, an unused
one, an undeclared custom field and a built-in field. It proves the plan reports each as
drift with exit 2 and writes nothing, that `--apply` alone deletes nothing, that
`--apply --prune` deletes only the unused label, unused option and undeclared field while
in-use items stay reported, and that it converges once they are migrated. Evidence:
`test-results/work-bootstrap.json`.

`python3 scripts/test-work-close.py` exercises filing, epic/task close and reopen through the
real CLI and Git with a process-level GitHub fixture in an isolated temporary home. It
covers filing first: a task without a kind or area, an undeclared label, a `[Task]:` title
prefix and a wait-for-recurrence body without `--exit-by` are refused before any write; a
classified task is created with exactly its kind and area labels and its exit line, then
added to the Project with Status Ready; an epic gets only `epic`; `issue edit` replaces a
body. It then covers completed epics, unfinished children on later pages, failed reads, foreign claims,
and idempotent recovery after a partial close; and for reopen, refusal without a reason
or of an open issue, the Ready/In progress Status choice, the audited write, and
idempotent recovery after a partial reopen. Regenerable evidence is written to
`test-results/work-close.json`; the fixture repository and home are removed on exit.

`python3 scripts/test-work-handoff.py` exercises handoff through the real CLI and Git
in an isolated fixture, with owner-status evidence served by real Gateway WebSockets
using the built client helper. A protocol mismatch is emitted as a structured helper
refusal with distinct exit code 3 and is named by `handoff`; other helper failures
remain indeterminate and cannot establish settlement. Only the matching Home task row's
status is read. It checks refusal of an unassigned IP before socket
access, acceptance of a locally assigned interface IP when one is available, active-only
refusal without status reads, pagination to a finished matching owner, malformed
evidence, settled no-report proof with stopped or naturally completed children, task/session/operation mismatches, missing or failed settlement, excluded unknown reasons, status races, natural completion with zero stopped subagents, refusal preservation of
refs/index/dirty bytes, ordinary and TTY-confirmed takeover, idempotent audit, and
missing-worktree refusal without recreation, and a legacy bare-verdict helper with a stale
source stamp is rebuilt before a settled-owner handoff succeeds; only that call allows
the helper's 300-second build bound plus 30 seconds for the CLI/Gateway exchange.
Evidence is written to `test-results/work-handoff.json`; build the Gateway first with the
pinned Node runtime using `npm --prefix packages/gateway run build`. The fixture sets
`TRON_GATEWAY_HOST=127.0.0.1` by default so it remains independent of host Tailscale.

`scripts/test-work-start.py` additionally exercises path declarations and preserved handoffs,
ancestor/sibling overlap, unknown legacy scope, and the Home work view while a real landing
lock is held and after it is released. The heavy FIFO journey checks that same CLI view
against real holders/waiters before and after release; the land journey verifies sync counts
and unknown historical receipts through `gate report`.

`python3 scripts/test-tron-heavy.py` runs the heavy-run queue with real concurrent
processes: two slots with FIFO order and printed positions, a killed holder whose
command tree keeps its slot, a dead waiter leaving the queue, the bounded load gate and
an inherited slot. Evidence: `test-results/tron-heavy.json`.

`python3 scripts/test-work-release.py` exercises `release` through the real CLI, Git, the
built owner helper, a Gateway WebSocket fixture (with a seeded session root) and a gh
fixture. It proves refusal without any change for a live session, a live Home task, an
idle listed session without force (naming the maintainer route), an idle session whose Home
task ended without settlement proof, an unlisted session that has a file, a non-Gateway owner id, an
unverifiable session root, a stalled `home.taskList` (bounded at the 20 s deadline), and a
claim branch carrying published work. Dirty work (staged, unstaged, untracked,
non-regenerable ignored and an unpublished local commit) is restored byte for byte from
the bundle into a fresh clone after release. A failed audit comment after the remote
delete resumes once on retry, and the result is Status Ready, one comment and the log
record. A settled Home task owner is also released through 5 s Home task pages, which the
former 4 s cap refused. The stale sweep keeps a recent absent-owner claim, one with a recent
issue comment, and idle live, resumable and settled owners, each with refs, worktree (including
an uncommitted file) and GitHub unchanged; it releases an absent owner idle for 100 hours and
its uncommitted files are restored byte for byte from the bundle. Maintainer release refuses a
live owner even with force, refuses an idle owner without a terminal, while another process
holds a worktree file open, and on a confirmation naming another owner; through a real
pseudo-terminal it releases an idle Gateway session (whose worktree holds an interrupted
`.tron-warm-*` clone, kept out of the bundle) and a legacy owner after the exact confirmation. Evidence: `test-results/work-release.json`.

`python3 scripts/test-work-handoff.py --recovery-only` runs the focused recovery
journeys through the same CLI/Git/WebSocket boundaries; the default command also
includes these journeys. It proves unchanged ordinary handoff refusal, dirty and
operation refusal, canonical owner/child and settlement-race refusal, same-claim
ancestry, local Git writer exclusion, exact remote CAS race refusal, partial audit
repair, idempotence, and subsequent ordinary handoff preserving candidate bytes.
It does not run the separate host-interface and maintainer-TTY handoff journeys.
