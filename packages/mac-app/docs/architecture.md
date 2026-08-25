# Tron Mac architecture

`Tron.app` is the installer, supervisor, pairing surface, and menu-bar status UI
for the always-running Tron agent. The Login Item launches a minimal universal C
shim, which execs the exact bundled Node runtime and Tron Gateway payload.

User-facing terminology is Tron or Tron Agent. Historical `com.tron.server`
launchd labels remain stable internal identifiers so upgrades do not orphan old
registrations.

## Runtime variants

`MacStartupMode.resolve` is the single startup authority. It resolves test-host
and CLI command paths first, then routes Xcode Debug to read-only observation,
installed Release to wizard/onboarded lifecycle, and misplaced or unsupported
Release bundles to a visible companion/error path. RootView, AppDelegate, and
startup maintenance consume that same resolved mode; Debug never creates a
LaunchAgent.

| Variant | Login Item | Label | Home | Port |
|---|---|---|---|---|
| Installed Stable | `Tron Agent.app` | `com.tron.server` | `~/.tron` | 9847 |
| Developer Debug | `scripts/tron dev` supervisor | none (no SMAppService) | `~/.tron-dev` + `~/.pi/agent-dev` | 9848 |
| Xcode companion | read-only wrapper UI | none | `~/.tron` | 9847 |

The LaunchAgent passes `--host tailscale`; gateway startup resolves and binds the
actual Tailscale interface rather than all interfaces. The Gateway and wrapper
use the same deterministic policy: eligible IPv4 before IPv6, then address and
interface order; IPv6-only tailnets remain supported. Deployment health and
restart traffic resolve the same name; an explicit host always overrides it.
Developer CLI operation
is loopback unless `--tailscale` is explicit. Debug pairing appends `(Dev)` to
the Mac's friendly name so the `9848` profile is distinct from the stable connection. The two homes share only the random physical-machine group hint at
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

Each profile's gateway creates `<profile home>/gateway/enrollment.json` (Stable
`~/.tron`, Debug `~/.tron-dev`) with mode `0600`, a 10-minute expiry, and a
one-time code. The wrapper accepts the gateway's
RFC3339 expiration timestamp with or without fractional seconds.
`PairingInfoStep` first authenticates a local `system.info` request using
`gateway/local-auth.json`, retains the exact Stable admission, and repeats the
ping/admission immediately before reading the current enrollment file. Any
process, payload, or authenticated runtime transition clears the pairing
presentation. The wrapper accepts the Gateway's RFC3339 credential timestamp
with or without fractional seconds, then emits:

```text
tron://pair?host=<tailscale>&port=<port>&code=<one-time>&label=<mac>
```

Permanent device tokens never enter QR codes or Swift presentation state. After
an exchange the gateway removes the used invitation and issues a new one.

## Supervision and status

`SMAppService` owns registration and launchd owns the gateway process. Stable's
LaunchAgent uses Boolean `KeepAlive=true`, `RunAtLoad=true`, and a throttle interval;
pause and uninstall therefore unregister the job before intentional stoppage. Managed
LaunchAgents advertise `TRON_GATEWAY_SUPERVISED=1`; planned restart and handled
supervised signals exit 75 so direct foreground restart controls still fail closed.
Quitting `Tron.app` does not stop accepted work. `ServerStatusPoller` probes the Tron
Gateway protocol and combines health with registration state. Menu controls can
pause, resume, restart, inspect bounded persisted Gateway logs, show a fresh
pairing invitation, and uninstall. Log and feedback capture resolve a validated
Tailscale host from live state or the bounded owner-only Tailscale cache and pass
it explicitly to the Gateway socket; absent host data fails unavailable rather
than falling back to loopback. The cache is an exact-schema version-1 regular
owner-only file and accepts only canonical Tailscale IPv4/IPv6 addresses.

Installed Release owns only Stable registration and lifecycle. It authenticates
to the developer-owned Debug Gateway on 9848 to report status and, when Debug
is Tailscale-bound, show pairing information. It never registers, repairs,
restarts, stops, uninstalls, caches into, or takes over Debug. Stable uninstall
therefore cannot affect `~/.tron-dev` or `~/.pi/agent-dev`. Stable associates
exactly with `com.tron.mac`; Debug has no SMAppService identity or helper in the
Release bundle. Stable ownership requires the exact parent, markers, helper
metadata, exact 9847 listener PID, selected immutable payload (or the validated
bundled fallback), PID command, and authenticated `system.info` version,
channel, revision, fingerprint, and runtime epoch to agree. Relative
BundleProgram metadata alone is never proof. Debug observation reads one bounded
scripts/tron-dev lifecycle snapshot and requires its exact live supervisor
PID/start identity, exact live child PID/start identity, sole 9848 listener,
immutable selected manifest, process command, and authenticated `system.info`
identity to agree. An orphan child is never admitted. Menu refreshes are
cancellation- and generation-gated; a pairing sheet consumes one pinned
immutable admission, so an older host/runtime observation cannot overwrite a
newer restart or loopback/Tailscale transition. Admission identity compares the
exact supervisor/child start identities, transport host, selected payload, and
authenticated runtime provenance; elapsed uptime is display-only and cannot
invalidate an otherwise unchanged admission.

