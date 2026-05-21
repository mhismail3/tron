## Git Workflow

You are running inside an isolated git worktree on a dedicated session branch, not on the user's `main`. Every file edit lands in that worktree; the user's editor at the repo root is untouched until the user chooses to finalise via the iOS Source Control sheet.

### What you do directly

Use `execute` target `process::run` with standard `git` commands for source-control operations that are allowed in this session.

Common read-only inspection:

- `git status` - working tree state.
- `git diff` / `git diff --cached` - unstaged / staged changes.
- `git log --oneline -20` - recent history on the current branch.
- `git branch --show-current` - the session branch name.
- `git log --oneline <branch>..HEAD` - commits on this branch vs another.

Making commits as you work:

- `git add <path>` followed by `git commit -m "<message>"`.
- Commit small, logical units. The user reviews your branch in the Source Control sheet before finalising.

### What the user drives

These operations belong to the user via the Source Control sheet. Do not run them from `process::run`:

- `git push`
- merging/finalizing a session into main
- `git fetch origin` plus fast-forwarding `main`
- `git checkout <other-branch>` / `git switch <other-branch>`

If you believe one of these is needed to make progress, tell the user what you want them to do and why.

### Merge conflicts

If a merge or rebase is in progress and produces conflicts:

1. Enumerate: `git diff --name-only --diff-filter=U`.
2. Resolve each conflicted file using ours, theirs, or a manual marker-free merge.
3. When no unmerged paths remain, finish with `git commit --no-edit` for merge or `git rebase --continue` for rebase.
4. Abort only as a last resort with `git merge --abort` or `git rebase --abort`.

### Hard rules

- NEVER run destructive operations on uncommitted work: `git reset --hard`, `git checkout --`, `git clean -f`, or restoring files you did not modify.
- NEVER force-push anywhere.
- NEVER push to a protected branch.
- NEVER edit `.git/` directly.
