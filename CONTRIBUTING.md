# Contributing to Tron

Tron is a native iPhone interface and minimal Mac gateway for a private coding
agent. User-facing language calls the product and agent **Tron**. The embedded Pi
SDK may be named in technical implementation documentation, dependency work, and
source contracts, but not as a second user-facing product.

## Repository map

- `packages/gateway` — strict TypeScript gateway, protocol, supervision, tests
- `packages/ios-app` — SwiftUI iPhone app and share extension
- `packages/mac-app` — macOS installer/menu bar and gateway packaging
- `scripts/tron` — contributor command entry point

The custom Rust backend, Engine/Activity protocol, workers, event SQLite mirror,
browser operator, and notification relay were retired. Do not reintroduce their
terminology or architecture through compatibility wrappers.

## Change requirements

1. Ship implementation, focused tests, and owning documentation together.
2. Fix root causes and preserve canonical runtime ownership; do not create a
   second model/session/settings schema unless the mobile protocol requires a
   bounded projection.
3. Never include personal paths, handles, domains, credentials, or fixture
   secrets. Run `scripts/personal-info-guard.sh`.
4. Use exact production dependency versions and commit lockfile changes.
5. Never add or invoke an automated production deployment command.
6. Trust is not sandboxing. Copy and docs must say that executable resources run
   with the Mac user's authority.

## Fast validation

Start with the smallest owner and expand only after it passes.

### Gateway

```bash
cd packages/gateway
npm run build
npx vitest run src/sessions/runtime-registry.integration.test.ts
npm test
npm audit --omit=dev
```

Gateway mutations require `commandId`. Distinct sessions may run concurrently;
all mutations for one session stay serialized. A disconnect must not abort an
accepted run. Use `scripts/tron chat --session <id>` when testing terminal/mobile
handoff: it attaches to the Gateway-owned runtime. Never open the same canonical
JSONL simultaneously in a separate Pi process. `scripts/tron dev --background`
runs the isolated Gateway behind a restart supervisor. After rebuilding Gateway
source, use `scripts/tron dev --restart --tailscale`; it drains admitted agent
runs and reconnects clients. Never stop the Gateway from one of its own tools.

### iOS

```bash
cd packages/ios-app
xcodegen generate
xcodebuild build-for-testing -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/<OwningSuite>
```

Reuse `test-without-building` for nearby test owners. Run the complete unit target
and smoke UI target only at a checkpoint.

### Mac

Stage generated gateway payloads only when a build/archive needs them:

```bash
packages/mac-app/scripts/bundle-gateway.sh
cd packages/mac-app
xcodegen generate
xcodebuild build-for-testing -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64'
xcodebuild test-without-building -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -only-testing:TronMacTests/<OwningSuite>
```

The Login Item directory names are `Tron Agent.app` and `Tron Agent Dev.app`.
Their stable launchd labels remain `com.tron.server` and `com.tron.server.dev`.

## Documentation ownership

- Product shape, setup, and primary workflow: root `README.md`
- Gateway protocol/security/session invariants: `packages/gateway/README.md`
- iOS structure and state: `packages/ios-app/docs/architecture.md`
- iOS test workflow: `packages/ios-app/docs/development.md`
- Mac supervision and pairing: `packages/mac-app/docs/architecture.md`
- Mac packaging and testing: `packages/mac-app/docs/development.md`

Update the nearest owner when behavior changes. Keep root README concise and link
to implementation-level detail.

## Commits and releases

Keep commits reviewable and avoid generated build output. Xcode projects may be
regenerated from `project.yml`; staged Mac gateway payloads and Node runtimes are
ignored. CI does not publish production artifacts. TestFlight/App Store delivery,
Mac signing and notarization, and production deployment are deliberate manual
maintainer actions. Release tags use `tron-v<version>`.
