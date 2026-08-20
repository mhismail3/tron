# Tron Mac development

## Stage the gateway

A fresh clone has neither Gateway dependencies/build output nor generated Mac
payloads. The Mac Xcode target automatically runs
`ensure-gateway-bundle.sh` before compiling when the payload is missing. This
stages the Gateway's locked production dependencies and embedded Node runtimes;
it does not require Pi to be installed globally.

For an explicit preflight or to refresh an existing payload:

```bash
packages/mac-app/scripts/ensure-gateway-bundle.sh
# Force a fresh staging pass:
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

The Xcode post-build signing phase signs the embedded Node runtimes with
`TronNode.entitlements`. Node executes V8 JIT code, so the
`com.apple.security.cs.allow-jit` entitlement is required when the runtime is
sealed by the hardened runtime. Native Gateway modules and Login Items remain
signed without that extra entitlement.

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

The build fails closed if staging cannot complete (for example, if the
machine lacks the development Node/npm toolchain or network access). A
completed app contains the Gateway entrypoint, production `node_modules`, and
both arm64/x64 Node runtimes, so the installed app does not consult `PATH`, a
user's nvm installation, or a global Pi command. Release validation must also
execute the signed embedded runtime, not only check that the binary is present;
a hardened Node runtime without its JIT entitlement exits before the Gateway
can bind its port.

### Reinstall a local Release build

This is a manual developer installation, not a production deployment command.
Do not remove `~/.tron`; it contains canonical sessions and owned credentials.
When replacing an already-installed app, first wait for active runs to finish,
choose **Pause Tron** from the Mac menu bar, and quit the wrapper. Then build a
Release app with an explicit derived-data directory:

```bash
cd packages/mac-app
xcodegen generate
xcodebuild -project TronMac.xcodeproj -scheme TronMac \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/tron-mac-release build
open /tmp/tron-mac-release/Build/Products/Release/Tron.app
```

In Finder, replace `/Applications/Tron.app` with that built `Tron.app`, then
launch it. The existing onboarding marker keeps the wrapper in menu-bar mode;
choose **Resume Tron** so macOS registers the new bundled LaunchAgent plist
and starts the new helper. Approve Tron Agent under System Settings → General →
Login Items if macOS asks. Wait for the menu-bar status to report Running before
reconnecting iOS. Pause/Resume is intentional here: it reloads the plist and
its supervision environment, whereas **Restart Tron** only restarts the
currently registered job. The new wrapper also detects a running same-bundle
job without the supervision marker and repairs its registration before it
settles into the healthy state.

Verify the result with the read-only check:

```bash
scripts/tron mac verify
```

It fails if the installed app, structured Gateway payload, supervision marker,
LaunchAgent PID, or running executable is stale. If the menu-bar controls are
unavailable, use the installed app's **Uninstall Tron** action without selecting
reset options, then launch the replacement and complete the Install step; that
preserves canonical sessions and credentials but stops the Gateway during the
transition.

Use `TronMac Isolated Install` to own `com.tron.server.dev`, `~/.tron-dev`,
`~/.pi/agent-dev`, and port 9848 without replacing the installed production app.
The isolated Gateway shares only the physical-machine group hint stored at
`~/.tron-machine-group-id`; it does not share canonical JSONL sessions or
credentials. Ordinary Debug runs as a regular companion window and do not
install a second production menu-bar item or manage production registration.

### Automated isolated development versus release replacement

Routine agent-driven Gateway changes stay isolated: use `~/.tron-dev/gateway`,
port `9848`, and the repository supervisor. `scripts/tron dev --status --json`
is a deterministic, read-only preflight; it does not build, restart, or touch
the installed app. `scripts/tron dev --stop` is likewise build-free. The
supervisor's atomic lifecycle manifest records PID start identities, epoch,
revision, payload fingerprint, bounded restart state, and `/health` readiness.
Status/preflight probes the manifest's expected host and port (an explicit
`--tailscale` selection remains an override). Exit 75 means the authenticated
Gateway drain completed intentionally. A
restart action reconciles a new epoch and health identity before it succeeds.

The installed `Tron.app` and its supervised `9847` Gateway are a frozen release
image during this workflow. Never automate copying into `/Applications`,
production deployment, launchd/SMAppService operations, or iOS release
installation from the isolated development command. Release replacement remains
the manual runbook above, including the explicit Finder replacement and the
read-only `scripts/tron mac verify` check afterward.

### Separate-terminal stopping point

When implementation and allowed static validation are complete, stop before
operating the Gateway and give the maintainer this exact separate-terminal
sequence:

1. From the repository root run `scripts/tron dev --preflight --json` and inspect
   endpoint/home, lifecycle, PID identities, epoch, revision/fingerprint, and
   readiness. This command does not build.
2. In that separate terminal, run exactly
   `scripts/tron dev --restart --tailscale --command-id <new-unique-command-id>`.
   This is the single approved rebuild/restart operation; do not run `bundle`,
   launchd/SMAppService commands, or replace `/Applications/Tron.app`.
3. Wait for the command to report the new runtime epoch and ready health, then
   verify with `scripts/tron dev --status --json` (and retain the bounded log path
   if it fails).
4. Return to the agent terminal with the preflight and readiness output.

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

Mac release is manual. The Xcode build preflight stages the Gateway, then the
maintainer archives with the Developer ID identity. `package-dmg.sh` verifies
the entrypoint, production dependency tree, both Node runtimes, and Login Item
before creating the DMG. Notarize and staple the app and DMG, then publish the
release assets deliberately. `packages/mac-app/scripts/package-dmg.sh`
owns DMG layout verification and requires `create-dmg` on `PATH`. Never add an
automated production release or deployment command.
