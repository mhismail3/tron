# Tron

Tron is a private coding agent designed around a native iPhone experience. The
agent runs continuously on your Mac; the SwiftUI app is its primary interface.
Accepted work continues when the phone disconnects, and reconnecting converges
to an authoritative session snapshot.

To users, the product and agent are **Tron**. Internally, Tron Gateway embeds the
pinned Pi SDK as its agent runtime. Pi is an implementation dependency, not a
second product users must configure or operate.

## System

```text
┌──────────────────────┐      Tailscale       ┌─────────────────────────┐
│ Tron for iPhone      │◀── authenticated ──▶│ Tron Gateway on Mac     │
│ SwiftUI chat + tools │      WebSocket       │ sessions + files + PTY │
└──────────────────────┘                      └───────────┬─────────────┘
                                                         │ stable SDK
                                             ┌───────────▼─────────────┐
                                             │ pinned agent runtime    │
                                             │ canonical JSONL/config  │
                                             └─────────────────────────┘
```

- **iOS** owns chat presentation, onboarding, settings, attachments, forks,
  context inspection, and SwiftTerm presentation.
- **Gateway** owns enrollment, authentication, detached session supervision,
  uploads, filesystem access, project trust, package administration, extension
  interactions, and PTYs.
- **The embedded runtime** owns model/provider behavior, tools, extensions,
  settings, credentials, compaction, retries, and canonical session JSONL.
- **The Mac app** installs and supervises the always-running gateway and emits
  short-lived one-time pairing invitations.
- **Tron Push** is an optional product-operated, App Attest-gated APNs transport;
  the bundled `notify` tool and typed Ask policy enqueue through the Gateway
  without exposing device routing or transport credentials to the model.

Tron does not mirror sessions into SQLite and does not reconstruct state from an
event journal. Local iOS snapshots are bounded, disposable offline presentation
state only.

## Security model

- Pairing QR codes contain a short-lived one-time code, never a permanent token.
- Device tokens are stored in the iOS Keychain; only hashes are persisted on the
  Mac. Authorized devices can be listed and revoked.
- Provider credentials stay in the runtime credential store on the Mac and are
  never returned to iOS.
- The Mac wrapper uses a separate owner-only local credential under
  `~/.tron/gateway/`.
- Project trust controls whether project-local settings and executable resources
  load. Trust is **not a sandbox**. Agent tools, extensions, and packages run
  with the Mac user's authority.
- Mobile exposure binds explicitly to the detected Tailscale interface. The
  default developer gateway remains loopback-only.

Do not open the same session concurrently in another runtime client: the
canonical session format does not provide a cross-process session-file lock.
Use `scripts/tron chat [--session <id>]` for terminal chat; it attaches to the
same Gateway-owned runtime as iOS and therefore stays on the authoritative
snapshot/event sequence instead of becoming a competing JSONL writer.

## Repository

```text
packages/gateway/   TypeScript gateway and protocol tests
packages/ios-app/   native SwiftUI iPhone app and share extension
packages/mac-app/   macOS installer, menu bar, pairing, and gateway packaging
packages/push-relay/ closed Cloudflare/APNs transport
scripts/tron        contributor entry point
```

The retired custom Rust backend, agent worker platform, browser operator,
notification inbox/delivery subsystem, and Engine/Activity client domains remain
absent. The current push relay is only a closed installation registry,
idempotency boundary, and APNs adapter.

## Requirements

- macOS 15 or newer
- The Xcode and XcodeGen versions pinned in `config/ci-toolchain.env`
- Node 22.22.0 for gateway development (the exact pin is `.node-version`)
- Tailscale on the Mac and iPhone for mobile operation

Production dependencies are exact-pinned. The shipped Mac app bundles exact
Node runtimes and the locked gateway production tree.

## Development

```bash
# Gateway: fast, deterministic checks
cd packages/gateway
npm ci
npm run build
npm test

# Developer-owned gateway, loopback on port 9848
scripts/tron dev start

# Expose the Debug gateway on the detected Tailscale address
scripts/tron dev start --tailscale

# Generate native projects
scripts/tron ios generate
scripts/tron mac generate
```

A fresh clone contains no generated Xcode projects or staged Mac gateway.
Run `npm ci` before direct Gateway development and `xcodegen generate` before
either native build. The Mac Xcode target automatically stages the bundled
Gateway, its production dependencies, and pinned Node runtimes when the
payload is missing; a global Pi installation is not required.

The iOS matrix has five configurations: Development for simulator work,
Test for the isolated hosted test host, LocalDevice for ordinary development
device installs, DevicePerformance for hosted performance tests, and Release
for manual archives only. Use `scripts/tron-ios-device` for its safe
Tron Device + LocalDevice default; signed artifact metadata and entitlements
are the final push-route and signing authority.

### Focused native tests

Use the canonical owned simulator runner for iOS; it builds once, then reuses
products for focused tests with bounded process and result evidence. See the
[iOS development guide](packages/ios-app/docs/development.md).

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileTests/SnapshotCacheTests

cd packages/mac-app
xcodebuild build-for-testing -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64'
xcodebuild test-without-building -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -only-testing:TronMacTests/PairingURLBuilderTests
```

This avoids rebuilding or running unrelated suites for each edit. Run broader
suites only after focused owners are green.

## Mac packaging

```bash
packages/mac-app/scripts/ensure-gateway-bundle.sh
```

The build preflight and this script stage the Gateway, a separate
production-only dependency tree, checksum-pinned Node runtimes matching
`.node-version` (arm64/x64), and a universal launcher for both Login Item variants. The resulting
Mac app runs without a global Pi or Node installation. Generated payloads are
ignored; use `bundle-gateway.sh` when you explicitly need to refresh them.

## Legacy session migration

The iOS Settings screen can import sessions from the retired authenticated local
server running on loopback (default migration port `9849`). The gateway reads the
legacy owner-only credential locally, imports message history into canonical
Tron sessions, records idempotent receipts, and never modifies legacy databases
or credentials.

## Documentation

- [Gateway architecture and protocol](packages/gateway/README.md)
- [iOS architecture](packages/ios-app/docs/architecture.md)
- [iOS development](packages/ios-app/docs/development.md)
- [Mac architecture](packages/mac-app/docs/architecture.md)
- [Mac development and packaging](packages/mac-app/docs/development.md)
- [Contributing](CONTRIBUTING.md)

CI validates source but does not publish production artifacts. iOS/TestFlight
and App Store delivery, Mac signing/notarization, and production deployment are
manual maintainer actions; see the platform development guides.
