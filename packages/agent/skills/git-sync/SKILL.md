---
name: "Git Sync"
description: "Sync the current git branch with its remote: stash, fetch, rebase, push, unstash — with rollback safety at every phase"
version: "1.0.0"
tags: [git, sync, rebase, workflow]
subagent: ask
deniedTools: [Edit]
---

# Git Sync — Safe Branch Synchronization

Sync the current git branch with its upstream remote. Uses a rebase strategy for linear history. Every phase stores checkpoints so any failure can be unwound cleanly.

## Phase Overview

| Phase | Action | Rollback |
|-------|--------|----------|
| 0 | Pre-flight | — |
| 1 | Stash uncommitted changes | `git stash pop` |
| 2 | Fetch all remotes | — (read-only) |
| 3 | Rebase onto upstream | `git rebase --abort` → `git reset --hard $CHECKPOINT` |
| 4 | Push to remote | — (force-with-lease is safe) |
| 5 | Unstash changes | Stash preserved on failure |

**Rollback priority:** If anything goes wrong in Phases 3–5, the most important recovery is restoring the working tree to the state the user had before invoking this skill.

## State Variables

Track these throughout execution — you will need them for rollback:

- `BRANCH` — current branch name
- `UPSTREAM` — full upstream ref (e.g. `origin/main`)
- `REMOTE` — remote name (e.g. `origin`)
- `CHECKPOINT_SHA` — HEAD sha recorded before any mutations
- `STASH_CREATED` — boolean, whether a stash was created in Phase 1
- `AHEAD` / `BEHIND` — commit counts relative to upstream after fetch
- `REBASE_REWROTE` — boolean, whether rebase replayed commits (changed SHAs)

---

## Phase 0: Pre-flight

Verify the environment and collect checkpoint data.

### Step 1 — Verify git repo

```bash
git rev-parse --is-inside-work-tree
```

If this fails, stop: "This is not a git repository."

### Step 2 — Check for detached HEAD

```bash
git symbolic-ref --short HEAD 2>/dev/null
```

If this fails, stop: "You are in detached HEAD state. Check out a branch first (`git checkout <branch>`) and re-run."

### Step 3 — Record checkpoint data

```bash
BRANCH=$(git symbolic-ref --short HEAD)
CHECKPOINT_SHA=$(git rev-parse HEAD)
echo "Branch: $BRANCH"
echo "Checkpoint: $CHECKPOINT_SHA"
```

### Step 4 — Check tracking branch

```bash
git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null
```

**If no tracking branch:** Ask the user:
> Branch `$BRANCH` has no upstream tracking branch.
> 1. Set upstream to `origin/$BRANCH` and continue
> 2. Choose a different remote/branch
> 3. Cancel sync

If they choose option 1 and `origin/$BRANCH` does not exist on the remote, offer to push the branch to create it:
```bash
git push -u origin $BRANCH
```
Then report success and stop — the branch was just created on the remote, nothing more to sync.

### Step 5 — Extract remote and upstream ref

```bash
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{upstream})
REMOTE=$(echo "$UPSTREAM" | cut -d/ -f1)
echo "Upstream: $UPSTREAM"
echo "Remote: $REMOTE"
```

### Step 6 — Check for in-progress operations

```bash
git status
```

If a rebase, merge, or cherry-pick is already in progress, stop: "There is already a [rebase/merge/cherry-pick] in progress. Resolve or abort it first."

### Report

> **Pre-flight complete.**
> - Branch: `$BRANCH`
> - Upstream: `$UPSTREAM`
> - Checkpoint: `$CHECKPOINT_SHA` (first 8 chars)
> - Working tree: [clean / N files modified]

---

## Phase 1: Stash

Preserve any uncommitted work before rebasing.

```bash
git status --porcelain
```

**If clean (no output):** Set `STASH_CREATED=false`, skip to Phase 2.

**If dirty:**

```bash
git stash push --include-untracked -m "git-sync: auto-stash on $BRANCH (checkpoint: ${CHECKPOINT_SHA:0:8})"
```

Verify:
```bash
git stash list --max-count=1
```

Set `STASH_CREATED=true`.

**If stash fails:** Stop immediately — the user's changes must be protected before any mutations. Report the error.

> Stashed N uncommitted changes (including untracked files).

---

## Phase 2: Fetch

Sync all remote refs and prune deleted branches.

```bash
git fetch --all --prune
```

**If fetch fails:**
- Authentication error → tell user to check credentials/SSH keys
- Network error → tell user the remote is unreachable
- Stop in all cases. Do not proceed without fresh refs.

### Check ahead/behind status

```bash
git rev-list --left-right --count HEAD...$UPSTREAM
```

Output is `<ahead>\t<behind>`.

| Ahead | Behind | Action |
|-------|--------|--------|
| 0 | 0 | Up to date — skip to Phase 5 |
| 0 | N | Only behind — rebase will fast-forward |
| N | 0 | Only ahead — skip rebase, go to Phase 4 |
| N | M | Diverged — rebase will replay local commits |

> Fetch complete. Branch is N ahead, M behind `$UPSTREAM`.

---

## Phase 3: Rebase

Skip this phase if `BEHIND=0`.

```bash
git rebase $UPSTREAM
```

### Success — no conflicts

