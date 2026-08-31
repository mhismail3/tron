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
# Force a fresh local staging pass while product push is unconfigured:
packages/mac-app/scripts/bundle-gateway.sh --allow-unconfigured-push
```

Staging resolves the exact Node version in the repository's `.node-version`
before installing anything, then derives `npm` from that Node's sibling `bin`
directory. A wrong ambient `PATH` Node is skipped; resolution checks the exact
`$NVM_DIR/versions/node/v<version>/bin/node` directory and Homebrew candidates
only after proving their version. `TRON_NODE_BIN` may explicitly name an
absolute executable, but it must print the pinned version; there is no ambient
npm override. Failure happens before build or payload mutation. These variables
affect staging only; the completed app uses its embedded Node runtimes and does
not consult this toolchain.

`config/PushService.xcconfig` is the one maintainer-owned public Push service
origin consumed by both iOS and this bundled Gateway. Development may stage an
unconfigured **dev-channel** payload with `--allow-unconfigured-push`; push then
remains unavailable. Every payload carries a regular, fingerprinted
`app/PushService.xcconfig`. Stable staging, selection, source update, rollback,
launcher admission, and packaging require exactly one non-empty public HTTPS
origin and reject missing, empty, malformed, or symlinked projections. A Stable
source update preserves the validated active payload's product configuration;
it never reads an environment override or substitutes the source checkout's
configuration. `scripts/tron mac verify` additionally compares the selected stable origin with the installed signed app, so an old external selection cannot masquerade as the current product configuration; repairing that mismatch requires selecting/installing a payload from the current signed product before another source-only update. Direct official staging and Mac Release builds fail closed while
the origin is empty. This is release configuration, never end-user setup, and
contains no credential. Notification grants and pending delivery state remain
under the Tron home outside immutable payload directories and survive updates.

The script:

1. runs locked gateway install and TypeScript build;
2. creates an independent `npm ci --omit=dev` production tree, including the
   owned node-pty postinstall helper;
3. downloads exact Node 22.22.0 arm64 and x64 archives;
4. checks hard-coded SHA-256 values;
5. compiles `tron-gateway-launcher.c` as a universal macOS executable;
6. creates exact relative `runtime/bin-{arm64,x64}` command aliases for the
   corresponding checked Node binaries and the bundled backing SDK CLI;
7. stages the launcher into the single Stable Login Item skeleton;
8. hashes every regular file and safe internal symlink under `app/**` (including
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

Before accepting an existing generated payload, `ensure-gateway-bundle.sh`
invokes `bundle-gateway.sh --verify-only`. Verification is read-only: it checks
bounded manifest identity against `.node-version`, compiles a fresh trusted
launcher verifier for the complete fingerprint, validates runtime hashes,
architectures, required paths, safe symlinks, immutable publication modes,
exact source/package manifest identity, and byte equality with a freshly
compiled unsigned universal helper. Staged runtimes are never executed during
validation; only the host build Node selected by `.node-version` is executed.
Verification also requires every runtime command alias to be an exact symlink
with exact relative target text resolving to its signed architecture runtime or
bundled SDK CLI. Missing, substituted, dangling, absolute, wrong-target, or
escaping aliases fail closed. A failed check triggers one explicit rebuild and a second verification;
malformed or tampered output is never silently accepted. `runtimeEpoch` is a freshness nonce bound by the immutable payload tree and its
subsequent Xcode code signature; it is not an externally reproducible source
input or a standalone secret. This milestone binds all other deterministic
identity fields to source/build inputs
without redesigning the production fingerprint algorithm. The isolated fixture
command below copies a payload to
a temporary directory and exercises valid, tampered, forged-helper, runtime,
writable-tree, symlink-escape, valid-identity-tamper, and malformed-manifest cases.

The Xcode post-build signing phase signs the embedded Node runtimes with
`TronNode.entitlements`. Node executes V8 JIT code, so the
`com.apple.security.cs.allow-jit` entitlement is required when the runtime is
sealed by the hardened runtime. Native Gateway modules and Login Items remain
signed without that extra entitlement.

Useful iteration options:

```bash
# Reuse gateway node_modules/dist, but refresh runtime payloads
packages/mac-app/scripts/bundle-gateway.sh --allow-unconfigured-push --skip-install

# Reuse already staged exact Node runtimes too
packages/mac-app/scripts/bundle-gateway.sh --allow-unconfigured-push --skip-install --skip-download

# Remove generated payloads only
packages/mac-app/scripts/bundle-gateway.sh --clean

# Read-only publication verification (does not build, install, or redownload)
packages/mac-app/scripts/bundle-gateway.sh --verify-only

# Pure helper check against a staged payload (does not build or install)
packages/mac-app/scripts/hash-gateway-payload.sh Sources/Resources/Gateway

# Isolated publication-policy fixtures (requires a staged payload; uses mktemp)
packages/mac-app/scripts/test-gateway-payload-verifier.sh

# Launcher boundary fixture (also covers channel path-component rejection)
packages/mac-app/scripts/test-tron-gateway-launcher.sh

# Manifest fingerprint rewrite (preserves launcher-sensitive JSON strings)
packages/mac-app/scripts/test-update-payload-fingerprint.sh
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
completed app contains the Gateway entrypoint, production `node_modules`, both
arm64/x64 Node runtimes, and fingerprinted architecture-specific `node` command
aliases. Stable adds only its selected immutable alias to `PATH` before extension
discovery, so it never consults a user's nvm/Homebrew installation or a global Pi
command. Debug preserves an already-resolving developer Node and uses the payload
alias only as fallback. Release validation must also
execute the signed embedded runtime, not only check that the binary is present;
a hardened Node runtime without its JIT entitlement exits before the Gateway
can bind its port.

### Gateway payload promotion

The installed Release wrapper owns only the Stable LaunchAgent. Debug lifecycle
belongs only to `scripts/tron dev`; the Release menu is a read-only authenticated
observer. Gateway transitions are user-initiated: repository agents may prepare and
validate a complete payload but must not run the following mutating operations. A user
or maintainer can stage and then explicitly promote that payload:

```bash
scripts/gateway-payload-deploy.mjs stage --channel stable --source <payload>
scripts/gateway-payload-deploy.mjs promote --channel stable --version <version>
scripts/gateway-payload-deploy.mjs rollback --channel stable --command-id <unique-command-id>
```

Promotion is serialized per channel, verifies the complete payload fingerprint,
uses authenticated drain-aware `gateway.restart`, waits without a deadline for the
exact old PID/start to disappear, and proves one different stable PID/start plus the
exact candidate health identity. Normal candidate startup belongs exclusively to launchd;
listener absence cannot authorize a kickstart because a live startup process may not have
bound yet. On failure it restores and revalidates the prior selection. If the launcher
already restored the exact healthy payload, recovery accepts it without another kill;
otherwise, after the candidate deadline, it kickstarts only an absent or exact
captured failed listener and fails closed on an unknown listener. Recovery never calls the failed Gateway. The iOS update button invokes
only the LaunchAgent-owned helper; verified artifact promotion is wired, and source
builds read only the validated `gateway/update-config.json` projection. Source mode uses
the repository's local TypeScript compiler with a private temporary output directory,
never `packages/gateway/dist`, and stages only verified output. A helper launch
acknowledgement does not claim eventual build or promotion success; failures are exposed
through bounded update progress. The Mac menu Restart seam uses the authenticated drain command rather than
`launchctl kickstart`; kickstart is deployment recovery only.

The Stable plist now requires Boolean `KeepAlive=true`. Delivering that plist requires
following **Reinstall a local Release build** below and refreshing registration with
Pause/Resume; payload promotion alone does not replace the registered plist.

An isolated opt-in launchd fixture verifies handled-exit relaunch and selection reread
without using Tron's label, ports, or data directories:

```bash
TRON_RUN_LAUNCHD_FIXTURE=1 packages/mac-app/scripts/test-launchd-relaunch-fixture.sh
```

The fixture registers a temporary `com.example.*` label and cleans it up on exit. It is
never part of ordinary automated tests because it intentionally invokes `launchctl`.

## Reinstall a local Release build

This is a manual developer installation, not a production deployment command.
The user or maintainer performs Pause, replacement, launch, Resume, and every
Gateway transition. Repository agents may prepare and validate the `.app` artifact and
report its path, but must not initiate those operations. It is also the bootstrap path for an intentional lockstep Gateway protocol bump:
the new signed launcher rejects a previously selected payload whose manifest
protocol differs and falls back to the matching bundled Gateway. The final Mac
app binds its own protocol metadata to that bundled payload before signing.
After `scripts/tron mac verify` passes, the physical iOS helper independently
requires the same signed protocol before installation.

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

Do not install the new iOS app before this Mac verification succeeds. Verify
the result with the read-only check:

```bash
scripts/tron mac verify
```

It fails unless Stable's Release-owned launchd PID is the sole 9847 listener,
executes the validated active payload, and returns matching authenticated
`system.info` channel/revision/fingerprint/epoch. An incompatible or invalid
external selection may remain as bounded rollback history after a protocol
bump; verification accepts it only when both the launcher and live PID have
rejected it in favor of the signed bundled payload. If Debug is present, it also
requires one lifecycle snapshot whose live supervisor and child PID/start
identities, sole 9848 listener, selected manifest, command, and authenticated
identity all agree. Debug absence is informational; loaded legacy Debug or
Preview services are collisions. The verifier checks both signed runtimes and
aliases on every Mac, but executes only the host-native runtime. The bundled
foreign-architecture runtime is validated statically; this avoids false
failures when Rosetta is unavailable or when translated Node cannot obtain its
JIT permissions. If the menu-bar controls are
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

The installed wrapper owns Stable only. Developer tooling owns Debug. `status` and
`preflight` are read-only; the user or maintainer must initiate every listed mutating
lifecycle or handoff command. Repository agents report the needed command but do not
execute it:

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
supervisor before changing exposure. `scripts/tron dev` resolves the pinned
repository Node once and uses its absolute Node and sibling npm for every
helper, build, and deployment command; it fails before touching `~/.tron-dev`
when that toolchain is unavailable. Mutating commands use a short-lived atomic
command lock, released before the supervisor continues running, so concurrent
start/restart/stop/handoff commands fail closed. If the supervisor is stale but
the exact recorded child PID/start identity is still live, start first terminates
that owned orphan through `stopping` → `stopped`; a listener without that exact
identity remains foreign and is never killed.

The handoff proves the selected Debug fingerprint/revision/epoch before and
after copying, rejects runtime drift that requires a manual `Tron.app` update,
and never changes Stable `current.json` or restarts 9847. The confirmed iOS
**Promote Debug Gateway to Stable** action pins both candidate version and
fingerprint and invokes the existing asynchronous Stable deployment core.

The command serializes selection publication per channel, verifies complete
payload fingerprints, calls authenticated drain-aware `gateway.restart`, waits
without a startup deadline for the exact local pre-restart listener process to
exit or be replaced, and only then starts bounded exact-candidate health checks.
Health absence alone is never accepted as a drain transition. Local listener ownership
uses bounded `lsof` terse PID output plus a separate process-start identity probe; field
mode is intentionally excluded because macOS always emits an extra file-descriptor record.
Normal promotion never kickstarts from listener absence: launchd owns candidate relaunch,
and a live startup process may not have bound its listener yet. On failure the helper
restores and revalidates the prior selection, accepts an already-running exact restored
payload, or uses one fixed recovery kickstart only after the candidate deadline and only
for an absent/exact captured failed listener; unknown listeners fail closed.
Recovery never issues RPC to the failed Gateway. The Mac menu Restart seam uses
authenticated `gateway.restart` instead of `launchctl kickstart`. Never automate
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
