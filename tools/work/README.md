# Work tooling

Repository-agnostic tooling for many agents working in one GitHub repository at
the same time. GitHub Issues and one GitHub Project are the only record of work.
This tooling holds no local registry or cache of that state.

The core lives here until a second repository adopts it (decision D-1 of the
parallel agent workflow plan). To keep that extraction mechanical:

- Nothing in this directory imports or names repository-specific code, paths,
  owners or handles.
- Everything specific to one repository lives in its `.github/work.json`.
- The repository and its owner are read from the checkout's GitHub remote at run
  time.
- It uses the Python 3.9 standard library and the GitHub CLI, and nothing else.

Tron runs it through `scripts/tron work`.

## GitHub CLI resolution

`gh` is resolved in this order:

1. `WORK_GH`;
2. `gh` on `PATH`;
3. the Homebrew locations under `/opt/homebrew/bin` and `/usr/local/bin`.

Agent shells can inherit a PATH without Homebrew, which is why step 3 exists.
Authentication stays in gh's own credential store.

## GitHub writes and the local audit

Every GitHub mutation made by this tool uses `Gh`, which records the attempt
before invoking `gh` and appends its terminal outcome afterwards. This covers
all typed work commands (claim/status/comment, receipt publication, bootstrap,
landing, handoff and cleanup-related reads/writes); callers do not construct an
alternate `gh` writer. It is deliberately not a generic `work gh` passthrough.

The append-only JSONL audit lives in the repository's private Git common
metadata at `work/github-writes.jsonl`, shared safely by linked worktrees. A
separate lock file serializes each append across threads and processes. Each
mutation has a stable random ID, timestamp, operation class and an `attempt`
record followed by `succeeded`, `failed` or `uncertain`; an interrupted command
therefore remains visibly attempted, never silently successful. A single
request rejected with HTTP 4xx is failed. Compound CLI operations that can
commit a sub-write before a later rejection (including `issue close --comment`)
are uncertain on any command failure; transport/opaque errors are also
uncertain. No request body, credential, CLI arguments, response body, or issue
text enters the audit. Files are owner-only, symlinks are refused, and history
is capped at 16 MiB. Capacity is reserved for terminal outcomes before a
mutation starts; a full, malformed, or unwritable audit refuses the GitHub
mutation instead of dropping history.

`scripts/tron work comment <issue> --body-file <markdown>` is the typed command
for public progress/evidence comments. It bounds and privacy-checks the body
with the configured scrub command before GitHub is called, and suppresses guard
output so private offending text is not copied to the terminal. Read operations
such as `work issues` remain reads and do not appear in the audit.

### Failure modes

`test_gh.py` runs the real CLI/GitHub boundary against an executable stand-in.
It checks that reads are not audited, every CLI/REST/GraphQL mutation has
attempt and outcome records, concurrent writers produce complete records,
privacy refusal prevents a public write, rejected and ambiguous/partial errors
remain distinct, payloads are absent, well-formed full and reservation-bearing
audits refuse writes, and admitted records stay within the bound. A compound
fixture commits a comment-like side effect before returning HTTP 422 and proves
its result is `uncertain`, not `failed`. Malformed audit refusal is a separate
case. The stand-in does not prove remote GitHub availability or server-side
behavior.

## `bootstrap`

Declares the tracking vocabulary, and converges GitHub to it when you pass
`--apply`:

- repository labels;
- one owner-level Project, with its settings and a link to this repository;
- the Project's fields and single-select options.

Without `--apply` it only prints the plan. It exits 0 when nothing differs and 2
when changes are pending. With `--apply` it applies the plan, plans again, and
fails unless the second plan is empty, so every apply also proves idempotency.
`--report <path>` writes the final plan and every action taken as JSON.

It adds and updates, and never deletes a label, field or Project. Labels and
fields that are not declared are reported and left alone.

Rulesets listed in `.github/work.json` are reported, never applied. Branch rules
are an account-level change for the maintainer, and applying them before the
landing tooling exists would block today's direct pushes to `main`. The report
prints the one-line command to apply them.

### Failure modes

Isolated tests in `test_bootstrap.py` target these failure modes. The live
GitHub run covers the rest.

1. **Updating a single-select field drops option IDs.** Every Project item that
   used a dropped option silently loses its value. Options whose names match
   case-insensitively must keep their IDs, including across a rename in case
   only.
2. **An option still in use is removed.** A live option that is not declared
   may be removed only when no item uses it. Otherwise bootstrap refuses and
   names the option.
3. **Planning never converges.** The same live state must plan as unchanged on
   every run: no spurious differences from ordering, case, missing
   descriptions, or colors GitHub normalizes.
4. **A field with the right name has the wrong type.** Bootstrap refuses rather
   than deleting and recreating it, because deleting a field destroys every
   value in it.
5. **Two Projects share the declared title.** Bootstrap refuses rather than
   choosing one.

## `start`

`scripts/tron work start <issue> [--base <branch>]` claims one issue and
prepares its isolated workspace:

1. **Eligibility.** The issue is open, is not an epic, has Status Ready in the
   Project, and every issue it is blocked by is closed.
