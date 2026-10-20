# Core (`TronMobileCore`)

## Purpose

The app's lowest layer: Gateway wire contracts, transport, pairing profiles, value models and
nonvisual support, built as the framework `TronMobileCore` that the app, the share extension and
the hosted test targets link.

## Owns

- `Gateway/`: `GatewayClient` (one authenticated WebSocket per connection epoch), protocol
  decoding (`GatewayProtocol`, `GatewayProtocolContract`), `SessionEventSynchronizer`, socket and
  bounded HTTP transports, pairing profiles and their store, LAN pin and path snapshots.
- `Models/`: wire-compatible value types grouped by authority (connection, session catalog,
  transcript, runtime, resources, workspace, terminal, automations, knowledge, notifications…),
  plus `JSONValue` and `ModelDisplayFormatting`.
- `Support/`: `AppLog`, `ChatInteractionTrace`, `IOSClientDiagnostics`, `PerformanceSignposts`,
  `MonotonicClock`, `UUIDSource`, reconnect/recovery policies, `GatewayTimestamp`,
  `SharedContent` (share handoff), camera authorization, `ChatViewportMode`.
- `PrivacyInfo.xcprivacy` (Core reads UserDefaults).

## Contract

- **Module boundary.** The app is three Swift modules: the application `TronMobile`, this framework
  (embedded, loaded by the share extension from the app's `Frameworks/`, hence
  `APPLICATION_EXTENSION_API_ONLY`) and the static `TronSwiftAppEngine`. A lower module cannot see
  a higher one: a Core file that reaches for State or UI fails to compile.
- **Foundation-only.** Core may import Foundation and nondrawing system frameworks (CryptoKit,
  Network, OSLog, Security, AVFoundation for camera authorization), never SwiftUI, UIKit,
  Observation or UserNotifications; `packages/ios-app/scripts/test-source-policy.sh` fails otherwise. Presentation
  stores, UI decoding and notification delivery live in the app target beside their consumers.
- **Access.** A declaration another module uses is `package` (`public` only for an outside
  consumer); every target sets `SWIFT_PACKAGE_NAME = TronIOSApp` in `project.yml`. Test-only
  declarations stay `internal` behind `@testable import TronMobileCore`. A type has exactly one
  owner: no duplicate copies, re-export shims or compatibility typealiases.
- **Transport.** Epoch ownership, deadlines, the shared ping grid, frame and `JSONValue` ceilings
  and decoding are specified in [Gateway connection and events](../docs/events.md).
- **Requests.** Each request owns its send and timeout tasks through queued → sending → sent;
  failure after send begins is a local, non-Codable possibly-sent error the Gateway cannot forge.
- **HTTP.** Idempotent bodiless GET/HEAD (media, exports, live-view frames) share one long-lived
  session per configuration with per-task byte ceilings and no cache, cookie or credential storage;
  uploads, POSTs and DELETEs use a fresh session per request. Blob reads and upload staging are
  paired-profile operations, so a same-profile reconnect does not disturb them. Response bodies are
  bounded (64 KiB for API responses, 25 MiB for media).
- **Pairing.** Only `tron://pair` invitations with host, port and an 8–32-character one-time code;
  missing values and duplicate keys fail closed. `GatewayPairer` alone owns `POST /v1/pair`
  (responses ≤ 64 KiB). The device token goes straight to Keychain; profiles persist non-secret
  metadata only. Socket, upload and blob URLs are validated, so an invalid profile never opens
  transport.
- **Profile store.** One transactional boundary: atomic Keychain upsert before a single metadata
  commit, exact rollback on failure, corrupt metadata self-cleans, legacy metadata migrates on the
  next write.
- **Share handoff.** At most 32 providers, 64 KiB per UTF-8 fragment and 128 KiB in total; prompts
  ≤ 192 KiB; `PendingShareStoring` rejects documents above 256 KiB and reports save failure, so the
  extension opens the app only after a successful write. One slot, cleared after confirmed send.
- **Models.** Model identity is always `(provider, id)`. Cross-file references are plain value
  composition; no model is a second cache or reducer.

## Invariants

- Signpost and diagnostic metadata is limited to result codes, counts and bytes: never
  identifiers, paths, methods, filenames, model names, prompts, transcript content or terminal
  output.
- Typed decode failures surface as bounded `invalid_response` errors (method, category, sanitized
  coding path) before any presentation or diagnostic.
- Time and identity enter only through injectable `MonotonicClock` and `UUIDSource` values.
- Scripted test sockets hold no protocol, receipt or admission policy; `GatewayClient` stays the
  only decoder and client runtime.

## Entry points

`Gateway/GatewayClient.swift`, `Gateway/GatewayProtocol.swift`, `Gateway/GatewayProfileStore.swift`,
`Support/AppLog.swift`, `Support/ChatInteractionTrace.swift`.

## Signals

| Signal | Meaning |
|---|---|
| `gateway.rpc` | Bounded `session.list` request record: sanitized request ID, outcome, failure code, duration, profile |
| lifecycle incidents | Reconnect scheduling/attempt/failure, foreground/background and path changes with loop IDs; LAN/Tailscale race fields (`packages/ios-app/docs/events.md`) |
| `ChatInteractionTrace` | 256-record, content-free, in-memory chat trace merged into Logs |

## Verify

TBD by #1499.

## Not here

Lifecycle, reconnect scheduling and every presentation store live in
[State](../Sources/State/README.md). How a type moves into the module is in the
[development guide](../docs/development.md#module-layout).
