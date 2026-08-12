# Tron iOS gateway integration completion plan

## Verdict

The Engine-to-gateway architecture replacement is implemented and validated,
but the release is not complete until historical visual review and signed
artifact validation finish.

Tron now uses the pinned Pi 0.84.1 stable SDK behind a minimal authenticated Mac
gateway. Pi JSONL, settings, credentials, packages, resources, compaction,
retries, tools, and extensions remain canonical. iOS owns presentation and a
bounded disposable cache; it does not reconstruct an event journal or mirror
sessions in SQLite.

This is a backend replacement, **not an iOS redesign**. The pre-migration iOS
client at `c3f12c17c` remains the visual and interaction specification.

## Non-negotiable experience contract

Release review must preserve:

- screen composition, navigation hierarchy, sidebar behavior, sheets, alerts,
  menus, and toolbars;
- typography, colors, materials, spacing, sizing, radii, shadows, and icons;
- transcript grouping, Markdown, code, thinking, tool chips, and progress;
- composer focus, keyboard dismissal, attachments, speech, queueing, send/stop,
  scrolling, and selection/copy behavior;
- onboarding, pairing, workspace, provider, model, context, forks, terminal,
  settings, diagnostics, devices, and sharing;
- Dynamic Type, VoiceOver order, contrast, hit regions, reduced motion, and
  supported device-size adaptations.

A gateway contract may replace a retired presentation model, but it may not
silently simplify the UI. Generic rendering is reserved for arbitrary extension
data that has no established specialized presentation.

## Implemented architecture

### Gateway and canonical ownership

- One live runtime owns each canonical session.
- Same-session mutations serialize; distinct sessions run concurrently.
- Accepted prompts survive iOS disconnect and app termination.
- Command IDs and bounded receipts protect mutation retries.
- Reconnect opens authoritative snapshots; prompts are not automatically replayed.
- Runtime generations and event sequences detect replacement and gaps.
- Each project session owns an isolated mutable model/provider runtime.
- The administration runtime composes global providers for setup without loading
  untrusted project resources.
- Session discovery and model discovery are cursor-paginated with repeated-cursor
  protection.
- Project trust gates project resources and is explicitly not a sandbox.

### Supported product surfaces

- Pairing, Keychain profiles, device listing/revocation, and reconnect.
- Session create/open/list/search/delete/import/export/rename/fork/tree/navigation.
- Text, thinking, images, uploads, Markdown, model changes, labels, compaction,
  retries, usage, queue state, and typed tools.
- Streaming text, detached completion, abort, steering, and follow-up queues.
- Generic extension statuses, widgets, editor requests, notifications, prompts,
  selections, confirmations, and custom data fallback.
- Provider API-key/OAuth flows without returning provider secrets to iOS.
- Global/project settings, custom models, package/resource administration, trust,
  filesystem browsing, Git inspection, uploads, and terminal reattachment.
- Native Apple speech and SwiftTerm; no worker speech or recreated agent platform.

### Removed retired domains

Engine transport, Activity, workers, reusable-agent management, coordination,
event reconstruction, SQLite session mirroring, APNs infrastructure, browser
extension, relay, and Rust agent remain removed. They must not be reintroduced as
compatibility layers.

## Historical presentation restoration

### Onboarding

The session shell mounts before first-run setup. Onboarding is again a
non-dismissible adaptive sheet with a hidden drag indicator and native upward
expansion gesture.

The established nine-page progression is retained:

1. Welcome
2. Tailscale
3. Install Tron on Mac
4. Pair Mac
5. Default workspace
6. Anthropic
7. OpenAI
8. Other providers
9. Default model

Preparation and pairing prefer the medium detent; setup pages use large. The
centered emerald title, icon navigation, tinted glass cards, page dots, mounted
shell logo/title/settings toolbar, and floating new-session action follow the
historical composition. Provider pages consume the runtime catalog rather than
assuming credentials exist.

Executable references from `c3f12c17c` are tracked under
`docs/assets/parity/`. `TronSmokeUITests` captures current references and uses a
Vision feature print plus geometry assertions for the medium sheet. The copy
change from permanent pairing token to short-lived enrollment code is required
by the new security contract.

### Typography and accessibility

The historical font catalog and persisted keys are retained. Variable axes are
created through `UIFontDescriptor`, including Recursive `MONO`/`CASL` and Source
Serif optical sizing. SwiftUI custom fonts carry semantic Dynamic Type metadata.
The secure one-time-code field uses a native Dynamic-Type-aware text field
because SwiftUI `SecureField` audits as fixed size.

