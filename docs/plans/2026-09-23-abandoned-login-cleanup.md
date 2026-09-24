# Abandoned provider login cleanup

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-23, approval
- **Goal:** Make interrupted provider login resumable or explicitly replaceable without accumulating abandoned operations or leaking provider resources.

## Goal and constraints

Preserve login across ordinary iPhone backgrounding, browser handoffs, and transport reconnects. A disconnected socket or hidden sheet is not proof that an accepted authentication operation is abandoned. Preserve exact device ownership, profile/session targeting, command idempotency, callback validation, and canonical SDK credential storage.

Address abandoned-login admission and cleanup, not the separate problem of email links escaping the authentication browser. Do not increase capacity limits, shorten the timeout as a substitute for cleanup, cancel unrelated devices' work, or silently log out stored credentials. Do not add a durable authentication mirror, background polling loop, generic resource scheduler, or provider-specific Gateway workaround without demonstrated necessity.

The Gateway owns authentication operations; iOS owns their presentation; the provider owns its callback listener and network work. Retiring UI or removing an operation from a map does not prove its provider has settled. Keep Gateway drain accounting truthful until the exact provider invocation settles.

No Gateway rebuild, restart, deployment, or lifecycle mutation is part of agent execution. Any required running-version transition is a manual maintainer action. No live credentials, callback URLs, authorization codes, or personal diagnostics belong in source or fixtures.

## Context

Evidence inspected on 2026-09-23:

- The reported incident ended in an `auth.begin` failure and the toast “Concurrent authentication operations reached their bounded capacity.” The supplied export does not identify the pending operations or establish whether the device or global limit was reached.
- `packages/gateway/src/admin/auth-broker.ts` bounds authentication to two operations per device and eight globally, retains disconnected operations, and times them out after fifteen minutes. Repeating a command ID is idempotent, but a new begin command can admit another operation.
- `packages/ios-app/Sources/State/ProviderAuthCoordinator.swift` retains the active operation identity in memory. Recovery must cover losing that presentation identity, not just replacing a socket.
- The installed pi-sub-anthropic 0.1.4 provider uses a fixed loopback port, falls back to manual input on listener errors, and closes its listener when its callback/manual-input race exits. Verify cancellation through the actual SDK adapter rather than assuming an abort signal alone closes the listener.
- Prior local wire checks covered streaming, not mobile authentication lifecycle. A later focused Gateway test attempt could not start because the local Rolldown binding was missing; there is no passing lifecycle reproduction yet.

These are investigation inputs, not a complete reproduction. Revalidate the deployed versions and owning contracts before implementation.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| AUTH-1 | Ready | Reproduce abandoned admission and provider-resource retirement; settle the recovery contract | none | Unassigned |
| AUTH-2 | Ready | Implement Gateway-owned exact login recovery and replacement | AUTH-1 | Unassigned |
| AUTH-3 | Ready | Integrate iPhone resume, restart, and cancellation with authoritative ownership | AUTH-2 | Unassigned |
| AUTH-4 | Ready | Verify cross-boundary cleanup and publish owning documentation | AUTH-2, AUTH-3 | Unassigned |

Tasks cannot be claimed while this plan is Proposed. After approval, follow the claim-on-main and isolated-worktree procedure in `docs/plans/README.md`.

## Task details

### AUTH-1 — Reproduction and contract

Owners to trace:

- `packages/gateway/src/admin/auth-broker.ts` and `packages/gateway/src/admin/auth-broker.test.ts`
- `packages/gateway/src/transport/gateway-service.ts` and `packages/gateway/src/transport/server.ts`
- `packages/ios-app/Sources/State/ProviderAuthCoordinator.swift`
- `packages/ios-app/Sources/UI/Onboarding/SetupComponents.swift`
- `packages/ios-app/Sources/UI/Onboarding/AuthPromptSheet.swift`
- `packages/ios-app/Sources/Auth/ProviderOAuthBrowser.swift`
- The pinned SDK provider-login adapter and installed provider's cancellation/listener contract

Use synthetic credentials and local callback servers. Reproduce begin → disconnect/presentation loss → fresh begin, including a fresh coordinator with no retained operation ID. Distinguish normal reconnect, process loss, explicit dismissal, profile switch, and deliberate restart.

Record the proposed behavior before changing it:

1. Opening login for an existing exact owner/provider/auth-method/target operation recovers that operation rather than allocating another one, even after iOS loses its operation ID.
2. Explicit Restart cancels the exact recovered operation and admits a successor only after the required cleanup boundary. It is distinct from Resume; ordinary reconnect never silently restarts OAuth.
3. Distinct targets, providers, and devices cannot accidentally resume or cancel one another. For providers with a shared callback port, prove what a second distinct operation does and surface a bounded conflict where necessary rather than silently misrouting callbacks.
4. Explicit Cancel retires the operation and its owned resources. Ordinary backgrounding preserves it. Sheet dismissal behavior must be deliberate and consistent with the existing cancellation UI.
5. Providers that ignore cancellation remain accurately accounted for; a retired UI operation cannot become a successful successor or silently store credentials after cancellation. Determine the SDK's actual credential-commit fence and flag any limitation instead of claiming a guarantee it cannot provide.

