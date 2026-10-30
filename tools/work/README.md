# Git/gh work and preservation

The [Git/gh skill](../../.agents/skills/tron-work/SKILL.md) owns the ordinary workflow:
read issues with `gh`, create an isolated branch/worktree with Git, integrate a
worktree-private fetched main, run affected checks, then push without force.
No claim, dashboard, status projection, landing wrapper, ACK relay or queue is
required. `gh issue list`, `gh issue view --comments`, `gh pr list`,
`gh project item-list`, `git worktree list --porcelain` and `git status` expose
current source state without inferring another worker's liveness.

The skill's executable Integrate/Publish blocks run against disposable Git remotes
in `scripts/test-work-skill.py`: concurrent main, conflict/unpublished preservation,
dirty/untracked files, shared tracking-ref lock and a push race. No copied landing
implementation lives in that test. A committed review uses ordinary `git diff
--binary --full-index <base> HEAD --`; privacy-check any patch before sharing it.

## Guarded GitHub writes

Reads may use ordinary `gh`. Writes use `scripts/tron work comment|issue|project`:
its existing owner keeps the dedicated agent token in Keychain, checks public
text with `scripts/personal-info-guard.sh`, and writes a bounded private audit.
Do not export tokens, change the maintainer's gh login or bypass this owner.
`work auth status` reports setup; missing auth requires the maintainer's Terminal
`scripts/tron work auth setup`, never a printed credential.

A nonzero GraphQL mutation or compound exit is **uncertain**, not proof nothing
committed; result-field errors can follow writes even with null data. Read back
remote state and inspect the audit before acting. Existing idempotent commands
may recover an accepted operation; never blindly replay a write. Explicit
single-request REST HTTP 4xx rejection is failed. Historical audit rows are not
rewritten. Full (16 MiB), unreadable or unowned audit history refuses before
network dispatch, without truncation/rotation. Linked worktrees share the common
Git directory journal; reservations retain space for every accepted result.
Local admission errors remain local, not an invented uncertain remote outcome.
`scripts/test-work-close.py` exercises real CLI/API/subprocess boundaries,
partial writes, reverse-completion reservations and refusal/recovery; auth has
its real isolated-Keychain fixture in `scripts/test-work-auth.py`.

`.github/work.json` declares labels, Project fields, claim/cleanup rules and issue
classification. `work bootstrap [--apply [--prune]]` plans/converges that vocabulary,
not repository protection or required checks. Explicit prune keeps values used
by open issues/Project items. Read the plan before destructive changes.

Useful writes (`--help` owns exact arguments):

- `work comment <issue> --body-file F`: privacy-checked, audited comment.
- `work issue create --title T --body-file F --kind kind:maintenance --area area:tooling`:
  file classified work in the Project; choose the fitting declared labels.
- `work issue edit|labels|close|reopen|parent|block`: tracking only. Close uses
  `--reason completed|not_planned --comment-file F`; partial slices stay open.
  Closing requires no claim ownership, is idempotent and sets Done. Epic closure
  still requires closed sub-issues. Reopen posts its reason and restores status.
- `work issue parent N --epic P [--replace-parent|--remove]`: link to an epic or
  an open tracked `Module: <id>` maintenance issue; no self-parent or implicit
  replacement. Removal detaches only the relation. `block --blocked-by` is advisory.
- `work project add|set`: Project membership/status/priority, never approval.

## Existing claim preservation

One writer per issue; preserve parked/unpublished and active foreign work. Branch
names and historical claim trailers do not prove a running worker. The ordinary
Git workflow needs no new claim. Existing claim operations remain explicit
preservation/coordination tools, not prerequisites to landing:

- `work start <issue> [--area PATH]` can create a claimed isolated worktree without
  dependencies/tests. Actual live foreign claims require handoff. Ordinary parked
  checkpoints and released work are retained; a collision gets a fresh path, not
  adoption. Areas are advisory, never locks. A push race needs an observed competitor,
  not an inference from any Git error. Creation/handoff admission is exercised by
  `scripts/test-work-start.py` and `scripts/test-work-coordination.py`.
- `work handoff <issue> --session RECEIVER --reason TEXT` transfers coordination,
  preserving index/files/processes. Unknown/live owner states refuse; no TTY or
  lifecycle override. Exact local/remote publication fences remain. Handoff cannot
  prevent the prior owner from using plain Git; coordinate explicitly.
- `work recover <issue> --expected-local SHA --expected-remote SHA --reason TEXT`
  publishes an exact clean settled-owner descendant as **unverified** work; not
  acceptance or ownership transfer. `scripts/test-work-handoff.py` covers exact
  heads, owner-state uncertainty, live owners and refusal/preservation.
- `work release <issue> --reason TEXT` backs up local/published heads and a snapshot
  of tracked/untracked/non-regenerable ignored data under the Git common directory's
  `work/releases/`. It deletes only the exact leased remote claim ref. Every local
  branch/worktree/index/file/process remains intact, including the caller's checkout.
  No cleanup hooks run. Published work and live/unverifiable owners are not refusals
  for this explicit preservation operation. Accepted remote release can resume its
  audit/Project finish without replaying the deletion. Backup/privacy/ambiguous-claim
  and remote-race failures stop it. Optional `--stale [--dry-run]` is older-than-72h,
  absent-owner only, re-proven before writing, and keeps published unlanded changes.
  `scripts/test-work-release.py` covers real Git/socket/API boundaries. Already-landed
  remote-only heads need no empty bundle and stay reachable through preservation refs.

## Exact-head cleanup

`scripts/tron work cleanup [--dry-run]` is the existing destructive cleanup owner,
not part of landing. Use it only for your own completed task with explicit removal
authority; `--all` is a separate broad operation, never an automatic follow-up.
It recognizes a closed issue whose **exact head** is reachable on origin/main, a
closed issue with only its unchanged claim commit, or an exact-head historical
merged PR (not a fork's same-named branch). A squash with identical files does not
prove a unique head landed. Open/unknown owner, dirty/untracked files, non-regenerable
ignored data, unpublished nested checkouts, active processes, locks or moved heads
keep the worktree. No snapshot/content-subset trick discards unique work.

Cleanup owns operation-in-progress checks and remote exact-head deletion leases.
Release hooks run only after eligibility, then local/head/process checks repeat
before removal. A remote refusal keeps the moved branch; no broad kills or forced
cleanup. Unclaimed/unrecognized worktrees remain protected, not silently admitted.
`scripts/test-work-cleanup.py` crosses real CLI/Git/process boundaries for these
preservation cases and writes `test-results/work-cleanup.json`. Closing an issue
never deletes branches/worktrees or authorizes bypassing this owner.

## Validation and lifecycle

Tests run directly with `scripts/tron test tooling scripts/test-work-<name>.py`.
Fresh worktrees prepare their own pinned Gateway development dependencies before
Gateway checks; see [verify](../verify/README.md#worktree-dependencies). No shared
install or global compiler substitutes. Affected checks and the known-failures
validator run before plain-Git push; broader coverage uses explicitly requested
local batches, not queues or required receipts. Keep evidence under `test-results/`.

Mac, iOS and Gateway lifecycle contracts stay with their development guides.
Nothing here installs, deploys, replaces, restarts or promotes Stable. Never add an
automatic release, check queue or revert to this workflow.
