---
name: Git Operations
description: Version control with git best practices and safe defaults
version: "1.0.0"
tags: [git, vcs]
allowedTools: [Bash]
display:
  label: Git
  icon: arrow.triangle.branch
  color: "#F97316"
---

# Git Operations

Version control with `git`. Follow safe defaults and best practices.
Always include `skill: "git"` in your Bash call when using this skill.

## Common Operations

```bash
# Status and overview
git status
git log --oneline -10
git diff --stat

# Branching
git branch -a                    # List all branches
git checkout -b feature/name     # Create and switch to new branch
git switch main                  # Switch to main

# Staging and committing
git add file1.rs file2.rs        # Stage specific files (preferred)
git commit -m "feat: description"

# Viewing changes
git diff                         # Unstaged changes
git diff --staged                # Staged changes
git diff main...HEAD             # All changes since diverging from main
git log --oneline main..HEAD     # Commits on this branch

# Remote operations
git fetch origin
git pull --rebase origin main    # Preferred over merge for linear history
git push -u origin branch-name   # Push and set upstream
```

## Safe Defaults

- **Stage specific files** rather than `git add -A` or `git add .` to avoid accidentally including sensitive files
- **Create new commits** rather than amending unless explicitly asked — amending rewrites history
- **Never force push to main/master** — warn if asked
- **Never skip hooks** (`--no-verify`) unless explicitly asked
- **Investigate before destructive operations** — `git reset --hard`, `git clean -f`, `git checkout .` discard work permanently
- **Resolve merge conflicts** rather than discarding changes
- **Check lock files** before deleting — another process may hold them

## Commit Message Style

Follow the repository's existing commit style. Common conventions:

```
type(scope): short description

type: feat, fix, refactor, test, docs, chore, ci
scope: module or area affected
```

## Diff Inspection

Before committing, always review:
```bash
git diff --staged    # What's about to be committed
git status           # Any untracked files that should be included
```
