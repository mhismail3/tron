# Tron Mac development

## Stage the gateway

A fresh clone has neither Gateway dependencies/build output nor generated Mac
payloads. Install the repository-pinned project generator once with
`scripts/install-ci-tools.sh xcodegen`; `scripts/tron mac generate` verifies that
exact tool before generating the disposable project. The Mac Xcode target then
automatically runs `ensure-gateway-bundle.sh` before compiling when the payload
is missing. This stages the Gateway's locked production dependencies, embedded
Node runtimes, and checksum-pinned universal XcodeGen toolchain inside the app;
the resulting destination Mac needs no global Pi, Node, or XcodeGen installation.

For an explicit preflight or to refresh an existing payload:

```bash
packages/mac-app/scripts/ensure-gateway-bundle.sh
# Force a fresh local staging pass while product push is unconfigured:
packages/mac-app/scripts/bundle-gateway.sh --allow-unconfigured-push
```

Staging resolves the exact Node version in the repository's `.node-version`
before installing anything, then derives `npm` from that Node's sibling `bin`
directory. Candidate admission proves the complete pair: a wrong-version Node
or a pinned-version payload alias without sibling npm is skipped before the
exact `$NVM_DIR/versions/node/v<version>/bin/node` directory and Homebrew
candidates are considered. `TRON_NODE_BIN` may explicitly name an absolute
executable, but it must provide both the pinned Node and sibling npm; there is
no ambient npm override. Failure happens before build or payload mutation. These variables
affect staging only. Focused shell and Node payload tests derive their fixture
root from the active pinned Node executable, or from an explicit
`TRON_NODE_ROOT`, and reject a version mismatch. Hosted Mac tests use the npm
runtime embedded in their built test app. No test depends on a machine-specific
temporary archive path. Release preparation also downloads and verifies the
repository-pinned XcodeGen archive, executable, and preset tree, then
fingerprints them under `Gateway/runtime/xcodegen`. Bundle writers serialize
before touching the shared dependency tree, assemble and verify generated
resources under a private source-local staging root, and publish the payload,
launcher, and icon through bounded backup renames. Failure or interruption
restores the prior generated projection; `ensure-gateway-bundle.sh` never erases
that projection before a replacement is ready. The completed app uses only those
embedded runtimes for supervised work and does not consult Homebrew, NVM, or the
destination checkout's `.ci-tools` cache.

