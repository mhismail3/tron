# mac-app/gateway-payload

## Purpose

Builds, stages, verifies and selects the immutable Gateway payload that the signed C launcher
(`tron-gateway-launcher.c`) runs: Node runtimes, production dependencies, the Gateway, the
pinned XcodeGen toolchain and command aliases.

## Owns

`bundle-gateway.sh`, `ensure-gateway-bundle.sh`, `stage-gateway-app.sh`,
`hash-gateway-payload.sh`, `verify-gateway-payload.sh`, `update-payload-fingerprint.sh`,
`verify-macho-architectures.sh`, the launcher and their tests. Immutable operations and
promotion: `scripts/gateway-payload-deploy.mjs` ([host control](../../gateway/src/admin/host-control.md)).

## Contract

- **Bundle.** `bundle-gateway.sh` resolves the exact `.node-version` Node with its sibling npm
  (`.ci-tools` cache checked against `config/ci-toolchain.env`; `TRON_NODE_BIN`/`TRON_NODE_ROOT`
  explicit overrides) before changing anything, then: checks the source install against the lock
  (`scripts/gateway-install-inputs.mjs`), builds, makes an independent `npm ci --omit=dev` tree,
  downloads and checks both Node archives, compiles the universal launcher, creates
  `runtime/bin-{arm64,x64}` aliases (`node`, `npm`, `pi` → `../../app/node_modules/.bin/pi`),
  stages the Login Item, the `pi-subagents` pin and installers (`stage-gateway-app.sh`),
  writes `app/build-inputs.json`, fingerprints
  `app/**` and `runtime/**`, and stamps a runtime epoch. Writers hold a lock and publish payload,
  launcher and icon from a private staging root by backup renames; failure restores the prior
  projection. macOS tools are used by absolute path (`/usr/bin/find`, `/usr/bin/stat`,
  `/bin/realpath`, …); any write bit or failed scan is refused.
- **Freshness.** `ensure-gateway-bundle.sh` accepts an existing payload only after
  `--verify-only` (read-only): integrity, a freshly compiled launcher's fingerprint, runtime
  hashes and architectures, safe symlinks, immutable modes, exact aliases, then
  `sourceRevision`, package files and the build-input digest. One mismatch triggers one rebuild
  and a second verification.
- **Selection.** Each launcher validates `TRON_GATEWAY_CHANNEL` (`stable` or `dev`) as one
  bounded path component, then reads `~/.tron/gateway/payloads/<channel>/current.json` (schema 1,
  kind `tron-gateway-selection`, `channel`, `version`, `payloadFingerprint`) and
  `versions/<version>/manifest.json`, recomputes the complete fingerprint, rejects escaping,
  dangling or special links and writable entries, resolves paths with `realpath` and exports
  provenance before `exec`; anything invalid falls back to the validated bundled payload. The
  manifest's protocol range must equal the launcher's compiled range, so after an app
  replacement an older selection is refused and the bundled Gateway bootstraps.
- **Contents.** A regular fingerprinted `app/PushService.xcconfig` (Stable: exactly one public
  HTTPS origin; dev may be empty via `--allow-unconfigured-push`), every compiled `app/dist`
  relative import resolving inside `app/`, aliases with exact relative targets, the XcodeGen
  tree (passed to the iOS installer as `TRON_XCODEGEN`). Stable puts its payload command first
  on `PATH`; Debug keeps a working developer Node and uses it as fallback. Package Git
  operations still use the host `git`.

## Invariants

One fail-closed manifest policy, enforced by the launcher, `GatewayPayloadStore.swift` and
`gateway-payload-deploy.mjs`; none is wider than the launcher, which parses with a bounded flat
parser (no escapes):

| Field | Rule |
|---|---|
| manifest keys | exactly twelve, each once; selection pointer exactly five |
| `schema`, `kind` | `1`, `tron-gateway-payload` |
| `channel` | `stable` or `dev` |
| `version` / `gatewayVersion`, `nodeVersion` | path component ≤ 128 / ≤ 127 |
| `sourceRevision` | 40 lowercase hex |
| `runtimeEpoch` | lowercase UUID |
| `payloadFingerprint` | 64 lowercase hex |
| `dependencyTreeCoverage` | the exact coverage string (kept for older launchers) |
| `protocolVersion`, `minProtocolVersion` | the compiled lockstep values from `config/GatewayProtocol.json` |
| `app/package.json`, `app/package-lock.json` | ≤ 64 KiB, ≤ 16 MiB |

`runtimeEpoch` is a freshness nonce sealed by the tree and signature, not a source input.

## Verify

```bash
packages/mac-app/scripts/test-tron-gateway-launcher.sh   # one refused fixture per rule
packages/mac-app/scripts/test-gateway-payload-verifier.sh  # needs current unsigned staged inputs
python3 packages/mac-app/scripts/test-gateway-payload-precondition.py
packages/mac-app/scripts/test-bundle-gateway-rebuild.sh [--gnu-shadow|--cleanup-only]
packages/mac-app/scripts/test-tron-gateway-npm.sh
packages/mac-app/scripts/test-update-payload-fingerprint.sh
```

The verifier matrix exits 2 (`generated-input precondition`) when its baseline is stale and runs
no cases; stage current inputs explicitly (an authorized operation), never rewrite pins. Strict
rejection is exit 78. A launcher argv change also needs `GatewayLauncherArgvTests`.

## Not here

Promotion, rollback and Debug handoff: [host control](../../gateway/src/admin/host-control.md).
Signing and release: [development](../docs/development.md#release).
