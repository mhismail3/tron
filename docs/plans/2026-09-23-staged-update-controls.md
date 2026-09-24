# Install staged Gateway updates from the app

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-23, approval
- **Goal:** Let the user safely adopt an exact verified staged Gateway artifact from iPhone settings without a Terminal command.

## Goal and constraints

Preserve user-confirmed, drain-aware Gateway transitions and exact candidate identity. The Gateway/control-plane deployment owner remains authoritative for verification, admission, progress, readiness and rollback; iOS is a bounded presentation and command client, not a second updater.

Do not turn source rebuild into dependency installation, automatically promote candidates, infer Debug provenance, weaken signature/fingerprint checks, or claim success from RPC acknowledgement. Preserve explicit source rebuild and Debug-to-Stable flows. Agents may implement and validate source/artifacts, but a user or maintainer must initiate every running Gateway transition.

This approved plan captures future work. Committing it does not start implementation or authorize deployment. Claim tasks on main before implementation.

## Context

On 2026-09-23 the SDK upgrade required a dependency-bearing staged artifact. The backend supports artifact promotion with an exact candidate version and fingerprint, but the iPhone's `GatewayUpdateIntent` offers only source rebuild or recognized Debug promotion. Generic staged artifacts are informational, leaving Terminal as the adoption route.

Relevant owners:
- `packages/ios-app/Sources/UI/Settings/ConnectionSettingsView.swift`
- `packages/ios-app/Sources/State/AppModel.swift`
- `packages/gateway/src/admin/gateway-update-service.ts`
- `scripts/gateway-payload-deploy.mjs`
- `packages/gateway/README.md`
- `packages/mac-app/docs/development.md`

Revalidate these contracts against the implementation branch before work; do not mistake this dated description for current behavior documentation.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| UPDATE-1 | Ready | Trace candidate status/admission and specify artifact action eligibility | none | Unassigned |
| UPDATE-2 | Ready | Implement exact staged-artifact confirmation and command flow | UPDATE-1 | Unassigned |
| UPDATE-3 | Ready | Verify lifecycle, failure recovery and native UX; update owner docs | UPDATE-2 | Unassigned |

## Task details

### UPDATE-1 — Admission contract

Trace staged candidate projection through `gateway.update.status`, native models, update intent, confirmation, RPC and the supervised helper. Reuse existing version/fingerprint provenance rather than introduce candidate discovery, copied manifests or another state store.

Define eligibility for same-channel verified generic candidates distinct from the currently selected artifact. Keep Debug-origin provenance checks intact; stale, invalid, absent, ambiguous or already-active candidates must not offer a misleading action. Show the target version/revision and enough fingerprint to distinguish artifacts. Source rebuild remains explicitly different and must not be presented as the way to change dependencies.

If the current wire contract cannot express a required field safely, propose the smallest atomic first-party contract update and document adoption order. Do not add speculative compatibility aliases.

### UPDATE-2 — User-confirmed artifact installation

Add an Install Staged Update intent alongside existing source and Debug intents. Freeze profile/channel/version/fingerprint at confirmation and send exact `mode: artifact` parameters with a stable command ID. Do not retarget an open confirmation when a newer candidate appears. Backend exact-candidate validation remains the final authority.

Handle repeated taps, uncertain responses, profile switching, cancellation of presentation, background/reconnect and candidate replacement through the existing mutation/progress owner. Accepted updates continue when the sheet closes. Distinguish queued/draining, transitioning, readiness verification, success, rollback and failure. Explain waiting for accepted agent work; never silently force-stop it.

Audit the Mac wrapper's corresponding maintenance presentation. Reuse its existing contract where applicable; explicitly disposition any equivalent gap rather than silently duplicating update logic.

### UPDATE-3 — Evidence and documentation

Add focused native intent/coordinator tests and Gateway contract tests for exact artifact admission, version-only rejection, wrong channel/fingerprint, candidate changes during confirmation, duplicate command IDs, disconnect after admission, failed health verification and rollback. Use isolated helper/transport fixtures, not the running Gateway.

Verify source-only, Debug-origin, no-candidate and already-selected states remain correct. Preserve presentation-activity/latest-request fences and accessible confirmation text. Run owning focused suites first; reserve broader checks for the final cross-module checkpoint. Load the iOS skill before simulator/build work. Show useful simulator screenshots, labelled honestly, when the UI is implemented.

Update `packages/gateway/README.md`, `packages/ios-app/docs/architecture.md` and `packages/mac-app/docs/development.md` with the actual user workflow, acceptance-versus-completion distinction and recovery behavior. Run documentation and personal-info guards. On completion, follow the existing plan closeout protocol; no new tracker or deployment automation.

## Handoff log

Approved for tracking and committed at the user's request. No tasks claimed, implementation, validation of a new UI, or runtime transition performed.
