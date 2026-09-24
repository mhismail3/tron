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

## 2026-09-23 → 2026-09-24 · Pi SDK 0.87.1 integration · Completed

- Plan: `2026-09-23-pi-sdk-0871-upgrade.md`, deleted in commit `docs(plans): close SDK upgrade and abandoned-login plans`.
- Outcome: Tron's pinned Pi runtime moved from 0.84.4 to 0.87.1 with every applicable release delta dispositioned (TranscriptContext compaction wrapping, context-edit history, settlement events, Opus 5.5 catalog, per-model image limits). The user adopted the Gateway and iOS builds and verified the remaining SDK-5 acceptance gates.
- Key commits: `43c2a8821`, `42b795f17`, `7a4c694a2`, `3d610d0d3`, `a559326e9` (merge), `4822d8ac4` (Safari-return reattachment), `ada384d05`, `d200eef59`, `1fa1452da` (CortexKit usage).
- Deviations: Validation ran in an isolated worktree with an officially verified Node 22.22.0 because the local Node could not load Rolldown's native binding. `pi-sub-anthropic@0.1.4` proved incompatible with TranscriptContext and was replaced by a locally pinned CortexKit build (`1.23.1-tron.x`); nothing was published upstream. Login recovery work moved to the abandoned-login plan.
- Lessons: Compilation and focused suites do not prove provider behavior; capture wire requests with fake credentials and keep live OAuth acceptance as an explicit manual gate. Check external extensions against removed SDK context fields before adoption. Catalog index caches are disposable and rebuild from canonical JSONL rather than migrating.
- Knowledge moved to: `packages/gateway/README.md` (SDK package family, context-edit, settlement, import, and image-limit boundaries).

## 2026-09-23 → 2026-09-24 · Abandoned provider login cleanup · Completed

- Plan: `2026-09-23-abandoned-login-cleanup.md`, deleted in commit `docs(plans): close SDK upgrade and abandoned-login plans`.
- Outcome: A lost operation ID no longer accumulates provider logins. The Gateway recovers the one active login per owner/provider/method/target, restarts it explicitly with `replaceOperationId`, withholds conflicting fixed-port callbacks, and projects late credential commits truthfully; iOS offers Restart/Cancel for recovered logins and retries lost cancellations. The user verified the cross-boundary behavior (AUTH-4).
- Key commits: `2c708ef2c`, `2a90fcc3c` (reproductions and settlement boundary), `f94cae616` (Gateway recovery and restart), `3d234948c` (iOS recover, restart, cancel); follow-ups `f20ba9bad` (changeable choices), `e142de727` (Restart Now), `c82b12295` (restart cancels waiting logins, login logging).
- Deviations: The settlement boundary is Pi's login promise, not the provider's own promise, which Pi hides; an abort-ignoring listener provider can still hold its port after a successor starts. AUTH-4 verification was performed and reported by the user rather than recorded in an agent handoff.
- Lessons: Retiring UI or an operation map entry does not prove provider settlement; broker prompt retirement is the joinable boundary for manual-code logins. A login waiting on the user should not hold a restart drain.
- Knowledge moved to: `packages/gateway/README.md` (provider authentication), `packages/ios-app/docs/architecture.md` (provider login presentation).
