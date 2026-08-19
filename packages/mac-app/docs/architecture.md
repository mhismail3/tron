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
actual Tailscale interface rather than all interfaces. Developer CLI operation
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

`SMAppService` owns registration and launchd owns the gateway process. Quitting
`Tron.app` does not stop accepted work. `ServerStatusPoller` probes the Tron
Gateway protocol and combines health with registration state. Menu controls can
pause, resume, restart, inspect bounded in-memory gateway logs, show a fresh
pairing invitation, and uninstall.

The wrapper and gateway share no in-memory state. Their only shared secrets are
owner-only gateway files. Legacy `~/.tron/auth.json` is neither wrapper nor
gateway authentication and is left untouched for explicit migration.

## Signing order

The Xcode post-build phase copies the tracked `Contents/Library` tree and signs
nested Login Items before resealing the outer app. The shared gateway payload is
in `Contents/Resources/Gateway`; its Node runtimes are signed with
`TronNode.entitlements` so V8 JIT execution remains permitted under the
hardened runtime, while native modules remain minimally entitled. Release
validation must inspect the helper launcher, execute both runtime binaries,
verify the production dependency tree, outer signature, and notarization
ticket.