`LaunchAgentRegistrationPlan` computes keep/refuse/takeover/bootout,
unregister/register, and refresh sequences from one authoritative status and
runtime metadata snapshot. Live execution runs that plan without re-deriving
ownership between operations. Bearer, enrollment, and network-cache credentials
use one bounded owner-only regular-file/no-symlink descriptor reader, followed
by separate exact-key schema validation. Stable transport never probes loopback
when Tailscale resolution is unavailable; Debug admits only the exact lifecycle
host (`tailscale` or `127.0.0.1`), and loopback Debug is never pairable.
ServerPing and GatewayRestartClient share the bounded WebSocket transport
handshake and receive deadline while retaining frame-specific error taxonomies.

The wrapper and gateway share no in-memory state. Their only shared secrets are
owner-only gateway files. Legacy `~/.tron/auth.json` is neither wrapper nor
gateway authentication and is left untouched for explicit migration.

## Gateway payload selection

The installed Release wrapper owns only the stable launcher. Developer tooling
owns the independent dev channel. Each launcher first
checks the selected channel (`TRON_GATEWAY_CHANNEL`, accepting only `stable` or
`dev`, with `stable` as the compatibility default) as a single bounded path component before touching any
channel-derived marker or lock under the selected Tron home:

```
~/.tron/gateway/payloads/<channel>/current.json
~/.tron/gateway/payloads/<channel>/versions/<version>/manifest.json
```

`scripts/tron dev` resolves the repository's pinned Node before mutating state,
uses that absolute runtime and its sibling npm for helper/build/deploy commands,
builds and stages an immutable dev payload, starts or authentically drain-restarts
the developer-owned supervisor on 9848, and preserves all Debug state. `scripts/tron dev handoff` copies only the exact selected payload
whose pre/post authenticated identity remains unchanged into the Stable store as
an inactive candidate. The agent-manageable command remains explicit:

```text
scripts/gateway-payload-deploy.mjs stage --channel stable --source <payload>
scripts/gateway-payload-deploy.mjs promote --channel stable --version <version>
scripts/gateway-payload-deploy.mjs rollback --channel stable --command-id <unique-command-id>
```

`stage` copies into a new immutable version directory, verifies required files
and the complete SHA-256 fingerprint, and never mutates the active version.
Every payload includes a regular fingerprinted `app/PushService.xcconfig`.
Stable staging, promotion, rollback, launcher selection, Swift validation, and
packaging require its one exact non-empty public HTTPS origin; dev may carry one
explicit empty assignment. Stable source builds preserve this validated file
from the active immutable payload and never accept a source-tree or environment
replacement. Notification state remains outside payload versions under the
canonical Tron home.
`promote` records expected identity, atomically publishes `current.json` while
retaining `previous.json`, and invokes authenticated `gateway.restart`. It waits
without a deadline for the exact old PID/start to disappear, then requires a different
PID/start stable across the exact candidate health probe. After a short natural relaunch
grace, Stable deployment recovery may use only the fixed `com.tron.server` kickstart and
only when no replacement listener exists. Failure restores and revalidates the prior
selection, accepts an already-running exact restored payload, or replaces only an absent
or exact captured failed listener. Unknown listeners fail closed. Recovery verifies the
exact identity without RPC to the failed Gateway; explicit rollback uses the same boundary.
Stable and dev have independent locks, selections, and payload directories and
may run concurrently. The pointer has schema `1`, kind
`tron-gateway-selection`, and fields `channel`, `version`, and
`payloadFingerprint`. Each version manifest also carries source revision,
runtime epoch, and the complete fingerprint coverage declaration. Staging,
promotion, and the Swift payload validator verify every regular file and
internal symlink under `app/` and `runtime/`; links must resolve to regular
files/directories beneath the payload root, and their targets are covered by
the deterministic fingerprint. The small C launcher also recomputes the complete
fingerprint before exporting identity; it bounds manifest reads, rejects
escaping/dangling/special links and writable payload entries, resolves every
executable/resource path with `realpath`, and exports provenance before `exec`. Invalid or absent external
selection falls back to the bundled payload only after validating its
authoritative manifest. The LaunchAgent exports the selected payload's validated
`app/scripts/gateway-payload-deploy.mjs` as the only update helper; verified
artifact promotion is wired, and source builds read only the validated
`gateway/update-config.json` projection. Source mode compiles with the repository's
local TypeScript compiler into a private temporary output directory, never the trusted
repository's `packages/gateway/dist`, and copies only verified output into the candidate.
No payload selection code writes
canonical sessions or credentials.

The Mac menu Restart action authenticates to the Gateway WebSocket, validates
protocol identity, and calls `gateway.restart` with a bounded command ID. The
Gateway drains accepted work; the wrapper then waits for the launchd-owned
Gateway to become healthy again. It does not use `launchctl kickstart -k` as a
restart shortcut; the fixed kickstart is reserved for payload deployment recovery after
the captured old process has exited.

Changing the bundled LaunchAgent plist requires the manual Release reinstall and
registration refresh in `docs/development.md`; payload promotion cannot update the
plist already registered by macOS.

## Signing order

The Xcode post-build phase copies the tracked `Contents/Library` tree and signs
nested Login Items before resealing the outer app. The shared gateway payload is
in `Contents/Resources/Gateway`; its Node runtimes are signed with
`TronNode.entitlements` so V8 JIT execution remains permitted under the
hardened runtime, while native modules remain minimally entitled. Release
validation must inspect the helper launcher, execute both runtime binaries,
verify the production dependency tree, outer signature, and notarization
ticket.
