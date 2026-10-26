# gateway/resources

## Purpose

K4 owns executable resource admission and canonical Project-root identity.

## Owns

`project-root.ts` resolves the real Git worktree root through the platform bounded
Git process owner. The actual spawned process, environment sanitization, output
bounds, exit rules and retirement live in `util/git-inspection.ts`.

`trust-service.ts` owns the one Pi ProjectTrustStore and serialized trust changes,
including inherited decisions, standalone directories, worktree propagation and
compensating runtime application/commit rollback. `reserveUntrustedDirectory` pins
an exact new directory before it has a Git root, never an enclosing repository.
An exact false decision on a requested directory narrows inherited/root authority;
a subdirectory's positive decision still never grants authority to its Git root.
Approved `relocate` holds that same mutex/fence, shadows destination trust before
filesystem effects and leaves both names explicitly false on a partial move. It
never replays filesystem effects or automatically moves user data backwards.
Admin supplies binding I/O;
the canonical resource owner supplies the trust decision used by sessions.

`prompt-bounds.ts` owns the prompt text/attachment limits and canonical line-bound
calculation. Native evidence reads and Episodic defaults consume its one derived
default budget; the upload producer consumes the same attachment limits.

## Contract

`projectRoot(cwd)` returns the real worktree root, or the caller’s cwd when Git
has no usable worktree. Timeout and overflow remain retryable failures.

## Invariants

Project trust and Project settings address the same canonical worktree root.
A linked worktree has its own root; inherited Git selectors never redirect it.

## Entry points

`TrustService`, `TrustInspection`, `PropagatedTrustDecision`, `projectRoot`.

## Signals

Git launch, timeout and output failures propagate as existing Gateway errors.
Unresolved decisions refuse resource loading with `trust_required`; incomplete
compensation refuses with the existing trust rollback error.

## Verify

```bash
scripts/tron test gateway src/kernel/resources/project-root.integration.test.ts \
  src/machine/workspace-inspection-service.integration.test.ts
```

## Not here

User workspace browsing, Git status/history projection and worktree creation:
[machine](../../machine/README.md).
