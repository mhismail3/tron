# Parallel agent workflow

- **Started:** 2026-09-30
- **Status:** Active
- **Last updated:** 2026-09-30, W-2 Done
- **Goal:** Any number of agents can pick up, isolate, validate, land and clean
  up Tron work concurrently, using GitHub Issues, PRs and one Project as the
  shared record, while the user sees everything on one dashboard.

## Goal and constraints

End state, agreed with the user in an interview on 2026-09-30:

- **One authority for work state.** GitHub Issues plus one GitHub Project hold
  every epic, task, claim, progress update, decision, and piece of evidence.
  `docs/plans/` is retired after migration, and closed epics replace
  `docs/plans/HISTORY.md`. Code and owning docs still describe current
  behavior (AGENTS.md documentation ownership is unchanged).
- **Hierarchy.** An epic is a parent issue whose body holds the goal,
  constraints, decisions and rules that plan docs hold today. Tasks are native
  sub-issues, and ordering uses native blocked-by links. Work discovered during a
  task is filed as a new sub-issue of the same epic (or as a standalone triage
  issue) and linked from the PR. It is not done in that PR unless it blocks the
  task.
- **Approval.** A new epic and its tasks start as Proposed and cannot be
  claimed until the user approves. Items that need a user decision carry
  `needs-decision`, appear at the top of the dashboard, and send a Tron push
  when they block work.
- **Isolation.** Every claimed task has exactly one branch
  (`<type>/<issue#>-<slug>`) in exactly one worktree under one worktree root,
  created by one command from a freshly fetched `origin/main`. Every agent
  assumes other agents are working at the same time.
- **Landing.** PRs go straight to `main` (`Closes #N`). An integration branch
  exists only when an epic must ship as one release, and the epic records that
  choice. Merge happens automatically once:
  1. the branch is up to date with `main`;
  2. the Linux policy CI passes;
  3. there is a local validation receipt for the exact head commit.

  There is no human or agent review gate. The macOS CI jobs run for the paths
  they cover but report without blocking merges (D-4).
- **Local validation is the merge gate.** A verify command decides which checks
  the diff needs, runs them, records evidence (D-5), and posts a receipt bound to
  the head SHA. After an update from `main`, it reruns only the checks whose scope
  the incoming change touches. A scheduled heavy run on `main` on this Mac,
  subject to the existing memory admission, files regression issues.
- **User-only validation.** Some proof needs a user action: a dev Gateway
  restart, a Mac reinstall, or an iPhone install. Such a PR merges on its
  receipt, and the issue then moves to **Needs you** with the exact action and
  check. It closes after confirmation.
- **Cleanup.** Once a PR is merged, its worktree and branches are removed
  automatically if they are provably done: the merged PR's head equals the
  local head, the worktree is clean with no untracked or ignored-but-unique
  files, and no merge or rebase is in progress. Everything else is only flagged
  on the dashboard.
- **Dashboard.** A skill, run on request, renders a rich HTML card in Tron
  chat. It is fetched live and has no local cache that could become a second
  authority.
- **Reuse.** The core is repository-agnostic and configured per repository.
  Tron is the first and reference consumer and must work reliably before the
  core is reused elsewhere.

What must not change:

- AGENTS rules 7–9 hold. Merging to `main` never rebuilds, restarts, promotes
  or deploys anything. Gateway and app transitions remain user actions, and the
  tools only name them.
- Agents use the user's GitHub account. Every claim, progress comment and PR
  carries the Tron session ID (`PI_SESSION_ID`) so agents stay distinguishable.
  Credentials stay in gh's own store and are never written to the repository or
  to issues.
- The repository is public, so issues, PRs, comments and their attachments are
  public. They are outside `scripts/personal-info-guard.sh`, so every tool
  that posts text runs the same needles over it first. Screenshots, clips and
  raw logs never go to the public repository (D-5).
- The simulator admission and lease rules in `scripts/tron-ios-test` stay the
  simulator authority; this system calls them and does not duplicate them.
- In-flight plans (`docs/plans/2026-09-29-pi-sdk-099-upgrade.md`, the
  `hardening/integration` branch of
  `docs/plans/2026-09-27-connection-scale-hardening.md`, and others) finish
  their current phase under the current protocol. They migrate at their next
  natural boundary.

## Context

Dated 2026-09-30:

- There are 13 plan docs. Claims are commits on `main` (`plan(<slug>): claim`),
  and handoffs are prose in the plan. About 1,370 commits landed in 14 days.
  Merges happen locally, and no PRs are in use.
