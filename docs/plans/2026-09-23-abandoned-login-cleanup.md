# Abandoned provider login cleanup

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-24, AUTH-2
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
| AUTH-1 | Done | Reproduce abandoned admission and provider-resource retirement; settle the recovery contract | none | worker, 2026-09-24 |
| AUTH-2 | Done | Implement Gateway-owned exact login recovery and replacement | AUTH-1 | worker, 2026-09-24 |
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

## Findings

### AUTH-1 findings

- A fresh `auth.begin` with a new command ID after losing the operation ID allocates a second operation for the same stable device/provider/auth-method/target. The bounded receipt only recovers a retried original command ID; `auth.resume` requires the operation ID.
- Pi SDK 0.87.1 `ModelRuntime.login` races the provider login promise against abort (`pi-ai/dist/models.js`). Aborting can settle the SDK promise and release Gateway work before an abort-ignoring provider login itself settles. The credential-store mutation is separately guarded by the signal, so a late returned credential is not committed after that abort.
- Read-only inspection of the exact npm tarballs `@cortexkit/pi-anthropic-auth@1.23.0` and `@cortexkit/anthropic-auth-core@1.23.0` shows `loginAnthropic` does not use the provider signal: it emits an authorization URL, awaits the existing manual callback prompt, and exchanges the code with `fetch` without a signal. This provider does not create a local callback listener, so a listener-close claim cannot be made about it. The iPhone handoff listener is a distinct resource owner and was not exercised here.
- Synthetic Gateway regressions prove fresh-begin accumulation, exact loopback fixture close/rebind, and early SDK work release while a synthetic provider remains pending (with credential non-commit after abort). Do not infer that a provider's completion or network exchange has settled from Gateway drain release.
- Unblocking boundary (2026-09-24): Pi's `adaptOAuth` (`pi-coding-agent/dist/core/provider-composer.js`) maps legacy `onPrompt`/`onManualCodeInput` directly to the broker's `interaction.prompt`, and `AuthBroker.retire` rejects that exact pending prompt. The installed provider is `@cortexkit/pi-anthropic-auth@1.23.1-tron.1` (not the audited 1.23.0 tarball); its `loginAnthropic` has the same shape: `onAuth` → await `onPrompt` → signal-less `exchange`. An abandoned login is in the prompt wait, so cancelling it settles the exact provider promise through a Gateway-owned boundary. The only unjoinable window is the post-code token exchange: it holds no local resource, Pi's abort-aware credential mutation fences the result, and it remains a documented limitation rather than a guarantee.
- Credential-commit fence limitation: `ModelRuntime.login` rejects on abort only before `credentials.modify` begins. If cancellation lands after the mutation started, Pi commits and resolves successfully, but `AuthBroker.complete` sees the operation already retired and emits neither `auth.completed` success nor `providers.changed`. The credential is canonical yet the UI reports cancellation. AUTH-2 owns fixing this projection.

### Settled recovery contract (AUTH-1)

Recovery key: stable owner identity + provider ID + auth type + target key. AUTH-2 enforces at most one active operation per key, so ambiguity cannot arise from new admissions.

1. **Recover.** `auth.begin` with a new command ID and a matching active key returns that operation, rebinds delivery, and replays its bounded event/prompt, before any capacity check. The response gains `recovered: true` so iOS can offer Continue/Restart. The new command ID's receipt binds to the recovered operation.
2. **Restart.** `auth.begin` gains an optional `replaceOperationId`. The broker validates exact owner and key, retires that operation (rejecting its prompt), waits for its SDK login promise to settle, then admits the successor. The command ID covers the whole replacement, so an uncertain retry cannot launch two flows. A stale `replaceOperationId` (already retired) admits normally; one naming a different key is a conflict. Ordinary reconnect uses `auth.resume` or recovery and never restarts.
3. **Isolation.** Distinct owners, providers, auth types, and targets never match. For listener-based providers with a fixed callback port, a second distinct active operation's callback capture on the same host:port is refused with a bounded conflict rather than relayed into the other operation's listener. Its provider listen failure stays bounded to that operation.
4. **Cancel and dismissal.** Explicit `auth.cancel` retires the operation. Backgrounding preserves it. Keep the existing iOS policy that cancels on sheet disappearance only while the scene is active (`ProviderAuthBrowserPolicy.shouldCancelOperationWhenProviderSheetDisappears`).
5. **Accounting.** Drain work stays tied to the SDK login promise. Providers that ignore abort after an accepted code are documented, not claimed settled. A retired operation's late success must never be reported as a successor's success, but a credential Pi actually committed must surface as `providers.changed` and a truthful tombstone completion, not a false cancellation.

## Handoff log

Approved for tracking and committed at the user's request. Before AUTH-1, account for the SDK upgrade and iOS provider reattachment fix in `4822d8ac4`; CortexKit has replaced pi-sub-anthropic. Those changes do not establish Gateway recovery after loss of the operation ID or provider-resource retirement coverage.

### AUTH-1 · Blocked · 2026-09-24 · worker

