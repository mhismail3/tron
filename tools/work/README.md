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
| `start <issue> [--integration] [--base REMOTE-BRANCH]` | Claims an open, unclaimed issue: pushes a canonical claim commit to `claim.remote`, sets Status In progress, comments the claim, and creates its worktree under `../tron-worktrees/`. Ordinary start excludes epics; maintainer-approved epic integration uses `--integration`. `--base` selects a branch on the configured remote; its name is recorded as `Work-Claim-Base` and the claim commit's parent pins the exact starting commit. Without it the configured base is used. A session resumes its own claim from that immutable creation receipt, including after handoff or a base advance. Closed issues and open blockers remain refused. Never create manual ownerless epic/custom-base branches. This is not adoption: unknown/live claims must go through supported handoff. |
| `handoff <issue> --reason TEXT [--session ID] [--force-maintainer]` | Transfers an existing claim in place; preserves the registered worktree and dirty files. Automatic transfer requires authoritative terminal settlement evidence from `packages/gateway/dist/client/work-owner-status.js`; unknown `no-report` work is eligible only when the Gateway's `ownerSettlement` proof validates its canonical task marker, invocation start/terminal receipts, and successful subagent settlement for the same task, session, and operation (including a successful join with zero stops). The helper rechecks task identity, lifecycle, operation and proof before accepting. A terminal task with zero projected live runs is not independent settlement proof. This requires both a rebuilt helper and a Gateway running the updated Home status projection; an older Gateway omits the proof and therefore fails closed. Prepare the helper with `scripts/tron-node exec npm --prefix packages/gateway run build`. The helper defaults `TRON_GATEWAY_HOST` to the local Tailscale address, matching terminal chat. Set `TRON_GATEWAY_HOST=127.0.0.1` when querying a loopback-bound development Gateway, or set it to a literal IP assigned to this Mac; it refuses other hosts before reading the local credential or opening a socket. Maintainer override requires a real TTY and exact typed confirmation. A legacy claim with no owner is `unknown`, never automatically transferable; this includes both a claim commit with no owner trailer and an established claim-style remote branch with no claim commit or claim trailers at all. The branch name plus the matching registered worktree and exact local/remote head identify the existing claim; they do not invent an old session identity. A maintainer can recover it only with `--force-maintainer` and the exact prompt `HANDOFF #<issue> FROM unknown`. This records `unknown` as the prior owner; it does not invent an identity or liveness result. The public audit includes old/new owner, reason, and exact transition commit SHA. Local and remote claim heads must match exactly (except a verified partial handoff retry); an unpushed or divergent local head is refused even with force. Only a clean descendant candidate with a settled owner can use `recover` below before ordinary handoff. |
| `recover <issue> --expected-local SHA --expected-remote SHA --reason TEXT` | Publishes an exact clean descendant candidate as **unverified work**, without transferring ownership or changing local history. Requires the same known claim at both full commit IDs and canonical owner/children settlement; there is no force override. See [candidate recovery](#candidate-recovery). |
| `release <issue> --reason TEXT [--force-maintainer]` | Gives up a stale claim on an **open** issue: preserves the claim's work, deletes the remote claim branch with an exact lease, posts an audited comment, sets Status back to Ready and removes the worktree and local branch. The issue stays open and unclaimed. Refuses a live or indeterminate owner; an idle Gateway session or a legacy owner needs the maintainer's `--force-maintainer`. See [`release`](#release). |
| `release --stale [--dry-run]` | Sweeps every open-issue claim idle for more than 72 h and releases, through the same path, each one whose owner is `absent`. See [stale sweep](#stale-sweep). |
| `land --summary-file <md> [--title T] [--tests CMD]... [--ready] [--dry-run]` | Merges `origin/main` in, runs the [gate](#gate) on the merged tree, pushes the branch, opens or updates its pull request (title = `--title` or the issue title; body = the summary file, verbatim), squash-merges at the verified commit, deletes the remote branch, and closes the issue as completed with Status Done. A draft pull request refuses before the merge unless `--ready`, which marks it ready for review only after verify and the exact-head publication, re-reads it, and merges nothing if it is still a draft. An issue with open sub-issues (an epic) is left open and `land` lists them: close each fulfilled child with `work issue close`, then the epic. Prints `merged: <commit>`. |
| `cleanup [--all] [--dry-run]` | Removes a task worktree and its branches once its pull request merged at its head (or its issue is closed and it holds only its claim commit). Names what it keeps and why. |
| `dashboard [--html P] [--json P]` | Read-only view of claims, Status, epics, stale claims, paused epics, past exit dates, orphans, classification gaps and main CI. |
| `comment <issue> --body-file F` | Privacy-checks, then posts a public issue comment. |
| `issue create\|edit\|labels\|close\|reopen\|parent\|block` | Files issues and changes labels and links; see [filing](#filing). `edit <issue> [--title T] [--body-file F]` replaces a title or body (privacy-checked). `close` posts a comment, closes, and sets Status Done. Epics may close only when all linked children are closed (every page is checked before any write, for either close reason). `reopen <issue> --comment-file F` requires the reason as a non-empty, privacy-checked comment, posts it with an audit marker, reopens, and sets Status In progress when the issue is claimed (claims are left as they are) or Ready otherwise; it refuses an open issue it did not reopen, and a re-run finishes a partial reopen without a second comment. `parent --replace-parent` moves a task from its current epic to another. |
| `project add\|set` | Adds an issue to the Project, or sets Status (Ready, Blocked) and Priority. |
| `bootstrap [--apply [--prune]]` | Plans or converges labels and the Project fields to `.github/work.json`. Labels, custom Project fields and Status/Priority options on GitHub that the file does not declare are reported as `drift:` lines (exit 2). `--apply` adds and updates; `--apply --prune` also deletes drifted labels that no open issue carries, options no Project item uses, and undeclared custom fields with their values. Labels and options still in use stay reported until migrated. |

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
| `gate submit [run args]` / `jobs` / `wait JOB` / `cancel JOB` | Hands a run to the background and returns at once, so the session keeps working; `jobs` shows each job's live state, heavy-queue position and last line; `wait` streams it and returns its result; `cancel` stops it and its running step. |
| `gate report [--json]` / `gate catalog` | Median and max wall time and peak RSS per shard from every recorded run; the catalog as a table. |

**Plans.** Plan order is catalog order, so the same change always gets the same
plan. Markdown and `docs/` paths never start a build. Representative plans:

- docs only: `repo.privacy`, `repo.whitespace`;
- Gateway TypeScript: `gateway.deps` (verifies the install against the lock and
  repairs drift with `npm ci`, the #1011 guard) → `gateway.typecheck` → the related
  vitest files in 3 shards, two at a time (`gateway.affected`) → the nested-SDK pass in
  four named shards run one at a time, balanced by measured file time (`gateway.nested`; it has no
  affected-only form, and new nested files land in its `[rest]` shard);
- Gateway lockfile, package, vitest config, test support or `.node-version`: the
  whole default suite in 6 shards, two at a time (`gateway.full`, which supersedes
  `gateway.affected`) plus `gateway.scripts` (three named shards);
- iOS Swift: one `ios.build` (build-for-testing), then `ios.journeys`, which runs the
  changed UI test classes (or the smoke set) with test-without-building, two test
  methods per shard, from the same stamped products;
- Mac: `mac.build` (build-for-testing; it stages the Gateway payload, so it precedes
  every Gateway step) → `mac.test` (test-without-building); replacement scripts add
  `mac.replace-e2e`;
- protocol (`config/GatewayProtocol.json`): `protocol.contract`, `mac.build`, the full
  Gateway suite and `ios.build`;
- tooling (`tools/work`, `scripts/test-*.py`): `repo.syntax` and one `tooling.tests`
  shard per affected suite; `--tests` commands become `journey` shards.

**Shards and cache.** Each shard's cache key hashes its expanded command and the
git tree of its declared inputs (`keyExtra: xcode` adds the Xcode version;
`cacheScope: worktree` binds steps whose products live in the worktree). A passing
shard is recorded under `<git common dir>/work/gate/results/`; a rerun reuses every
pass whose key still matches and reruns only failed or invalidated shards. Tests are
never skipped or weakened to meet a budget: a slow step is split into shards or
narrowed to affected files.

**Progress and failure.** Each shard prints a start line with its class, budget,
hard limit and log path (`<git dir>/work/logs/<head12>/`), a heartbeat every 15 s
with elapsed time, live tree RSS and the log's last line, and a result line with
wall time, peak tree RSS and CPU. The first failing shard stops the run, prints the
end of its log, names the step and how many later shards did not start, and lists
the step's `knownFlakes` (for example #1016). A shard past its hard timeout is
killed with its process group and reported as `TIMEOUT <shard> exceeded its hard
limit`. Every finished shard appends to `<git common dir>/work/gate/metrics.jsonl`.

**Heavy steps.** A `heavy` shard waits in the host-wide heavy queue
(`heavy.py`, `scripts/tron-heavy status`;
[host load management](../../packages/gateway/docs/host-load.md#1-heavy-run-queue-work-tooling))
with its catalog `expectedRssMb`, so admission accounts for memory; the shard's
tree holds the lease descriptor and inherits it (`TRON_HEAVY_LEASE_HELD`), so a
journey that runs `scripts/tron-ios-test` does not wait on itself. Light shards never
wait.

`land` runs the whole plan on the merged, committed tree (`gate.verify`) and
refuses a dirty worktree or a tree that changed while steps ran. `python3 -B
scripts/test-gate.py` exercises the real CLI in temporary repositories: the plan for
each change kind, an injected failure that stops at its shard, a retry that reuses
passing shards, input invalidation, a hard timeout, background submit/cancel/wait,
and the dirty-tree refusal; evidence is `test-results/gate.json`.

## `land`

`land` refuses a detached HEAD, a base branch, a dirty worktree, a merge or rebase in
progress, and a branch with no commits beyond the base. The privacy guard runs on the
title and summary before anything is pushed or posted. A merge conflict with the base
is aborted, and the conflicting files are listed for the agent to resolve and commit,
then `land` runs again. A moved base sends `land` back to merging it, at most three
times. A refused merge after the base moved is retried the same way. A head that a
pull request already merged is refused, so a repeat run cannot open a second one.
Other refusals stop `land` with nothing merged. Claim handoff serializes through a read-only descriptor on the pre-existing common Git directory (it creates no lock file), checks operation markers in the selected worktree's private Git directory (including linked-worktree merge/rebase/cherry-pick/revert state), and rechecks local and remote heads before changing a ref. An exact accepted transition commit can repair local ref state after a partial push; unrelated or malformed remote objects are never treated as proof. A local head that differs from the remote claim head is not accepted merely because it is unpushed or has the same tree: use the explicit candidate recovery path for a clean settled-owner descendant, or stop and preserve the conflicting state. Force confirmation does not bypass this expected-head fence.

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
- `settled`: its Home task is terminal with settlement proof (as `handoff` requires).
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

## Failure modes this protects

- **A claim is taken twice.** The claim is a remote branch created without force; the
  smallest branch name wins the race and the loser deletes only its own ref. `handoff`
  appends the new owner trailer using an exact remote expected-head lease and updates
  the local branch only at its expected old head. The audit marker is keyed by the exact handoff commit.
- **A foreign session's claim is changed.** `issue close` refuses when another session
  holds a claim on the issue.
- **Public text leaks personal data.** Issues, comments, and pull request text pass the
  privacy guard first; a refusal prints no matching line.
- **A conflict is merged by hand.** `land` aborts a conflicting merge and names the files.
- **Unverified code is merged.** The squash merge names the verified commit, so GitHub
  refuses it if the branch changed. A base that moved is re-merged and re-verified first.
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
