# Stable agent-home cutover (manual)

This runbook is the operator handoff for the prepared, **not automatic** move from
`~/.pi/agent` to `~/.tron/agent`. It changes the one writable Pi authority. Do not
run the old and new homes concurrently, use a symlink/fallback, merge a non-empty
destination, or treat a successful build as a cutover.

## Exact inputs and dependency gate

The integrated Tron source contains package hardening commit `adcfe579f` and
agent-home preparation commit `6014b25c8`, on top of Ask User `ff94df9ec`.
The pinned Pi SDK remains `0.84.4`; bundled runtime provenance is Node `22.22.0`
with npm `10.9.4`. The integration branch must be built from the reviewed source
revision selected by the maintainer; do not activate a source checkout merely
because it compiles.

Browser configuration has a separate prerequisite. The installed
`pi-agent-browser-native` package must be replaced by an immutable artifact built
from source commit
`8512681e89aba5a44d070a77bac46451bbe5c77d` (parent
`1b5f11bb251843f5b7536eea9eea7b17f96ac970`). The artifact must export and honor
`PI_AGENT_BROWSER_GLOBAL_CONFIG`, keep `PI_AGENT_BROWSER_CONFIG` as the higher
priority explicit override, reject relative global paths, and preserve
project-config precedence. This commit is not part of this repository and has
not been published or installed by Tron. Until the maintainer publishes or
otherwise installs a verifiable artifact containing that exact source, stop:
the new Gateway environment variable is intentionally not a compatibility
fallback for the old browser package.

A maintainer can build and inspect an artifact without changing the installed
package (run from the browser checkout):

```bash
git -C /path/to/pi-agent-browser-native checkout --detach 8512681e89aba5a44d070a77bac46451bbe5c77d
npm ci
npm run build
node --input-type=module -e 'import("./dist/extensions/agent-browser/lib/config-policy.js").then(m => { if (m.AGENT_BROWSER_GLOBAL_CONFIG_ENV !== "PI_AGENT_BROWSER_GLOBAL_CONFIG") process.exit(2); if (m.AGENT_BROWSER_CONFIG_ENV !== "PI_AGENT_BROWSER_CONFIG") process.exit(3); })'
npm pack --pack-destination /tmp/tron-browser-artifact
```

Record the tarball SHA-256 and install it only through the approved package
installation procedure. Do not install the old version and do not silently
change a running Gateway. After installation, inspect the installed package's
`dist/extensions/agent-browser/lib/config-policy.js` for the same exported
constant before proceeding. Browser profiles/cookies and Keychain credentials
remain browser/OS-owned; this move handles only the global JSON configuration.

## Prepare and verify (before changing the running app)

The following are operator actions. Use a fresh staging suffix and a protected
backup location. Stop immediately on any non-zero command or unexpected status.
The paths below assume the default Stable profile and must be substituted only
for an explicitly approved custom profile.

1. From the **old installed wrapper**, complete **Permissions… → Disable Helper
   for Update** and wait for successful native drain/unregister. Then choose
   **Pause Tron**, quit the wrapper, stop Debug separately, and exit standalone
   Pi clients, child/delegation writers, and package operations. A missing lock
   or absent process is not proof of quiescence.
2. Create and independently protect a backup of the old agent root and the
   separately owned Gateway state/workspace/logs. Include the browser config as
   its own component. Keep post-cutover writes out of this backup. Verify the
   backup bytes and modes before continuing; the migration command's
   `--acknowledge-backup` is only an assertion, not backup creation.
3. Prepare the exact source artifacts and confirm the new browser artifact gate
   above. The source-only Gateway build prepares code but cannot update an
   already-installed signed Mac payload.

```bash
cd /path/to/tron
scripts/tron mac generate
mkdir -p /tmp/tron-home-cutover-gateway-dist
(cd packages/gateway && npm run build)
# Optional read-only assessment; this must report only understood decisions.
scripts/tron agent-home-preflight \
  --source "$HOME/.pi/agent" --destination "$HOME/.tron/agent"
```

The preflight must show the source is a real directory, destination absent,
no collision/overlap/special-file/unsafe-link issue, and no unresolved or
relocation-sensitive configuration decision. Registry/VCS package specs such as
`npm:...` and `git:...` are portable because their installed trees move with
the agent home; absolute/local/session/resource paths still require explicit
owner handling. `writer-quiescence-unproven` is expected and is never an
approval.

