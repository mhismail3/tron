# iOS Development

## Setup

### Prerequisites

- Xcode 26+ with iOS 26 SDK
- XcodeGen (`brew install xcodegen`)
- Tron server running locally

### Project Generation

```bash
cd packages/ios-app
xcodegen generate
open TronMobile.xcodeproj
```

### Server Connection

The app connects to the Tron server:
- **Beta**: `localhost:8082` (run `tron start beta` or `tron dev`)
- **Production**: `localhost:8080` (run `tron start`)

## Build Configurations

| Config | Server | Use Case |
|--------|--------|----------|
| Beta | localhost:8082 | Development (debug, beta bundle ID) |
| Prod | localhost:8080 | App Store (release, production bundle ID) |

## Running Tests

### Command Line

```bash
xcodebuild test \
  -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Xcode

1. Open `TronMobile.xcodeproj`
2. Select Tron scheme
3. Cmd+U to run tests

### Test Structure

```
Tests/
├── ViewModels/        # ViewModel tests
├── Services/          # Service tests
├── Core/              # Event plugin tests
├── Mocks/             # Test doubles
└── Navigation/        # Deep link tests
```

## Debugging

### Console Logging

```swift
TronLogger.shared.debug("Message", category: .network)
TronLogger.shared.error("Error: \(error)", category: .session)
```

Categories: `.network`, `.session`, `.events`, `.notification`, `.audio`

### Network Inspector

View WebSocket traffic:
1. Run in Beta
2. Check Xcode console for `[Network]` logs
3. Or use Proxyman/Charles for detailed inspection

### Event Debugging

```swift
// In ChatViewModel
eventPublisherV2.sink { event in
    print("Event: \(event.type) - \(event.sessionId ?? "nil")")
}
```

### Local Diagnostics

Tron does not send usage analytics. `MetricKitDiagnosticsStore` subscribes to
Apple MetricKit in `AppDelegate` and stores payload JSON under Application
Support with 30-day / 50-file / 10 MB retention. Settings -> Send Feedback
builds a redacted `tron-diagnostics-<timestamp>.json` attachment that includes
bounded iOS logs, `logs.recent(limit: 1000)` when connected, local session and
event summaries, and MetricKit payloads.

Mail delivery uses `TRON_FEEDBACK_EMAIL` from build/runtime configuration. Keep
the value out of git by setting it in `Configuration/Local.xcconfig`, which is
ignored. If the value is blank or Mail is unavailable, the app presents the
share sheet so the user can save or attach the JSON manually. Release builds
must keep `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`; App Store/TestFlight
crashes are retrieved through Apple's Xcode Organizer diagnostics path.

## TestFlight Release CI

The iOS beta is published by `.github/workflows/release-ios.yml` on the same
`server-v*` tag that cuts the Mac DMG. The workflow always regenerates the
Xcode project with XcodeGen before building, so `project.yml` and `VERSION.env`
are the release sources of truth.

The upload lane uses the `Tron` scheme with the `Prod` configuration. That is
the App Store Connect bundle (`com.tron.mobile`, App ID `6761511764`); the
`Tron Beta` scheme remains a local/dev variant with `com.tron.mobile.beta`.
CI creates or selects an available iPhone simulator, runs the simulator tests,
archives for `generic/platform=iOS`, exports an App Store Connect IPA with
Xcode's `app-store-connect` export method, validates the exported app/extension
bundle IDs, entitlements, and export-compliance plist keys, uploads with
`asc builds upload`, waits for the build to become valid, resolves TestFlight
export compliance, updates the What to Test notes, submits/waits for TestFlight
beta review when Apple marks the build `READY_FOR_BETA_SUBMISSION`, and assigns
it to the configured internal and public TestFlight groups. App Store Connect
does not allow direct API assignment to an internal group, so CI verifies the
configured internal group has access to all builds and assigns the processed
build to the public external group. The group validation step supports both
`asc testflight beta-groups list` and older `asc testflight groups list` CLI
shapes. Reruns use `asc builds list` to reuse an existing Apple build number
instead of uploading a duplicate binary.

The app and share extension Info.plists set
`ITSAppUsesNonExemptEncryption=false`, which is the current release assertion
for TronMobile's use of platform networking and non-encryption hashing. Revisit
that assertion before adding non-exempt cryptography. The workflow verifies the
key in archives and exported IPAs; for already-uploaded builds that are stuck in
`MISSING_EXPORT_COMPLIANCE`, it uses the App Store Connect API to set
`usesNonExemptEncryption=false` before distribution. Build beta-detail and beta
review state are also read directly from the App Store Connect API because local
and CI `asc` installations can expose different TestFlight subcommand names.

The export step supports two signing modes. If all local signing secrets are
present, CI imports an Apple Distribution `.p12` into a temporary keychain,
installs App Store Connect provisioning profiles for the app and share
extension, and exports locally. Manually managed profiles use
`signingStyle=manual`; Xcode-managed App Store profiles use
`signingStyle=automatic` without cloud-signing credentials so Xcode can reuse
the installed profiles. If the local signing secrets are absent, CI falls back
to automatic Xcode cloud signing with the ASC API key. Cloud signing requires
Apple to allow that key/account to manage App Store signing; a cloud signing
permission error means either grant that access or use the local signing
secrets.

Required GitHub Actions secrets:

| Secret | Purpose |
|---|---|
| `ASC_KEY_ID` | App Store Connect API key id |
| `ASC_ISSUER_ID` | App Store Connect issuer id |
| `ASC_KEY_P8_BASE64` | base64-encoded `.p8` private key contents |

Optional local signing secrets:

| Secret | Purpose |
|---|---|
| `IOS_DISTRIBUTION_CERT_P12_BASE64` | base64-encoded Apple Distribution `.p12` for team `MYGKXH6TY4` |
| `IOS_DISTRIBUTION_CERT_PASSWORD` | Password used when exporting the `.p12` |
| `IOS_APPSTORE_PROFILE_BASE64` | base64-encoded App Store Connect provisioning profile for `com.tron.mobile` |
| `IOS_SHARE_EXTENSION_APPSTORE_PROFILE_BASE64` | base64-encoded App Store Connect provisioning profile for `com.tron.mobile.ShareExtension` |

Required repository variables:

| Variable | Purpose |
|---|---|
| `ASC_TESTFLIGHT_INTERNAL_GROUP_ID` | Internal TestFlight group id |
| `ASC_TESTFLIGHT_PUBLIC_GROUP_ID` | Public TestFlight group id used by the Mac onboarding QR link |

To reuse the local App Store Connect API key, `asc auth status --verbose` shows
the current profile and key id, and `asc auth doctor` shows the `.p8` path. The
issuer id is shown in App Store Connect under Users and Access -> Integrations
-> App Store Connect API -> Team Keys. If the original `.p8` is unavailable,
generate a replacement team key there, download it once, and update all three
GitHub secrets together. Store the private key in GitHub as base64 text:
`base64 -i /path/to/AuthKey_<KEY_ID>.p8 | gh secret set ASC_KEY_P8_BASE64`.

To create the local signing secrets:

1. In Keychain Access, create a certificate signing request for the signing Mac.
2. In Apple Developer -> Certificates, Identifiers & Profiles -> Certificates,
   create an Apple Distribution certificate from that CSR, download it, and
   import it into Keychain Access.
3. Export the Apple Distribution certificate plus private key from Keychain
   Access as a password-protected `.p12`, then set
   `IOS_DISTRIBUTION_CERT_PASSWORD` and
   `base64 -i /path/to/ios_distribution.p12 | gh secret set IOS_DISTRIBUTION_CERT_P12_BASE64`.
4. In Profiles, create two Distribution -> App Store Connect profiles: one for
   `com.tron.mobile` and one for `com.tron.mobile.ShareExtension`. Select the
   same Apple Distribution certificate, generate, and download both profiles.
5. Set the profile secrets with
   `base64 -i /path/to/AppStore.mobileprovision | gh secret set IOS_APPSTORE_PROFILE_BASE64`
   and
   `base64 -i /path/to/ShareExtension.mobileprovision | gh secret set IOS_SHARE_EXTENSION_APPSTORE_PROFILE_BASE64`.

The workflow decodes each profile before export and fails early if the
`application-identifier` does not match the expected team/bundle ID, if the
profile is an Ad Hoc/development profile with devices, or if the app and share
extension mix Xcode-managed and manually managed profile styles.

Manual workflow runs default to `dry_run=true`, which builds and tests but skips
App Store Connect upload and TestFlight distribution. A manual run with
`dry_run=false` exercises the full upload/distribution path without creating a
new tag, but it must use a unique Apple build number or an existing build that
is safe to redistribute. If Apple beta review does not approve an external build
before the workflow timeout, rerun the same workflow after App Store Connect
shows the build as externally testable; duplicate-build detection will reuse the
existing upload and continue distribution.

## Common Tasks

### Adding a New Screen

1. Create view in `Views/<Feature>/`
2. Create view model if needed in `ViewModels/`
3. Add navigation in parent view or sheet coordinator
4. Add deep link route if applicable

### Adding a Tool Visualization

1. Create chip in `Views/Tools/<ToolName>/<Name>Chip.swift`
2. Create detail sheet in same folder
3. Add case in `ToolChipFactory.swift`
4. Add sheet case in `SheetCoordinator`

### Updating Event Handling

See `docs/events.md` for the complete event handling guide.

## Known Issues

| Issue | Status | Notes |
|-------|--------|-------|
| DeepLinkRouter URL parsing | Bug | Host vs path confusion |
| StreamingManager timing test | Flaky | `testRapidDeltasGetBatched` |

## Performance

### Memory Management

- Event arrays capped (100 events per subagent)
- Messages windowed for large sessions
- Images loaded lazily

### UI Performance

- Streaming batched at 16ms intervals
- Scroll state tracked to avoid unnecessary updates
- Heavy transforms run on background threads

## Code Style

- SwiftLint configured via `.swiftlint.yml`
- Run `swiftlint` before committing
- Use `@MainActor` for all UI-touching code
- Prefer `@Observable` over `ObservableObject`
