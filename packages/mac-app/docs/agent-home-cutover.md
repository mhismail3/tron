# Stable agent-home cutover (one-time operator command)

This runbook moves only the canonical Pi agent directory from `~/.pi/agent` to
`~/.tron/agent`. It does not move or rename the entire `~/.pi` directory.
Browser global configuration remains at its existing owner-managed location
(`~/.pi/config/pi-agent-browser-native/config.json` by default); browser
profiles, cookies, and Keychain credentials remain OS/browser-owned. Browser
configuration relocation is deferred until upstream provides a supported
owned-path contract. No symlink, fallback, merge, or dual writable authority is
allowed.

## Preconditions

Use the reviewed integration revision on `main` (the final source revision is
authoritative; earlier commits `ff94df9ec`, `adcfe579f`, and `6014b25c8` are
historical component references). The Pi SDK is pinned in `packages/gateway/package.json`; the
bundled runtime contract is Node `22.22.0` with npm `10.9.4`.

Before taking the current installation offline, confirm that the installed
browser extension remains on its upstream configuration behavior. Do not set or
introduce `PI_AGENT_BROWSER_GLOBAL_CONFIG`; do not install the unpublished
isolated browser patch. Preserve any user-owned `PI_AGENT_BROWSER_CONFIG`
override unchanged.

## Prepare, cut over offline, then activate manually

1. Build and validate the exact Mac Release artifact, but do not install or
   launch it yet. A source-only Gateway build cannot update the installed Mac
   payload or supply bundled npm.

   ```bash
   cd /path/to/tron
   scripts/tron mac generate
   cd packages/mac-app
   xcodebuild -project TronMac.xcodeproj -scheme TronMac \
     -configuration Release -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath /tmp/tron-mac-release build
   ```

2. Begin a private operation with the signed artifact. This validates the build
   and records its identity; it does not copy or move live data:

   ```bash
   scripts/tron agent-home-cutover --app /tmp/tron-mac-release/Build/Products/Release/Tron.app
   ```

   This one-time command requires `~/.pi/agent` to be the sole existing agent
   authority and `~/.tron/agent` to be absent. Already migrated machines use
   `scripts/tron mac reinstall` instead. Custom paths, symlink roots, both roots
   present, path/config overrides, or cross-filesystem publication stop for an
   owner decision. No fallback, overwrite or merge is offered. A custom browser
   override is preserved unchanged but requires a reviewed backup procedure;
   this command never clears overrides to make its check pass.

   An existing `0755` `~/.tron` container is supported without changing its
   permissions. Both parent containers must be user-owned, non-symlinked,
   owner-accessible and not group/other-writable; ACLs require review. The agent
   home and private backup/receipt directories still require owner-only modes.

3. From the old installed wrapper, complete **Permissions… → Disable Helper for
   Update** and wait for successful native drain/unregister. Then choose
   **Pause Tron** and quit. Stop Debug separately, standalone Pi clients,
   child/delegation writers, and package operations. A missing lock, absent
   process, or elapsed timer is not proof of quiescence.

   If the old app lacks that control or retirement fails, stop for a reviewed
   maintainer procedure. The exact pre-helper build described under **Reviewed
   pre-helper bootstrap** below has its own explicit confirmation; all other
   missing-control cases remain blocked. Do not infer retirement from the offline probes.