4. Stage the old agent root. Supply the legacy browser config if it exists. If
   the old settings contain the exact audited package
   `npm:@zhushanwen/pi-ask-user@7.0.15`, pass the explicit transform flag. This
   removes only that exact string or package-object source **in the staged copy**;
   it never edits the source or backup. The transform is recorded in the marker
   with original/transformed settings digests and count.

```bash
STAGING="$HOME/.tron/.agent.migrate-$(date +%Y%m%d-%H%M%S)"
scripts/tron agent-home-migrate stage \
  --source "$HOME/.pi/agent" --destination "$HOME/.tron/agent" \
  --staging "$STAGING" \
  --browser-config-source "$HOME/.pi/config/pi-agent-browser-native/config.json" \
  --remove-legacy-ask-user \
  --acknowledge-quiescence --acknowledge-backup
scripts/tron agent-home-migrate verify --staging "$STAGING"
```

If the browser config is absent, omit `--browser-config-source` only after the
operator has confirmed that no browser global settings need preserving. If the
legacy Ask User package is absent, omit `--remove-legacy-ask-user`; the tool
refuses an unaccounted transform. Never edit `settings.json` in the staging
root after `stage` or `verify`; any edit invalidates the manifest and requires
starting over with a new staging root. Keep the stage and verify JSON output
with secrets redacted; they contain only bounded paths, types, modes, sizes,
and hashes.

Expected verify output has `changesMade: false`, destination still absent,
`publicationMode: same-filesystem-rename` when applicable, matching source and
staged manifests (apart from the explicitly recorded browser component and
Ask User transform), and the expected transform/browser digest records.
`decision-required`, any source/staging digest mismatch, changed source,
missing browser component, or destination collision is a stop condition. A
failed stage leaves marked partial staging for inspection; clean only the exact
marker-owned root with `agent-home-migrate cleanup --staging "$STAGING"`.

## Publish, activate, and verify (manual)

Only after the protected backup and successful verify may the maintainer publish
one authority. On the same filesystem, with no destination, rename the old root
to a clearly marked protected quarantine and rename the verified staging root to
`~/.tron/agent`. Do not delete the old root. Cross-filesystem copies are
non-atomic: copy to a separately verified destination and retain both manifests;
never claim an atomic rename.

Then manually replace the Mac Release app with the signed artifact built from
the reviewed integration source, and **Resume Tron** to refresh LaunchAgent
registration. A mere Gateway restart does not load the new app/payload. Run:

```bash
scripts/tron mac verify
```

It must prove Stable's sole supervised listener, selected signed payload,
matching authenticated identity/protocol/fingerprint/epoch, and the new agent
path. Stop if the old app/helper remains registered, the browser artifact gate
is not met, the destination is recreated/empty, pairing identity changes, or
`system.info`/session catalog/package inventory cannot be reopened. Only after
Mac verification succeeds should the maintainer install the iOS development
artifact (`Tron Device` + `LocalDevice`) and reconnect iOS. iOS cannot add the
bundled npm runtime or browser package.

## Failure diagnosis and rollback

Capture command exit status, the exact redacted error line, source/staging
manifest digest, and app/Gateway build identity. Keep artifacts in a private
operator directory such as `/tmp/tron-home-cutover-<id>/` (permissions `0700`)
and do not include settings, session JSONL, credentials, browser JSON, tokens,
UDIDs, or full paths in tickets. Relevant read-only diagnostics are
`scripts/tron mac verify`, the Gateway log under the selected Tron home's
`logs/`, and the saved `stage`/`verify` JSON after redaction. Never paste raw
Gateway or browser logs into a public issue.

- `missing prepared ... dist`: build the source artifact explicitly; do not
  make the CLI auto-build or activate it.
- `decision-required` or `relocation-sensitive-reference`: resolve the named
  owner/path, or stop. Do not rewrite third-party strings blindly.
- `destination collision`, source/staging digest mismatch, unsafe link, or
  marker failure: do not publish; preserve/inspect the marked staging tree.
- `spawn npm ENOENT`: the installed Mac app is an old payload; manually build
  and replace the signed Mac app containing the verified npm projection.
- Browser config is ignored or precedence changes: installed browser artifact
  is not commit `8512681...`; stop and replace it through the approved package
  channel.
- `scripts/tron mac verify` fails: do not restart repeatedly. Keep the new root
  quarantined, stop the new owner, and use the protected backup/profile to
  restore the old authority manually.

Rollback never merges post-cutover writes into the old home. Stop the new owner,
quarantine the new agent root and preserve its manifest, restore the unchanged
protected old root/profile, manually activate exactly one old Gateway, and
verify it. Any writes made after publication require a separate recovery
 decision; retain them for analysis rather than silently copying them backward.