- Result: Added deterministic Gateway reproductions for id-less recovery loss and the SDK abort race; verified a synthetic cancellation-aware listener closes before a successor rebinds its port. AUTH-1 remains blocked because the exact selected provider creates no local listener, ignores the Pi login signal, and the public Pi SDK login surface does not expose the underlying provider promise for settlement accounting.
- Evidence: `npx vitest run src/admin/auth-broker.test.ts` unavailable because `npx` is not installed. The same focused Vitest suite run using the workspace's existing `node_modules/.bin/vitest` passed 16/16. Read-only package tarball audit verified exact package versions/integrities; no live login or credentials used.
- Changes: Claim commit `e7bbfa788`; implementation and findings commit recorded with this handoff.
- Tasks added: none.
- Kept on purpose: No Gateway recovery protocol or SDK/provider workaround was implemented; AUTH-1 acceptance requires settling a truthful provider-retirement boundary first.
- Deviations: The resource close/rebind proof uses a local signal-aware provider fixture because CortexKit has no local listener. The exact provider's non-abortable manual-prompt/code-exchange path was inspected, not executed against a network.
- For the next agent: Keep AUTH-1 blocked pending an explicit owning-package/SDK adoption path or a proven boundary that can join the actual provider call. Do not treat the broker's SDK-facing promise as provider settlement; preserve Pi credential-store ownership and do not add a parallel login path.

### AUTH-1 · Done · 2026-09-24 · worker (continuation)

- Result: Unblocked by a proven Gateway-owned boundary. Pi's legacy OAuth adapter routes the provider's pasted-code prompt to the broker, and broker retirement rejects it, so an abandoned manual-code login settles the exact provider promise on cancellation. Recorded the recovery contract above.
- Evidence: `npx vitest run src/admin/auth-broker.test.ts` in `packages/gateway` passed 17/17 (~0.4 s) using Homebrew Node 25.9.0 (`/opt/homebrew/bin` was missing from the agent PATH, which is what made `npx` unavailable before). `npx tsc --noEmit -p .` clean. New test `settles a signal-ignoring manual-code provider through broker prompt retirement` runs a provider fixture with the installed CortexKit shape through the real `ModelRuntime.registerProvider`/`adaptOAuth` path. Negative control: disabling the prompt rejection in `retire` fails the test. I read the installed provider source; no live login and no credentials were used.
- Changes: this commit (test, Gateway README boundary sentence, plan).
- Tasks added: none. The credential-commit projection gap and fixed-port capture conflict are folded into AUTH-2 by the settled contract.
- Kept on purpose: No SDK or provider patch. The post-code exchange window has no local resource and is fenced by Pi's credential mutation, so joining it would need an SDK change the contract does not require.
- Deviations: Listener close/rebind remains proven with the synthetic signal-aware fixture because the selected provider has no listener. The iPhone handoff listener is AUTH-3's resource.
- For the next agent: AUTH-2 implements contract items 1–5 in `AuthBroker` and `gateway-service.ts` (`recovered` response field, `replaceOperationId`, one-active-per-key, callback port conflict, and truthful late-commit projection). The `auth.begin` change is additive (optional request field, new response field), so AUTH-2 can land first and AUTH-3 consumes it. Update protocol fixtures in `packages/protocol-fixtures` with AUTH-2.

### AUTH-2 · Done · 2026-09-24 · worker

- Result: `AuthBroker` enforces one active operation per owner/provider/auth-method/target key, recovers it for a fresh `auth.begin` before capacity (`recovered: true`), and supports explicit restart through `replaceOperationId`. A successor's provider login waits for its predecessor's Pi login to settle (30 s bound, then a retryable failure while the predecessor keeps its drain work). Fixed-port callback captures owned by another active login are withheld. A success Pi committed after cancel or timeout now updates the tombstone, emits `auth.completed` and broadcasts `providers.changed`.
- Evidence: `npx vitest run src/admin/auth-broker.test.ts` 21/21. Full Gateway `npx vitest run` passed 173/174 files; the two failures came from the `start()` return-type change in `global-provider-resources.test.ts`. After fixing them, `npx vitest run src/admin` passed 93/93. `npm run build` is clean. Negative controls: disabling recovery, the predecessor wait, or the late-success projection each fails the targeted tests.
- Changes: this commit (`auth-broker.ts`, `gateway-service.ts`, tests, Gateway README).
- Tasks added: none.
- Kept on purpose: Admission stays synchronous because `DeviceStore.admitDevice` requires a synchronous register; the settlement wait is deferred into the login chain instead. A callback port conflict falls back to manual code rather than failing the login. No protocol fixture exists for `auth.begin`, so none changed. The change is additive, and current iOS ignores `recovered`.
- Deviations: The settlement boundary is Pi's login promise, not the provider's own promise. Pi hides the provider promise, so a listener-owning provider that ignores abort can still hold its port after the successor starts (see AUTH-1 findings). The successor's own listen failure stays bounded to that operation.
- For the next agent: AUTH-3 consumes `recovered` and sends `replaceOperationId` for Restart. A restart that returns `busy` for an unsettled predecessor completes asynchronously as `auth.completed` failure with a retryable message, not as an RPC error.
