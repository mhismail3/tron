# Work history

One entry per finished or abandoned plan, oldest first. This file records what
happened. It never describes current behavior; the code and owning docs do. To
read a plan's full text, check out the commit before the one that deleted it.

Append entries in this format when closing a plan (see [the plan protocol](README.md#closing-a-plan)):

```markdown
## YYYY-MM-DD → YYYY-MM-DD · <Title> · Completed | Abandoned

- Plan: <plan file name>, deleted in <commit>
- Outcome: <one or two sentences>
- Key commits: <commits>
- Deviations: <how the work differed from the plan>
- Lessons: <what future work should know>
- Knowledge moved to: <owning docs that now hold the lasting rules>
```

## Entries

## 2026-09-23 → 2026-09-23 · Global provider extension settings · Completed

- Plan: `2026-09-23-global-provider-settings.md`, deleted in commit `docs(plan): close global provider settings`.
- Outcome: Global extensions and package-installed provider registrations are available through the canonical administration ModelRuntime and reconcile safely after global resource changes. The reviewed implementation is integrated into local `main`; the running Gateway was not transitioned.
- Key commits: `1f6a94cfd` (activate plan), `86194d0bc` (claim GP-1), `daf6dc11b` (initial implementation), `fcdf90345` (review fixes and integration).
- Deviations: No iOS code change was needed. Review corrected the initial false fail-closed collision assumption to match the pinned SDK's ordered merge contract. The maintainer must manually transition the Gateway and verify the live dashboard/auth flow.
- Lessons: Track underlying global login promises until actual settlement after cancellation/timeout. Provider IDs may have multiple ordered contributors; unregister and replay current contributions to remove stale merged fields while retaining the real extension runtime for failed registrations. Serialize global provider/model reads with asynchronous publication. Reconcile only successful or explicitly uncertain admitted global mutations.
- Knowledge moved to: `packages/gateway/README.md`, `packages/ios-app/docs/architecture.md`.
