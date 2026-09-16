# Stable agent-home cutover (manual)

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
historical component references). The pinned Pi SDK remains `0.84.4`; the
bundled runtime contract is Node `22.22.0` with npm `10.9.4`.

Before taking the current installation offline, confirm that the installed
browser extension remains on its upstream configuration behavior. Do not set or
introduce `PI_AGENT_BROWSER_GLOBAL_CONFIG`; do not install the unpublished
isolated browser patch. Preserve any user-owned `PI_AGENT_BROWSER_CONFIG`
override unchanged.

## Prepare without changing the running app

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

2. From the old installed wrapper, complete **Permissions… → Disable Helper for
   Update** and wait for successful native drain/unregister. Then choose
   **Pause Tron** and quit. Stop Debug separately, standalone Pi clients,
   child/delegation writers, and package operations. A missing lock, absent
   process, or elapsed timer is not proof of quiescence.

3. Independently create and protect a backup of `~/.pi/agent`,
   `~/.tron/gateway`, `~/.tron/workspace`, logs, and any approved external
   session directory. Protect the browser config as its own owner-managed
   backup component if it is included in the operator backup. Verify bytes and
   modes. The migration acknowledgement does not create a backup.

4. Prepare the Gateway sources and run the read-only assessment. The expected
   `writer-quiescence-unproven` finding is not approval.

   ```bash
   cd /path/to/tron
   (cd packages/gateway && npm run build)
   scripts/tron agent-home-preflight \
     --source "$HOME/.pi/agent" --destination "$HOME/.tron/agent"
   ```

   Stop for any collision, overlap, special file, unsafe link, unresolved or
   relocation-sensitive reference, malformed settings, or external authority
   that lacks an owner decision. Registry/VCS package specifications and their
   installed trees move with the agent home; absolute/local/session/resource
   paths do not.

5. Stage and verify a fresh sibling staging root. This transform removes only
   the exact audited legacy Ask User package, and only in the staged settings;
   it never edits the old source or backup. Do not pass the removed
   `--browser-config-source` option.

   ```bash
   STAGING="$HOME/.tron/.agent.migrate-$(date +%Y%m%d-%H%M%S)"
   scripts/tron agent-home-migrate stage \
     --source "$HOME/.pi/agent" --destination "$HOME/.tron/agent" \
     --staging "$STAGING" \
     --remove-legacy-ask-user \
     --acknowledge-quiescence --acknowledge-backup
   scripts/tron agent-home-migrate verify --staging "$STAGING"
   ```

   Omit `--remove-legacy-ask-user` only after confirming that the exact package
   is absent; if supplied and absent, staging must fail closed. Keep only
   redacted stage/verify output. Expected verify output has `changesMade: false`,
   destination still absent, matching manifests except for the recorded Ask
   User transform, and an appropriate publication mode. Any digest mismatch,
   source change, marker failure, decision-required result, or destination
   collision is a stop. A failed stage leaves marked partial staging; inspect
   it and clean only that exact marker-owned root.

## Publish and activate manually

6. After backup and successful verification, publish one authority. On the same
   filesystem rename the old `~/.pi/agent` to a clearly marked protected
   quarantine/backup, then rename the verified staging root to `~/.tron/agent`.
   Never rename/delete all of `~/.pi`; never merge a non-empty destination or
   use a symlink. Cross-filesystem copying is non-atomic and requires separate
   manifest verification.

7. Manually replace the Mac Release app with the prepared artifact, then
   **Resume Tron** to load its LaunchAgent environment. Run:

   ```bash
   scripts/tron mac verify
   ```

   Stop if the old helper remains registered, pairing identity changes, the
   selected payload is not the reviewed build, or Gateway cannot reopen its
   identity, session catalog, selected session, settings, trust, package
   inventory, model/auth state, and workspace continuity. Do not repeatedly
   restart a failed activation; use rollback below.

8. Only after Mac verification succeeds, install the iOS development artifact
   with `Tron Device` + `LocalDevice`, then reconnect iOS. iOS cannot supply
   the bundled npm runtime or alter browser configuration.

## Failure diagnosis and rollback

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