- About 70 registered worktrees and about 115 local branches use mixed naming
  (`hardening/*`, `ct-23-*`, `codex/*`, `knowledge/*`, `archive/*`). They are
  spread across `/private/tmp` and sibling `Workspace` directories.
- GitHub state:
  - `gh` is installed in Homebrew's prefix, which is not on the Gateway-inherited
    agent PATH (the same class of problem as N-1 in
    the proposed Node runtime lifecycle plan).
  - The user re-authenticated `gh` on 2026-09-30 with the repo, workflow,
    project and read:org scopes.
  - The repository is public. Auto-merge, delete-branch-on-merge and
    update-branch are enabled. Squash, merge-commit and rebase merges are all
    still allowed. No rulesets exist yet.
  - Standard GitHub-hosted runners, macOS included, are free for public
    repositories, so CI cost is not a constraint. CI wait time is.
  - `.github/` has user-facing bug and feature forms, a checklist PR template,
    `.github/dependabot.yml`, and `.github/workflows/ci.yml`. The latter runs
    Linux policy checks plus macOS Gateway, iOS and Mac jobs on every PR and
    push.
- GitHub capability facts relevant to the design:
  - Sub-issues and blocked-by dependencies are native, and `gh issue` can edit
    and read them.
  - Issue types exist only for organizations, so this repository uses labels.
  - Merge queue is available only for organization-owned repositories, so it
    is unavailable here. Required status checks, "require branches to be up to
    date", auto-merge and delete-on-merge are available.
  - `gh issue/pr comment --attach` uploads files to GitHub-hosted assets that
    are as visible as the repository hosting them.
- A cross-worktree simulator collision (T-2/T-3 in the hardening plan) is
  prior evidence that Git isolation alone is not enough.

## Plan rules

### Decisions (settled by the user on 2026-09-30)

- **D-1 Home of the core:** inside Tron as a self-contained module that
  imports nothing from Tron, with all repository specifics in one
  configuration file.
  - Extract it into its own pinned package when a second repository adopts it.
  - The no-import rule is checked, so extraction stays mechanical.
  - Rejected: its own repository from day one, because every early fix would
    need a release.
- **D-2 Merge method:** squash only.
  - `main` gets one commit per PR, and the PR keeps the branch history.
  - Merged-PR state from GitHub, not Git ancestry, is the landing evidence for
    cleanup.
- **D-3 Worktree root:** a `tron-worktrees` directory next to the primary
  checkout, holding `<issue#>-<slug>` worktrees. The root is configurable.
  Nothing goes in `/private/tmp`, which macOS may clear, or in the Tron
  internal workspace.
- **D-4 macOS CI jobs:** kept and path-scoped, but not required checks.
  - Their failures appear on the dashboard and file `regression` issues.
  - They give free clean-machine checking without slowing merges, which are
    gated by up-to-date branches plus the local receipt.
- **D-5 Evidence privacy:**
  - Text evidence (commands, pass counts, wall times, short scrubbed log
    excerpts) goes in the public PR.
  - Screenshots, clips and full logs go only to a private companion evidence
    repository, which the user creates. The public PR links to them.
  - Rejected: making the Tron repository private, which would cost CI minutes
    and may require GitHub Pro for rules and auto-merge.

### Vocabulary for agents

- **Labels:**
  - Type: `epic`, `task`, `bug`, `chore`, `dependencies`, `enhancement`.
  - Area: `area:gateway`, `area:ios`, `area:mac`, `area:relay`, `area:tooling`,
    `area:docs`.
  - Flags: `needs-triage`, `needs-decision`, `needs-user-validation`,
    `regression`.
- `.github/work.json` is the source of truth for this vocabulary; this
  section is a summary.
- **Project fields:**
  - Status: Proposed, Ready, In progress, In review, Needs you, Blocked, Done.
  - Priority: P0 (drop everything), P1 (next), P2 (normal), P3 (someday).
  - Epic rank: an integer, lower is first.

  To pick a task:
  1. Take the lowest epic rank.
  2. Within it, take the highest priority.
  3. Take a Ready task whose blockers are all closed.
- **Claim:** the atomic creation of the remote branch. The claimer:
  1. creates the branch;
  2. confirms it is the only branch for that issue number;
  3. sets the Project status to In progress;
  4. posts a claim comment with the session ID, branch and worktree.

  If it loses a race, it deletes only the ref it created and picks again.
- **Progress:** a comment at each milestone and whenever the plan deviates. A
  claim with no push or comment for 48 hours is flagged stale on the dashboard.
  It is never reset automatically.
- **Receipt:**
  - A commit status `tron/verify` on the head SHA.
  - Its target is a PR comment listing the checks run, commands, pass counts,
    wall times, log and artifact attachments, and the verify configuration
    revision.
  - The receipt is bound to the check set that the configuration requires for
    the diff, so it cannot be satisfied by running fewer checks.
