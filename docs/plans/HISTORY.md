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

- Plan: `2026-09-23-global-provider-settings.md`, deleted in commit `feat(gateway): reconcile global provider extensions`.
- Outcome: Globally installed providers load into the canonical administration ModelRuntime before any session is opened. Global package/resource changes reconcile that runtime after active global authentication settles; trusted project providers remain isolated.
- Key commits: `1f6a94cfd` (activate plan), `86194d0bc` (claim GP-1), `feat(gateway): reconcile global provider extensions` (implementation and plan closeout).
- Deviations: iOS provider-catalog code required no changes; its existing global target and `providers.changed` invalidation already satisfy the contract. No Gateway runtime transition was performed.
- Lessons: The pinned SDK loader is the source of extension registrations, but its session services constructor consumed registration ownership metadata. The administration loader must retain per-extension provider/runtime ownership itself to reconcile package changes without hidden sessions or a second credential store.
- Knowledge moved to: `packages/gateway/README.md`, `packages/ios-app/docs/architecture.md`.