Set `REBASE_REWROTE=true` if branch was both ahead AND behind (rebase replayed commits, SHAs changed). Set `REBASE_REWROTE=false` if it was a fast-forward (behind only).

> Rebase successful. [Fast-forwarded / Replayed N commits onto `$UPSTREAM`].

### Conflicts

Assess complexity:

```bash
git diff --name-only --diff-filter=U
```

**Simple conflicts (1–3 files, obvious resolution):**

1. Read each conflicted file to understand the conflict
2. If resolution is clear (e.g. both sides added imports, trivial formatting), resolve it
3. `git add <resolved-file>` for each
4. `git rebase --continue`
5. If more conflicts appear, repeat. If any conflict is non-obvious, abort.

**Complex conflicts (4+ files, semantic conflicts, or uncertain resolution):**

```bash
git rebase --abort
```

> Rebase produced conflicts in N files that I cannot confidently resolve:
> - `file1` — [brief description]
> - `file2` — [brief description]
>
> Branch restored to pre-rebase state (HEAD: `$CHECKPOINT_SHA`).
> Options:
> 1. Re-attempt rebase and you resolve conflicts manually
> 2. Use merge instead (`git merge $UPSTREAM`)
> 3. Cancel sync entirely

Wait for user decision. Do not proceed.

### Rollback

```bash
git rebase --abort
```

Verify: `git rev-parse HEAD` should equal `$CHECKPOINT_SHA`.

---

## Phase 4: Push

Skip if `AHEAD=0` and rebase was fast-forward only (no local commits to push).

### After rebase rewrote history (`REBASE_REWROTE=true`)

Local commits have new SHAs. Remote has old ones. Use `--force-with-lease` — it only succeeds if the remote branch matches what we last fetched:

```bash
git push --force-with-lease
```

**If rejected:** Someone pushed between our fetch and push. Tell the user: "Push rejected — remote was updated by someone else. Re-run git sync to incorporate their changes." Do not force push. Do not retry.

### No rewrite (`REBASE_REWROTE=false`)

```bash
git push
```

**If rejected (non-fast-forward):** Same as above — tell user to re-run sync.

> Pushed N commits to `$UPSTREAM`. [Used --force-with-lease due to rebase rewrite.]

---

## Phase 5: Unstash

Skip if `STASH_CREATED=false`.

```bash
git stash pop
```

### Success

> Restored stashed changes. Working tree is back to where you left it.

### Conflicts

```bash
git diff --name-only --diff-filter=U
```

**Simple conflicts (1–2 files):** Resolve, then `git add` the files and `git stash drop`.

**Complex conflicts:** Do NOT drop the stash. Leave it intact.

> Your stashed changes conflict with the updated code in:
> - `file1`
> - `file2`
>
> The stash is preserved (`git stash list` to see it). You can:
> 1. Resolve conflicts manually, then `git stash drop`
> 2. `git stash show -p` to see what was stashed

### Error (not conflicts)

The stash is still intact. Report the error and the stash ref.

---

## Full Rollback Procedure

If you need to completely unwind at any point:

```bash
# 1. Abort in-progress rebase
git rebase --abort 2>/dev/null

# 2. Reset to checkpoint
git reset --hard $CHECKPOINT_SHA

# 3. Verify
test "$(git rev-parse HEAD)" = "$CHECKPOINT_SHA" && echo "Rollback verified" || echo "WARNING: HEAD mismatch"
```

Then, if `STASH_CREATED=true` and stash has not been popped:

```bash
# 4. Verify our stash is on top
git stash list --max-count=1 | grep "git-sync: auto-stash"

# 5. Restore
git stash pop
```

> Rolled back to checkpoint `$CHECKPOINT_SHA`. Working tree restored. No changes were pushed to the remote.

---

## Final Report

After all phases complete:

> **Git Sync Complete**
> - Branch: `$BRANCH`
> - Upstream: `$UPSTREAM`
> - Rebase: [fast-forward / replayed N commits / skipped]
> - Push: [pushed N commits / force-with-lease / skipped]
> - Stash: [restored / not needed]
> - New HEAD: `$(git rev-parse --short HEAD)`

---

## Edge Cases

| Scenario | Action |
|----------|--------|
| Detached HEAD | Stop in pre-flight |
| No tracking branch | Ask user to set one or push to create |
| Rebase/merge in progress | Stop in pre-flight |
| Empty repo (no commits) | Stop in pre-flight |
| Branch only exists locally | Push with `-u` to create, done |
| Upstream branch deleted | Report after fetch --prune |
| Multiple remotes | fetch --all syncs all; rebase uses configured upstream |
| Already up to date | Report and skip rebase/push |
| Force-with-lease rejected | Tell user to re-run sync |
| Network failure during push | Report; stash already restored; push can be retried |
| Submodules present | Note to user: run `git submodule update --init --recursive` after sync |

## Safety Rules

1. **Never `git push --force`.** Always `--force-with-lease`.
2. **Never `reset --hard` without a checkpoint.** Only reset to `$CHECKPOINT_SHA`.
3. **Never drop a stash you cannot restore.** If unstash conflicts, leave the stash intact.
4. **Abort rebase on doubt.** If you are not confident in a conflict resolution, abort and ask.
5. **Do not skip phases.** Each phase depends on the previous one succeeding.
6. **Report after every phase.** The user should always know what happened and what is next.