The Mac app build compiles the universal C Node-API8 capture client and places it
beside the helper at `Contents/Library/Native/tron-native-capture.node`, with its
production input manifest. `native-gateway-client/build.py` checks the four
Node22.22.0 C header SHA-256 pins and freezes its production inputs. The normal
nested signing phase signs the client before the outer app seals it. No library
validation entitlement is disabled. Gateway source-only updates never touch this
Mac-owned native client; native changes require a manual Mac app update. An absent
or incompatible client makes only capture unavailable, not the whole Gateway. See
[direct capture client ownership](computer-control.md#direct-gateway-capture-client) for
local-only cleanup versus remote Stop, test artifacts and qualification gates.

`config/PushService.xcconfig` is the one maintainer-owned public Push service
origin consumed by both iOS and this bundled Gateway. Development may stage an
unconfigured **dev-channel** payload with `--allow-unconfigured-push`; push then
remains unavailable. Every payload carries a regular, fingerprinted
`app/PushService.xcconfig`. Stable staging, selection, source update, rollback,
launcher admission, and packaging require exactly one non-empty public HTTPS
origin and reject missing, empty, malformed, or symlinked projections. A Stable
source update preserves its validated runtime base's product configuration; it
never reads an environment override or substitutes the source checkout's
configuration. The selected payload remains the preferred base. When a newer
payload contract invalidates it, source repair may use only the fully validated
configured artifact, the signed launcher's exported bundled root, or the prepared
Gateway bundle inside the admitted source checkout, in that order. The updater
revalidates the copied snapshot against the admitted manifest before changing it;
it never scans historical versions for a convenient fallback. This lets a prepared
local Release build break a toolchain bootstrap deadlock while malformed or stale
payloads still fail closed. `scripts/tron mac verify` additionally compares the selected stable origin with the installed signed app, so an old external selection cannot masquerade as the current product configuration; repairing that mismatch requires selecting/installing a payload from the current signed product before another source-only update. Direct official staging and Mac Release builds fail closed while
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

# Bundled npm removal with sanitized PATH and isolated HOME/cache
packages/mac-app/scripts/test-tron-gateway-npm.sh

# Manifest fingerprint rewrite (preserves launcher-sensitive JSON strings)
packages/mac-app/scripts/test-update-payload-fingerprint.sh
```

## Generate and build

```bash
scripts/tron mac generate
cd packages/mac-app
xcodebuild build -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64'
```

The build fails closed if staging cannot complete (for example, if the
machine lacks the development Node/npm toolchain or network access). A
completed app contains the Gateway entrypoint, production `node_modules`, both
arm64/x64 Node runtimes, the npm 10.9.4 CLI trees extracted from those same
official archives, and fingerprinted architecture-specific `node`, `npm`, and `pi`
command aliases. Stable adds only its selected immutable alias to `PATH` before extension
discovery, so it never consults a user's nvm/Homebrew installation or a global Pi
command. The Pi command is npm's `app/node_modules/.bin/pi` projection, and the
runtime aliases must target their exact payload entries; private package-internal CLI paths are not
a payload contract. Debug preserves an already-resolving developer
Node and uses the payload alias only as fallback. Release validation must also
execute the signed embedded runtime, not only check that the binary is present;
a hardened Node runtime without its JIT entitlement exits before the Gateway
can bind its port.

### Session search embedding helper

The `TronSearchEmbeddingHelper` target is copied to
`Contents/Resources/TronSearchEmbeddingHelper` and signed by the app's final
composition phase. The Gateway admits semantic readiness only after running its
bounded synthetic qualification (512 dimensions, paraphrase similarity, and a
negative control). Bundled runtime launches derive this path beside the Gateway
payload. The Gateway admits only the regular, non-symlink helper whose exact
`TronSearchEmbeddingHelper` code identity, `MYGKXH6TY4` team, hardened runtime
signature, and real path match the packaged artifact. A source-built helper may
set `TRON_SEARCH_EMBEDDING_HELPER` only when `NODE_ENV=development`; production
ignores that override. Missing, unsigned, tampered, unsupported-language, or
semantically unqualified helpers leave search lexical-only and are never treated
as ready. Helper responses include the NaturalLanguage sentence embedding
revision, and Gateway qualification requires that revision, language, and
512-dimensional vector metadata to remain stable for every vector and query.

The same build embeds the signed Aqua `Tron Native Host` at
`Contents/Library/Native/Tron Native Host.app`. Its target explicitly keeps
`PRODUCT_NAME=TronNativeHost`; the shared Release configuration's `Tron` product
name belongs only to the outer application. The build dependency disables
Xcode's automatic embedding/linking: the existing copy/sign phase is the sole
owner of the helper's `Contents/Library/Native` placement. Do not leave another
copy under `Contents/Resources`; composition validation rejects duplicate helper
bundle identities. Packaging must retain its fixed
`com.tron.mac.native-host` identity and deep strict signature. Its bundled Aqua
LaunchAgent/Mach service is registered only by explicit setup and removed by
explicit uninstall; ordinary readiness probes never register it or ask for TCC.
The helper queries TCC from its own process and both peers pin XPC messages to the
signed bundled build. `package-dmg.sh` checks the nested host signature and both
architectures. Packaging and the installed-app verifier also use
`scripts/validate-native-host.py` to require the exact Aqua Mach-service plist,
parent association, program path, accessory metadata and matching signing-team
metadata; signature checks remain separate. Validate final service attribution and background approval with
the signed installed composition; a temporary qualification app is not that proof.

The `.bin/pi` projection is an executable contract transition. Existing signed
launchers retain the old private CLI path until the user performs the documented
manual Mac Release reinstall; source-only payload promotion through that launcher
must fail closed rather than silently accepting the old target. The reinstall
replaces the launcher and payload together, after which `scripts/tron mac verify`
confirms the signed projection.

### Gateway payload promotion

Pi SDK rollback verification is performed before payload promotion with
`cd packages/gateway && npm run test:pi-sdk-rollback`; its JSONL/settings/auth
fixtures are disposable and isolated from `~/.tron`. The simulator-only iOS
E2E gate is upgrade-only: CI compares the committed Pi package graph and runs
`scripts/ios-gateway-e2e-test all` only when that graph changes, with cleanup
always guaranteed. The `.bin/pi` projection is a one-time signed launcher
transition; an installed old launcher is not a valid source-only promotion
path, so the user must perform the documented manual Release reinstall.

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

## Permission identity and stale listings

For normal Stable use, keep `Tron.app` (`com.tron.mac`) at `/Applications/Tron.app`
and its sole bundled `Tron Native Host.app` (`com.tron.mac.native-host`) under
`Contents/Library/Native`. FDA belongs to the wrapper. Depending on the service,
macOS can attribute the native helper's request to the responsible wrapper:
Screen Recording may appear as Tron, while Accessibility appears as Tron Native
Host. Native computer use needs Accessibility and Screen Recording; it does not
request Input Monitoring for an unused observer. Never infer identity from the
display name alone or merge Debug and Stable bundle identifiers to hide rows.
macOS can also present a separate direct-capture consent dialog on first capture.
The ordinary grant booleans do not prove that dialog was completed. The user must
handle it; foreground automation must first inspect the full desktop, not only a
window screenshot that can omit the blocking system prompt.

After granting Screen Recording, macOS may restart only the wrapper while the
native helper remains alive. If Settings shows the current Tron entry enabled but
Tron's own row remains ungranted, use **Permissions… → Restart Helper**, which
joins native retirement before unregister/register, then re-check. A pending or
failed drain is not permission to quit/kill the helper. Do not restart the Gateway or reset working grants as a workaround.
A still-failing fresh helper requires diagnosis, not repeated permission toggles.

Users who no longer use development/qualification builds can remove these old
permission-list entries through System Settings's minus control:

- `Tron-Dev` / `com.tron.agent` (retired application identity)
- `TronMac` / `com.tron.mac.dev` (development wrapper)
- `TronComputerUseQualification` / `com.tron.qualification.computer-use`
- `TronNativeObserverQualification` / `com.tron.qualification.native-observer`
- `TronNativeCaptureQualification` / `com.tron.qualification.native-capture`

This revokes only those old/test grants; it is not deletion of sessions or apps.
Keep unrelated apps and the current Stable identities. Do not use a global TCC
reset or edit TCC databases. Removing an old app's grant does not require deleting
`~/.tron`, `~/.pi`, worktrees or qualification evidence. Historical expanded app
bundles may also remain in Launch Services; archive/unregister only exact stale
artifacts after verifying they are not running or needed for development. Never
remove a nested helper from the installed signed app by hand. Release packaging
must contain exactly one native helper; the validator rejects automatic duplicate
embedding under Resources.

## Reinstall a local Release build

This is a manual developer installation, not a production deployment command.
The user or maintainer performs Pause, replacement, launch, Resume, and every
Gateway transition. Repository agents may prepare and validate the `.app` artifact and
report its path, but must not initiate those operations. It is also the bootstrap path for an intentional lockstep Gateway protocol bump:
the new signed launcher rejects a previously selected payload whose manifest
protocol differs and falls back to the matching bundled Gateway. The final Mac
app binds its own protocol metadata to that bundled payload before signing.
After `scripts/tron mac verify` passes, the physical iOS helper independently
requires the same signed protocol before installation. The Gateway package manager
uses the npm CLI shipped from the same pinned Node archive as the bundled runtime;
the launcher exports that architecture-specific command directory so package
install/remove/update operations do not depend on launchd's PATH. Git-backed package
operations remain intentionally dependent on the host `git` executable because Pi owns
that checkout lifecycle; verify `/usr/bin/git` (or another explicitly configured Git)
before using Git packages. This is a
Mac payload change: a source-only Gateway rebuild cannot add the missing npm
runtime to an already-installed app. Build and manually replace the Mac Release
app before testing package operations.

Do not remove `~/.tron`; it contains Gateway-owned state/credentials and Tron's
internal workspace (`workspace/files` and capability-owned `workspace/state`).
Preserve `gateway/workspace-state` lifecycle evidence with that workspace. Canonical
session JSONL, provider credentials and runtime settings stay under
`~/.tron/agent` (Debug: `~/.tron-dev/agent`); do not remove those either. Application
replacement and local settings/credential reset do not delete the internal
workspace. See the [workspace ownership and restore contract](../../gateway/docs/internal-workspace.md).
Build and validate the replacement artifact first; source preparation does not
require changing the running services. Before replacing an already-installed app,
the user must complete this sequence using the **old installed wrapper**:

1. Wait for active agent work to finish.
2. Open **Permissions… → Disable Helper for Update** and wait for successful
   native drain and unregister. A pending/failed result stops the update. Neither
   Gateway Pause, wrapper quit, process absence nor an elapsed timer substitutes
   for joined native retirement.
3. Only after that succeeds, choose **Pause Tron** and quit the wrapper. Stop any
   legacy Debug SMAppService separately; Release never takes over Debug lifecycle.
4. Replace the application in Finder, then launch the new installed copy.

Old and new wrapper/helper builds pin each other's signed code hashes. If the app
was replaced before this drain, the new wrapper may be unable to contact the old
helper. Do not weaken the pins, force unregister/kill surviving work, or assume
Restart Helper repairs that mismatch. If an older installed build lacks the
pre-update control, stop for an explicitly reviewed maintainer bootstrap based on
that build's actual capabilities; the capture-owning sequence cannot be skipped.
The separate one-time cutover runbook documents a narrowly admitted
[pre-helper bootstrap](agent-home-cutover.md#reviewed-pre-helper-bootstrap) for
the reviewed build that predates native capture entirely. It is not a general
missing-helper fallback and is not part of routine reinstall behavior.
Likewise, a `.notFound`/unknown native-service status refuses drain without XPC,
registration or Gateway/file changes. Some never-registered optional helpers can
report `.notFound`; successful uninstall/refresh for that first-install case is
an open availability gate, not evidence that native work has retired. Do not
register a helper or infer absence just to bypass the refusal.

Prepare a Release app with an explicit derived-data directory:

```bash
scripts/tron mac generate
cd packages/mac-app
xcodebuild -project TronMac.xcodeproj -scheme TronMac \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/tron-mac-release build
```

`TRON_CI_XCODE_VERSION` remains the deterministic CI reference, not an upper
bound on local Mac development. A later selected Xcode is usable only when the
pinned XcodeGen generation, Release build, complete signed-payload validation,
and installed-app verification all pass; compiler success alone is insufficient.
Mac asset validators therefore use stable tool projections rather than relying
on command forms whose argument parsing changed between Xcode releases.

In Finder, replace `/Applications/Tron.app` with that built `Tron.app`, then
launch it after the old-wrapper sequence above. The existing onboarding marker
keeps the wrapper in menu-bar mode. Explicitly enable the new native helper in
**Permissions…** when native capture is wanted; enabling does not request new TCC
grants. Choose **Resume Tron** so macOS registers the new bundled LaunchAgent plist
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
`system.info` channel/revision/fingerprint/epoch. Pointer admission mirrors the
current required runtime contract, including the signed universal pinned
XcodeGen tree, rather than accepting an older self-consistent fingerprint alone.
An incompatible or invalid external selection may remain as bounded rollback
history after a protocol or runtime-contract bump; verification accepts it only
when both the launcher and live PID have rejected it in favor of the signed
bundled payload. If Debug is present, it also
requires one lifecycle snapshot whose live supervisor and child PID/start
identities, sole 9848 listener, selected manifest, command, and authenticated
identity all agree. Debug absence is informational; loaded legacy Debug,
Preview or Stable dev-takeover services are collisions. Preview/dev-takeover
plists left in `~/Library/LaunchAgents` also fail verification, even when unloaded:
login could relaunch a retired owner against Stable's home and port. The maintainer
must retire the exact legacy service and its login plist; the verifier never unloads
services or removes files. A healthy current listener does not clear that gate.
The collision regression runs in `scripts/test-mac-reinstall.py`. The offline
checkpoint also refuses the loaded dev-takeover job, even without a listener.
The verifier checks both signed runtimes and aliases on every Mac, but executes
only the host-native runtime. The bundled
foreign-architecture runtime is validated statically; this avoids false
failures when Rosetta is unavailable or when translated Node cannot obtain its
JIT permissions. If the required menu-bar controls are unavailable, stop for a
reviewed maintainer procedure. Uninstall or re-registration is not a substitute
for successfully draining and retiring the old native helper.

The Release menu authenticates to a developer-owned Debug Gateway on 9848 and,
when one coherent observation is healthy, exposes read-only Debug status and
pairing information. The observation is generation-gated and pairing pins its
exact admitted host/runtime, so overlapping refreshes and restarts cannot mix
projections. It never controls Debug lifecycle or writes its cache. Stable remains independently owned
by `com.tron.server`/`com.tron.mac` on 9847. `scripts/tron dev` uses
`~/.tron-dev` and `~/.tron-dev/agent` without SMAppService registration.

### Resumable local reinstall preparation

For a coordinated state migration, use the [cutover runbook](../../gateway/docs/cutover-runbook.md).
Its pre-migration backup is separate from this helper's post-migration snapshot.
After migrations and their validation, while the old wrapper and every writer
remain stopped, run `scripts/tron mac reinstall --select-bundled-offline`.
This explicit maintainer operation validates both recorded app identities and
retires the complete `~/.tron/gateway/payloads/stable` directory by same-filesystem
exclusive rename into `~/.tron-maintenance/<operation>/retired-stable-payloads`.
The private `stable-selection.json` manifest and receipt prove recovery before
or after the rename; re-run the same command after an interruption. Existing
current/previous/pending-attempt state stays with its payloads, outside launcher
discovery. No Gateway starts, and the next installed-app launch uses its signed
bundle. Never resume the old app against migrated state. No individual pointer
is edited or deleted, and recovery never auto-restores an older runtime.

Selection must complete before `--confirm-offline`. The helper refuses a
selection after snapshot creation, changed evidence, or a channel reappearing
before activation. Following bundled selection, `--verify` requires the bundled
runtime explicitly, rather than accepting a coherent older external runtime.
The read-only standalone equivalent is `scripts/tron mac verify --require-bundled`.
Keep retired payloads through the observation window and any version-specific
rollback review. This command is not a replacement for native retirement or
for the pre-migration protected backup.

After preparing the signed Release artifact above, the user/maintainer can use:

```bash
scripts/tron mac reinstall --app /tmp/tron-mac-release/Build/Products/Release/Tron.app
# After successful old-helper retirement, Pause/quit, and stopping all writers:
scripts/tron mac reinstall --confirm-offline
# After the user replaces the app in Finder, launches it and chooses Resume:
scripts/tron mac reinstall --verify
scripts/tron mac reinstall --finish
```

The regular command requires an existing private `~/.tron/agent`. It does not
inspect, migrate or delete an old agent home. For a machine still using
`~/.pi/agent`, use the separate [one-time cutover](agent-home-cutover.md) instead.
Neither command replaces an app, changes LaunchAgents, starts/stops a Gateway,
or approves macOS permissions. Repository agents may test them on isolated
fixtures, but must not execute a live cutover or confirm the operator's offline
attestation. A missing helper retirement control still requires the reviewed
maintainer procedure above; an empty process list never substitutes for it.

Container permissions and data privacy are distinct: `~/.tron` may retain `0755`
when it is a real, user-owned directory with owner read/write/search access,
no group/other write access and no ACL requiring review. The cutover applies the
same container checks to `~/.pi`. Agent homes, receipts and backup directories
remain owner-only. Neither command silently chmods an existing directory.

The first invocation validates both apps and their signing teams, then records
the exact candidate identity (code seal plus resource seal). Candidate validation
uses `TRON_APP_PATH=<artifact> scripts/verify-mac-install.sh --artifact-only` and
the signed Pi smoke test; it never consults an installed payload selection or
contacts the live Gateway. The offline checkpoint refuses loaded services,
listeners, observed writers and path/config overrides; custom setups need a
reviewed owner decision rather than an inferred default.

Private `~/.tron-maintenance/<operation-id>/` receipts record the source revision,
phase, signed app identities, exact source-to-backup mapping, and SHA-256
manifests. Backups include the agent home, every other top-level `~/.tron` entry,
the old app, machine-group file and separately owned default browser config
(including explicit absence). The command never reads Keychain stores or copies
browser profiles/cookies. POSIX modes, ACLs, extended attributes, file contents
and symbolic-link text are checked; special files and unsafe root links stop
preparation. A copied tree may have different `com.apple.provenance` values:
macOS assigns the copying process's attribution even when `copyfile` reports
successful metadata preservation. The helper leaves that OS-owned attribute
alone and retains its observed source digest in the inventory. This is the only
copy-comparison exception; ACLs, link modes, quarantine and every other xattr
must still match. Live-source comparisons remain exact, including provenance.
Exclusive Stable-channel retirement may also reassign provenance on the renamed
root directory only; every nested entry and all other root metadata must match.
The original source inventory is retained unchanged, and an interrupted rename
resumes through the same selection command. Link modes are applied without
following targets.
Owner-only maintenance directories protect backup contents; do not
upload them or raw manifests/settings. External state referenced by custom
settings or browser overrides requires its own operator-managed backup.

One stable cross-process lock serializes both commands. Repeated invocations
resume the recorded operation; partial backups only accept already copied bytes
that still match the frozen source inventory. Source changes, corrupt receipts,
metadata loss, insufficient space and collisions stop without deleting evidence.
Before offering either Finder replacement or Resume, every offline retry verifies
the backups and unchanged data again. An already-replaced app exempts only that
installed app from comparison with the old-app manifest; its exact candidate
signature identity is checked separately. It never exempts agent data, rollback
evidence or the cutover's single-authority check. Failed checks do not advance
the saved phase. After actual activation, `--verify` checks live supervision
rather than requiring legitimately changing live data to match an offline snapshot.
No retries, resets, implicit cleanup or automatic rollback hide a failed check.
Use the same command with `--status` for its saved checkpoint. `--finish` is
accepted only after successful installed verification and removes only the active
operation pointer; all receipts and backups remain. No retention cleanup runs.

`--verify` runs `scripts/tron mac verify`, checks the exact replacement identity
and rejects loaded agent-directory overrides. A failure leaves the checkpoint
unfinished. Success verifies app/supervision/runtime identity, **not** complete
data or capability continuity: also open a historical conversation, run a fresh
delegated worker and its extensions, exercise browser operation and a live Ask
User form, and check historical answers, pairing, settings, trust, models and
packages. Do not repeatedly restart after failure. Preserve post-update writes
and use the coherent manual rollback procedure in the cutover runbook.

Focused regressions: `python3 scripts/test-mac-reinstall.py`; set `TRON_TEST_APP`
to a built app to include real bundled preflight/staging/verification against
temporary homes. CI runs both filesystem tests and the bundled-tool integration.

### Local recovery location and retention

Use `~/.tron-maintenance` as the single local recovery storage root, outside
live `~/.tron` so snapshots cannot recursively include their own backups. The
reinstall helper owns `<operation-id>/receipt.json`, source manifests,
`backups/` and any `retired-stable-payloads/`; archive registration owns
`recovery.json` and `<operation-id>/pre-cutover/`. Do not move these independently,
rewrite completed receipts, or use symlinks to conceal relocated stores.

For a coordinated migration, prepare the app checkpoint first to obtain the
operation directory. The maintainer places the separately verified **pre-write**
backup, isolated restore evidence and journals under that operation's
`pre-cutover/pre-migration/`, before publishing migrations. Keep it distinct from
the helper's **post-write** `backups/`. Register and verify a completed archive
without reopening `active.json`:

```bash
scripts/tron mac reinstall --recovery-relocate \
  --operation-id <verified-operation-id> \
  --source <owner-only-pre-cutover-root>
scripts/tron mac reinstall --recovery-verify \
  --operation-id <verified-operation-id>
```

The archive command exclusively renames the complete root, refuses collisions,
and resumes an interrupted rename without copying or merging. It verifies the
stored closure digest, recorded ownership and checkpoint manifests/evidence only;
it does not inspect live homes, stop writers or publish migrations. The historical
cutover `verify-publications.py` is not an operational verifier and must not be
executed against current state. Use the owning migration tool's
required same-filesystem staging location; do not relocate live staging or
journals merely to satisfy the archival layout.

Keep one accepted, coherent recovery set, including both checkpoints when a
migration requires them, until its replacement has passed restore and continuity
checks. Retention is explicit and manual, never age-based automatic deletion.
Review older sets for unique history or unmerged source before removing them.
Historical source archives and concise incident evidence may live in the same
root's `archives/`, clearly separate from verified operation components.
Retire released build/test output before preparing a snapshot rather than
silently excluding unknown workspace files from the backup inventory.

Keep a concise recovery index identifying each retained checkpoint, original
revision, verification evidence and recovery constraints. Completed archive
registration records the historical source path as evidence but verifies only the
centralized relative destination; it never requires a compatibility symlink or a
live checkout. Do not make another full copy merely to reorganize folders.
These are local recovery checkpoints, not scheduled ongoing backups and not
protection against disk loss. Off-device backup requires a separately configured
protected destination. Restoration and any app/Gateway transition remain
maintainer actions.

### Agent-home cutover (operator-owned)

Follow the canonical [agent-home cutover runbook](agent-home-cutover.md) for the
full dependency gate, exact commands, stop conditions, diagnostics, and rollback.
`scripts/tron agent-home-cutover` is a separate, explicitly invoked one-time
operator command. It reuses the reinstall backup/receipt owner and the bundled
canonical migration tools, then journals two no-clobber same-filesystem renames.
There is no startup migration or compatibility path in the regular reinstall
command. App replacement and activation remain manual in both workflows.

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
helper, build, and deployment command. Node-only payload aliases are skipped
rather than shadowing a complete pinned NVM or Homebrew toolchain; it fails
before touching `~/.tron-dev` when no complete pair is available. Mutating commands use a short-lived atomic
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
  -only-testing:TronMacTests/EnrollmentCodeReaderTests \
  -only-testing:TronMacTests/SingleInstanceLockTests
```

`SingleInstanceLockTests` launches the test-only `SingleInstanceLockProbe` in
separate processes. The owner and contender communicate through bounded pipe
markers, proving exclusion while the first process holds a disposable lock and
successful acquisition after release; it does not use sleeps or application
lifecycle state.

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

The wrapper's local credential path is `gateway/local-auth.json`; never put the
local token in the URL. Provider credentials remain in the Pi runtime store.

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

### Session embedding helper qualification

The Release app bundles `Resources/TronSearchEmbeddingHelper`, a separately
signed NaturalLanguage process. Before enabling semantic readiness, run the
built helper with bounded synthetic JSONL frames and record its model language,
dimension, timeout/crash behavior, and zero-overlap paraphrase cosine result.
Bundled Gateway launches derive the helper beside the packaged runtime; the
`TRON_SEARCH_EMBEDDING_HELPER` override is development-only and requires
`NODE_ENV=development`. An absent or unqualified helper leaves semantic
coverage explicitly unavailable and does not disable lexical search. Do not use
private or live transcript text for qualification.
