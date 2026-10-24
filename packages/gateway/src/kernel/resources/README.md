# gateway/resources

## Purpose

K4 owns executable resource admission and canonical Project-root identity.

## Owns

`project-root.ts` resolves the real Git worktree root through the platform bounded
Git process owner. The actual spawned process, environment sanitization, output
bounds, exit rules and retirement live in `util/git-inspection.ts`.

## Contract

`projectRoot(cwd)` returns the real worktree root, or the caller’s cwd when Git
has no usable worktree. Timeout and overflow remain retryable failures.

## Invariants

Project trust and Project settings address the same canonical worktree root.
A linked worktree has its own root; inherited Git selectors never redirect it.

## Entry points

`projectRoot`.

## Signals

Git launch, timeout and output failures propagate as existing Gateway errors.

## Verify

```bash
scripts/tron test gateway src/sessions/project-root.integration.test.ts \
  src/machine/workspace-inspection-service.integration.test.ts
```

## Not here

User workspace browsing, Git status/history projection and worktree creation:
[machine](../../machine/README.md).
