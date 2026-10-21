# Onboarding

## Purpose

First-run pairing and setup, plus the pickers setup shares with the rest of the app: the
workspace browser, the model picker and the provider authentication prompt sheet.

## Owns

`OnboardingView`, `OnboardingPresentationComponents`, `SetupComponents` (`ModelPicker`), `ProviderSetupRow`,
`ModelRailCard`, `ModelSelectionAvailability`, `QRCodeScanner`, `QRCodeCaptureServices`,
`WorkspaceBrowser`, `WorkspaceBrowserOwner`, `AuthPromptSheet`.

## Contract

- **Flow.** The page sequence, detents and copy are specified in
  [iPhone onboarding](../../../docs/onboarding.md). The session shell stays mounted under the
  adaptive first-run sheet.
- **Pairing.** `AppModel` admits one pairing attempt at a time; supersession, forget and switch
  cancel that exact task, and its identity is rechecked after HTTP, before the profile/Keychain
  save, before connect and after connect's suspensions, so a stale result never persists or
  connects. Invitation and HTTP rules are in [Core](../../../Core/README.md). Non-selecting pairing
  from Connections keeps the setup-completion state and suppresses the root setup sheet.
- **QR scanner.** Shares the camera-authorization boundary and delegates capture setup and serial
  start/stop to a provider. Its one permission task cancels on disappearance and rechecks before
  configuring capture; the first admitted QR value stops capture and closes the callback gate.
- **Workspace browser.** An isolated observable owner over the Gateway's folder listing; hidden
  folders are a local projection over entries already returned, never another read. Successful
  first-run pairing inspects an already selected workspace before enabling onward navigation.
- **Model picker.** `ModelPicker` (title **Models**) organizes one catalog read into a Recent rail
  (the Gateway's bounded recent-model history), a Latest rail (Gateway release dates) and one
  collapsible section per provider; cards show context window and Gateway-projected prices. The
  picker owns no usage list, date table or price table. `ModelSelectionAvailability` is a
  value-only projection of session admission and pending receipts: applying shows a pulse in a
  fixed slot, a blocked state exposes a 44-point lock that opens the full reason.
- **Auth prompts.** Provider authentication is presented only by the currently visible Providers or
  Onboarding surface, so an underlying sheet never defers a login prompt. Each row's nested-sheet
  visibility is presentation-scoped and keyed by provider and catalog target. Only actual dismissal
  retires its owned login; foreground content reconstruction and socket recovery retain the operation
  and unsent input. Manual callback syntax and state/PKCE checks remain provider-owned.

## Invariants

- Pairing never reports success without committed profile metadata and its Keychain secret.
- The picker never replaces canonical model identity `(provider, id)` or Gateway availability.

## Entry points

`OnboardingView.swift`, `SetupComponents.swift`, `WorkspaceBrowserOwner.swift`.

## Signals

None of its own.

## Verify

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronSmokeUITests/testOnboardingPreservesPagedSheetAndPairingJourney \
  --only-testing TronMobileUITests/TronSmokeUITests/testPairingValidationIsAccessibleAndDoesNotLeaveOnboarding \
  --only-testing TronMobileUITests/TronSmokeUITests/testModelAcknowledgementResolvesWithoutDismissingPicker
scripts/ios-gateway-e2e-test run-ui --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testInvitationLinkPairsCompletesSetupStreamsAndReconnectsAfterBackground
```

The real-UI journey pairs through the production invitation link and finishes first-run setup;
its wrong-code control asserts the app's own refusal. The focused
`RealGatewayPairAndChatUITests/testProviderLoginSurvivesSafariAndReconnect` journey retains a manual
login and unsent input across Safari and socket replacement, then completes, removes its fixture
credential, and logs in again against real Pi persistence.

## Not here

Profile storage and the pairing HTTP boundary: [Core](../../../Core/README.md). Provider auth
state: [State](../../State/README.md).
