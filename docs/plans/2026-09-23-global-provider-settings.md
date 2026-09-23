# Global provider extension settings

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-23, GP-1
- **Goal:** Make globally installed provider extensions discoverable and configurable in Dashboard Providers without opening a session, while preserving project isolation and reliable lifecycle ownership.

## Goal and constraints

A provider declared by a user/global Pi extension must be listed and support its declared API-key/OAuth authentication in Dashboard → Settings → Providers before any chat session is opened. Global provider registrations and credentials belong to the canonical global ModelRuntime. Project-only extensions remain available only to their trusted project/session runtime. Session catalogs may not be unioned into a global catalog, and the Gateway must not create hidden sessions, a second credential store, extension-specific provider code, or speculative compatibility layers.

Pi's pinned SDK is authoritative for extension loading, provider registration, resource-loader lifecycle, credentials, and package semantics. Global settings, package install/update/remove and resource changes must become visible through a well-defined owner/invalidation boundary. Malformed or partially failing extensions must not erase valid providers or strand their resources. Authentication operations must use the same global runtime that serves the global catalog and retain the resource owner for their lifetime. Do not claim active runtime updates unless the SDK provides a safe supported reload/unregister/teardown contract.

Implement and validate repository source/artifacts only. Do not rebuild, restart, update, promote, roll back, or deploy the running Gateway; the maintainer performs any runtime transition manually. Do not modify the actual user's installed package, credentials, or canonical settings to create tests. Leave the unrelated proposed `docs/plans/2026-09-23-abandoned-login-cleanup.md` untouched; abandoned-login cleanup is outside this plan except for shared lifecycle correctness required here.

## Context

Initial evidence from source at `e7cab3b167e32852d1d52a1bacff30e5b1bc5587`:

- The Gateway's `provider.list` and auth commands use the process-wide `modelRuntime`; session-targeted requests use the acquired RuntimeSlot's separate ModelRuntime.
- `packages/gateway/src/gateway-main.ts` constructs retained `administrationServices` with `createAgentSessionServices` against the global `modelRuntime`, resolving no project trust. This SDK helper loads global resources and registers discovered providers. Package/resource RPC mutations broadcast `packages.changed`, but no global administration resource reload/reconciliation boundary is apparent yet. Validate rather than assume.
- Pi SDK is pinned at 0.84.4. Its public `createAgentSessionServices` registers pending extension providers into the supplied ModelRuntime; `ModelRuntime` has register/unregister provider APIs. Inspect package declarations and implementation for resourceLoader.reload, provider lifetime, unload/teardown and error semantics before designing refresh.
- iOS Dashboard Providers uses target `.global`; session-scoped provider settings use `.session(id:)`, and the existing provider catalog coordinator fences async loads. Verify these contracts and invalidation delivery before altering them.
- The user's global `pi-sub-anthropic@0.1.4` is installed in `~/.tron/agent/npm`, but it was not modified as part of this plan. Its model and registration were previously observed only in a session runtime. Treat that as an incident reproduction candidate, not sole test scope.
- A previous focused Vitest launch was blocked by a missing Rolldown optional native binding in the development environment. Diagnose locally without deleting lockfiles or canonical state, and record actual results.

## Plan rules

- Keep one canonical ModelRuntime and AuthStorage for global providers. Keep session runtimes independently scoped.
- Treat resource loader and loaded extension as execution owners, not disposable catalog scans. Any replacement waits for provider/auth users to settle before retiring the old owner.
- Package mutations are already serialized in PackageService. Connect their authoritative completion to safe global-resource reconciliation; events are notifications, not state truth.
- Preserve valid earlier provider registrations if one extension fails, but surface bounded diagnostics for the failed owner. Duplicate/colliding provider IDs fail closed under existing SDK rules.
- Every async refresh/load must be bounded, serialized or generation-fenced, failure-safe and explicitly disposed. No unbounded extension/runtime copies.
- Update focused contract/integration tests and owning Gateway docs together. Do iOS code changes only if source/test evidence identifies a separate catalog admission/publication defect; otherwise preserve its existing exact-request fence.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| GP-1 | Claimed | Trace and implement global provider resource ownership/reconciliation, Gateway RPC, and regressions | none | worker, 2026-09-23 |
| GP-2 | Ready | Verify dashboard and session catalog/auth behavior against global/project scope; fix only demonstrated iOS defect | GP-1 | Unassigned |
| GP-3 | Ready | Validate package transitions, bounded failures/teardown, docs and manual runtime adoption | GP-1, GP-2 | Unassigned |

