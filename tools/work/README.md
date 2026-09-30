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

`scripts/tron work start <issue>` claims one issue and prepares its isolated
workspace:

1. **Eligibility.** The issue is open, is not an epic, has Status Ready in the
   Project, and every issue it is blocked by is closed.
2. **Claim.** The claim is the creation of the remote branch
   `<type>/<issue>-<slug>`, whose first commit is an empty claim commit carrying
   `Work-Claim-Issue` and `Work-Claim-Session` trailers.
   - The commit is based on the freshly fetched remote base branch, never on
     local `main`.
   - The push only creates the ref (`--force-with-lease=<ref>:`), so the remote
     accepts exactly one claimant.
   - Squash merges drop the empty commit.
3. **Tracking.** `start` sets the issue's Project Status to In progress. It then
   posts a claim comment giving the session, the branch, and the worktree path
   relative to the checkout's parent directory, never an absolute path.
4. **Worktree.** `start` creates `<worktreeRoot>/<issue>-<slug>` on the branch.

The session is `--session`, then `WORK_SESSION_ID`, then `PI_SESSION_ID`.

The branch type comes from the first matching label in `claim.branchTypes`,
otherwise from `defaultBranchType`. After claiming, `start` warns when the number of
In-progress items exceeds `claim.softCap`; the claim still proceeds.

Re-running `start` in the same session resumes a claim that is already made.
It fills in whatever is missing (Status, comment, worktree) and never makes a
second claim. A different session is refused, and the refusal names the owner.

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

`scripts/tron work verify [--post]` validates the committed head of the current
branch and writes a receipt for that exact commit.

1. **Clean head.** A worktree with modified, staged or untracked files is
   refused, because the receipt describes a commit and not a working tree.
2. **Diff.** It fetches the remote base branch (`claim.remote`,
   `claim.baseBranch`) and computes the changed paths from
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
5. **Run.** Each required check runs in its own process group. Its combined
   output goes to `<git-dir>/work/logs/<head>/<check>.log`, where `<git-dir>` is
   `git rev-parse --git-dir`, so every worktree keeps its own logs. The receipt
   is `<git-dir>/work/receipts/<head>.json`. It records the head, the base
   branch tip, the merge-base, the changed paths, a hash of the verify
   configuration, the required check set, and for each check its command, exit
   code, wall time, log path, and the commit it was carried from, if any. The
   receipt passes only when every required check exited 0. If the head moves or
   the worktree changes while checks run, verify refuses and writes no receipt.
6. **Incremental re-verify.** Verify looks for the nearest earlier passing
   receipt whose commit `P` is an ancestor of the head and whose configuration
   hash is identical. A required check is carried from `P` instead of run when it
   passed there, it is not `always`, and none of the paths changed between `P`
   and the head match its globs. Those paths include everything an update from
   the base branch brought in. After a rebase `P` is no longer an ancestor, so
   nothing is carried. A check's globs must therefore cover everything its
   result depends on, including the scripts it calls.

`--post` then publishes the receipt:

1. It refuses unless the current branch exists on the remote at exactly the
   head.
2. It sets the commit status `verify.statusContext` to `pending` on the head,
   replacing any earlier status there before any other lookup can fail.
3. The target is the open pull request for the branch, otherwise the issue
   whose number is in the branch name (`<type>/<issue>-<slug>`).
4. Full logs and the receipt go only to the evidence repository
   `<owner>/<repo><verify.evidenceRepositorySuffix>`, derived at run time,
   under `<issue>/<head>/`. They are not scrubbed and hold local paths, so
   verify uploads nothing unless GitHub reports that repository as private.
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

### Tron's check set

Tron's `verify` section in `.github/work.json` follows the validation commands
in `AGENTS.md` and `CONTRIBUTING.md`. The prelude puts the Node pinned by
`.node-version` from nvm first on `PATH`. Its limits are deliberate:

- **Gateway** is one check whose globs cover every build and test input:
  sources, dependencies, TypeScript and Vitest configuration, scripts, fixtures,
  protocol fixtures and the pinned Node version. A lockfile change merged from
  the base branch therefore reruns it. It runs `npm ci`, the Pi SDK cohort check
  and the build, then `vitest related` when every changed Gateway path is
  existing source or test support. A change that no test imports runs only the
  build. Any other changed input, or a deleted or renamed Gateway file, runs the
  full suite instead, because `vitest related` cannot select a test that still
  imports a deleted module and the build excludes tests.
- **iOS** runs the source, build-matrix and archive-privacy policy scripts,
  `scripts/tron-ios-test build` and the complete unit target. Focused owners cannot be derived from paths: suite names are not
  file names, and an `--only-testing` selector that names no suite runs zero
  tests and passes. The simulator admission and lease rules of
  `scripts/tron-ios-test` still apply, so a busy Mac fails the check with exit
  73; verify again once memory is free.
