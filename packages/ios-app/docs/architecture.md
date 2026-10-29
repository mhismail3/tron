# Tron iOS architecture

Tron for iPhone is the primary interface to the private Tron agent on the Mac: a native SwiftUI
app targeting iOS 26. The backing SDK is an implementation detail; user-facing language calls the
agent Tron. This page is an index: each module documents itself in a README beside its manifest,
and the two cross-module contracts live in this directory.

## Source map

| Directory | Module | Owner doc |
|---|---|---|
| `Core/` | `TronMobileCore`: Gateway client and protocol, profiles, value models, support | [Core](../Core/README.md) |
| `SwiftAppEngine/` | `TronSwiftAppEngine`: the displayed-Swift-app interpreter | [Swift apps](swift-apps.md) |
| `Sources/` (`App/`, resources) | app composition and lifecycle | [App](../Sources/README.md) |
| `Sources/State/` | authoritative UI projection, lifecycle and reconnect | [State](../Sources/State/README.md) |
| `Sources/Auth/` | provider OAuth browser | [Auth](../Sources/Auth/README.md) |
| `Sources/Notifications/` | push registration and the notification inbox | [Notifications](../Sources/Notifications/README.md) |
| `Sources/UI/` (`Components/`, `Theme/`) | shared presentation | [Presentation](../Sources/UI/README.md) |
| `Sources/UI/Chat/` | session shell, dashboard, chat, Manage Session, Home | [Chat](../Sources/UI/Chat/README.md) |
| `Sources/UI/Settings/` | settings, renderer, providers, integrations | [Settings](../Sources/UI/Settings/README.md) |
| `Sources/UI/Automations/` | dashboard selector, Automations, Knowledge | [Automations](../Sources/UI/Automations/README.md) |
| `Sources/UI/Onboarding/` | pairing, setup, workspace and model pickers | [Onboarding](../Sources/UI/Onboarding/README.md) |
| `Sources/UI/Terminal/` | SSH/tmux Mac Terminal | [Terminal](../Sources/UI/Terminal/README.md) |
| `Sources/UI/SwiftApps/` | Swift-app runner and card | [Swift apps](../Sources/UI/SwiftApps/README.md) |
| `MacTerminalSSH/` | Mac Terminal's SSH client package | [Terminal](../Sources/UI/Terminal/README.md) |
| `ShareExtension/` | app-group share handoff | [Core](../Core/README.md#contract) |

Cross-module contracts:

- [Gateway connection and events](events.md): transport epochs, lifecycle and reconnect, receipts,
  session synchronization and every event topic.
- [Presentation parity](presentation-parity.md): the shared UI contract, presentation-scoped
  state and presentation activity.
- Feature specifications: [onboarding](onboarding.md), [Swift apps](swift-apps.md),
  [display artifacts](display-artifacts.md), [knowledge sources](knowledge-sources.md).

## Modules

The app is three Swift modules: the application `TronMobile`, the framework `TronMobileCore`
(sources in `Core/`) and the static framework `TronSwiftAppEngine`. Core is Foundation-only, a
lower module cannot see a higher one, and cross-module API is `package` access. The rules and
their check (`packages/ios-app/scripts/test-source-policy.sh`) are in [Core](../Core/README.md#contract); how a type
moves into the module is in the [development guide](development.md#module-layout).

## State flow

Connection lifecycle, reconnect, receipts and session synchronization:
[Gateway connection and events](events.md). The owners: [State](../Sources/State/README.md).
Chat projection, opening and viewport: [Chat](../Sources/UI/Chat/README.md).

## Sessions

Snapshots, the composer, queue and attachments: [Chat](../Sources/UI/Chat/README.md#contract) and
[events](events.md#session-topics).

## Security

Pairing and profiles: [Core](../Core/README.md#contract). Push registration:
[Notifications](../Sources/Notifications/README.md). OAuth: [Auth](../Sources/Auth/README.md).
Provider credentials and the Mac wrapper credential are never decoded by iOS. Project trust copy
states that trust controls project resource loading and is not a sandbox.

### Session terminal closed by the Gateway

[Terminal](../Sources/UI/Terminal/README.md#contract).

### Mac Terminal

[Terminal](../Sources/UI/Terminal/README.md#contract).

## Presentation-scoped state

[Presentation parity › Presentation-scoped state](presentation-parity.md#presentation-scoped-state).

## Presentation parity

[Presentation parity](presentation-parity.md).

## Offline cache

`SnapshotCache`: [State](../Sources/State/README.md#contract).

## Removed architecture

The app has no Engine transport, SQLite event store, reconstruction plugins, Activity feed,
workers, reusable-agent management, coordination dashboard or worker speech service. Runtime tools
and extension interactions render directly from snapshot contracts.

## Presentation activity

[Presentation parity › Presentation activity](presentation-parity.md#presentation-activity).

## Integration management projection

[Settings › Integrations](../Sources/UI/Settings/README.md#contract).

## Knowledge projection

[Automations › Knowledge](../Sources/UI/Automations/README.md#contract).

### Session search

[Chat › Dashboard](../Sources/UI/Chat/README.md#contract).

### Home display identity and terminal

[Chat › Home](../Sources/UI/Chat/README.md#contract) and
[Terminal](../Sources/UI/Terminal/README.md#contract).

### Home task sheets

[Chat › Home](../Sources/UI/Chat/README.md#contract); task contract in the Gateway's
[Home](../../gateway/docs/home.md).