- **Take a task:**
  - When the user names an issue, take it.
  - When the user asks for suggestions, propose the top candidates.
  - Otherwise, claim the top Ready task and report which one was taken.
- **Parallelism:** a soft cap on In-progress tasks, set in the configuration.
  The start command warns above it, and the dashboard shows it.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| W-1 | Done | User setup: `gh` re-authenticated, repository settings applied (squash-only), private evidence repository created, D-1–D-5 settled | none | User, 2026-09-30 |
| W-2 | Done | GitHub bootstrap: labels, Project and fields, Epic/Task issue forms, ruleset spec; the user applies the settings and ruleset changes | W-1 | session 01a0f183, 2026-09-30 |
| W-3 | Ready | Shared-resource isolation audit so any two worktrees can validate concurrently; each fix becomes a sub-issue | none | Unassigned |
| W-4 | Ready | Core: `start`/claim, naming, soft cap (the config file and `gh` resolution exist since W-2) | W-2 | Unassigned |
| W-5 | Ready | Core: `verify` (diff → check set → run → evidence → receipt) and the incremental re-verify after a `main` update | W-4, W-3 | Unassigned |
| W-6 | Ready | Core: `finish` and `land` (PR with `Closes`, evidence comment, auto-merge, update-and-reverify loop, Needs-you handoff) and a recurring steward for orphaned PRs | W-5 | Unassigned |
| W-7 | Ready | Core: automatic cleanup of provably done resources; update the housekeeping skill to match | W-6 | Unassigned |
| W-8 | Ready | Dashboard skill and HTML card | W-4 | Unassigned |
| W-9 | Ready | CI: required Linux policy job and `tron/verify` status; path-scoped, non-blocking macOS jobs whose failures reach the dashboard (D-4) | W-5 | Unassigned |
| W-10 | Ready | Scheduled local heavy run on `main` that files `regression` issues | W-5 | Unassigned |
| W-11 | Ready | Rewrite the guidance: `AGENTS.md` work section, `CONTRIBUTING.md`, `.agents/README.md`, PR template, retirement notice in `docs/plans/README.md` | W-6, W-8 | Unassigned |
| W-12 | Ready | Pilot: migrate this plan into an epic and finish W-7 onward through the new flow | W-6 | Unassigned |
| W-13 | Ready | Dependabot intake: each PR becomes an agent-owned `deps` task; the Pi SDK family and Node follow their runbooks | W-6 | Unassigned |
| W-14 | Ready | One audited legacy sweep of the existing worktrees and branches, with the user approving the exact list | W-7 | Unassigned |
| W-15 | Needs scoping | Migrate each remaining plan at its boundary; retire `docs/plans/` and `docs/plans/HISTORY.md` once empty | W-11 | Unassigned |

## Task details

### W-2 — GitHub bootstrap

- Create the labels, Project and fields from the vocabulary above as
  declarative configuration applied by an idempotent command, so the setup is
  reproducible and diffable.
- Add Epic and Task issue forms beside `.github/ISSUE_TEMPLATE/bug_report.yml`.
  - Epic: goal, constraints, decisions, rules.
  - Task: scope, acceptance criteria, focused checks, evidence expected.
- The rulesets and the repository settings (auto-merge, delete-on-merge,
  required checks, up-to-date, D-2) are account changes. Write the exact
  settings, and the user applies them or explicitly authorizes the command.

### W-3 — Isolation audit

- Inventory every resource that two worktrees could share: ports, fixed `/tmp`
  paths, `~/.tron-dev` and the 9848 dev Gateway, simulator lanes, DerivedData,
  npm caches and installs, Xcode's `project.yml` generation, and the iPhone.
- Record each resource as one of:
  - per-worktree isolated;
  - leased with an owner and bounds (the device, 9848);
  - a proven bug, which gets a sub-issue with a reproduction.
- Evidence: two worktrees run their focused Gateway, iOS and Mac checks at the
  same time, and both pass. The run leaves a retained report.

### W-5 — Verify and receipt

- The configuration maps path globs to check sets. Tron's sets come from the
  existing validation commands in `AGENTS.md` and `CONTRIBUTING.md`: Gateway
  build plus the owning Vitest file, `scripts/tron-ios-test` focused owners, the
  Mac focused build, and policy scripts. Unmapped paths fail closed to the
  broadest set for their package.
- Before this ships, write down its failure modes:
  - a stale receipt accepted;
  - a check set narrowed by the diff;
  - a crash posting success;
  - evidence leaking personal data;
  - an incoming `main` change missed during re-verify.
