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

## 2026-09-25 → 2026-09-25 · Organized model picker · Completed

- Plan: `2026-09-25-organized-model-picker.md`, deleted in commit `docs(plans): close organized model picker`.
- Outcome: the shared `ModelPicker` shows a Recent rail (Gateway-wide `model.recent`, recorded at admitted user-input runs), a Latest rail (bundled models.dev `releaseDate` on `model.list`, alias-only when a pinned release shares its date), and provider sections that collapse like dashboard workspaces and remember each explicit choice per device, Gateway profile and provider. Search hides both rails and expands every matching section. The New Session quick selections and dashboard disclosure moved onto the same shared `TronCardRail` and `TronDisclosure` primitives.
- Key commits: `cdb481496` (MP1, MP2), `c35bd9ad2` (observability row), `e0c1c0221` (MP3–MP6), `4a47b0385` (expansion memory fix).
- Deviations: the refresh script is `scripts/update-model-release-dates.mjs`, following the Node-script naming in `scripts/`. Both DeepSeek workers hit the 30-minute child timeout once and were resumed from their partial worktrees. Supervisor review found the expansion store persisted only collapses, so expanding a provider without the selection was forgotten; it now stores explicit choices, with a failing-first test.
- Lessons: a remembered-state store must be tested for both directions of every choice, not only the one that differs from the default. Hosted tests that share a device store need an explicit reset, not a reset that depends on the store's current semantics. Gateway vitest must run on Homebrew or nvm Node; the Tron.app bundled Node cannot load rolldown's native binding.
- Knowledge moved to: `packages/gateway/README.md` (model recents and release dates), `packages/gateway/docs/observability.md` (`recent-model-record-failed`), `packages/ios-app/docs/development.md` and `architecture.md` (picker layout and tests).

## 2026-09-25 → 2026-09-26 · Agent resources organization · Completed

- Plan: `2026-09-25-agent-resources-organization.md`, deleted in commit `docs(plans): close agent resources organization`.
- Outcome: Settings now shows what is installed in or configured on the agent (Extensions with Installed packages and read-only Tron Modules, and Hooks under Agent), and Manage Session → Project Resources shows what the agent can use (Skills, Subagents, Prompts, Tools, Commands), each row tagged External, Module or Local. Every installed package opens a detail sheet listing what it provides. The user rebuilt the Gateway, installed iOS and verified the sheets on the phone.
- Key commits: `12b24b5bc` (distribution tag and subagents), `bacc45668`, `3a5b04bdd`, `4dcd55b7e` (Tron modules, `modules.list`, `hooks.list`), `f75c5b7ac`, `82a3aa4ee` (shared session-free loader, package provides), `cd3c47c63`, `602a77b14`, `eb9c8463f`, `8a23571cc` (iOS Project Resources, Extensions, Hooks), `81fa926e8` (package detail sheet), `c6204c216` (section order).
- Deviations: R-0 showed the tag could not reuse Pi's `origin`, so it became a new `distribution` field. The user added R-7/R-8 so installed packages show what they provide, and later set the group order to Skills, Subagents, Prompts, Tools, Commands. Pi themes stayed under Extensions because they affect only the Mac terminal. R-6's simulator walkthrough became the user's on-device check after the rebuild, because the simulator app was unpaired.
- Lessons: Settle one vocabulary table against the repository before wire work; it prevented a colliding `origin`/`provenance` field. The iOS hosting harness cannot assert rendered SwiftUI text or nested-control tap routing (an Installed row button containing a menu), so those need a device or UI-test check. New Gateway fields reach iOS only after a user rebuild, so iOS decodes them optionally.
- Knowledge moved to: `packages/gateway/README.md` (distribution rule, subagents, `modules.list`, `hooks.list`, package `provides`), `packages/ios-app/docs/architecture.md` and `packages/ios-app/docs/development.md` (Settings versus Project Resources ownership, sheets and group order).

## 2026-09-26 → 2026-09-26 · Session archive · Completed

- Plan: `2026-09-26-session-archive.md`, deleted in commit `docs(plans): close session archive`.
- Outcome: an idle session can be archived instead of deleted.
  - It leaves the dashboard for one collapsed Archived (N) section at the bottom, and stays searchable, labeled Archived.
  - Any new run unarchives it; opening or reading it does not.
  - Archive state is a Gateway-owned store (`session-archive.json`) behind `session-archive.v1`, never written into the Pi JSONL.
  - On iOS, a swipe reveals Archive or Unarchive, which then confirm like Delete. Expanding the section shows a header spinner and scrolls the revealed rows into view.
  - The user rebuilt the Gateway and iOS and confirmed it on the phone.
