# gateway/machine

## Purpose

The Gateway's reach into this Mac: filesystem and Git browsing, Project-root
resolution, worktrees, uploads, and the native capture and
`computer` clients.

## Owns

`filesystem-service.ts`, `workspace-inspection-service.ts` (workspace projection),
`git-worktree-service.ts`, `upload-store.ts`,
`native-capture-client.ts`, `native-capture-transport.ts`,
`cua-client.ts`, path containment and workspace bounds.

## Contract

### Project root

The Project layer is the `.pi/` of a chat's Project root, even for a chat started in a
subdirectory. `projectRoot()` is the only resolver: the realpath of
`git rev-parse --show-toplevel` for the canonical cwd, so each linked worktree is its
own Project. With no work tree (no repository, a cwd inside `.git`, a refused
ownership check) or no runnable Git, the cwd is the Project; a Git timeout stays a
retryable error. `TrustService` resolves it with every inspection
(`TrustInspection.projectDir`) and keys trust decisions by the root. Home's workspace
is a standalone directory, so its untrusted decision never reaches an enclosing
repository. Each runtime build passes the root as the SDK's `projectDir` (from the
[Tron-patched `pi-coding-agent`](../../docs/pi-sdk-maintenance.md#tron-patched-pi-coding-agent)),
so Pi reads Project settings, packages, `.pi/` resources, `SYSTEM.md` and MCP
configuration there and starts stdio MCP servers there. The chat's cwd still owns
tools, context files (`AGENTS.md` up the tree), session grouping and `ctx.cwd`. Trust
and Project settings changes reload every live chat of the root.

### Mac Terminal

SSH/tmux shells use a private ordinary-user native `/usr/sbin/sshd`, independent
of the Gateway. Security's `MacTerminalService` owns the service, not the machine
module or a Gateway child. Stock Remote Login, system SSH files and PF are untouched.

- **Endpoint:** port 44222, `AddressFamily inet`, only the locally assigned online
  Tailscale Self IPv4 in 100.64.0.0/10. No DNS, LAN, loopback, wildcard, IPv6 or
  alternate-port fallback. CLI and enrollment share one canonical-home lifecycle
  lock; launchd directly runs sshd in the ordinary user's GUI domain.
- **Private state:** `<tronHome>/mac-terminal` is 0700; persistent Ed25519 host key,
  config and authorized_keys are 0600. Missing/corrupt initialized identity fails
  closed, never regenerates. Configuration binds one address and disables
  password/PAM/keyboard-interactive login and forwarding.
- **Enable/trust:** `permissions.macTerminalServer` explicitly prepares/starts
  the service at approve floor. The iPhone displays the host fingerprint; only
  **Trust and Enroll** publishes `permissions.macTerminalKey`, device-qualified,
  P-256 only, restricted to Tailnet IPv4. Decline preserves the old enrollment.
- **Status:** paired-iPhone `macTerminal.status` returns username, port, numeric
  hosts, hostKeys/fingerprint, serviceState/detail, enrolled/enrolledKey. It never
  starts or repairs anything. Running requires owned config/key/job/argv plus
  exact kernel listener and PID evidence. Passive health checks do not open
  unauthenticated SSH connections; the client verifies the presented key before auth.
- **Recovery:** stale address, absent Tailnet, port conflict or job failure is
  explicit. Recovery validates the newly assigned address and preserves host key
  and tmux; the iPhone explicitly refreshes enrollment, never silently repins.
- **Revocation:** unset the device key or revoke its pairing. Authorization is
  removed first; failure refuses device revocation. Removing the last key stops
  only the owned daemon. Stopping never kills tmux or unrelated admin sessions.
- **Persistence:** one tmux shell per Mac/iPhone on `tron-mobile`, /dev/null config,
  no plain-shell fallback. Closing a link does not terminate that shell.

Prepare the CLI with `scripts/tron build gateway`, then the maintainer may run
`scripts/tron terminal-ssh status|start|stop|recover --home <existing-tron-home>`.
Status is read-only. Start requires the user's GUI launchd domain and a free port;
stop/recover refuse an unknown label, plist, executable or argument list.
No Gateway startup hook installs or starts the service.

The iPhone pins the private host identity at enrollment
([iOS Mac Terminal](../../../ios-app/docs/architecture.md#mac-terminal)).

### Native capture and computer use

- **`native_capture`** lists bounded window and display handles (`catalog`), selects
  one (`view`, a whole window or a display region in display-local points) or stops
  this session's scopes (`stop`). Selection returns an opaque `native_live` source for
  `display`, never pixels or a grant. `native-capture-client.ts` binds one connection
  to the session and extension load and opens the signed
  `Tron.app/Contents/Library/Native/tron-native-capture.node` (API4) only on explicit
  catalog; missing or incompatible code disables capture only. First viewer starts
  capture; last viewer suspends and joins it; reopen reuses the exact retained source.
  Each native operation has an owner deadline; a silent host is an explicit uncertain
  failure, never a fabricated join. Frames are latest-only and never cached.
  Contract: [Mac computer control](../../../mac-app/docs/computer-control.md#direct-gateway-capture-client).
- **`computer`** is a thin `{tool, arguments}` client of the pinned Cua Driver, whose
  per-generation socket the Native Host owns; the Gateway gets only a read-only
  `{socket, generation}` bootstrap and accepts no endpoint, environment or session
  from model input. Refused, malformed, non-zero or disconnected results are refusal
  or `outcomeUnknown`, never success or replay. Actions need fresh observations from
  the same load; accepted calls outlive a waiter's Stop. Observation images come from
  disposable files removed before publication. Cua telemetry is off; missing Cua
  assets disable only this tool. Before foreground input, inspect the whole desktop
  for system dialogs; the agent never approves OS permissions.
- A native executor keeps its tool promise through native cleanup
  ([native-tool settlement](../../docs/native-tool-settlement.md)).

## Invariants

- No Mac Terminal state lives in the Gateway: the `authorized_keys` file is the store.
- `projectRoot()` is the only Project resolver; a decision for a subdirectory never
  applies to its root.
- Native capture and computer use accept no raw IDs, endpoints or input replay.

## Entry points

`projectRoot`, `WorkspaceInspectionService`, `GitWorktreeService`, `UploadStore`,
`CuaComputerClient`.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `uploads.storage-pressure` | info on return to `normal`; warning otherwise | A 10-minute maintenance pass changed attachment storage pressure; free bytes and the floor in the message |
| `storage.maintenance-failed` | warning | The bounded artifact maintenance pass threw and will retry: `error` |

## Verify

```bash
scripts/tron verify --module gateway/machine
scripts/tron test gateway src/kernel/resources/project-root.integration.test.ts
cd packages/gateway && npm run test:mac-terminal   # needs the tailnet and Swift 6.2
```

`project-root.integration.test.ts` uses a real repository, linked worktree, stdio MCP
server and faux model (`test-results/project-root-864.json`). `test:mac-terminal`
enrolls through a real Gateway into a real sshd and logs in with the app's SSH client,
then proves same-PID tmux reattachment after transport/network loss and refuses
missing tmux (`test-results/mac-terminal.json`). Installed XPC and
real-window capture remain manual qualification.

## Not here

Trust decisions: `TrustService` ([admin](../admin/README.md)). Live-view routes:
[display](../display/README.md); uploads: [uploads](uploads.md). Mac-side Native Host: `packages/mac-app`.
