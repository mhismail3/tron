# Contributing to Tron

Tron is a native iPhone interface and minimal Mac gateway for a private coding
agent. User-facing language calls the product and agent **Tron**. The embedded Pi
SDK may be named in technical implementation documentation, dependency work, and
source contracts, but not as a second user-facing product.

## Repository map

- `packages/gateway` — strict TypeScript gateway, protocol, supervision, tests
- `packages/ios-app` — SwiftUI iPhone app and share extension
- `packages/mac-app` — macOS installer/menu bar and gateway packaging
- `packages/push-relay` — closed product-operated App Attest/APNs transport
- `scripts/tron` — contributor command entry point

The custom Rust backend, Engine/Activity protocol, agent workers, event SQLite
mirror, browser operator, and legacy notification delivery subsystem were
retired. Do not reintroduce their terminology or architecture through
compatibility wrappers. The current Cloudflare push relay is only a closed
installation registry, idempotency boundary, and APNs transport; it owns no
agent execution, session state, inbox, badge, or reminder policy.

## Change requirements

1. Ship implementation, focused tests, and owning documentation together.
2. Fix root causes and preserve canonical runtime ownership; do not create a
   second model/session/settings schema unless the mobile protocol requires a
   bounded projection.
3. Never include personal paths, handles, domains, credentials, or fixture
   secrets. Run `scripts/personal-info-guard.sh`.
4. Use exact production dependency versions and commit lockfile changes. The
   repository-wide Node toolchain pin is `.node-version` (currently 22.22.0);
   package `engines` remain compatibility minimums.
5. Never add or invoke an automated production deployment command.
6. Trust is not sandboxing. Copy and docs must say that executable resources run
   with the Mac user's authority.
7. Gateway rebuilds and lifecycle transitions are user-initiated. Automated
   assistants may prepare and validate source or artifacts, but must not run a
   mutating `scripts/tron dev` lifecycle command or submit Gateway
   update/rollback/restart/promote RPCs.
8. Pi SDK updates are one atomic family change. `packages/gateway/package.json`
   is the version authority; do not merge independent Pi package updates. Use
   `cd packages/gateway && npm run update:pi-sdk -- <exact-version>` from a
   clean manifest/lockfile, then run `npm run check:pi-sdk` and
   `npm run test:pi-sdk-scripts` and `npm run test:pi-sdk-rollback`. The
   `pi-sdk-baseline.json` file records only the prior runtime used by the
   sequential rollback probe; `package.json` remains the current-version
   authority. The updater performs online metadata preflight, uses the npm
   paired with the repository-pinned Node runtime, runs normal repository
   lifecycle scripts with `--engine-strict`, and restores only its owned manifests plus
   the disposable installed tree with `npm ci` if anything fails. No deployment or
   Gateway lifecycle command is part of dependency maintenance.
9. Stop on any meaningful Pi behavior delta. Event ordering, canonical JSONL,
   compaction/retries, extension UI, projections, settings/auth/models,
   packaging, or user-visible UI/UX changes must be compared with the approved
   baseline and explicitly decided; never accept a changed behavior merely
   because TypeScript or tests compile. The executable payload contract is npm's
   `app/node_modules/.bin/pi` projection and the exact runtime alias
   `../../app/node_modules/.bin/pi`; changing it requires the documented one-time
   manual Mac Release reinstall, not source-only promotion through an old launcher.

## Fast validation

Start with the smallest owner and expand only after it passes.

### Toolchain

Node is pinned exactly by `.node-version`; CI and Mac packaging read that file.
Use `scripts/verify-ci-toolchain.sh node` to verify the current executable and
reject duplicated version mirrors. Install native project generation with
`scripts/install-ci-tools.sh xcodegen`; both `scripts/tron ios generate` and
`scripts/tron mac generate` reject a mismatched XcodeGen. Xcode version literals
remain intentional Apple-toolchain pins. Run
`python3 scripts/check-documentation-policy.py` after changing documentation
navigation, commands, or repository paths. Run `scripts/check-agent-policy.sh`
after changing agent guidance.

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
JSONL simultaneously in a separate Pi process.

### Isolated development lifecycle

`~/.tron-dev/gateway` on port `9848` is the only routine agent-development
surface. `scripts/tron dev status` (or `preflight`) is read-only and never
builds; it reports the expected endpoint/home, PID start identities, lifecycle
epoch, source revision, payload fingerprint, and health readiness.
`scripts/tron dev stop` is also build-free and refuses to trust a stale or
reused PID based on `kill -0` alone. The supervisor atomically publishes bounded lifecycle state:
`starting`, `ready`, `stopping`, `restarting`, `failed`, or `stopped`. Lifecycle writes use the explicit transition table in `scripts/tron-dev-state.mjs`; illegal regressions fail closed. Exit 75
is the intentional authenticated restart drain; other exits consume a bounded
restart budget and eventually become `failed`.

After source changes, automated assistants stop after source/build validation
and report the appropriate command; they do not execute a Gateway rebuild or
lifecycle transition. The user or maintainer initiates the Debug restart with
`scripts/tron dev restart` for loopback or adds `--tailscale` when iOS must reach
it. A command without a host flag inherits a live supervisor's recorded host; an
explicit conflicting flag fails closed and requires the user to run
`scripts/tron dev stop` before changing exposure. A fresh user-initiated start without a flag
defaults to loopback. This sole Debug supervisor uses the signed launcher from
`/Applications/Tron.app`, builds and stages an immutable candidate, preserves
accepted-run shutdown draining, and waits for truthful exact health identity.
It refuses an unknown owner already listening on 9848. After testing, the user
may initiate `scripts/tron dev handoff --tailscale`; it performs authenticated
pre/post identity checks and copies the exact payload into Stable as an inactive
candidate only after pre/post authenticated identity proof. Promotion still
requires explicit user confirmation in iOS pinned to version plus fingerprint. Debug and Stable RPCs are
channel-bound; neither runtime can mutate the other channel. Do not
replace `/Applications/Tron.app`, invoke production
deployment, or install an iOS release as part of routine agent work. The
installed supervised app remains a frozen release image while isolated
iteration proceeds on `9848`.

### iOS

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileTests/<OwningSuite>
```

The canonical runner reuses products for nearby owners and preserves bounded
logs/results on its exact repository-owned test simulator. Run
`scripts/tron-ios-test checkpoint` only after focused owners pass. See
`packages/ios-app/docs/development.md` for status, cleanup, and diagnostics. Development is the simulator app,
Test is the explicit `HOSTED_TEST` host, LocalDevice is the canonical physical
device install, DevicePerformance is test-only, and Release is archive-only.
Keep generated schemes and DerivedData out of the diff.

### Mac

Stage generated gateway payloads only when a build/archive needs them:

```bash
packages/mac-app/scripts/bundle-gateway.sh
scripts/tron mac generate
cd packages/mac-app
xcodebuild build-for-testing -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64'
xcodebuild test-without-building -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -only-testing:TronMacTests/<OwningSuite>
```

The Release app packages only `Tron Agent.app` under the stable
`com.tron.server` label. Developer tooling reuses that installed signed launcher
with the isolated Debug payload and never registers a second Login Item.

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