Prefer extending the existing begin/resume/cancel contract over adding a separate inventory API. If matching operations are already ambiguous, require an explicit owner-scoped decision; do not choose an arbitrary operation or cancel all devices. Document any required protocol change and update first-party consumers atomically, without compatibility shims.

Acceptance: a deterministic failing behavioral test demonstrates accumulation or lost recovery, and a resource-level test observes actual listener closure/rebind and provider settlement, not merely a decremented map size.

### AUTH-2 — Gateway recovery and retirement

Implement the AUTH-1 contract at `AuthBroker`, keeping one authoritative owner of lookup, admission, delivery rebinding, cancellation, and retirement.

- Recover the exact active operation before enforcing capacity for a genuinely new admission. Replay only bounded, owner-authorized prompt/event state.
- Preserve command-ID receipts: retrying an uncertain begin/restart must not launch duplicate OAuth flows. A reused ID with different parameters remains a conflict.
- Serialize exact replacement against callback completion, timeout, cancellation, and concurrent begin calls. Fence late completion against its original identity, not the successor.
- Join provider cleanup where resource reuse requires it. If cleanup cannot settle, return an actionable bounded outcome; do not release drain ownership falsely, launch repeated colliding successors, or kill processes.
- Retain the timeout as the final bound for abandoned recoverable operations. Preserve credential storage ownership and unrelated active logins.
- If the provider itself needs a fix, deliver it through its owning source/package workflow with tests and an explicit adoption decision. Do not hand-patch the installed dependency or add a hidden fallback to Tron.

Focused coverage: same-command retry; new-command recovery; cross-device/target isolation; simultaneous begin; replacement versus late callback; timeout/cancel duplication; provider ignoring abort; resource release after manual-prompt rejection; fixed-port reuse; truthful drain release. Add only bounded, redacted lifecycle diagnostics necessary to explain admission/recovery/retirement; never log prompt values or callback query strings.

Ship the Gateway contract and tests with the implementation in `packages/gateway/README.md`.

### AUTH-3 — iPhone recovery and cancellation

Load the iOS skill before build, simulator, or device work. Keep accepted authentication mutations with the coordinator, not disposable view tasks.

- Reopening the provider flow recovers the authoritative pending operation even when the app has lost its previous operation ID.
- Present clear Continue Login, Restart Login, and Cancel behavior for recovered operations. Restart must explain that the old authorization link becomes invalid.
- Disable duplicate starts while admission/replacement is unresolved. Reconcile uncertain responses with the same command identity rather than issuing a fresh command blindly.
- Await or reconcile cancellation acknowledgement; do not discard the sole recovery handle merely because a cancellation request failed in transit.
- Fence all publications and responses by profile, target, operation, and request identity. A dismissed or stale begin response must not orphan accepted work or take over a newer sheet.
- Stop and join the old phone callback listener before reusing its port; verify both phone browser ownership and Mac provider ownership independently.
- Keep browser cancellation distinct from cancelling the whole provider operation when continuing via manual code is still supported. Preserve ordinary background/reconnect continuity.

Use focused coordinator/presentation and loopback-listener tests for process-state loss, dismissal while begin is pending, cancellation during disconnection, repeated taps, profile switch, and stale callback/completion. No credentials in snapshots or fixtures.

Ship the iOS ownership/recovery documentation in `packages/ios-app/docs/architecture.md` and relevant validation guidance in `packages/ios-app/docs/development.md` with the implementation.

### AUTH-4 — Cross-boundary verification and closeout

- Run focused Gateway and iOS owners first. Repair local test prerequisites without deleting canonical credentials/settings or blindly removing lockfiles; report unresolved tooling failures honestly.
- Exercise more consecutive abandon/recover/restart cycles than the device/global admission limits, proving recovery does not consume extra slots and replacements actually release callback resources.
- Verify that a second device's login and a different target survive the exercise unchanged, and that normal background/reconnect resumes the original operation.
- Test stale authorization URLs after replacement, dropped cancellation responses, provider settlement delayed past UI retirement, and a provider that never settles. The last case must remain visibly blocked/accounted for, not falsely reported cleaned up.
- On an authorized device/build, verify login-sheet dismissal and reopening, external-browser backgrounding, and explicit restart. The email-link callback handoff itself remains a separate product issue; do not claim this cleanup change fixes it.
- Run `scripts/personal-info-guard.sh`, the documentation-policy check, and the appropriate final cross-module checks after focused tests pass. Record actual commands, results, and any physical-device coverage limit.
- Provide manual maintainer adoption steps if changed Gateway/iOS artifacts are required. Do not transition the running Gateway.
- Move lasting knowledge into owning docs, append the completion entry to `docs/plans/HISTORY.md`, and delete this plan in the completion commit per the plan protocol.

## Handoff log

Approved for tracking and committed at the user's request. No implementation tasks claimed or completed under this plan. Before claiming AUTH-1, account for the SDK upgrade and iOS provider reattachment fix in `4822d8ac4`; CortexKit has replaced pi-sub-anthropic. Those changes do not establish Gateway recovery after loss of the operation ID or provider-resource retirement coverage.