## Task details

### GP-1 — Global extension provider runtime

Inspect `packages/gateway/src/gateway-main.ts`, `packages/gateway/src/admin/package-service.ts`, `packages/gateway/src/transport/gateway-service.ts`, `packages/gateway/src/sessions/runtime-registry.ts`, relevant Gateway tests, and the exact SDK public type declarations/source for `DefaultResourceLoader`, `ModelRuntime`, provider registration, and extension shutdown.

Prove these observable transitions using isolated temp agent homes/resource fixtures and test-only providers/extensions (never the real `~/.tron` installation):

1. At Gateway startup, a globally configured provider is available via global `provider.list`, `model.list`, and `auth.begin` before any session create/open RPC. A project-only provider cannot appear globally.
2. A successful user-scope package install/update/remove and global extension/settings resource change is reflected in the global catalog/auth runtime without a hidden session. Project package changes do not mutate global providers.
3. One broken extension is diagnosed and does not erase functioning providers. Failed refresh does not publish a half-replaced registry or strand the currently valid provider/auth owner.
4. Active login/provider operations are not invalidated by resource reload. Teardown is bounded and joined; if SDK lacks a supported safe dynamic unload, choose and document a supported restart/manual transition rather than inventing an unsafe mechanism.
5. Repeated refreshes do not duplicate provider registration, retain old resource loaders, or leak extension runtime callbacks. Concurrent refresh and provider-list/auth calls observe coherent state.

Use the SDK supported API for extensions. If its loader contract cannot safely reconcile live loaded code, keep startup composition and implement only the correct package/resource invalidation/restart-required reporting allowed by current product protocol; raise an explicit decision if this would violate immediate visibility in the user requirement. Do not edit SDK internals or runtime dependencies.

Targeted files likely include a new small admin/global-resource owner, `gateway-main.ts`, package service callback wiring, Gateway protocol/RPC service and focused integration tests. Determine exact minimal seam from code before changing.

### GP-2 — iOS surface contract

Review `ProviderSettingsView.swift`, `ProviderAuthCoordinator.swift`, provider catalog invalidation/events, `ProviderSetupRow`/configuration sheet, and owning tests. Verify dashboard's `.global` target receives the current global catalog and that OAuth/API-key interactions route to the same global model runtime. Verify session settings continue to target their session runtime and never publish their package-only providers globally.

If no iOS defect exists, make no native changes and record the observed contract in docs/tests. If a defect is proven, load `.agents/skills/tron-ios/SKILL.md`, add focused owner tests, and make the narrow fix.

### GP-3 — Validation and docs

Update the contract in `packages/gateway/README.md` and the nearest iOS architecture/development documentation, including the distinction between global and trusted project providers and exact package/settings invalidation semantics. Run focused Gateway integration and iOS coordinator tests as applicable, package/gateway build, `scripts/check-documentation-policy.py`, and `scripts/personal-info-guard.sh`.

Inspect final diff/status and report changed files, added tests, commands/results, integration commit/artifact state, whether worktree changes were integrated, manual maintainer action needed to make a running Gateway serve the new global catalog, and all unresolved SDK/resource lifetime risks. Do not mutate running Gateway lifecycle.

## Handoff log

### GP-1 · Claimed · 2026-09-23 · worker

- Result: User explicitly approved drafting and implementation in the same request; plan is Active and GP-1 is claimed before implementation.
- Evidence: Pinned SDK 0.84.4 contains `createAgentSessionServices` global resource loading and ModelRuntime provider register/unregister APIs; current main already retains a startup administration resource owner, but package mutation reconciliation and end-to-end tests remain to be proven.
- Changes: Activation commit `1f6a94cfd`; claim commit follows.
- Tasks added: GP-2, GP-3.
- Kept on purpose: Exact global runtime/AuthStorage ownership and project/runtime isolation; no provider-specific handling.
- Deviations: None yet.
- For the next agent: Continue in the claimed worktree; inspect the pinned SDK's full `DefaultResourceLoader.reload` lifecycle and avoid treating successful startup registration as proof of live package transition support.
