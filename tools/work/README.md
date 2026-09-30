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