4. With **all writers still offline**, the user runs:

   ```bash
   scripts/tron agent-home-cutover --confirm-offline
   ```

   This flag attests successful native retirement and writer quiescence; it is
   not a bypass or a machine-generated proof. The command:

   - Refuses loaded services, listeners and observed writers; runs the canonical
     read-only preflight using the prepared app's signed bundled Node and tools.
     Every finding except the explicit quiescence acknowledgement blocks it,
     including stale extension/skill/subagent paths. No global Pi/npm is used.
   - Creates and verifies protected backups before any publication. Components
     include the old app, agent home, every `~/.tron` top-level entry, machine-group
     file and the separately owned default browser config. External directories,
     browser profiles/cookies and Keychain stores stay with their existing owners.
     See [backup and receipt contract](development.md#resumable-local-reinstall-preparation).
   - Stages to `~/.tron/.agent-cutover-<operation-id>` with canonical migration
     tooling. It passes `--remove-legacy-ask-user` only when the exact supported
     `npm:@zhushanwen/pi-ask-user@7.0.15` package is present. This changes staged
     settings only; original and backup bytes remain unchanged. Verification
     includes the canonical manifests and a separate metadata preservation check.
   - Durably records verified manifests and source/staging inode identities before
     publication. Atomically renames the original to
     `~/.pi/.agent-retired-<operation-id>`, then the stage to `~/.tron/agent`, using
     no-clobber same-filesystem renames. These are two journaled operations, **not**
     one atomic transaction. After a crash between them, no live authority is
     started; rerunning the same command validates the exact recorded trees and
     completes the remaining rename. Changed or unknown trees are never adopted.

   The new home must not be used until this checkpoint reports ready for Finder
   replacement. A failed stage stays marked; it is not automatically deleted or
   silently restarted. Resolve reported path/metadata/ownership findings before
   using the canonical cleanup owner on that exact marked stage. Never edit a
   verified stage or receipts to force progress. Do not rename/delete all of
   `~/.pi`, merge homes or add a symlink. The preserved retired home is rollback
   evidence, not a second writable authority.

5. Manually replace `/Applications/Tron.app` in Finder with the exact prepared
   artifact, launch it, then choose **Resume Tron** to refresh LaunchAgent
   registration. A restart is not equivalent. Enable the new native helper through
   **Permissions…** if wanted and handle macOS approvals yourself. Run:

   ```bash
   scripts/tron agent-home-cutover --verify
   ```

   This invokes `scripts/tron mac verify`, pins the recorded installed app and
   checks the new agent authority without restarting anything. Stop if any check
   fails, the old helper remains registered, pairing identity changes, the
   selected payload is not the reviewed build, or Gateway cannot reopen its
   identity, session catalog, selected session, settings, trust, package
   inventory, model/auth state, and workspace continuity. Do not repeatedly
   restart a failed activation; use rollback below.

6. Verify continuity separately: open historical conversations and answers, launch
   a fresh delegated worker with its extensions, exercise browser operation and
   a live Ask User form, and check pairing/settings/trust/models/packages. These
   are not proven by a successful health or signature check. After completing them:

   ```bash
   scripts/tron agent-home-cutover --finish
   ```

   This archives only the active operation pointer; all backups, manifests and
   the old agent home remain. Future updates use `scripts/tron mac reinstall`.

7. Only after Mac verification succeeds, install the iOS development artifact
   with `Tron Device` + `LocalDevice`, then reconnect iOS. iOS cannot supply
   the bundled npm runtime or alter browser configuration.

## Reviewed pre-helper bootstrap

The signed Mac app whose bundled Gateway records source revision
`0f376b197df6603c32cee3a5706e0295c1705e55` predates the native helper entirely.
Its historical Mac source has no native-host implementation, service identity or
update control; the reviewed product contains only `Tron Agent.app` and the
`com.tron.server` LaunchAgent. It cannot perform **Disable Helper for Update**.
This is not a `.notFound` or failed-retirement exception for a newer helper.

For this build only, the operator may substitute:

```bash
scripts/tron agent-home-cutover --confirm-pre-helper-offline
```

This attests that the old wrapper/Gateway, Debug, standalone clients, delegated
writers and package work are stopped, **not** that an unavailable drain control
was used. The command independently verifies the original app's strict signature,
recorded identity, exact reviewed source revision and restricted embedded service
layout. Unknown revisions, extra native capabilities, a changed app or any loaded
service fail closed. It records that native retirement is not applicable for this
reviewed build; all offline, backup, staging and publication checks remain required.
After Finder replacement, retries validate the original signed backup, not the
replacement's different capabilities. This option is exclusive to the one-time
cutover and cannot be combined with another confirmation or action. Routine
`mac reinstall` does not recognize it. No automatic service shutdown, unregister,
app replacement or activation is introduced. Repository agents may validate this
gate read-only; the user must run the live cutover confirmation.

## Failure diagnosis and rollback

Use `scripts/tron agent-home-cutover --status` to inspect the saved phase. It uses
the same stable process lock as routine reinstalls, so the two workflows cannot
interleave. A wrong workflow, corrupt receipt or changed artifact stops without
overwriting evidence. The receipt records the source revision, artifact identity,
source-to-backup paths, manifests, phase and publication identities. Keep the
artifact at its recorded path until verification finishes. The command never
activates, reinstalls, force-kills or rolls back anything automatically.
Even after Finder replacement, `--confirm-offline` rechecks verified backups,
unchanged published/retired homes and absence of a recreated old authority
before offering Resume. Only the installed app's expected identity change is
exempted from the old source snapshot. If anything else changed, the command
stops without advancing its checkpoint or removing the conflicting data.

Keep command exit status, redacted error text, stage/verify manifests, and build
identity in a private `0700` diagnostics directory. Do not include session JSONL,
settings, credentials, browser JSON, tokens, UDIDs, or raw logs in tickets.
Relevant read-only checks are `scripts/tron mac verify`, Gateway logs under the
selected Tron home, and saved redacted stage/verify output.

- `decision-required`, unsafe link, collision, digest mismatch, or marker
  failure: do not publish; preserve and inspect the marked staging tree.
- `spawn npm ENOENT`: the installed Mac app is an old payload; prepare and
  manually replace the signed Mac app. Do not mutate the running Gateway to
  work around it.
- Browser behavior changed or the global config is missing: restore the old
  owner-managed browser installation/configuration; this migration never owns
  or rewrites that file.
- `scripts/tron mac verify` fails: stop the new owner, quarantine the new agent
  root while preserving its manifest, restore the unchanged protected old root
  and old profile, and manually activate exactly one old Gateway.

Rollback never merges post-cutover writes into the old home. Retain those writes
for an explicit recovery decision.
