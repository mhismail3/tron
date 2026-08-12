# Tron iOS development

## Generate and build

```bash
cd packages/ios-app
xcodegen generate
xcodebuild build -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration ProdDebug \
  -destination 'generic/platform=iOS Simulator'
```

The generated Xcode project is not architectural truth; edit `project.yml` and
source files, then regenerate.

## Efficient focused tests

Do not rerun the full suite for each edit. Compile test products once, then run
only the owning suite without rebuilding:

```bash
xcodebuild build-for-testing -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SnapshotCacheTests
```

Multiple `-only-testing:` arguments may select adjacent owners. After source
changes, rerun the incremental `build-for-testing` (normally seconds), then
continue with `test-without-building`. Run the complete unit target only after
focused suites pass:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests
```

Run UI tests separately because simulator launch dominates their cost:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron UI Validation' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileUITests/TronSmokeUITests \
  -collect-test-diagnostics never
```

For real gateway-to-iOS E2E work, keep the deterministic gateway fixture and
DerivedData alive across edits. Preparation and the first build happen once;
`run` renews only the one-use enrollment/session fixture and executes the
focused UI test without reinstalling dependencies or rebuilding:

```bash
scripts/ios-gateway-e2e-test prepare
scripts/ios-gateway-e2e-test build
scripts/ios-gateway-e2e-test run

# After a Swift edit:
scripts/ios-gateway-e2e-test iterate
```

The focused runner disables Xcode's failure sysdiagnose collection, which can
otherwise add a ten-minute timeout after a UI assertion. Use `logs`, `status`,
`stop`, and `clean` to inspect or manage the persistent fixture. CI uses the
same script and reuses its UI-test products for smoke and real-gateway tests.
Full unit and UI suites remain final checkpoint validation, not an edit loop.

Typography or control-style changes must run
`TronMobileTests/FontSettingsTests` and
`TronMobileTests/PresentationStyleGuardTests`. The font tests verify all bundled
faces resolve, historical preference keys round-trip, and variable Source Serif
and Recursive code roles do not silently become system fonts. The presentation
guard rejects app-owned system fonts, stock bordered/search/segmented/field
styles, system-generated section/navigation titles, unstyled text inputs, and
Form/List surfaces that omit the Tron collection treatment. OS-owned alerts,
menus, and pickers are deliberate exceptions.

UI validation audits onboarding in light and dark modes and audits a
populated real-gateway chat, session management, settings, and appearance. The
real-gateway test retains named screenshot checkpoints for the completed chat,
Manage Session, root settings, and appearance in its result bundle. It also
relaunches at accessibility XXXL to verify standard SwiftUI controls that
XCTest's simulated Dynamic Type audit misclassifies. Any audit suppression must
name one exact element, have a retained rendered checkpoint, and have a separate
real-size assertion; category-wide suppression is not allowed.

Simulator screenshots are deterministic regression artifacts, not the final
system-chrome authority. At broad presentation checkpoints, build the actual
`Tron Fast` `ProdDebug` app for the connected iOS 27 device, install it without
removing its Keychain pairing, launch it against the isolated development
gateway, and capture chat, dashboard/setup, Manage Session, tool detail, and
settings screens with `devicectl`. Compare those captures to the historical
references before declaring parity. A signed install, launch, and screenshot are
required together because default toolbar Liquid Glass can differ materially
between the simulator and physical hardware. Chat checkpoints must also verify
trailing alignment for user turns, historical transcript/tool insertion motion,
the Settings gear in the chat toolbar, the context ring immediately before the
microphone, and emerald toolbar/sheet actions. Terminal checkpoints must exercise
the native keyboard plus the floating shortcut and command-key surfaces rather
than validating only PTY output.

Historical onboarding references captured by executing commit `c3f12c17c` live
under `docs/assets/parity/`. `TronSmokeUITests` keeps matching medium/pairing
screenshots in its result bundle. Compare the medium sheet crop as well as the
full screen: the mounted shell toolbar, detent, centered title, card geometry,
page dots, and toolbar navigation are all part of the parity contract. Copy may
change only where gateway security semantics require one-time enrollment rather
than a permanent pairing token.

## Gateway fixture work

Protocol DTO changes require matching gateway tests and Swift decoding tests.
Use provider-qualified models, preserve unknown JSON through `JSONValue`, and
make new mutation calls carry a UUID `commandId`.

## Privacy

The app declares local-network, microphone, and speech-recognition usage.
Speech audio is transcribed through Apple Speech APIs. Provider credentials must
never be placed in fixtures, defaults, logs, or UserDefaults.
