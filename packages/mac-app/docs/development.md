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

Staging resolves `node` and `npm` independently before installing anything. This
works with Xcode's sanitized `PATH`: set `TRON_NODE_BIN` and/or `TRON_NPM_BIN`
to absolute executable paths to override resolution. Without overrides, the
script checks `PATH`, then the bounded nvm tree under `$HOME` (or `NVM_DIR`),
then `/opt/homebrew/bin` and `/usr/local/bin`. It fails with the override and
installation guidance if either tool is unavailable. These variables affect
staging only; the completed app uses its embedded Node runtimes and does not
consult this toolchain.

The script:

1. runs locked gateway install and TypeScript build;
2. creates an independent `npm ci --omit=dev` production tree, including the
   owned node-pty postinstall helper;
3. downloads exact Node 22.22.0 arm64 and x64 archives;
4. checks hard-coded SHA-256 values;
5. compiles `tron-gateway-launcher.c` as a universal macOS executable;
6. stages the launcher into the single Stable Login Item skeleton;
7. hashes every regular file and safe internal symlink under `app/**` (including
   the complete production `node_modules` tree) and `runtime/**` with the
   launcher's bounded in-process hasher, then writes that fingerprint into the
   bundled `manifest.json` and stamps a runtime epoch. The shell hash helper
   remains the readable cross-implementation test fixture. Use
   `scripts/gateway-payload-deploy.mjs` for immutable payload operations;
   `scripts/tron dev` is the sole Debug supervisor on port 9848.

The bundled manifest is the fallback identity authority. External payloads use
an atomically replaced `gateway/payloads/<channel>/current.json` pointer to a
complete `versions/<version>` directory. The Stable LaunchAgent selects the
`stable` channel; scripts/tron-dev launches the installed signed launcher with
the `dev` selection. The helper validates
both manifests and all required paths before selecting an external payload,
otherwise it uses the validated bundled payload. Promotion additionally checks
the complete fingerprint before publishing.

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

# Pure helper check against a staged payload (does not build or install)
packages/mac-app/scripts/hash-gateway-payload.sh Sources/Resources/Gateway

# Launcher boundary fixture (also covers channel path-component rejection)
packages/mac-app/scripts/test-tron-gateway-launcher.sh
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

### Gateway payload promotion

The installed Release wrapper owns only the Stable LaunchAgent. Debug lifecycle
belongs only to `scripts/tron dev`; the Release menu is a read-only authenticated
observer. Without building, bundling, installing, or restarting during preparation, an operator
can stage and then explicitly promote a complete payload:

```bash
scripts/gateway-payload-deploy.mjs stage --channel stable --source <payload>
scripts/gateway-payload-deploy.mjs promote --channel stable --version <version>
scripts/gateway-payload-deploy.mjs rollback --channel stable
```

Promotion is serialized per channel, verifies the complete payload fingerprint,
uses authenticated drain-aware `gateway.restart`, and proves the new health
identity before success. On timeout or identity mismatch it atomically restores
`previous.json` and requests/awaits rollback restart. The iOS update button invokes
only the LaunchAgent-owned helper; verified artifact promotion is wired, and source
builds read only the validated `gateway/update-config.json` projection. Source mode uses
the repository's local TypeScript compiler with a private temporary output directory,
never `packages/gateway/dist`, and stages only verified output. A helper launch
acknowledgement does not claim eventual build or promotion success; failures are exposed
through bounded update progress. The Mac menu Restart seam uses the same authenticated drain command rather than
`launchctl kickstart`.

## Reinstall a local Release build

This is a manual developer installation, not a production deployment command.
Do not remove `~/.tron`; it contains canonical sessions and owned credentials.
When replacing an already-installed app, first wait for active runs to finish,
choose **Pause Tron** from the Mac menu bar, and quit the wrapper. Stop any
legacy Debug SMAppService separately; Release installation never takes over or
mutates Debug lifecycle. Then build a
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

It fails unless Stable's Release-owned launchd PID is the sole 9847 listener,
executes the validated active payload, and returns matching authenticated
`system.info` channel/revision/fingerprint/epoch. If Debug is present, it also
requires one lifecycle snapshot whose live supervisor and child PID/start
identities, sole 9848 listener, selected manifest, command, and authenticated
identity all agree. Debug absence is informational; loaded legacy Debug or
Preview services are collisions. If the menu-bar controls are
unavailable, use the installed app's **Uninstall Tron** action without selecting
reset options, then launch the replacement and complete the Install step; that
preserves canonical sessions and credentials but stops the Gateway during the
transition.

The Release menu authenticates to a developer-owned Debug Gateway on 9848 and,
when one coherent observation is healthy, exposes read-only Debug status and
pairing information. The observation is generation-gated and pairing pins its
exact admitted host/runtime, so overlapping refreshes and restarts cannot mix
projections. It never controls Debug lifecycle or writes its cache. Stable remains independently owned
by `com.tron.server`/`com.tron.mac` on 9847. `scripts/tron dev` uses
`~/.tron-dev` and `~/.pi/agent-dev` without SMAppService registration.

### Gateway payload operations

The installed wrapper owns Stable only. Developer tooling owns Debug:

```bash
scripts/tron dev start       # build, immutable-stage, and start 9848
scripts/tron dev restart     # stage and authentically drain/restart
scripts/tron dev status
scripts/tron dev stop
scripts/tron dev handoff     # exact tested Debug artifact -> inactive Stable candidate
```

Fresh starts default to loopback; pass `--tailscale` when iOS must connect.
Status, restart, handoff, and stop without a host flag inherit a live
supervisor's recorded host. A conflicting explicit flag is rejected; stop the
supervisor before changing exposure.

The handoff proves the selected Debug fingerprint/revision/epoch before and
after copying, rejects runtime drift that requires a manual `Tron.app` update,
and never changes Stable `current.json` or restarts 9847. The confirmed iOS
**Promote Debug Gateway to Stable** action pins both candidate version and
fingerprint and invokes the existing asynchronous Stable deployment core.

The command serializes selection publication per channel, verifies complete
payload fingerprints, calls authenticated drain-aware `gateway.restart`, waits
without a startup deadline for the exact local pre-restart listener process to
exit or be replaced, and only then starts bounded exact-candidate health checks.
Health absence alone is never accepted as a drain transition. On failure it restores the
previous selection and requests/awaits rollback. The Mac menu Restart seam
uses authenticated `gateway.restart` instead of `launchctl kickstart`. Never automate
copying into `/Applications`, release deployment, or launchd registration.

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
the deep strict app/helper signatures, authoritative complete payload
fingerprint, exact Node architectures and allow-jit entitlements, runtime
execution, production dependency tree, and Login Item both before imaging and
from the read-only mounted DMG. Notarize and staple the app and DMG, then publish the
release assets deliberately. `packages/mac-app/scripts/package-dmg.sh`
owns DMG layout verification and requires `create-dmg` on `PATH`. Never add an
automated production release or deployment command.
