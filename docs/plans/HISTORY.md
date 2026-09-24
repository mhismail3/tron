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

## 2026-09-23 → 2026-09-24 · Observability foundation · Completed

- Plan: `2026-09-23-observability-foundation.md`, deleted in commit `docs(plans): close observability foundation`.
- Outcome: every Tron process now records automatically, at a fixed level, in a known place: the Gateway (four levels, debug buffer, 40 MB segmented retention, startup, shutdown and drain timing, stall evidence), the deploy helper and C launcher (`deploy.jsonl`, captured stderr), the Mac app (`mac.jsonl`) and the phone (always-on `AppLog`, one-tap export, connect records that say whether a transport opened). `scripts/tron diagnose` collects one redacted bundle. The work also made source rebuilds cheaper (fewer fingerprints, one clone copy), fixed false `mac verify` failures, a 14 s synchronous search-index clear at startup, a 15 s forced shutdown during search warm-up, and semantic search never finding its helper. The user approved and received drain judgment by oldest blocker (L-17), proceeding past unresolved owners (L-18) and the "No path to this Mac" label (L-9a).
- Key commits: `1919394af` (L-0), `3897f0c26` (L-1a), `c00a62e52` (L-2), `ff9700958` (L-1c), `669d07534` (L-16), `a97571044` (L-10), `2bd3c376e` (L-15), `af16dc297` (L-7), `162fc33d2` (protocol corrections), `957028716` (L-11), `66ff518bb` (L-15b), `b69523c16` (L-5), `669f6e05c` (L-1b), `5bf7575b6` (L-12), `165bf30fb` (L-3), `0d16fc9d0` (L-1d), `b3ba2f53c` (L-13), `84e392b8a` (L-4), `75e0efc73` (L-14), `1548d35c6` (L-19a), `1c70ab311` (L-3b), `19197bd74` (L-6), `af16f999b` (L-17, L-18), `1acf71bfd` (L-9a), `9fd686a7d` (L-15c).
- Deviations: stderr capture moved from the LaunchAgent plist to the launcher, because launchd does not expand `~` in a static bundled plist. Node 22 cannot clone on macOS, so payload copies use `/bin/cp -c`. L-8b (search warm-up peak heap) was blocked on the core session reader and moved to the simplification program as S-GW-SESS-SEARCH-1. L-9b (stall tolerance versus faster give-up) waits for L-9a data and moved to a proposed plan. Supervisor review rejected or corrected several lane changes that passed their own tests: a skipped pre-publication import check (L-11), a clone flag Node ignores (L-14), a `~` path launchd never expands (L-1d), an 8 s event-loop block moved onto the reconnect path (L-15c), and unguarded awaits in admission-ordered connect paths (L-9a).
- Lessons: measure against the real artifact, not a simplified reproduction; one-table and small-fixture repros hid both the 8 s cascade delete and the missing clone. A lane that builds the Mac app runs `npm ci` and must not share a symlinked `node_modules`. Code under test that resolves the Tron home globally needs a test `TRON_DATA_DIR`. The full Gateway suite is safe on the live Mac at `nice -n 19` with two workers. When a restart's records leave a gap, add the step records first; the next restart then names the cause.
- Knowledge moved to: `packages/gateway/docs/observability.md` (level policy, streams, retention, privacy, event catalog), `AGENTS.md` (the incident rule), `packages/gateway/README.md` (logging, diagnostic bundle, export, deploy and drain contracts), `packages/gateway/docs/connection-resilience.md`, `packages/mac-app/docs/architecture.md` and `development.md`, `packages/ios-app/docs/architecture.md`, `development.md` and `events.md`.

## 2026-09-24 → 2026-09-24 · SDK-backed Anthropic model catalog · Completed

- Plan: `2026-09-24-anthropic-model-catalog.md`, deleted in commit `docs(plans): close anthropic model catalog`.
- Outcome: the local CortexKit Pi extension (`@cortexkit/pi-anthropic-auth` 1.23.1-tron.5, CortexKit commits `9bfd6cc`, `adde152`, `8b811d6`; unpublished) builds its Anthropic catalog from a deep-cloned snapshot of the pinned SDK's built-in models, filtered by a converter-proven allowlist, and adapts only transport and auth. It adds Haiku 4.5 and the dated Opus 4.5 and Sonnet 4.5 entries, keeps Mythos 5 and 5.1 as labelled additions, and offers only thinking levels that a no-network request matrix proves are sent as distinct, valid values. The user installed it, and the live Gateway lists all 14 models. Live model discovery is unavailable for subscription OAuth, so the pinned SDK stays the catalog authority.
- Key commits: Tron `ad0d40c63` (CAT-1 and CAT-4 findings), `91dbdc060` (CAT-2), `4e4e64b14` (CAT-3), `42f21e1f5` (tron.4 correction); CortexKit `9bfd6cc`, `adde152`, `8b811d6`.
- Deviations: by the user's decisions, adaptive Minimal is sent as Low, and Off is hidden on models that always think. Opus 4.6, 4.7 and Sonnet 4.6, plus Opus 4.8's Extra High and Max, are excluded until CortexKit has an adaptive converter branch for them. The first adopted build, tron.4, failed to load because Pi's extension loader does not alias `@earendil-works/pi-ai/providers/anthropic`; tron.5 fixed that and added a loader-alias test.
- Lessons: an extension's imports must be checked against Pi's extension-loader aliases, and adoption must be proven by loading through `loadExtensions`, not by ordinary module resolution. Copying SDK thinking maps is not enough: the converter decides which levels are real, so prove each level on the wire. The SDK's own provider is not ground truth for CortexKit's subscription path.
- Knowledge moved to: the CortexKit pi package README and CHANGELOG, `packages/ios-app/docs/architecture.md` (authoritative names versus ID fallback), and `packages/gateway/src/providers/provider-usage.test.ts` (usage admission for every CortexKit model).
- Follow-up (not a plan): an adaptive converter branch in CortexKit would admit Opus 4.6 and 4.7, Sonnet 4.6, and Opus 4.8's extended levels.
