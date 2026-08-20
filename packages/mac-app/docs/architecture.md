# Tron Mac architecture

`Tron.app` is the installer, supervisor, pairing surface, and menu-bar status UI
for the always-running Tron agent. The Login Item launches a minimal universal C
shim, which execs the exact bundled Node runtime and Tron Gateway payload.

User-facing terminology is Tron or Tron Agent. Historical `com.tron.server`
launchd labels remain stable internal identifiers so upgrades do not orphan old
registrations.

## Runtime variants

| Variant | Login Item | Label | Home | Port |
|---|---|---|---|---|
| Installed | `Tron Agent.app` | `com.tron.server` | `~/.tron` | 9847 |
| Isolated Xcode install | `Tron Agent Dev.app` | `com.tron.server.dev` | `~/.tron-dev` + `~/.pi/agent-dev` | 9848 |
| Debug companion | regular companion window; observes installed agent only | none owned | `~/.tron` | 9847 |

The LaunchAgent passes `--host tailscale`; gateway startup resolves and binds the
actual Tailscale interface rather than all interfaces, choosing the lowest IPv4
address (then deterministic IPv6/address/interface order). Deployment health and
restart traffic resolve the same name; an explicit host always overrides it.
Developer CLI operation
is loopback unless `--tailscale` is explicit. Isolated pairing invitations append
`(Dev)` to the Mac's friendly name so the `9848` profile is distinct from the
production connection; production invitations keep the unchanged name. The two
homes share only the random physical-machine group hint at
`~/.tron-machine-group-id`; their gateway machine IDs, agent directories, JSONL
sessions, credentials, and runtime markers remain separate.

## Source owners

- `App/` — wrapper modes, lifecycle, single-instance ownership
- `Wizard/` — location, installation, permissions, Tailscale, pairing, finish
- `MenuBar/` — status poller, controls, pairing window, gateway logs
- `Server/LaunchAgent/` — the retained internal name for SMAppService ownership
- `Server/Health/` — authenticated `system.info` gateway probe
- `Server/Paths/` — canonical wrapper identities and filesystem paths
- `Support/Pairing/` — strict invitation URL and QR generation
- `Sources/Resources/Library/` — tracked Login Item and LaunchAgent skeletons
- `scripts/bundle-gateway.sh` — generated gateway payload owner

The retired Mac Operator accessibility/socket bridge is absent. The agent uses
its normal filesystem, terminal, extensions, and tools; the wrapper is not a
worker host.

## Pairing

The gateway creates `~/.tron/gateway/enrollment.json` with mode `0600`, a
10-minute expiry, and a one-time code. The wrapper accepts the gateway's
RFC3339 expiration timestamp with or without fractional seconds.
`PairingInfoStep` first authenticates a local `system.info` request using
`gateway/local-auth.json`, then reads the current enrollment file and emits:

```text
tron://pair?host=<tailscale>&port=<port>&code=<one-time>&label=<mac>
```

Permanent device tokens never enter QR codes or Swift presentation state. After
an exchange the gateway removes the used invitation and issues a new one.

## Supervision and status

`SMAppService` owns registration and launchd owns the gateway process. Managed
LaunchAgents advertise `TRON_GATEWAY_SUPERVISED=1`; the Gateway exposes that
capability so remote restart controls fail closed for direct foreground processes.
Quitting `Tron.app` does not stop accepted work. `ServerStatusPoller` probes the Tron
Gateway protocol and combines health with registration state. Menu controls can
pause, resume, restart, inspect bounded persisted Gateway logs, show a fresh
pairing invitation, and uninstall.

The repository's isolated development supervisor is deliberately a separate
boundary: it owns `~/.tron-dev/gateway` and port `9848`, not the installed
`com.tron.server` image on `9847`. Its atomic manifest distinguishes starting,
ready, draining, restarting, failed, and stopped, matches PID start identities
before trusting a process, and publishes a runtime epoch plus optional source
revision/build fingerprint. `/health` reports those optional identities while
remaining truthful (`200/ok` only after the Gateway is ready; `503` while
starting or stopping). This manifest is bounded projection state, not a runtime
or session mirror. Status/preflight and stop never build. Isolated updates must
not copy an app into `/Applications`, alter production registration, or install
an iOS release; release replacement is a separate manual maintainer action.

The wrapper and gateway share no in-memory state. Their only shared secrets are
owner-only gateway files. Legacy `~/.tron/auth.json` is neither wrapper nor
gateway authentication and is left untouched for explicit migration.

## Gateway payload selection

The installed release wrapper is one launcher image and LaunchAgent owner for
both the stable and optional dev channels; the channels may run in parallel on
9847 and 9848. It first checks the selected channel (`TRON_GATEWAY_CHANNEL`,
with `stable` as the compatibility default) under the selected Tron home:

```
~/.tron/gateway/payloads/<channel>/current.json
~/.tron/gateway/payloads/<channel>/versions/<version>/manifest.json
```

The isolated LaunchAgent supplies `.tron-dev` and the `dev` channel. The
agent-manageable command is explicit:

```text
scripts/gateway-payload-deploy.mjs stage --channel stable --source <payload>
scripts/gateway-payload-deploy.mjs promote --channel stable --version <version>
scripts/gateway-payload-deploy.mjs rollback --channel stable
```

`stage` copies into a new immutable version directory, verifies required files
and the complete SHA-256 fingerprint, and never mutates the active version.
`promote` records expected identity, atomically publishes `current.json` while
retaining `previous.json`, invokes authenticated `gateway.restart` (the
Gateway remains the drain-aware supervisor), and waits for health identity and
a changed runtime epoch. Failure restores the prior selection and requests a
second restart; `rollback` performs the same checked transition explicitly.
Stable and dev have independent locks, selections, and payload directories and
may run concurrently. The pointer has schema `1`, kind
`tron-gateway-selection`, and fields `channel`, `version`, and
`payloadFingerprint`. Each version manifest also carries source revision,
runtime epoch, and the complete fingerprint coverage declaration. Staging,
promotion, and the Swift payload validator verify every regular file under
`app/` and `runtime/`. The small C launcher does not re-hash that tree; it
bounds manifest reads, rejects symlinks and writable payload entries, resolves
every executable/resource path with `realpath`, and exports provenance before
`exec`. Invalid or absent external
selection falls back to the bundled payload only after validating its
authoritative manifest. No payload selection code writes canonical sessions or
credentials.

The Mac menu Restart action authenticates to the Gateway WebSocket, validates
protocol identity, and calls `gateway.restart` with a bounded command ID. The
Gateway drains accepted work; the wrapper then waits for the launchd-owned
Gateway to become healthy again. It does not use `launchctl kickstart -k` as a
restart shortcut.

## Signing order

The Xcode post-build phase copies the tracked `Contents/Library` tree and signs
nested Login Items before resealing the outer app. The shared gateway payload is
in `Contents/Resources/Gateway`; its Node runtimes are signed with
`TronNode.entitlements` so V8 JIT execution remains permitted under the
hardened runtime, while native modules remain minimally entitled. Release
validation must inspect the helper launcher, execute both runtime binaries,
verify the production dependency tree, outer signature, and notarization
ticket.