- **Mac** regenerates the project with `scripts/generate-xcode-project mac`
  (what `scripts/tron mac generate` runs) and runs `build-for-testing` and
  `test-without-building` for `TronMacTests`, as in the Mac development guide.
  Checks call the owning script directly rather than the `scripts/tron`
  dispatcher, so a dispatcher edit does not rebuild the Mac app. The isolated
  Mac script fixtures that need no staged payload run as their own check.
  Packaging checks that need a staged Gateway payload stay with the macOS CI job.
- **Scripts** run their owning `scripts/test-*` suite where one exists. Scripts
  without an owner (`scripts/tron`, `scripts/tron-dev`, the hook installer and a
  few one-off tools) get a syntax check only.
- **`.github` workflows, forms and rulesets** get a JSON or YAML syntax check;
  GitHub validates their meaning when they run.
- The privacy guard, agent policy, documentation policy and `git diff --check`
  over the branch diff always run.

### Failure modes

`test_verify.py` checks these against real temporary repositories, local bare
remotes and a fake `gh` (`WORK_GH`) that records every call. The live E2E
covers the GitHub side.

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

## `dashboard`

`scripts/tron work dashboard [--html <path>] [--json <path>]` shows the state of
all work in one read-only view. It is fetched live on every run from GitHub and
local Git, and it keeps no cache or registry. Without flags it prints a short
text summary. `--html` writes one self-contained HTML file with inline CSS, no
external assets and no script, readable in a narrow phone sheet and in dark
mode. `--json` writes the same model as JSON for tests and other tools.

It reads, in a bounded number of calls:

- the Project's items (paginated GraphQL): Status, Priority and Epic rank, and
  each issue's state, labels, parent, sub-issue progress, blockers and latest
  comment;
- open issues carrying a `dashboard.needsYouLabels` label or the
  `dashboard.regressionLabel`, whether or not they are in the Project;
- open pull requests with their head branch, the combined check state of the
  head commit, and the `dashboard.verifyContext` commit status;
- the state of any issue named by a claim branch that the reads above did not
  return (one aliased query);
- remote branches (`git ls-remote`), the claim owner from each claim branch's
  claim commit (the same code as `start`), and local worktrees
  (`git worktree list`).

Sections, in order:

1. **Needs you:** open issues labeled with a `needsYouLabels` label, or with
   Status `needsYouStatus`.
2. **Epics:** open issues labeled `epicLabel`, by Epic rank, with sub-issue
   progress.
3. **In progress:** issues with Status `claim.claimedStatus`, with the claim
   branch, the worktree relative to the checkout's parent directory, the owning
   session, last activity, the pull request, its checks and its verify status.
4. **Ready queue:** Ready issues that are not epics. They are ordered by the
   Epic rank of their parent epic (or their own Epic rank when they have no
   ranked parent; unranked last), then by Priority in the order the options are
   declared, then unblocked before blocked, then issue number.
5. **Blocked:** issues with Status `blockedStatus`.
6. **Stale claims:** In-progress issues with no push to their claim branch and
   no comment on the issue or its pull request for 48 hours. They are only
   flagged, never reset.
7. **Soft cap:** the number of In-progress issues against `claim.softCap`.
8. **Disagreements:** a claim branch whose open issue is not In progress, an
   In-progress issue without a claim branch, or an issue with more than one
   claim branch. The branch is the authority; Status is its projection.
9. **Orphans:** worktrees under `claim.worktreeRoot` that are not on the claim
   branch of an open issue, and remote claim branches whose issue is closed or
   does not exist.
10. **Regressions:** open issues labeled `regressionLabel`.

The names it reads (statuses, labels, fields, the verify context) come from the
`dashboard` and `claim` sections of `.github/work.json`.

### Failure modes

`test_dashboard.py` checks these against recorded GitHub-shaped responses.

12. **GitHub text injects markup into the HTML.** Titles, labels and branch
    names are attacker-controlled in a public repository. Every such string is
    HTML-escaped, and only `https://` links are rendered.
13. **A Project item without usable content crashes the run or shows up.**
    Deleting an issue before removing its Project item leaves an item whose
    content is null. Such items, drafts, pull requests and issues from other
    repositories are ignored and only counted.
14. **Staleness is misjudged.** Last activity is the latest of the claim
    branch's head commit, the issue's latest comment and its pull request's
    latest comment, so a recent comment keeps an old branch fresh. A claim is
    stale only past 48 hours.
15. **A disagreement between the claim branch and Status goes unreported.**
    Each of the three kinds above is reported, and a consistent claim is not.
16. **The Ready queue is ordered wrongly.** Priority follows the declared option
    order, not the alphabetical order of names, and a parent epic's rank wins
    over the task's own.
17. **An orphan is missed, or live work is called an orphan.** A worktree on the
    claim branch of an open issue is not an orphan; a worktree outside the
    worktree root is not reported at all.
18. **Output leaks a local absolute path.** Worktrees appear only relative to
    the checkout's parent directory.
19. **A Needs-you item is missed.** A labeled issue that is not in the Project
    still appears, and closed issues do not.
20. **Pagination drops items.** Every page of Project items, pull requests and
    labeled issues is read, and the number of calls grows with pages, not with
    issues.