- The receipt comment runs the personal-info needles before it is posted.

### W-6 — Finish, land, steward

- Nothing can be merged unless it is up to date, so the owning agent lands its
  own PR: fetch, update, re-verify the affected checks, push, wait for CI, merge.
- A recurring prompt automation, created with the user's approval, runs a
  steward session. The steward lands or flags PRs whose owner session ended.
- For a task that needs user-only validation, the issue moves to **Needs you**
  with the exact command, for example the dev Gateway restart named in
  `CONTRIBUTING.md`. After the user acts, the agent verifies and closes the
  issue.

### W-8 — Dashboard

- Sections:
  - needs-decision and Needs you;
  - epics with progress;
  - In-progress tasks with branch, worktree, session, last activity, PR, CI and
    receipt;
  - Ready queue;
  - Blocked;
  - stale claims;
  - soft-cap state;
  - local worktrees without an open issue, and remote branches without a
    worktree;
  - open `regression` issues.
- It is read-only and fetched live, in a bounded number of API calls.

## Handoff log

### Draft · Proposed · 2026-09-30 · interview session

- Result: Drafted from an eight-round interview with the user, a read-only
  review of `.github/`, `docs/plans/README.md`, `CONTRIBUTING.md`,
  `.agents/skills/tron-workspace-housekeeping/SKILL.md`, and the local branch
  and worktree inventory, plus GitHub documentation lookups (sub-issues,
  dependencies, issue types, merge queue, attachments).
- Changes: this file only; not committed.
- For the next agent:
  - Finish W-1: the user switches to squash-only merges and creates the private
    evidence repository.
  - D-1 to D-5 are settled; W-2 and W-3 can start once the plan is Active.
  - This file is the last plan doc; W-12 turns it into the first epic.

### W-1 · Done · 2026-09-30 · interview session

- Result: The user re-authenticated `gh`, enabled auto-merge,
  delete-branch-on-merge and update-branch, restricted merges to squash only,
  created the private evidence repository, and approved the plan with D-1 to
  D-5 as recorded.
- Evidence: read-only `gh repo view` checks show squash as the only allowed
  merge method and the evidence repository as private.
- Changes: this plan committed as Active.
- For the next agent: W-2 and W-3 are Ready. Until W-9 lands, claims and
  merges still follow the protocol in `docs/plans/README.md`. Do not add
  rulesets before the work tooling can replace direct pushes to `main`.

### W-2 · Done · 2026-09-30 · session 01a0f183

- Result:
  - `scripts/tron work bootstrap` plans, and with `--apply` converges, the
    repository labels and one private owner-level Project titled Tron. The
    Project is linked to this repository and has Status, Priority and Epic
    rank fields.
  - The tooling lives in `tools/work/`, declared by `.github/work.json`.
  - Epic and Task issue forms were added.
  - The branch ruleset is written in `.github/rulesets/main.json`.
    Bootstrap reports it with a one-line apply command, but does not apply it.
- Evidence:
  - `python3 -m unittest discover -s tools/work` gives 6 passed.
  - Negative controls: removing ID preservation from `plan_options` fails 3
    tests, and removing the in-use check fails 1.
  - The live apply made 20 changes in 13.4 s and converged in the same run. A
    fresh plan afterwards exited 0 with no changes.
  - Live refusal control: a temporary draft item set to Ready, plus a
    declaration without Ready, made bootstrap refuse and name the option. The
    item was then deleted and the plan re-checked as in sync.
  - Reports are in the Tron internal workspace under
    `files/w-2-bootstrap/`. Regenerate them with
    `scripts/tron work bootstrap --report <path>`.
  - With PATH set to `/usr/bin:/bin`, `gh` still resolved through the Homebrew
    fallback.
- Changes: this commit.
- Tasks added: none.
- Kept on purpose:
  - The existing undeclared labels (`documentation`, `wontfix`, …) are
    reported, never deleted, and are left for the maintainer.
  - The user-facing bug and feature forms stay, because the repository is
    public. Their `needs-triage` label now exists.
- Deviations:
  - The type label is `dependencies`, not `deps`, because Dependabot already
    applies that label.
  - No custom Project views were created. The dashboard (W-8) is the primary
    view, and GitHub's default table remains.
  - The Project is private, the least exposure available, even though the
    issues themselves are public.
  - The ruleset requires the `policy` CI job and the `tron/verify` status.
    Apply it only at the W-9 cutover.
- For the next agent:
  - W-4 builds `start` and claiming on `tools/work/gh.py` and `.github/work.json`.
  - Keep the rule that nothing in `tools/work/` names this repository.