2. **Claim.** The claim is the creation of the remote branch
   `<type>/<issue>-<slug>`, whose first commit is an empty claim commit carrying
   `Work-Claim-Issue`, `Work-Claim-Session` and `Work-Claim-Base` trailers.
   - The commit is based on the freshly fetched remote base branch, never on
     local `main`: `--base`, otherwise `claim.baseBranch` (see
     [The claim's base](#the-claims-base)).
   - The push only creates the ref (`--force-with-lease=<ref>:`), so the remote
     accepts exactly one claimant.
   - Squash merges drop the empty commit.
3. **Tracking.** `start` sets the issue's Project Status to In progress. It then
   posts a claim comment giving the session, the branch, and the worktree path
   relative to the checkout's parent directory, never an absolute path.
4. **Worktree.** `start` creates `<worktreeRoot>/<issue>-<slug>` on the branch.
   `worktreeRoot` is relative to the primary checkout, so `start` gives the
   same path when run from any worktree.
5. **Warm local dependencies.** On a new or resumed worktree, `start` copy-on-write
   clones `packages/gateway/node_modules` and `packages/push-relay/node_modules`
   only when the corresponding lockfile bytes exactly match the primary
   checkout and npm verifies that its dependency tree is complete. A missing or
   incomplete source install, lock mismatch, or clone failure falls back to
   `npm ci` in that worktree. iOS build caches are owned and seeded by
   the build-bearing commands of `scripts/tron-ios-test` (`build`, `checkpoint`
   and `prepare`), not by `start`.

The session is `--session`, then `WORK_SESSION_ID`, then `PI_SESSION_ID`.

The branch type comes from the first matching label in `claim.branchTypes`,
otherwise from `defaultBranchType`. After claiming, `start` warns when the number of
active claims exceeds `claim.softCap`; the claim still proceeds.

Re-running `start` in the same session resumes a claim that is already made.
It fills in whatever is missing (Status, comment, worktree) and never makes a
second claim. A different session is refused, and the refusal names the owner.

### The claim's base

A claim starts from and lands into one base branch. It is recorded in the
claim commit's `Work-Claim-Base` trailer: `start --base <branch>`, otherwise
`claim.baseBranch`. A claim commit made before bases were recorded has no
trailer, and its claim keeps `claim.baseBranch`. Wherever this document says
*base branch* for a claim, it means that base:

- `verify` diffs from the merge-base with it;
- `land` merges it in, opens the pull request into it, checks it again before
  merging, squash-merges into it, and resumes from a merge into it;
- `steward --land` requires the head to contain its tip;
- `cleanup` proves a merge into it.

A base other than `claim.baseBranch` must be another open issue's claim
branch that exists on the remote and carries its claim commit, so every
long-lived branch belongs to an issue. Use one to hold a set of changes off
`claim.baseBranch` until the maintainer verifies them together: an integrating
issue's claim holds them, each piece of work is claimed with `--base <that
claim branch>` and lands into it, and the integrating issue then lands them all
at once.

- A claim's base is fixed for its life. A resumed `start` with a different
  `--base` is refused.
- `land` and `steward --land` refuse a pull request whose base is not the
  claim's base. The base is read again right before the merge, so a pull
  request retargeted while checks ran is not merged. GitHub's merge call takes
  no expected base, so a retarget in the moment between that read and the
  merge is not caught.
- A branch that an open issue's claim starts from is never deleted, because
  that claim lands into it. A stacked claim whose issue is closed does not
  count.
  - `land` and `steward --land` refuse to land such a branch. `land` checks
    before it verifies and again right before the merge, because a claim can
    start during the wait.
  - After the merge, `land` keeps the branch, and says why, if a claim started
    from it in the meantime.
  - `cleanup` keeps such a worktree and its branch, checking again after its
    release commands.
- GitHub applies `Closes #N` only to merges into the default branch, so `land`
  closes a stacked claim's issue itself, with a comment naming the branch it
  landed into.
- Claim commits are still found in the range from `claim.baseBranch`, which a
  claim commit is never on. That range also holds the claim commit of the
  branch beneath a stacked claim, which names another issue.

To hold work that has already landed, revert it on `claim.baseBranch` through
a normal claim. Then build the held branch on the new tip by reverting that
revert. A held branch cut from before the revert would keep the revert when it
merges and silently drop the work.

### Base failure modes

`test_claim.py`, `test_land.py`, `test_cleanup.py` and `test_verify.py` check these against real
repositories, local bare remotes and the fake `gh`. Each module builds its repository
history once and every test copies it (`repo_template.py`), so setup costs no per-test Git
processes while each test keeps its own repositories. The land fixtures disable
Git auto-GC and automatic maintenance for every child Git process, so repository
temporary-directory cleanup does not race detached maintenance.
The fixture-level test process owner tracks every child process and applies the
Git auto-GC/maintenance configuration. It terminates and joins any remaining
children before fixture-directory cleanup, including on test failures.
`GitMaintenanceCleanupTests` makes auto-GC eligible with auto-detachment disabled,
then uses an owner-tracked writer to reproduce a late write during
`TemporaryDirectory` cleanup without the fixture configuration. It verifies
cleanup succeeds with the fixture configuration. Its failure-injection case
also verifies that a child-release exception still restores the process owner
and closes both FIFO descriptors.

75. **A stacked claim uses the wrong base.** `verify`, `land` (update, pull
    request, merge, resume and the closing comment), `steward` and `cleanup`
    use the base the claim commit records. A claim without one keeps
    `claim.baseBranch`. The claim commit is found even though the branch beneath
    carries another issue's claim commit.
76. **A base is invented, or changes.** `start` refuses a base that is not
    `claim.baseBranch` or an open issue's claim branch carrying its claim
    commit, refuses the issue's own branch, and refuses a resumed claim with a
    different base, all before any claim or GitHub write.
77. **The base of an open stacked claim is deleted.** `land` and `steward
    --land` refuse, naming the stacked claims. `land` refuses both before any
    GitHub write and right before the merge, for a claim started during the
    wait. After a merge, `land` keeps the branch if a claim started from it
    meanwhile. `cleanup` keeps such a branch, whether its worktree is merged or
    claim-only. A stacked claim whose issue is closed does not block.
78. **A pull request into another base is merged.** `land` refuses an open
    pull request into another base before any GitHub write, and the shared
    merge step refuses one retargeted since, for `land` and `steward --land`.

### Warm-worktree failure modes

`test_warm.py` covers dependency seeding: exact lock match plus a complete npm
hidden lock and dependency tree clones independent files; mismatch, missing or
incomplete primary dependencies uses `npm ci`; and failed clones remove partial
output before installing. `scripts/test-ios-test-infrastructure.py` covers
runner-owned iOS cache seeding and cleanup of failed cache clones. Neither tool
shares mutable build products or trusts an incomplete dependency tree.

### Claimed and active statuses

A claim moves through several Statuses, all listed in the `claim` section:

- `claimedStatus` (In progress) is the Status `start` sets.
- `claimedStatuses` (In progress, In review, Needs you) are the Statuses a
  claim branch may validly have. `land` moves a claim to In review, and a
  merged claim that waits for maintainer-only validation to Needs you. A
  resumed `start` never moves a claim in one of these back to In progress.
- `activeStatuses` (In progress, In review) are the Statuses of work an agent
  is doing. The soft cap counts open issues in an active Status that do not
  carry an `excludeLabels` label. `start` and the dashboard count them with
  the same code. An issue in an active Status needs a claim branch; Needs you
  does not, because it also holds merged work and undecided questions.

The remote branch is the authority for who owns an issue. Project Status and
comments are projections of it, and the dashboard reports any disagreement
between them.

### Failure modes

`test_claim.py` checks these against a local bare remote. The live E2E covers
the GitHub side.

6. **Two agents claim the same issue at the same time and both succeed.** If
   they compute the same branch name, the create-only push admits one. If the
   issue title changed between their reads, the branch names differ. The rule
   is that the smallest ref name for the issue wins, and the loser deletes
   only its own ref.
7. **The claim is based on stale local `main`.** The work would start behind
   and the landing update would pull in unrelated changes. The claim commit's
   parent must be the freshly fetched remote tip.
8. **A resumed or repeated `start` claims twice, or takes over another
   session's claim.** The owner is read from the claim commit's trailers.
9. **An ineligible issue is claimed.** This covers an issue that is closed, an
   epic, Proposed, In progress, Done, not in the Project, or has an open
   blocker.
10. **A name is an invalid ref or an unsafe path.** Slugs come from arbitrary
    titles.
11. **Public claim text leaks a local absolute path.** The repository may be
    public.

## `verify`

`scripts/tron work verify [--jobs N] [--post] [--evidence-manifest <json>]` validates the
committed head of the current branch and writes a receipt for that exact commit.
Before loading or selecting checks, it refuses inherited `TRON_DATA_DIR` or `TRON_HOME_NAME`
that select a live Tron home. Inherited path variables that point into one are removed, and each
check runs without them; the Gateway's shared path policy applies the same rule to its Vitest
configurations and Node test scripts.

1. **Clean head.** A worktree with modified, staged or untracked files is
   refused, because the receipt describes a commit and not a working tree.
2. **Diff.** It fetches the remote base branch (on a claim branch, the claim's
   base; otherwise `claim.baseBranch`) and computes the changed paths from
   `merge-base(<remote>/<base>, HEAD)..HEAD`, deletions included.
3. **Check set.** `verify.checks` names each check with path globs and a shell
   command run from the repository root after `verify.prelude`. A check is
   required when any changed path matches its globs, or always when it sets
   `"always": true`. Every changed path must match at least one check;
   otherwise verify refuses, lists the unmapped paths and writes no receipt.
   Globs use `*` within one path segment, `**` across segments and `?` for one
   character.
4. **Placeholders.** `{paths}` expands to the shell-quoted absolute paths of the
   changed files that matched this check and still exist at the head.
   `{merge_base}` expands to the merge-base commit.
5. **Run.** Required, non-carried checks run concurrently. The default bound is
   `max(1, min(4, host CPU count, physical RAM / 8 GiB rounded down))`; if RAM
   cannot be determined, it uses one worker. `--jobs N` overrides this bound
   with a positive integer; `--jobs 1` runs sequentially. The bound does not
   replace the native tools' live-memory admission or leases: exit 73 remains
   a refusal, never an automatic retry, and lease waits count in check time.
   Checks sharing an optional `exclusiveGroup` name in `.github/work.json`
   never overlap within one invocation. Optional nonempty `exclusivePaths`
   restricts membership to diffs matching those globs (and requires a group).
   Blocked checks do not occupy workers;
   later independent checks can start. A failed check never cancels siblings.
   Start lines follow eligible configuration order; the final result lines,
   receipt and evidence table follow configuration order, not completion order.
   Each check runs in its own process group, retired on settlement or interruption.
   Its combined output goes to `<git-dir>/work/logs/<head>/<check>.log`, where `<git-dir>` is
   `git rev-parse --git-dir`, so every worktree keeps its own logs. The receipt
   is `<git-dir>/work/receipts/<head>.json`. It records the head, the base
   branch tip, the merge-base, the changed paths, a hash of the verify
   configuration, the required check set, and for each check its command, exit
   code, wall time, log path, and the commit it was carried from, if any. The
   receipt passes only when every required check exited 0. If the head moves or
   the worktree changes while checks run, verify refuses and writes no receipt.
6. **Incremental re-verify.** For each required check, verify looks for the
   nearest receipt, on the head itself or an ancestor `P`, with an identical
   configuration hash in which **that check** passed. The receipt as a whole
   need not have passed, so re-running after one failed check reruns only the
   checks that did not pass. A check is carried from `P` instead of run when it
   is not `always` and none of the paths changed between `P` and the head match
   its globs. Workers run `scripts/tron work verify` at
   their final commit, before handing off to `land`. A merge of the base carries
   unaffected checks, including already-carried checks with their original
   provenance; matching incoming paths rerun their checks. Those paths include everything an update from
   the base branch brought in. After a rebase `P` is no longer an ancestor, so
   nothing is carried. A check's globs must therefore cover everything its
   result depends on, including the scripts it calls.

`--post` then publishes the receipt:

1. It refuses unless the current branch exists on the remote at exactly the
   head.
2. It sets the commit status `verify.statusContext` to `pending` on the head,
   replacing any earlier status there before any other lookup can fail.
3. The target is the open pull request for the branch whose head is in this
   repository, otherwise the issue whose number is in the branch name
   (`<type>/<issue>-<slug>`). A fork's pull request with the same head name
   never counts.
4. Full logs and the receipt go only to the evidence repository
   `<owner>/<repo><verify.evidenceRepositorySuffix>`, derived at run time,
   under `<issue>/<head>/`. They are not scrubbed and hold local paths, so
   verify uploads nothing unless GitHub reports that repository as private.
   Each upload is a commit on that repository's branch. Concurrent lands race
   for its head, so a lost race (HTTP 409) re-reads the file and re-applies the
   same upload, at most five times; any other error fails the post.
5. The public comment has a table of checks, commands, results, wall times and
   carried-from commits, plus the last `verify.excerptLines` lines of each
   failed log. The repository root and home directory are replaced by `<repo>`
   and `~` in excerpts. The whole comment goes through `verify.scrubCommand` on
   stdin; any finding or error refuses the comment.
6. Only after the comment is posted does it set the final status: `success`
   when the receipt passed, `failure` otherwise. Any error after the pending
   status sets `failure` before verify exits.

The comment links the evidence directory with a relative link, so no owner
name is written into public text.

Exit status is 0 only when the receipt passes (and, with `--post`, the evidence
was posted).

### UI evidence

Capture screenshots or short recordings with the owning test/device tooling first,
then review their contents for secrets and personal data. Verify does not capture
screens, inspect image contents, redact media, or prove an interaction happened.
Do not submit credentials or unreviewed captures. The manifest is explicit opt-in;
no files are discovered automatically and callers without media need no new input.

Keep captures outside source control. In their directory, create a JSON manifest:

```json
{
  "head": "<full git rev-parse HEAD output>",
  "artifacts": [{"path": "screen.png"}, {"path": "interaction.mp4"}]
}
```

Run `scripts/tron work verify --evidence-manifest <manifest.json>` (add `--post`
after pushing the exact head), or pass the same flag to `scripts/tron work land`.
Paths are relative to the manifest's directory. Absolute paths, traversal,
symlinks in any path component, missing files, special files and duplicates are
refused. Use physical paths, not symlink aliases such as `/tmp` on macOS.
Only PNG, JPEG, MP4 and MOV extension/signature pairs are accepted: signatures
identify containers, not valid playback or safe contents. Limits are 10 files,
10 MiB per file, 25 MiB total, and 64 KiB for the manifest. Recording duration is
not decoded; keep clips short enough to inspect and within the byte bounds.

Before checks, verify snapshots the bounded bytes into
`<git-dir>/work/media/<head>/<sha256>.<extension>`. The receipt binds each opaque
name, byte count and SHA-256 to that head. Same-head re-verification without the
flag reuses these snapshots, even if the original capture has gone. Supplying a
manifest replaces that head's media selection. A different head never inherits
media: verify refuses when the nearest ancestor receipt contains media, requiring
a new capture and manifest. This also stops `land` after it merges a new base;
recapture against the resulting head and rerun. Check carry-over is unchanged.

Posting rechecks every snapshot before uploading anything. Missing, changed or
unsafe snapshots refuse publication instead of silently omitting evidence.
All media uses the existing private-repository gate and uploader, under
`<issue>/<head>/media/`; nothing is attached to the public repository. Public
comments and the PR's Verification section link opaque filenames in the private
repository, including when `land` opens the PR after posting its receipt to the
issue. Source filenames and local paths never appear in those links. As with
logs, a partial remote upload may remain if a later upload fails, but no success
status or evidence comment is published on that failure.

### Tron's check set

Tron's `verify` section in `.github/work.json` follows the validation commands
in `AGENTS.md` and `CONTRIBUTING.md`. The prelude puts the Node pinned by
`.node-version` from nvm first on `PATH`. Its limits are deliberate:

- **Gateway** is one check whose globs cover every build and test input:
  sources, dependencies, TypeScript and Vitest configuration, scripts, fixtures,
  protocol fixtures and the pinned Node version. A lockfile change merged from
  the base branch therefore reruns it. It runs `npm ci`, the Pi SDK cohort check
  and the build, then `vitest related` when every changed Gateway path is
  existing source or test support. That related selection runs twice, once per
  Vitest config: the parallel main pass, then the nested pass
  (`vitest.nested.config.ts`) that runs the files spawning nested Vitest or pi
  children one at a time. A nested pass runs only when a changed file is one of
  those tests or imports a changed module, and a change that no test imports runs
  only the build. Any other changed input, or a deleted or renamed Gateway file,
  runs the full suite (`npm test`, which runs both passes) instead, because
  `vitest related` cannot select a test that still imports a deleted module and
  the build excludes tests.
- **Gateway scale** runs the dedicated scale suite when one of its own
  `*.scale.test.ts` files, `vitest.scale.config.ts`, or an explicitly exercised
  Knowledge source/helper changes. It stays separate from the ordinary source
  selector so unrelated Gateway changes do not pay for the large corpus tests.
- **iOS** runs the source, build-matrix and archive-privacy policy scripts,
  then `scripts/tron-ios-test build`. For changed test files, verify derives
  their declared suites only when every non-private top-level declaration is a
  test suite; shared helpers or unrecognized syntax force the complete unit
  target. Audited Settings UI sources select their explicit owning suites.
  The fixture-only `RealGatewayPiBoundaryTests` and the fault proxy that shapes
  its cases (`scripts/ios-gateway-fault-proxy.mjs`) dispatch to the real
  `scripts/ios-gateway-e2e-test all` runner, where an ordinary run would skip
  every case.
  Any deletion or rename anywhere in the branch diff forces the complete unit
  target because `{paths}` omits files that do not exist at HEAD. Unmapped
  source paths and empty selections also run the full target. Do not infer a
  suite from a filename: an `--only-testing` selector that names no suite runs
  zero tests and passes. The full hosted suite
  remains in CI's heavy run and explicit checkpoints. The simulator admission
  and lease rules of `scripts/tron-ios-test` still apply, so a busy Mac fails
  the check with exit 73; verify again once memory is free.
- **Advisory hosted macOS CI** starts with the Linux `scope` job, which runs
  `scripts/ci_macos_scope.py` over the available event-base and checkout trees
  (no merge-base required). Recognized docs, work-tooling and push-relay-only
  changes skip macOS. Gateway inputs run the Gateway job, the hosted iOS/Gateway
  boundary and Mac packaging; iOS inputs run iOS and the boundary; Mac inputs run
  Mac. Shared workflow, protocol and toolchain inputs, unknown paths, empty diffs
  and unavailable Git inputs run all four. Deleted/renamed paths retain both
  owners. Manual dispatch runs all four, and a failed classifier or missing output
  never skips coverage. An explicit `!cancelled()` status check lets selected or
  missing-output jobs run even if an earlier job fails; an explicit `false` scope
  still skips, and workflow cancellation stops advisory work. `test_ci_scope.py`
  exercises the CLI with real Git histories and the `scope` job's selector shell,
  not GitHub's job dependency scheduler.
  The required `gateway` job runs only Gateway's install, `check:pi-sdk`, build,
  `npm test`, the Pi SDK rollback when the graph changed, and audit. The advisory
  `gateway-tooling` job runs the pi-subagents provider checks, the dev-lifecycle
  state tests, the profiler test and the payload-deploy test, each only when
  `scripts/ci_verify_scope.py` selects its check. That selector matches the
  `paths` of the same-named verify checks in `.github/work.json` through
  `tools/work/verify.py`, so CI and `scripts/tron work verify` select alike. An
  empty diff selects none, as verify does; a missing or unresolvable base, or any
  selector error, runs every check. `scripts/test-ci-verify-scope.py` covers the
  selector's real-Git cases in `policy`. `policy` needs `scope` and gates only its
  slow `profiler`, `triage` and `work-tooling` test steps on the same selector; its
  syntax checks and selector tests stay unconditional, and `!cancelled()` keeps it
  running when selection fails.
  The advisory macOS jobs also need `gateway`, so the required job never queues
  for a macOS runner behind them; they still run when it fails or is skipped.
  Jobs keep real failure conclusions;
  only `policy`, `gateway` (`land.requiredChecks`) and `tron/verify` gate `land`.
  The `main` ruleset remains
  unapplied by maintainer decision; no schedule or deployment is added.
  The workflow's concurrency group stays ref-scoped, and it cancels in progress
  only for `pull_request` events. A started base-branch push run therefore always
  finishes - its result is the evidence the epic's consecutive green `main`
  pushes need - while GitHub's one pending run per group still lets the newest
  pending `main` run supersede an older pending one. So the advisory-CI section's
  base-branch evidence is that push run's own result, not the next land's
  cancellation of it, and `land` cancels a merged pull request's own runs
  (step 8) so it stops holding the macOS queue the base push run and later lands
  need.
- **CI policy's iOS infrastructure test** uses
  `scripts/ci_ios_infra_scope.py` to skip only for recognized non-iOS paths.
  The workflow compares the available base and head trees directly (two-dot
  `git diff`); it logs the selected value and reason. iOS-app, runner/toolchain,
  CI-workflow, unknown and empty path sets run the infrastructure suite. If the
  base commit cannot be resolved or path classification fails, the workflow
  runs it. This does not change CI's hosted iOS unit suite.
- **The related-issue check** (`.agents/skills/tron-work/related-issues.js`)
  has its own `work-related-issues` check, a Node test that runs the script as
  codemode does against a Jev stand-in enforcing Jev's request bounds.
- **iOS selector tooling** has its own `work-selector-tests` check, so owner
  selection and CI path-classification tests run locally when their sources
  change, not only in GitHub Actions.
- **Mac** regenerates the project with `scripts/generate-xcode-project mac`
  (what `scripts/tron mac generate` runs) and runs `build-for-testing` and
  `test-without-building` for `TronMacTests`, as in the Mac development guide.
  Checks call the owning script directly rather than the `scripts/tron`
  dispatcher, so a dispatcher edit does not rebuild the Mac app. The isolated
  Mac script fixtures that need no staged payload run as `mac-scripts` on its
  existing paths. `mac-bundle-rebuild` runs the real bundle rebuild/refusal test
  only for packaging inputs: bundler/staging/verification helpers, launcher and
  login-item resources, Node/npm/toolchain pins, dependency manifests, provider
  artifacts/installers, and protocol/push/deploy/receipt helpers exercised by
  the build. Ordinary Gateway sources and deployment tests do not select it.
  Gateway, scale, provider verification, Mac and bundle-rebuild share the
  `gateway-source-tree` exclusive group: `npm ci` and Xcode's bundle preparation
  mutate dependencies/payloads, and the rebuild test temporarily changes a
  provider installer. Native leases alone do not protect those shared inputs.
  Ordinary iOS owns a separate simulator lane/admission and can run concurrently.
  Its `exclusivePaths` join that group only for real Gateway fixture inputs:
  those runners also install/build the in-place Gateway tree. A regression
  compares the configured paths with the iOS selection owner's trigger list,
  so adding a fixture trigger cannot silently bypass exclusion. Deploy and fast
  Mac tests own temporary fixture trees; they do not mutate the source Gateway.
  These groups serialize shared files, not all host work. Packaging coverage
  also remains in the macOS CI job.
- **Scripts** run their owning `scripts/test-*` suite where one exists. Scripts
  without an owner (`scripts/tron`, `scripts/tron-dev`, the hook installer and a
  few one-off tools) get a syntax check only.
- **`.github` workflows, forms and rulesets** get a JSON or YAML syntax check;
  GitHub validates their meaning when they run.
- The privacy guard, agent policy, documentation policy and `git diff --check`
  over the branch diff always run.

To measure sequential versus default scheduling without carry-over, use two
fresh worktrees at the same commit, running `verify --jobs 1` in one and `verify`
in the other. Each worktree has its own Git-directory receipts, so neither run
carries results from the other. This forces the checks required by that branch's
diff, not unrelated checks. Do not delete evidence or alter check inputs just to
force a measurement. Worker count is an execution choice, not a configuration
hash input: changing `--jobs` does not invalidate already-passing receipts.

### Failure modes

`ParallelCheckTests` in `test_verify.py` exercises real subprocess checks and
temporary Git histories. Its oracles are events, never wall time or the host's
size: overlap is a rendezvous (a check finishes only after its peers started),
order comes from one append-only event log, and the worker bound is the number
of checks still running at each launch, with the CPU and memory inputs mocked.
It covers independent overlap, sequential override,
exclusive-pair ordering without idle-worker blocking, aggregated failures
(including exit 73), interruption disposal, configuration validation, carried
provenance across a merge, and the Mac bundle/fast-script selection split. These
protect the scheduling and selection boundaries without starting native builds.

`test_verify.py` checks these against real temporary repositories, local bare
remotes and a fake `gh` (`WORK_GH`) that records every call. The live E2E
covers the GitHub side. `test_scale_suite_selector_is_narrow` also protects the
Tron-specific selector: a scale test path selects `gateway-scale`, while an
unrelated Gateway source does not.

12. **A stale receipt is accepted for another head.** A receipt is named by and
    records its head. `--post` publishes only the receipt it just made for the
    current head, and refuses when the remote branch is at another commit.
13. **The check set is narrowed by the diff or by carry-over.** The required set
    comes from the whole branch diff against the merge-base, not from the
    commits since the last receipt. Carried checks stay in the required set,
    and `always` checks are never carried.
14. **A crash or partial post leaves a success status.** The status is
    `pending` before any lookup or upload, `success` is set only after the
    comment exists and only for a passing receipt, and any error sets `failure`.
    A concurrent poster's evidence commit (HTTP 409) is re-applied rather than
    stopping the post (`test_concurrent_evidence_commit_is_reapplied_not_fatal`).
15. **Evidence leaks personal data.** Every public comment passes the scrub
    command first; excerpts are redacted; full logs go only to the evidence
    repository, and only when GitHub reports it as private.
16. **An incoming base-branch change is missed by carry-over.** Carry-over
    compares the globs against every path changed between `P` and the head,
    including merged base-branch changes, and carries nothing across a rebase.
17. **Unmapped paths pass silently.** A changed path that no check covers
    refuses verification.
18. **A configuration change reuses an old receipt.** Carry-over requires an
    identical configuration hash.
19. **A receipt describes content that is not the committed head.** Dirty
    worktrees are refused, and a head or worktree that changes during the run
    discards the receipt.
47. **A narrowed iOS run misses deleted inputs or shared owners.** The selector
    owns deletion detection and forces the full iOS suite for any deletion. A
    changed test file focuses its declared suites only when every non-private
    top-level declaration is a test suite and no other test file references
    those suites as `SuiteName.`; shared helpers, external references and
    unknown syntax therefore run the full target. Owner-map and the configured
    command-line invocation are covered by
    `scripts/test-ios-verify-test-selection.py`.
48. **The policy job skips iOS infrastructure for a relevant or unknown path.**
    Only recognized non-iOS changes skip that test; iOS/toolchain/workflow paths,
    an empty diff, an unclassified path, or an unresolved base run it. The
    workflow logs the decision. `scripts/test-ci-ios-infra-scope.py` covers the
    path classification.
63. **A fork's pull request receives a branch's verify evidence.** Claim branch
    names are public, so a fork can open a pull request with the same head
    name. `--post` comments on the branch's own pull request, or on the issue
    when only a fork's exists.

68. **Explicit UI evidence is lost or relabeled.** `MediaEvidenceTests` in
    `test_verify.py` runs the real CLI with files and Git, deletes the source
    capture, then reverifies and checks the exact uploaded snapshot bytes at the
    fake-gh boundary. Media survives only same-head reverify. `MediaLandingTests`
    in `test_land.py` proves the first PR links private media and a base merge
    stops for recapture before publication.
69. **Media escapes its input, storage or privacy bounds.** The same tests reject
    traversal, symlink files/directories/manifests, special/missing files,
    non-media, duplicates, count/byte overruns, malformed/stale manifests and
    changed/missing/symlink snapshots. Public evidence repositories and upload
    errors leave no media comment or success status. The fake-gh boundary is not
    live GitHub upload proof. Repeat with
    `python3 -m unittest discover -s tools/work`; retain its output alongside the
    verify receipt/logs for the tested commit.

## `dashboard`

`scripts/tron work dashboard [--html <path>] [--json <path>]` shows the state of
all work in one read-only view. It is fetched live on every run from GitHub and
local Git, and it keeps no cache or registry. Without flags it prints a short
text summary. `--html` writes one self-contained HTML file with inline CSS, no
external assets and no script, readable in a narrow phone sheet and in dark
mode. `--json` writes the same model as JSON for tests and other tools.

### Classification

Every open issue that is not an epic carries exactly one label with the
`dashboard.kindPrefix` (the kind of work, for example a bug or an idea) and
exactly one with the `dashboard.visibilityPrefix` (whether the maintainer would
notice it while using the product). The labels themselves, with their meanings,
are declared in the `labels` block of `.github/work.json`; the dashboard reads
the vocabulary from there, so a label is defined in one place. The issue that
files work sets both; triage corrects them. An idea (`dashboard.ideaLabel`) that
reaches the Ready status or a claimed status is reported, because approving an
idea makes it committed work with another kind.

### The HTML page

The page is an overview first and a drill-down second, with no script:

- a summary strip of counts that link to their sections;
- **Needs you** and **Health** (stale claims, disagreements, orphans,
  regressions, classification problems and the soft cap). Their items are
  never inside a collapsed section;
- **In progress**, one expandable row per claim with its branch, worktree,
  session and pull request checks;
- **Work**, every open issue that is not an epic plus those closed in the last
  `dashboard.recentDays`, under a kind-by-visibility count matrix. Filters for
  kind, visibility, status and area are radio buttons that CSS `:has()` applies;
  where `:has()` is unsupported the filters do nothing and every row shows.
  Ready rows keep their queue position;
- **Epics**, each expandable to its open and recently closed tasks by status.

Filter tokens come only from the declared vocabulary and Project options, never
from raw label text, and kind colors come from the declared label colors.

It reads, in a bounded number of calls:

- the Project's items (paginated GraphQL): Status, Priority and Epic rank, and
  each issue's state, labels, parent, sub-issue progress, blockers and latest
  comment;
- open issues carrying a `dashboard.needsYouLabels` label or the
  `dashboard.regressionLabel`, whether or not they are in the Project;
- open pull requests whose head branch is in this repository, with the
  combined check state of the head commit and the `dashboard.verifyContext`
  commit status;
- when `dashboard.ciWorkflow` and `dashboard.advisoryJobs` are configured, the
  latest workflow run for a push to the base branch, plus the latest run for each
  exact open same-repository PR head (fork PRs excluded). Actions run queries
  select one run; job lists use pages of 100 with a 1,000-job ceiling. Repeated
  run/job requests share the current fetch only. API errors, malformed responses
  and a job list beyond the ceiling report unavailable evidence, never success;
- the state of any issue named by a remote claim branch or a local worktree's
  claim-style branch that the reads above did not return (one aliased query);
- remote branches (`git ls-remote`), the claim owner from each claim branch's
  claim commit (the same code as `start`), and local worktrees
  (`git worktree list`).

Sections, in order:

1. **Needs you:** open issues labeled with a `needsYouLabels` label, or with
   Status `needsYouStatus`.
2. **Epics:** open issues labeled `epicLabel`, by Epic rank, with sub-issue
   progress.
3. **In progress:** issues with an active Status (`claim.activeStatuses`),
   with the Status, the claim branch, the worktree relative to the checkout's
   parent directory, the owning session, last activity, the pull request, its
   checks and its verify status.
4. **Ready queue:** Ready issues that are not epics. They are ordered by the
   Epic rank of their parent epic (or their own Epic rank when they have no
   ranked parent; unranked last), then by Priority in the order the options are
   declared, then unblocked before blocked, then issue number.
5. **Blocked:** issues with Status `blockedStatus`.
6. **Stale claims:** In-progress issues with no push to their claim branch and
   no comment on the issue or its pull request for 48 hours. They are only
   flagged, never reset.
7. **Soft cap:** the number of issues in section 3 against `claim.softCap`.
8. **Disagreements:** a claim branch whose open issue is not in one of
   `claim.claimedStatuses`, an issue in an active Status without a claim
   branch, or an issue with more than one claim branch. The branch is the
   authority; Status is its projection.
9. **Orphans:** worktrees under `claim.worktreeRoot` that are not on the claim
   branch of an open issue, and remote claim branches whose issue is closed or
   does not exist. A worktree on a claim branch whose issue is closed or whose
   remote branch is gone says that `work cleanup --all` removes it once its
   pull request merged at its head.
10. **Regressions:** open issues labeled `regressionLabel`.
11. **Advisory CI:** current run state, branch, SHA, run link and each configured
    job's state/link. Failed, cancelled, pending, missing and unavailable evidence
    is also visible under Health, outside collapsed rows. Skipped jobs remain
    distinguishable from successful jobs. Base-branch push evidence survives a
    PR's merge; PR evidence from an older head or a foreign repository is rejected.
    This is latest-run evidence, not an exhaustive unresolved-failure history:
    a newer base push supersedes the prior run, and a dispatch is not a base push.
    No local failure registry or regression issue is created.

The names it reads (statuses, labels, fields, the verify context) come from the
`dashboard` and `claim` sections of `.github/work.json`.

### Failure modes

`test_dashboard.py` checks these against recorded GitHub-shaped responses.

20. **GitHub text injects markup into the HTML.** Titles, labels and branch
    names are attacker-controlled in a public repository. Every such string is
    HTML-escaped, and only `https://` links are rendered.
21. **A Project item without usable content crashes the run or shows up.**
    Deleting an issue before removing its Project item leaves an item whose
    content is null. Such items, drafts, pull requests and issues from other
    repositories are ignored and only counted.
22. **Staleness is misjudged.** Last activity is the latest of the claim
    branch's head commit, the issue's latest comment and its pull request's
    latest comment, so a recent comment keeps an old branch fresh. A claim is
    stale only past 48 hours.
23. **A disagreement between the claim branch and Status goes unreported.**
    Each of the three kinds above is reported, and a consistent claim is not.
24. **The Ready queue is ordered wrongly.** Priority follows the declared option
    order, not the alphabetical order of names, and a parent epic's rank wins
    over the task's own.
25. **An orphan is missed, or live work is called an orphan.** A worktree on the
    claim branch of an open issue is not an orphan; a worktree outside the
    worktree root is not reported at all.
26. **Output leaks a local absolute path.** Worktrees appear only relative to
    the checkout's parent directory.
27. **A Needs-you item is missed.** A labeled issue that is not in the Project
    still appears, and closed issues do not.
28. **Pagination drops items.** Every page of Project items, pull requests and
    labeled issues is read, and the number of calls grows with pages, not with
    issues.
29. **A fork's pull request is taken for the claim's pull request.** Claim
    branch names are public, so anyone can open a pull request from a fork with
    the same head name. Only pull requests whose head is in this repository
    count toward a claim's PR, checks and activity.
30. **An orphan worktree misstates its issue.** A local worktree on a
    claim-style branch with no remote branch is reported with its issue's real
    state, not as "does not exist", even when the issue is outside the Project.
    `RunTests` drives `run` against real Git and a stand-in `gh` executable.
31. **A missing issue fails the run, or a missing repository reads as missing
    issues.** GitHub answers a lookup of a missing number with a `NOT_FOUND`
    error and exit status 1; that issue is reported as missing. A `NOT_FOUND`
    on the repository itself still fails the run.
43. **Something that needs attention is hidden.** Needs-you items and every
    health alert render outside any collapsed `<details>`, whatever the
    filters' default state.
44. **A classification problem goes unreported.** A missing kind or
    visibility, two of either, an undeclared label with either prefix, and an
    idea in the Ready status or a claimed status are each reported under
    Health; a correctly labeled issue is not.
45. **The work list drops, repeats or mislabels an issue.** Each open non-epic
    issue appears once; an issue closed within `dashboard.recentDays` appears
    and an older one does not; epics stay in their own section.
67. **Advisory CI failure or unavailable evidence disappears.**
    `test_ci_dashboard.py` drives the dashboard with real Git and a CLI-shaped
    GitHub fixture through fetch, JSON, text and HTML. It covers a failed main
    run with no open PR, a failure on a later jobs page, exact PR head and
    repository fencing, pending/cancelled/missing/unavailable evidence, and
    escaped branch text. `test_ci_scope.py` covers real Git path selection,
    shared consumers, empty/unknown/unresolved input, and deletion/rename.
46. **GitHub text reaches a filter or a style.** Undeclared or hostile labels
    never become filter tokens or class names, and a label color is used only
    when it is six hex digits.

## `issues`

`scripts/tron work issues [--closed [--closed-limit <n>]]` prints one JSON
document to stdout: every open issue, and with `--closed` the `n` most recently
updated closed issues (default 200, at most 500). Each entry has the number,
state, close reason, an epic flag (`dashboard.epicLabel`), the title, the
labels and a body excerpt with issue-form scaffolding (HTML comments, headings,
unanswered fields) removed. It is the input of a related-issue check, so it must
be complete or fail: an agent reads it back through a tool that merges stderr
into stdout and truncates at 1 MiB.

Titles are capped at 200 characters, bodies at 1,000, and the document at
900,000 bytes. Tron's related-issue check, which classifies the corpus with Jev
through Tron's codemode tool, belongs to the harness, not to this tooling. It
lives with the [tron-work skill](../../.agents/skills/tron-work/SKILL.md).

### Failure modes

`test_issues.py` runs `cli.py issues` in a real Git checkout against a stand-in
`gh` executable that honors `--state` and `--limit`.

49. **A truncated open list reads as complete.** It asks for one more than its
    limit of 500 open issues and refuses when GitHub returns that many, so a
    check never reports "nothing related" for an issue it did not see.
50. **Closed issues leak into the default corpus, or lose their state.** Closed
    issues are queried only with `--closed`, newest update first, and each
    keeps `state` and `stateReason`.
51. **The corpus overruns the agent's output bound.** A document over 900,000
    bytes is refused with nothing on stdout, never cut off mid-JSON.
52. **Success output is not pure JSON.** On success stderr is empty and stdout
    holds only the bounded corpus.

## `issue` and `project` mutations

Use these typed commands instead of direct `gh` writes:

- `issue create --title <title> --body-file <md> --kind kind:* --visibility visibility:* --area area:* [--area area:* ...] [--type task|epic]` files a task with exactly one declared kind and visibility label and one or more declared area labels, plus `needs-triage`. Repeat `--area` for each affected area. An epic receives only the `epic` and `needs-triage` labels and no task taxonomy. Titles and bodies are bounded and scrubbed before creation. A newly filed issue is not implicitly approved or added to the Project.
- `issue labels <issue> [--add <declared-label>] [--remove <label>]` changes classifications and triage labels. New labels must be declared. Issue-type labels are fixed at creation; non-epics must retain exactly one declared kind and visibility label plus one or more declared area labels. A stale undeclared label may be removed. Writes use GitHub's targeted add/remove endpoints rather than replacing a stale whole label set, so unrelated concurrent label changes are preserved. Taxonomy changes re-read under a private process lock shared by linked worktrees; ordinary flag changes can overlap safely.
- `project add <issue>` adds the issue idempotently to the configured repository-linked work Project.
- `project set <issue> [--status Proposed|Ready|Needs you|Blocked] [--priority P0|P1|P2|P3]` assigns only unclaimed statuses. `start` owns In progress, `land` owns In review and Done. Ready is only for maintainer-approved work inside approved scope after blockers close. Every requested live field and option is resolved before the first mutation; partial two-field updates report exactly which field succeeded if a request later fails, and rerunning is safe.
- `issue parent <task> --epic <epic>` creates the native parent/sub-issue relationship after validating the labels. `issue block <issue> --blocked-by <blocker>` creates GitHub's native blocked-by relation. Both are idempotent.

A new task normally follows this sequence: `issue create`, `project add`,
`project set --status Proposed --priority P2`, and optional `issue parent` /
`issue block`. Promotion to Ready is a separate, explicitly approved action.
Triage changes the complete label classification in one `issue labels` call,
then assigns Status/Priority with `project set`, and links the issue if needed.
For a maintainer decision, add `needs-decision`, set Needs you and post the
scrubbed question with `work comment`. Each GitHub mutation is individually
audited; multi-request commands explain completed fields on partial failure.
Each REST label delta and Project field mutation is audited separately; when a
later request fails, the command identifies completed label deltas or fields.
No generic argument passthrough is provided.

`test_tracking.py` uses the real CLI boundary with an executable GitHub stand-in
to exercise issue filing with multiple areas, taxonomy authorization, area
preservation during unrelated flag changes, overlapping independent label
additions, Project add and field selection, parent/blocker links, audit
completeness, live-option preflight and partially completed Project updates.
Controlled reads prove concurrent flags survive on the remote fixture, and
schema drift proves no field is changed before validation completes. The
stand-in does not substitute for live API/schema validation.

## `comment`

`scripts/tron work comment <issue> --body-file <markdown>` posts one public
issue comment. It accepts only a positive issue number and a nonempty UTF-8 body
up to 64 KiB. The configured privacy guard runs before any GitHub call; a
refusal reports only that the guard refused, not the guard's potentially
sensitive matching lines. The command requires `WORK_SESSION_ID` or
`PI_SESSION_ID` and appends a work-session marker, so milestone comments retain
agent attribution. The comment is sent on stdin rather than as a process
argument. The common `Gh` boundary audits the operation without retaining its
body. This is the supported agent path for reproduced, candidate, blocked and
other milestone evidence; GitHub reads remain available through read-only
commands.

## `land`

`scripts/tron work land [--title <title>] [--summary-file <path>]
[--needs-user-validation <text> --irreducible <part>]
[--acceptance <journey-id>[,<journey-id>]] [--session <id>]` merges the current
claim branch. The agent that owns the claim runs it from its task worktree once
the work is committed. The `land` section of `.github/work.json` configures it,
as does `acceptance` for the journeys it can run.

1. **Gates.** Before any GitHub write, `land` refuses when:
   - the current branch is not a claim branch on the remote, or its claim
     commit names another session (the session is resolved as in `start`);
   - the worktree has modified, staged or untracked files, HEAD is detached,
     or a merge, rebase, cherry-pick, revert or bisect is in progress;
   - the issue is closed or not in the Project;
   - the open pull request for the branch merges into another base than the
     claim's, or an open issue's claim starts from this branch
     ([The claim's base](#the-claims-base));
   - no pull request is open for the branch and `--summary-file` is missing;
   - `--needs-user-validation` is given without `--irreducible`, or
     `--irreducible` without `--needs-user-validation`;
   - `--acceptance` names no journeys, or an id the registry does not hold;
   - the scrub command (`verify.scrubCommand`) finds anything in the title,
     the summary, the validation text or the acceptance evidence;
   - an issue labeled `kind:bug` has a Summary without exactly one non-empty,
     top-level `## Repro`, `## Cause` and `## Fix` section in that order. Fenced
     examples, nested headings and a user-authored `## Verification` do not
     satisfy this contract. The separate `## Verification` section is generated
     from the passing receipt. This is checked before publication, push or PR
     create/edit; adopting an existing PR, resuming a merged PR and stewarding a
     merge check the stored body too. Other issue kinds keep the existing freeform
     summary contract.
2. **Update.** It fetches the remote base branch and, when the branch does not
   contain its tip, merges it in. It merges rather than rebases, so the
   incremental re-verify can carry over checks whose inputs did not change. On
   a conflict it stops and leaves the merge for the agent to resolve and
   commit; running `land` again continues.
3. **Acceptance.** With `--acceptance`, it runs each named journey against the
   head it is about to verify, and refuses unless every report proves that run:
   the run wrote it, it names the registered journey, the journey passed, its
   evidence is complete, its stamped source revision is that head, its stamped
   source is not dirty, and it carries a source fingerprint. A journey that
   fails, passes its registry bound, or leaves a report that does not name that
   head stops `land` with nothing pushed, posted or merged (see
   [Acceptance journeys](#acceptance-journeys)).
4. **Receipt.** It runs `verify` and stops on a failing receipt. It then
   pushes the branch (fast-forward only) and posts the receipt as
   `verify --post` does.
5. **Pull request.** It opens one pull request for the branch, or updates the
   open one. A pull request from a fork never counts.
   - The title is `--title`. Otherwise a new pull request is titled
     `<type>: <issue title>`, where `<type>` is the branch type, and an
     existing one keeps its title.
   - The body is `Closes #N`, a Summary section and a Verification section.
     The summary is the Markdown in `--summary-file`; an update without it
     keeps the current summary. The Verification section lists each receipt
     check with its result, wall time and the commit it was carried from, and
     with `--acceptance` also each journey with the sha256 of its report and
     its summary fields. No report path is published.
   - With `--needs-user-validation` the body says `Refs #N` instead, so the
     merge does not close the issue. It also ends with a Maintainer validation
     section holding the irreducible part and then the check, so both are on
     GitHub before the merge.
   - The body holds only text the scrub command has passed: the title,
     summary, validation text and acceptance evidence in step 1, and receipt
     fields that the receipt comment's scrub passed. The issue's Project
     Status becomes `land.reviewStatus`.
6. **Wait.** It polls the pull request every `land.pollSeconds`, for at most
   `land.waitSeconds`. It waits until every check run named in
   `land.requiredChecks` and the `verify.statusContext` status succeed on the
   pull request's head, and that head is the commit it pushed. A required job
   that CI skipped because the change does not touch its inputs counts as
   passed, as in GitHub's own required-check rule. A required check that fails
   or is cancelled stops `land` and names the check. A timeout also stops it.
   A pull request that GitHub reports as conflicting stops `land` at its first
   poll and names the base to merge; hosted checks never run on it. Neither
   merges.
7. **Base moves.** Once the checks pass, it fetches the base branch again.
   When the head no longer contains its tip, steps 2 to 6 repeat, at most
   `land.maxRounds` times in all, and the journeys run again against the new
   head. Until a branch rule requires up-to-date branches, this check is the
   only guard, and a move in the second between it and the merge call is not
   caught.
   - No round is needed, and the head is merged as verified, when no
     `--acceptance` journey was requested and all three hold: no path in `git diff --name-only --no-renames <merge-base> <tip>`
     matches a non-always check in the receipt's `required` list (on the
     current `verify.checks`); `.github/work.json` is not among those paths;
     and `git merge-tree --write-tree <head> <tip>` exits 0. Then land prints
     `moved:` naming the verified head and continues to the merge.
   - This rests on the assumption that a check's globs cover every input its
     result depends on, the same assumption verify's carry-over relies on. A
     required check keeps its inputs, since no incoming path matches it. A check
     the branch does not require had inputs the branch left untouched, and it
     already passed on the base. Always-run checks read the branch diff, which the
     move leaves alone. The merged tree itself is never checked; GitHub composes
     it from the base and the branch's diff. A check whose globs miss an input it
     reads can let such a move merge unverified. Journeys are cross-area runs
     whose inputs no glob describes, so any move reruns them in a new round.
8. **Merge.** It squash-merges with `--match-head-commit`, so GitHub merges
   only the commit that was verified. The subject is the pull request title
   plus ` (#N)` unless the title already has it, and the body is `Closes #N` or
   `Refs #N`. `land` never uses `gh pr merge --delete-branch`, which checks out
   the base branch and fails in a linked worktree. Once the branch ruleset
   requires up-to-date branches and these checks, GitHub auto-merge could
   replace the wait in step 6; `land` does not rely on it.
9. **After the merge.** Once GitHub reports the pull request as MERGED:
   - It cancels the merged pull request's own queued or in-progress runs for the
     merged head and branch, `pull_request` runs only, one reported line per run. The
     merged run is stale and its macOS jobs hold the queue later lands need.
     This is best effort: a failure to list or cancel the runs is printed as a
     warning and never fails a land that already merged.
   - With `--needs-user-validation`, it reopens the issue if GitHub closed it.
     It then comments the irreducible part and the exact text, adds
     `land.userValidationLabel` and sets Status to
     `dashboard.needsYouStatus`. The issue stays open until the maintainer
     confirms.
   - Otherwise, it closes the issue if GitHub has not, with a comment naming the
     pull request and the merge commit, and the base when it is not
     `claim.baseBranch`. Status becomes `land.doneStatus`.
   - It deletes the remote branch with a lease on the merged head. A branch
     that is already gone (the repository may delete merged branches) is fine;
     a branch at any other commit, including one pushed to just before the
     delete, is kept and reported.
   - It prints `work cleanup`, which the owner runs from the worktree once
     it is done there. Removing the worktree and the local branch is
     `cleanup`'s job, not `land`'s.

Running `land` again after a stop before the merge resumes: it reuses the open
pull request and the carried checks.

Running `land` again after a stop once GitHub reported MERGED finishes step 9
and nothing else. Before the claim check it looks for a pull request from the
branch in this repository that GitHub merged into the base branch at exactly
the local head. When there is one:

- the claim commit is read from the local history, because the remote branch
  may already be gone;
- the merged pull request's body decides the outcome: `Closes #N` closes the
  issue, and `Refs #N` hands it off with the text of its Maintainer validation
  section. A `--needs-user-validation --irreducible` section that differs from
  the body's is refused; `--title`, `--summary-file` and `--acceptance` are
  ignored, because the merged body already cites the journeys it ran;
- nothing is verified, pushed, posted or merged again, and a handoff comment
  already on the issue for that pull request is not posted twice;
- an outcome an earlier run finished and the maintainer changed since is left
  alone: a handed-off issue that has the handoff comment and is closed, or a
  closed issue that has its `Landed in #<pull>` comment and is open again.
  Only the branch is still deleted.

The error of a stop after the merge says that running `land` again finishes
it, and also names the steps left to do by hand (close the issue or hand it
off, set Status, delete the branch). With `--needs-user-validation` it repeats
the section, which is also in the pull request body. A stop after a
`steward --land` merge names only the steps by hand.

### Acceptance journeys

`--acceptance` takes comma-separated ids the repository's registry holds, and
runs them in the order given. The registry is one declarative section of
`.github/work.json`; nothing else in the tooling names a journey, a framework
or a language:

```json
"acceptance": {
  "evidenceEnv": "HARNESS_EVIDENCE_DIR",
  "journeys": {
    "journey-id": {
      "journey": "<the journey name this id runs and its report must name>",
      "command": "<shell command, run from the repository root>",
      "report": "<its report.json, inside the evidence directory>",
      "timeoutSeconds": 1800
    }
  }
}
```

`land` runs the command with `evidenceEnv` in its environment pointing at
`<git-dir>/work/acceptance/<head>`: one directory for every journey of the head
being landed, beside verify's receipts and logs, so a second journey reuses the
fixture state and dependency install the first one paid for. `{journey}` in a
command expands to the entry's `journey`, so the name is written once. `report`
is relative to the evidence directory, and `land` copies the bytes it validated
to `<journey-id>.report.json` there, because the next run in the directory
replaces the link that report path resolves through.

A report is JSON. `land` refuses it unless the run wrote it (the resolved path,
inode and modification time at the declared report path must differ from what
was there before the command ran), it names the entry's `journey`,
`journey_status` is 0, `evidence_complete` is true, `source.revision` is the
head being landed, `source.dirty` is false, and `source.source_fingerprint` is a
non-empty string. Those fields are the run's own statement of what it did and
which source state produced it: `revision` binds the run to that head, while
`dirty` and the fingerprint rule out content beyond it (a clean worktree's
fingerprint is the fixed clean-state value). The harness that writes them proves
its build products against the live source state before it runs the journey.
The reports and their digests stay local; the pull request's Verification
section carries each report's sha256 with its summary fields, and no report
path, so a reviewer can compare the digest and re-run the journey with the same
command.

`timeoutSeconds` is the wall-clock bound on that one command, setup included.
A journey that passes it is stopped with SIGINT — never SIGKILL, because the
harness stops its fixture and the lease holder releases the simulator lane only
while they run their own wind-down — and `land` reports the expiry instead of
proceeding. A journey still running 120 s after that SIGINT is named with its
PID and left for the agent to stop. The same holds for an interrupt: a journey
shares `land`'s terminal process group, so `land` waits for it to finish its own
wind-down and only then re-raises, rather than killing the holder and leaving
the lane booted.

Screenshots and recordings are not attached from a journey. `--evidence-manifest`
remains the explicit opt-in it is ([UI evidence](#ui-evidence)); exporting a
manifest from a result bundle is not part of this path, which is the one
residual of the journey evidence. A head's evidence directory is not pruned
while the worktree lives either: result bundles and fixture state accumulate
under `<git-dir>/work/acceptance/` until `work cleanup` removes the worktree.

### Tron's acceptance journeys

`.github/work.json` holds Tron's registry: `evidenceEnv` is
`TRON_IOS_E2E_STATE_DIR`, and the two ids `real-gateway-pair-and-chat` and
`real-gateway-wrong-pairing-code` run the real-UI journeys of
`scripts/ios-gateway-e2e-test` (`run-ui`) with
`results/latest-ui/report.json` as their report. Their commands, the journey
names they run and their bounds are the config file's, not this document's.

Tron's iOS verification routes those two journeys to the same `run-ui` command
([Tron's check set](#trons-check-set)). A journey for another layer is added to
that registry with the command a developer would run by hand, the journey name
its report carries, and the report it leaves.

### Maintainer validation handoffs

`--needs-user-validation <text>` is the maintainer-only check itself, and it
requires `--irreducible "<part>"`: the part no acceptance journey can prove,
such as real third-party consent, the maintainer's own route, or
physical-device-only behavior. `land` refuses either flag without the other,
before any GitHub write, and states both in the pull request body and the
handoff comment. A value that is empty or whitespace counts as absent, so a
blank `--irreducible` cannot stand in for a named part.

Installing or deploying a build is a deployment step, not validation: state it
in the summary, next to the handoff, never as the check the maintainer is asked
to perform. The handoff comment keeps its `<!-- work:needs-you pull=N -->`
marker exactly as it is; #334 types that marker with the runner and the
deployment prerequisite it needs, and re-marks existing handoffs by hand, so
nothing here writes a second marker format.

## `steward`

`scripts/tron work steward [--land <issue>]` looks after pull requests whose
owner session may have ended. It runs only when someone asks; there is no
schedule.

Without `--land` it only reports. For each open pull request from a claim
branch in this repository, it lists:

- the issue, branch and claim session;
- the state of the required checks and the verify status on the head;
- unresolved review threads;
- the age of the head commit;
- whether a local worktree has the branch checked out.

`--land <issue>` merges that issue's pull request as `land` would (steps 7 and
8), but only when all of these hold:

- the verify status and every required check succeed on the pull request's
  head;
- the pull request merges into the claim's base, and the head contains that
  branch's tip;
- no open issue's claim starts from the branch;
- the remote branch is at that head;
- any local worktree on the branch is clean and at the same commit;
- the body starts with `Closes #N` or `Refs #N`, as `land` writes it. A
  `Refs #N` body is a validation handoff: it merges with `Refs #N` and hands
  the issue off with the text of the body's Maintainer validation section,
  which must be present and pass the scrub command before the merge. A
  `Closes #N` body with that section is refused.

The steward never runs checks, merges the base branch or pushes commits. That
work belongs to the owner's worktree. A pull request that needs any of it has to be
resumed by a session that claims it.

### Failure modes

`test_land.py` checks these against real temporary repositories, local bare
remotes and a fake `gh` (`WORK_GH`) that keeps pull request, check, issue and
Project state and records every call. The live E2E covers GitHub itself.

32. **Another session's claim is landed.** `land` refuses unless the claim
    commit of the current remote branch names the caller's session.
33. **A dirty or mid-merge tree is landed.** Uncommitted or untracked files, a
    detached HEAD, or a merge, rebase, cherry-pick, revert or bisect in
    progress refuse before any GitHub write.
34. **A failing or stale receipt is merged.** Nothing is pushed, posted or
    opened after a failing receipt. The merge names the verified and pushed
    head with `--match-head-commit`.
35. **A red or pending required check is merged.** `land` merges only after
    every required check run and the verify status succeed on the pushed head.
    A scope-skipped required job counts as passed; a cancelled one stops `land`.
    A failure or a timeout stops `land` without merging.
36. **The base branch moves between the check and the merge.** A base tip
    the head lacks once the checks pass starts another round, unless step 7
    finds that it shares no required check with the branch (failure mode 81);
    the merge names the head it verified. A conflict stops `land` with the merge
    left in progress and nothing pushed.
37. **A pull request body leaks personal data.** The scrub command sees the
    title, summary and validation text before any GitHub write. The rest of
    the body is receipt fields that already passed the scrub of the receipt
    comment, which is posted first.
38. **The issue is left open or wrongly closed after the merge.** Without
    validation, an issue GitHub left open is closed. With validation, the body
    says `Refs #N` and a closed issue is reopened.
39. **The remote branch is deleted before the merge or at a moved head.** The
    branch is deleted only after GitHub reports MERGED, and only with a lease
    on the merged head, so a push between the check and the delete keeps it.
40. **The Needs-you handoff loses the action text.** The exact text is in the
    pull request body before the merge and is commented on the issue with the
    label and Status. It is scrubbed before the merge, so the scrub cannot
    refuse it afterwards, and a failure after the merge repeats it in the
    error.
41. **The steward lands without a passing receipt.** `steward --land` merges
    only a head with a successful verify status and required checks, that
    contains the base tip, that no local worktree has moved past, and whose
    body closes or refers to that issue and not one whose number starts with
    it. It never runs checks.
42. **A claimed status is misread.** An In review or Needs you claim is not a
    disagreement, a resumed `start` does not move it back to In progress, and
    `start` and the dashboard count the soft cap alike.
64. **The steward loses, invents or skips a validation handoff.** A `Refs #N`
    pull request merges with `Refs #N`, keeps the issue open and hands it off
    with the exact text of its Maintainer validation section, not a summary
    heading of the same name. A `Refs #N` body without that text, a `Closes #N`
    body that has it, and text the scrub refuses stop before the merge.
65. **A land stopped after the merge cannot finish, finishes twice or finishes
    the wrong thing.** Run again, it finishes from the merged body even when
    GitHub deleted the branch, without verifying, pushing, posting or merging
    again, and posts the handoff comment once. It does not reopen a handed-off
    issue the maintainer closed or close one the maintainer reopened after an
    earlier run finished it. Another session's claim and a
    validation text that contradicts the merged body are refused. A merge at
    an older head or from a fork is not a resume.
66. **A merged pull request's own runs keep holding the queue.** After the
    merge (a resumed `land` and `steward --land` share the same after-merge
    step), `land` cancels the merged branch's queued or in-progress
    `pull_request` runs at the merged head and reports one line per run.
    Completed runs and runs of another event, head or branch are left alone. A refused run list or cancellation is a warning, and never fails
    a land that already merged.
71. **An acceptance report does not prove the head being landed.** `land
    --acceptance` runs each registered journey against the head it is about to
    verify and refuses unless the run wrote the report (its resolved path,
    inode and modification time differ from what was at the declared report
    path before the command ran), the report names the entry's journey, and it
    says the journey passed, left complete evidence, ran from exactly that
    revision with no dirty source flag and carries a source fingerprint. A
    journey that exits 0 without writing is refused rather than judged on an
    earlier run's report. A failure stops land before the receipt is pushed,
    before the pull request is written and before the merge, and the bytes it
    refused stay inspectable under the journey's own name in the head's
    evidence directory.
72. **A journey that never finishes holds the lane.** Every registry entry
    declares `timeoutSeconds`, the wall-clock bound on its command. On expiry
    land sends SIGINT, waits for the harness and its lease holder to release the
    fixture and the simulator lane, and reports the expiry without proceeding;
    it never SIGKILLs a journey, which would skip that release. A journey still
    running after the wind-down grace is named with its PID and left for the
    agent to stop. An interrupt behaves the same way: land waits for the
    journey's own wind-down and then re-raises.
73. **An unknown journey id is run.** `--acceptance` admits only ids the
    registry holds, refuses a value with an empty id, and names the registered
    ids it refused, before any journey runs or any GitHub write happens.
74. **A handoff asks for work a journey could have done, or names no
    irreducible part.** `--needs-user-validation` is refused without
    `--irreducible` and `--irreducible` without it, before any GitHub write, and
    a value that is empty or whitespace counts as absent rather than naming a
    part. The pull request body's Maintainer validation section states the
    irreducible part and then the check, and the handoff comment carries both;
    a resumed land compares that whole section with the merged body, so a
    resume cannot quietly drop or change the irreducible part.
79. **A malformed bug summary is published or merged.** `test_land.py` runs
    the real `cli.py land` process against its isolated Git/fake-GitHub fixture.
    It refuses missing or empty sections (including headings/content hidden in
    comments, a sibling heading with no section body, empty fenced blocks,
    unclosed comments/fences and fence trailers that are not valid closers),
    reordered/nested/fenced headings, duplicate wrapper headings and a
    user-supplied Verification heading before publication. It checks adopted
    open and merged PR bodies as well. Only CR/LF Markdown line endings split
    lines; Unicode separators remain text. ATX headings and fence delimiters
    accept valid zero-to-three-space indentation only; four-space and
    tab-indented code is never structural. Closing ATX hashes require preceding
    whitespace, and raw `<pre>` blocks remain literal rather than supplying
    sections. A closing fence may trail only ASCII spaces or tabs; other Unicode
    whitespace is payload, not a delimiter. Raw `<pre>` blocks keep their
    contents literal, and an unclosed raw block is rejected so it cannot hide
    generated sections. Non-empty fenced evidence—including heading-shaped
    literal output—and balanced harmless comments remain valid.
    Valid non-bug summaries remain unchanged;
    stewarding and merged-resume paths preserve the generated Verification and
    Maintainer validation sections.
80. **A conflicting pull request waits out the timeout.** GitHub reports a pull
    request that conflicts with its base as `CONFLICTING` and runs no checks on
    it, so waiting never finishes. `land` stops at the first poll, names the
    base and says to merge it into the branch, resolve, commit and run land
    again. Nothing merges. `UNKNOWN` (GitHub still computing mergeability) keeps
    waiting.
81. **A base move merges unverified, or costs a round it cannot affect.** Step 7
    merges a moved base without another round only when its three conditions
    hold. `test_land.py` (`BaseMoveTests`) runs the real `land` against the fake
    GitHub. A move into a path a required check covers starts another round, and
    so does one touching `.github/work.json` or one that conflicts textually with
    a branch path that only always-run checks cover; that last round stops at the
    merge conflict. A move into paths no required check covers merges with one
    round, and the `moved:` line names the verified head. With `--acceptance`,
    any base move starts another round: journeys are cross-area runs whose inputs
    no glob describes.

## `cleanup`

`scripts/tron work cleanup [--all] [--dry-run]` removes a task worktree, its
local branch and its remote branch once the work is provably done. The owner
runs it from its task worktree after `land`; `--all` goes through every
worktree under `claim.worktreeRoot`. `--dry-run` reports the same decisions
and changes nothing. The `cleanup` section of `.github/work.json` configures
it.

A worktree is provably done when all of these hold:

- it is a linked worktree under `claim.worktreeRoot`, never the primary
  checkout, on a claim branch (`<type>/<issue>-<slug>`), and not locked;
- the branch head is accounted for, in either of two ways:
  - GitHub reports a pull request from that branch in this repository MERGED
    into the claim's base, and that pull request's head is the local branch
    head. Ancestry is not used, because a squash merge leaves the branch head
    outside the base branch;
  - or the issue the branch claims is CLOSED and the branch holds nothing
    beyond the one claim commit `start` created for it. That commit is
    identified as `start`, the dashboard and `land` identify it: the only
    commit in `<remote>/<base>..HEAD`, carrying both the issue's
    `Work-Claim-Issue` and `Work-Claim-Session` trailers, and empty. `start`
    makes it with `commit-tree` on the base tip's tree, so it has one parent
    and the same tree as that parent; the content is what proves the claim
    spent, because work amended or squashed into the commit keeps its message
    and trailers. This is how an evidence-only task, which produces no pull
    request, proves itself spent. A later base branch tip is not another
    commit of this branch, so a claim made before it still qualifies. An open
    issue, any commit beyond the claim, a single commit without that marker
    for the issue, a single commit carrying changes, and a `<remote>/<base>`
    that cannot be resolved all keep the worktree;
- the worktree has no modified, staged or untracked files, and no merge,
  rebase, cherry-pick, revert or bisect in progress;
- every ignored file matches a `cleanup.regenerableIgnored` glob. These are
  Git `glob` pathspecs: `*` stays within one path segment and `**` crosses
  segments. Any other ignored file keeps the worktree and is named;
- no process has its working directory inside the worktree (`lsof`), other
  than `cleanup` and its ancestors when the worktree is the one `cleanup` was
  started from. When `lsof` fails, nothing counts as proven.

For a worktree that is provably done, `cleanup`:

1. runs each `cleanup.releaseCommands` entry from inside the worktree, in its
   own process group, bounded by its `timeoutSeconds`. These release what the
   worktree's own tooling holds outside it. A non-zero exit or a timeout keeps
   the worktree and prints the end of the command's output;
2. checks every condition above again, since the commands take time. A claim's
   proof re-reads the issue state, because an issue can be reopened while a
   release command runs; a merged pull request cannot unmerge;
3. gives the owner read, write and search permission on every directory in the
   worktree through no-follow descriptors, so a replaced directory name cannot
   redirect permission changes outside it. Read-only generated output (the
   staged Mac Gateway payload is published 0555) cannot stop removal part way,
   after Git has already dropped the registration. A directory it cannot open
   keeps the worktree;
4. runs `git worktree remove` without `--force`. Git deletes the regenerable
   ignored files with the worktree;
5. deletes the local branch only if it is still at the head that proved it
   done (`git update-ref -d <ref> <head>`), then its `branch.<name>` settings
   in the shared Git config. The head check guards the short window after step
   2; while the branch is checked out, the recheck already covers it;
6. deletes the remote branch with a lease on the head that proved it done —
   the merged head, or the claim commit — as `land` does. A branch already
   gone is fine; a branch at any other commit is kept and reported.

Any other worktree is never touched and no release command runs for it.
Without `--all`, `cleanup` refuses the current worktree with its reasons.
With `--all`, each worktree under the root that is not provably done is listed
with every reason, and an error while checking or removing one worktree, such
as a failed `gh` call, keeps that worktree with the error and goes on to the
next. `--all` never lists the primary checkout, and only counts the worktrees
outside the root, leaving them to the repository's own housekeeping procedure.
Local paths are printed relative to the checkout's parent directory.

Exit status is 0 when the current worktree was removed (or would be), and with
`--all` when every provably done worktree was removed. A blocked current
worktree, or a removal that stopped part way, exits 1.

### Tron's release commands

`scripts/ios-gateway-e2e-test clean` stops the worktree's Gateway E2E fixture
and removes its fixture directory, focused DerivedData and simulator.
`scripts/tron-ios-test clean` removes the worktree's test lane simulator, its
runs and its products. Nothing else reclaims the E2E fixture once the
worktree is gone. The regenerable globs cover dependency installs, build
output, DerivedData, Python caches, the CI tool cache, test results, the
generated Xcode projects, and the staged Mac Gateway payload with its Login
Item launcher and icon (`bundle-gateway.sh` rebuilds them). Other ignored
files, such as agent state under `.pi/` or logs, keep the worktree for a person
to look at.

### Failure modes

`test_cleanup.py` checks these against real temporary repositories, linked
worktrees, a local bare remote and a fake `gh` (`WORK_GH`).

53. **Unmerged work is removed.** Only a pull request from the branch in this
    repository, MERGED into the base branch at exactly the local head, proves
    the work landed. No pull request, an open or closed-unmerged one, one
    merged at an earlier head, a local commit after the merge, a fork's pull
    request with the same head name, or a merge into another base keeps the
    worktree.
54. **Local data is lost with the worktree.** Modified, staged or untracked
    files, a non-regenerable ignored file, an operation in progress, or a lock
    keeps it. Ignored files that match the regenerable globs do not.
55. **A live process loses its working directory.** Another process with its
    working directory inside keeps the worktree, and so does an `lsof` that
    fails. The caller's own shell does not block its own cleanup, but an
    ancestor working inside another worktree blocks that one under `--all`.
56. **Something outside the managed set is touched.** The primary checkout,
    worktrees outside the root, detached heads and branches that are not claim
    branches are never touched, and blocked worktrees get no release command.
    `--all` lists each worktree under the root with its reason, never lists
    the primary checkout, and only counts the worktrees outside the root.
57. **A failing or hanging release command is ignored.** A non-zero exit keeps
    the worktree, and a command past its timeout has its process group killed
    and keeps it too.
58. **A branch that moved is deleted.** The remote branch is deleted only
    with a lease on the head that proved the worktree done. A remote branch
    pushed to after the merge, or after the claim commit, is kept and reported.
59. **The worktree changes between the check and the removal.** A commit or a
    new file made while the release commands run keeps the worktree.
60. **A dry run changes something.** `--dry-run` runs no release command and
    removes nothing.
61. **A deleted branch leaves its settings behind.** `start` creates task
    branches with `--track`; removing one also removes its `branch.<name>`
    section from the shared Git config.
62. **One worktree's error hides the rest.** Under `--all`, a failure while
    checking one worktree keeps it with the error, and every other worktree
    is still decided and listed.
66. **Read-only generated output strands a removal.** A merged worktree whose
    staged Mac Gateway payload is published read-only (directories 0555, files
    0444) is removed, under the repository's own ignore rules and regenerable
    globs. Neither an existing symlink nor a directory swapped for a symlink
    during permission opening changes anything outside it. A kept, dry-run,
    failed-release or failed-recheck worktree keeps its read-only tree as it was.
    After assertions, fixture teardown walks the surviving payload without
    following symlinks, including directories renamed by the controlled race;
    captured pre-race names would leave read-only children behind on Python 3.9.
70. **An evidence-only claim is removed while its branch still holds work, or
    kept after it is spent.** `test_cleanup.py` removes a claim worktree whose
    issue is CLOSED and whose branch is nothing but its empty claim commit,
    including after the base branch has moved on, and keeps it for an open
    issue, a `<remote>/<base>` it cannot resolve, any commit beyond the claim, a
    single commit carrying no claim marker for the issue, a single empty commit
    that is another issue's claim, and work amended or squashed into the claim
    commit, which keeps its message and trailers. It also keeps a modified,
    untracked or non-regenerable ignored file, an operation in progress, an
    issue reopened while a release command ran, and a failed `gh` lookup, under
    `--all` per worktree and, for one worktree, before anything is touched. With
    no pull request the claim commit is the whole proof, so the remote claim
    branch keeps its lease on exactly that commit, as for a merged worktree, and
    a dry run of the same proof changes nothing.