- Key commits:
  - Gateway: `bf521117e` (G-1), `5e718feb7` (G-2), `60e8773c9` (G-3).
  - iOS: `e8cf7b6ef` (I-1), `9a5934a54` (I-2), `064803d95` (I-3).
  - Follow-ups: `2dddf1f56` (F-3), `83994c2fd` (F-4), `1005048c5` (F-1/F-2), `db2ad600d` (F-5).
  - Review fixes: `ba0428e3a`, `4fbc144e4`, `6652c02a2` (R-1, F-6); `4fff91115` (R-2); `d07c068ea` (R-3); `d6924459f` (R-4); `9fc3b3e58` (R-5).
  - User changes: `8ea4c5507` (C-1), `b00626e38` (C-2), `58847d0b5` (C-3).
- Deviations:
  - Three independent review rounds found and fixed real defects, including:
    - archived rows with no owning Gateway, so two-Mac actions went to the wrong one;
    - a registry-mutex stall while waiting on a session lane;
    - a running session hidden after a failed write;
    - an iOS parallel archived-ID set;
    - a round-two regression that blocked extension `switchSession`.
  - Pre-existing defects fixed along the way:
    - mutation RPCs rejecting themselves as busy (F-1/F-2);
    - unwaited durable writes at disposal (F-5/F-6);
    - a dropped deferred catalog refresh after a retired traversal (C-2), fixed generally in both the selected and pool catalog paths.
  - By the user's decisions:
    - full-swipe archive was replaced by tap-and-confirm (C-1);
    - the pre-existing `switchSession` receipt split moved to its own proposal (F-7).
- Lessons:
  - Parallel workers need a supervisor review of each merged branch; every round found real bugs that the workers' own green tests missed, often because tests injected state that production never supplies.
  - Hosted UI fixtures must render production containers and declare their presentation activity, or XCUI never idles.
  - A catalog refresh that retires its own read must still owe a follow-up.
  - Gateway vitest needs Homebrew or nvm Node, and `scripts/ios-gateway-e2e-test` needs a plain Node 22.22.0, because the signed payload Node rejects unsigned native addons.
- Knowledge moved to: `packages/gateway/README.md` (archive contract, run-unarchive rule, disposal drains, mutation idle admission), `packages/gateway/docs/observability.md` (archive events), `packages/gateway/docs/session-search.md` (`archived` label), `packages/ios-app/docs/architecture.md` and `development.md` (dashboard archive flow, container, journeys).
- Follow-up (not in this plan): the Proposed `2026-09-26-switch-session-receipts.md`, and a later general dashboard sync-hardening pass, including the ~2 s `session.list` on the user's Mac.

## 2026-09-26 → 2026-09-27 · Switch-session invocation receipts · Completed

- Plan: `2026-09-26-switch-session-receipts.md`, deleted in commit `fix(sessions): settle a session-replacing command in its origin`.
- Outcome: an extension command that calls `ctx.switchSession`, `ctx.newSession` or `ctx.fork` is now settled in the session it started in, at Pi's committed replacement boundary. The replacement opens, the origin records the command `completed`, and no work, marker or pending state leaks. By the user's choice (S-1 option 1), handler code after the call runs unowned in the replacement.
- Key commits: `2759b2cae` (S-1 findings and options), `049bee820` (option 1 chosen), and the closing fix commit named above.
- Deviations:
  - The defect was not specific to the `preserve` rebind: `newSession` and `fork` failed identically.
  - Two S-1 symptoms were consequences, not separate defects. The missing terminal and snapshot came from a `publishSnapshot` that threw after the `accepted` receipt landed in the replacement. The "stranded client" was an artifact of the archive fixture, which had not wired `sessionRekeyed`; production does, and the fixture now does too.
  - Receipt and marker-clear writes now capture their session when requested, because a retry after a rebind would otherwise land in the replacement.
- Lessons:
  - A write that reads live identity at execution time is wrong across a rebind; bind the identity when the write is requested.
  - Ablate each mechanism: a live-invocation guard and a pending-state clear looked necessary but protected nothing observable and were removed. The two identity captures were proven by an injected retry that succeeds only after the rebind.
  - A test fixture that composes the Gateway must mirror `gateway-main.ts` wiring, or it reports production defects that do not exist.
- Knowledge moved to: `packages/gateway/README.md` (receipt ownership across a command-driven replacement).

