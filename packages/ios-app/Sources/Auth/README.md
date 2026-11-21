# Auth

## Purpose

Presents provider and MCP OAuth in the system authentication browser and captures the loopback
callback, without ever handling tokens or credentials.

## Owns

`ProviderOAuthBrowser.swift` (`ProviderOAuthBrowserSession`).

## Contract

- Admits only HTTPS authorization URLs with a Gateway-derived HTTP loopback callback descriptor.
- Binds fixed-port POSIX sockets directly to `127.0.0.1` and/or `::1` (`IPV6_V6ONLY`) before
  presenting the browser. `NWListener`'s fixed local endpoint fails with `EINVAL` on devices, and a
  wildcard listener would expose callback bearer data to other interfaces.
- One serial socket queue owns nonblocking accept/read/write; cancellation closes descriptors before
  restart; a browser-session generation rejects callbacks from replaced sessions. Retired listeners
  are joined before a restarted login rebinds the same port.
- At most eight clients, incomplete headers retired after five seconds, one bounded exact-path GET.
  A nonce-only `com.tron.mobile.oauth` redirect closes `ASWebAuthenticationSession`; authorization
  codes never enter the custom-scheme URL.
- The complete callback URL goes only to the matching Pi `manual_code` prompt; otherwise only the
  callback ID and query go to the Gateway's fixed-destination relay (`auth.callback`). MCP callbacks
  are relayed only to the loopback listener named by Pi's authorization URL.
- Leaving Tron for the browser does not cancel the operation; dismissing the sheet in an active
  scene does. The Gateway bounds a login to 15 minutes.

## Invariants

- Callback values stay in memory: never in snapshots, caches, logs or durable events.

## Entry points

`ProviderOAuthBrowser.swift`.

## Signals

None.

## Verify

```bash
scripts/tron-ios-test run --only-testing TronMobileUITests/TronIntegrationSheetsUITests \
  --only-testing TronMobileUITests/TronMCPServerSheetsUITests
```

These cover OAuth receipts, late completion and expiry without redispatch, and the shared auth
input; hosted tests never open `ASWebAuthenticationSession`. Before a release, smoke a disposable
provider account on a physical device: the system browser closes through the loopback handoff, a
restarted operation completes, and no callback query or token reaches a log.

## Not here

Operation, prompt and recovery state: `ProviderAuthCoordinator` in [State](../State/README.md).
