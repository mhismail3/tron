# gateway/mac-terminal

## Purpose

The Mac Terminal shell host: a separate process using
[Machine's TerminalService](../../machine/README.md) so shells survive SSH
connection loss and Gateway restarts. Gateway key enrollment/status remain in
`security/mac-terminal.ts`; this owner does not duplicate them.

## Owns

`mac-terminal-host.ts`, its CLI and versioned host socket/lifetime. The Gateway's
composition root imports `macTerminalHostCommand` directly; it reports the
compiled host's actual location, with no legacy-path wrapper.

## Contract

- **The shell host** (`mac-terminal-host.ts`) is `TerminalService` in its own process,
  so shells survive Gateway restarts and disconnects. `connect` relays stdio to
  `<tronHome>/gateway/mac-terminal/host-1.sock` (dir 0700), starting `serve` detached
  if none answers. One JSON object per line: `{"hello":{"protocol":1}}`, then `list`,
  `open`, `attach` (`after` sequence), `detach`, `write`, `resize`, `terminate`, with
  `output` and `exit` events. The socket name carries the protocol version. Idle period:
  `setup.terminalIdleMinutes`. With no shell and no connection for 24 hours the host
  exits. Diagnostics: `gateway/mac-terminal/host.log` (truncated past 1 MiB).
## Entry points

`mac-terminal-host.js connect|serve --home <tronHome>`. The reported `hostCommand`
and the iPhone's existing SSH client carry these arguments unchanged. Settings
remain canonical in the Gateway settings store; idle limit, frame/output bounds,
log bound and process cleanup are owned by the existing host implementation.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `host.started`, `host.stopped`, `host.idle-exit`, `shell.opened`, `shell.exited`, `shell.quit`, `terminal.auto-closed`, `terminal.idle-check-failed` in `gateway/mac-terminal/host.log` | JSON lines with `at` and `event` (not the Gateway log) | Mac Terminal's shell host (`mac-terminal-host.ts`) lifecycle and idle closures: `pid`, `protocol`, shell id, `exitCode`, `closed`, `reason`, `elapsedMs`; never input, output or cwd |

## Validation

`npm --prefix packages/gateway run test:mac-terminal` runs the existing real
private sshd/fixture-key/Swift SSH client journey and compiled Node host/PTY
survive-disconnect, replay, independent-shell exit and quit checks. It is a
native fixture check, not an app installation or a Stable runtime qualification.
