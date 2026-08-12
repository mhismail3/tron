# Tron Mac development

## Stage the gateway

A fresh clone has neither Gateway dependencies/build output nor generated Mac
payloads. Xcode copies generated payloads; it does not run npm or download Node
during a build. Stage before opening or archiving the project:

```bash
packages/mac-app/scripts/bundle-gateway.sh
```

The script:

1. runs locked gateway install and TypeScript build;
2. creates an independent `npm ci --omit=dev` production tree, including the
   owned node-pty postinstall helper;
3. downloads exact Node 22.22.0 arm64 and x64 archives;
4. checks hard-coded SHA-256 values;
5. compiles `tron-gateway-launcher.c` as a universal macOS executable;
6. stages the launcher into both tracked Login Item skeletons.

Useful iteration options:

```bash
# Reuse gateway node_modules/dist, but refresh runtime payloads
packages/mac-app/scripts/bundle-gateway.sh --skip-install

# Reuse already staged exact Node runtimes too
packages/mac-app/scripts/bundle-gateway.sh --skip-install --skip-download

# Remove generated payloads only
packages/mac-app/scripts/bundle-gateway.sh --clean
```

## Generate and build

```bash
cd packages/mac-app
xcodegen generate
xcodebuild build -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64'
```

Use `TronMac Isolated Install` to own `com.tron.server.dev`, `~/.tron-dev`, and
port 9848 without replacing the installed production app. Ordinary Debug runs
are companions and do not manage production registration.

## Efficient focused tests

```bash
xcodebuild build-for-testing -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64'

xcodebuild test-without-building -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -only-testing:TronMacTests/PairingURLBuilderTests \
  -only-testing:TronMacTests/EnrollmentCodeReaderTests
```

After an edit, rerun the incremental `build-for-testing`, then keep using
`test-without-building`. This separates compilation from execution and avoids
repeatedly paying for unrelated suites. `TronMacTests` is hosted by the app and
must inherit the app's signing team; forcing the bundle to an ad-hoc identity
causes macOS to reject it before tests bootstrap.

## Pairing checks

Pairing requires:

- a healthy authenticated gateway on the selected port;
- an owner-only, unexpired `gateway/enrollment.json`;
- a detected Tailscale address;
- a code whose trimmed length is 8–32 characters.

The wrapper's local credential path is `gateway/local-auth.json`; do not regress
to legacy `~/.tron/auth.json` and never put the local token in the URL.

## Release

Mac release is manual. Stage the Gateway, generate the project, archive with the
maintainer's Developer ID identity, notarize and staple the app and DMG, then
publish the release assets deliberately. `packages/mac-app/scripts/package-dmg.sh`
owns DMG layout verification and requires `create-dmg` on `PATH`. Never add an
automated production release or deployment command.
