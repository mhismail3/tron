# mac-app/native-host

## Purpose

`Tron Native Host` (`com.tron.mac.native-host`): one signed Aqua helper embedded once at
`Contents/Library/Native/Tron Native Host.app` that holds the native permissions and runs
capture and the bundled Cua Driver for `computer`.

## Owns

The helper sources and metadata, its Aqua LaunchAgent and Mach services
(`com.tron.mac.native-host`, `com.tron.mac.native-host.capture`), and the inert
`TronNativeCaptureHost` static library (only the executable starts listeners). Capture wire
contract: [computer control](../../docs/computer-control.md#installed-capture-wire-contract).

## Contract

- **Setup.** Core onboarding requires only FDA (the wrapper's own probe); the same page and the
  menu's Permissions window offer optional native preparation, which does not enable computer
  control. Explicit Enable registers the service through SMAppService (after bundle validation,
  for `notFound` or `notRegistered`); background approval opens Login Items and stays visibly
  unfinished; errors surface inline. Allow buttons need a fresh enabled status; approval never
  queues a TCC request. Probes may wake a registered service but never register it, request TCC
  or restart the Gateway.
- **Authority.** The helper queries Accessibility and Screen Recording from its own process, so
  no wrapper Boolean or Gateway is permission authority. Peers are validated with
  `setConnectionCodeSigningRequirement`/`setCodeSigningRequirement` bound to product identifiers,
  team and the bundled peer's CDHash; PID, UID and endpoint bytes are not authentication. The
  capture role authenticates its peer against current Stable job, process, payload and signed
  Node provenance and cannot change permissions or lifecycle.
- **Consent.** Requests carry an operation UUID; the wrapper fences to the latest request and
  publishes only a fresh probe. The host keeps 16 bounded command receipts to reject duplicates
  (not a grant cache); TCC operations serialize on the main queue; revocation replaces old badges;
  no automatic retries.
- **Restart Helper** joins accepted consent and capture retirement, unregisters, registers,
  stops at the first error and never asks for TCC. **Disable Helper for Update** drains and
  unregisters without re-enabling. Screen Recording may be attributed to the outer app while
  Accessibility is attributed to the helper, so after a grant only Restart Helper refreshes it.
- **Lifecycle.** Mach services with `RunAtLoad` and no `KeepAlive`: launchd starts the helper
  on demand while ServiceManagement reports `.enabled`. After capture and automation retire the
  helper exits once the wrapper closes the retirement connection (an earlier exit would make the
  pinned reply fail; the wrapper logs `native-host.retirement-unconfirmed`). Uninstall joins
  retirement and unregisters the helper before removing the Gateway service; a retirement
  failure keeps Gateway registration and local state; a non-absent file that cannot be removed
  reports **Uninstall incomplete**. Debug and read-only wrapper modes cannot request permissions.
- The Node-API capture client sits beside the host in `Contents/Library/Native`, outside any
  Gateway payload; its absence makes only capture unavailable. Native changes need a manual Mac
  app update; building source never updates an installed helper.

## Invariants

- Exactly one helper in the app (duplicates under `Contents/Resources` are rejected).
- No custom event injector; Cua owns native execution, Pi owns the tool await.

## Verify

`NativeHostRetirementTests` (hosted `TronMacIntegrationTests`, see
[development](../../docs/development.md#efficient-focused-tests)) and
`scripts/validate-native-host.py` in packaging. Signed-service TCC attribution, update and
background approval are release qualification, not provable by a qualification app.

## Not here

Capture and `computer` behavior: [computer control](../../docs/computer-control.md).
