# gateway/machine

## Purpose

The Gateway's reach into this Mac: filesystem and Git browsing, Project-root
resolution, worktrees, uploads, PTY terminals, the Mac Terminal shell host, and the
native capture and `computer` clients.

## Owns

`filesystem-service.ts`, `workspace-inspection-service.ts` (`projectRoot`),
`git-worktree-service.ts`, `upload-store.ts`, `terminal-service.ts`,
`mac-terminal-host.ts`, `native-capture-client.ts`, `native-capture-transport.ts`,
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

SSH login shells on this Mac through macOS Remote Login over Tailscale, independent of
the Gateway, so they keep working while Tron.app or the Gateway is down. The Gateway
only enrolls and revokes keys (`src/security/mac-terminal.ts`) and ships the host:

- **`macTerminal.status`** (paired iPhones, no parameters): login `username`, `port`
  22, `hosts` (MagicDNS name, then Tailscale addresses), `hostKeys`, `remoteLogin`
  (`on`/`off`/`unknown` from one loopback connect; Tron never changes it), `enrolled`,
  and `hostCommand`, the argv that reaches the shell host (omitted with no compiled
  host).
- **The shell host** (`mac-terminal-host.ts`) is `TerminalService` in its own process,
  so shells survive Gateway restarts and disconnects. `connect` relays stdio to
  `<tronHome>/gateway/mac-terminal/host-1.sock` (dir 0700), starting `serve` detached
  if none answers. One JSON object per line: `{"hello":{"protocol":1}}`, then `list`,
  `open`, `attach` (`after` sequence), `detach`, `write`, `resize`, `terminate`, with
  `output` and `exit` events. The socket name carries the protocol version. Idle period:
  `setup.terminalIdleMinutes`. With no shell and no connection for 24 hours the host
  exits. Diagnostics: `gateway/mac-terminal/host.log` (truncated past 1 MiB).
- **The key** is the Global setting `permissions.macTerminalKey` (qualified by
  `device`): one `~/.ssh/authorized_keys` line restricted to Tailscale ranges with no
  forwarding, admitting only `ecdsa-sha2-nistp256` (Secure Enclave) keys. Adding is
  an `approve`-floor widening, removing is `notify`; an iPhone enrolls only itself.
  Tron rewrites the file atomically under its lock, keeps every other line, writes
  0600 and refuses symlinked, non-regular or oversized files.
- **Revocation**: unset from the iPhone or any chat's `settings` tool, delete the line
  by hand, or `device.revoke`, which removes the key first and refuses if that fails.

The iPhone pins the host keys at enrollment
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

### PTY terminals

`TerminalService` uses node-pty's macOS `spawn-helper`; the package `postinstall`
enforces its executable bit and terminal tests open a real PTY.

## Invariants

- No Mac Terminal state lives in the Gateway: the `authorized_keys` file is the store.
- `projectRoot()` is the only Project resolver; a decision for a subdirectory never
  applies to its root.
- Native capture and computer use accept no raw IDs, endpoints or input replay.

## Entry points

`projectRoot`, `WorkspaceInspectionService`, `GitWorktreeService`, `UploadStore`,
`TerminalService`, `MacTerminalShellHost`, `CuaComputerClient`.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `terminal.auto-closed` | info | The Gateway closed a non-busy app terminal: terminal id, `reason` (`idle`, `restart`), `elapsedMs` since its last input or attachment; never content or cwd |
| `terminal.idle-check-failed` | warning | An idle pass could not read the idle setting or process table; every terminal is kept: `error` |
| `host.started`, `host.stopped`, `host.idle-exit`, `shell.opened`, `shell.exited`, `shell.quit`, `terminal.auto-closed`, `terminal.idle-check-failed` in `gateway/mac-terminal/host.log` | JSON lines with `at` and `event` (not the Gateway log) | Mac Terminal's shell host (`mac-terminal-host.ts`) lifecycle and idle closures: `pid`, `protocol`, shell id, `exitCode`, `closed`, `reason`, `elapsedMs`; never input, output or cwd |
| `uploads.storage-pressure` | info on return to `normal`; warning otherwise | A 10-minute maintenance pass changed attachment storage pressure; free bytes and the floor in the message |
| `storage.maintenance-failed` | warning | The bounded artifact maintenance pass threw and will retry: `error` |

## Verify

```bash
scripts/tron verify --module gateway/machine
scripts/tron test gateway src/machine/terminal-service.integration.test.ts \
  src/sessions/project-root.integration.test.ts
cd packages/gateway && npm run test:mac-terminal   # needs the tailnet and Swift 6.2
```

`project-root.integration.test.ts` uses a real repository, linked worktree, stdio MCP
server and faux model (`test-results/project-root-864.json`). `test:mac-terminal`
enrolls through a real Gateway into a real sshd and logs in with the app's SSH client,
then drives the real shell host (`test-results/mac-terminal.json`). Installed XPC and
real-window capture remain manual qualification.

## Not here

Trust decisions: `TrustService` ([admin](../admin/README.md)). Live-view routes:
[display](../display/README.md); uploads: [uploads](uploads.md). Mac-side Native Host: `packages/mac-app`.