UI validation runs complete accessibility audits in light and dark modes and on
populated real-gateway screens. Standard SwiftUI controls misclassified by
XCTest’s simulated size audit receive an exact-label suppression only when a
separate accessibility-XXXL relaunch proves the real control scales and remains
reachable. Category-wide audit suppression is forbidden.

## Automated acceptance status

The following checkpoints pass on the current working tree:

- Gateway TypeScript build.
- Gateway tests: 18 files, 31 tests.
- Gateway production dependency audit: zero vulnerabilities.
- Complete iOS unit target from a fresh CI-style build.
- iOS onboarding smoke, validation, native detent gesture, light/dark full
  accessibility audits, and historical visual regression.
- Real gateway-to-iOS E2E covering:
  - one-use pairing and Keychain token storage;
  - nine-page setup and provider-qualified model selection;
  - canonical session creation;
  - visible streaming;
  - app termination during a run;
  - detached completion and authoritative reconnect convergence;
  - portable extension confirmation;
  - running and completed bash-tool presentation;
  - populated-chat accessibility;
  - session management;
  - settings and appearance;
  - accessibility-XXXL reachability.
- Clean Mac hosted test build and complete Mac test target.
- Version, release-note, workflow YAML, shell syntax, diff whitespace, and
  personal-information guards.

## Remaining release blockers

### 1. Manual historical visual and interaction review

Automation now covers all deterministic contracts available in repository
history. A maintainer must perform eyes-on review on a physical iPhone and iPad
because material rendering, haptics, keyboard feel, VoiceOver cadence, camera,
speech permissions, and signed-device networking cannot be judged from
simulator assertions.

Review at minimum:

- medium and expanded onboarding against `docs/assets/parity/`;
- QR scan, manual entry, invalid enrollment, pairing success, and interrupted
  setup resume;
- empty and populated grouped session lists, floating create action, search,
  swipe delete, refresh, and compact/regular navigation;
- long streaming conversations, manual scroll retention, new-response control,
  Markdown/code/thinking, tool detail, queue controls, stop, and keyboard focus;
- image/file attachment, speech, share extension, export/share, fork/tree/context;
- terminal launch, input, resize, background, reconnect, and reattachment;
- every settings destination, provider OAuth/API-key flow, custom-model errors,
  packages, trust, devices, diagnostics, and legacy import;
- Light, Dark, Auto, accessibility text sizes, VoiceOver, Reduce Motion, portrait,
  landscape, and iPad split view.

Unexplained visual or interaction regressions are release blockers. Intentional
deviations require explicit approval and documentation.

### 2. Enrollment renewal

One-use pairing is deterministic and secure, but the product still needs a
supported maintainer/user path to issue a fresh enrollment code after expiry or
consumption without editing gateway state manually.

### 3. Signed artifact validation

Production deployment remains manual. Before release, manually stage the exact
bundled gateway and universal Node payload, then validate:

- signed Mac app, nested login item, launchers, Node runtimes, native modules,
  hardened runtime, notarization, and stapling;
- clean installation and launchd registration;
- Tailscale binding and Mac-local credential separation;
- physical iOS pairing and the complete acceptance journey;
- version `0.1.0-beta.7`, Apple build `7`, and `tron-v*` release metadata.

No automated production deployment may be added or run.

## Efficient validation workflow

Use focused owners while iterating:

```bash
# Gateway
cd packages/gateway
npm run build
npx vitest run <owner>.test.ts

# iOS units
cd packages/ios-app
xcodegen generate
xcodebuild build-for-testing -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/<Suite> -collect-test-diagnostics never

# Persistent real-gateway UI loop
scripts/ios-gateway-e2e-test prepare
scripts/ios-gateway-e2e-test build
scripts/ios-gateway-e2e-test run
# after Swift edits
scripts/ios-gateway-e2e-test iterate
```

Run complete suites only at cross-module/release checkpoints. Keep the gateway
fixture and DerivedData between focused iterations.

## Completion definition

The migration is complete only when:

1. automated gateway, iOS, E2E, and Mac checkpoints remain green;
2. manual historical visual/interaction review records no unexplained regression;
3. enrollment renewal has a supported product path;
4. a clean signed Mac/iOS installation passes the complete physical-device
   journey; and
5. maintainers explicitly approve every documented user-visible semantic
   deviation.
