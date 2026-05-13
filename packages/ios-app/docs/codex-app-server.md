# Codex App Server Mode

> Last verified: 2026-05-04 against OpenAI Codex App Server docs, Codex CLI command-line docs, and the local Tron implementation.

## Purpose

Codex mode is a separate iOS workflow for talking to a `codex app-server` process
on the active paired machine. It does not use Tron agent sessions, Tron event
streams, or Rust agent turn execution. Tron Server owns the Codex process,
configuration, bearer token file, startup, settings-triggered restart, and
shutdown. iOS discovers the active endpoint through authenticated Tron engine protocol and
then connects directly to the managed Codex WebSocket.

## Server-Owned Lifecycle

On daemon startup, Tron reads `settings.server.codexAppServer` and, when enabled,
launches:

```bash
codex app-server --listen ws://0.0.0.0:<port> --ws-auth capability-token --ws-token-file ~/.tron/internal/run/codex-app-server-token
```

The token file is generated once, stored outside settings, hardened to `0600` on
Unix, and never passed as a raw command-line argument. Tron stops the child
during daemon shutdown, including Ctrl-C and SIGTERM/launchd stop paths,
restarts it when `server.codexAppServer` changes, and re-applies defaults after
`settings.resetToDefaults`.

If Tron is hard-killed before its shutdown hook can run, the previous Codex App
Server child can remain orphaned and keep the configured port open. On the next
startup, Tron scans for stale managed `codex app-server` processes with the same
listen URL and token file, terminates only those exact matches, and then starts a
fresh owned child. This prevents the dashboard from getting stuck on a generic
`exited during startup: exit status: 1` failure after a dev-server takeover or
crash.

`codexApp.status` is the only iOS discovery surface. It returns:

- lifecycle state: `disabled`, `starting`, `running`, `failed`, or `stopped`;
- endpoint scheme/port/path and the bearer token when running;
- server-owned thread defaults: cwd, model, approval policy, and sandbox mode;
- process id and the most recent lifecycle error for troubleshooting.

Before spawning, Tron probes `codex --version` and `codex app-server --help`.
If the installed CLI does not list `--listen`, `--ws-auth`, and
`--ws-token-file`, startup is blocked before spawning and `codexApp.status`
reports a `failed` state with an upgrade-specific `lastError`. If startup fails
because `codex` is missing, the port is in use, or the process exits
immediately, Tron keeps running and reports `failed` through `codexApp.status`.

## Settings

`server.codexAppServer` is server-authoritative and has a matching iOS Settings
section:

- `enabled`: start/stop the managed child;
- `port`: WebSocket listen port, validated as `1...65535`;
- `preferredCwd`: optional cwd passed to new Codex threads;
- `preferredModel`: optional model passed to new Codex threads;
- `approvalPolicy`: `onRequest`, `unlessTrusted`, or `never`;
- `sandboxMode`: `readOnly`, `workspaceWrite`, or `dangerFullAccess`.

Changing these fields through iOS `settings.update` persists the sparse settings
file first, then reconfigures the live child. Reconfigure failures are logged and
surfaced via `codexApp.status`; the settings write itself is not rolled back.

## iOS Client

Codex mode uses the active paired Tron server for authenticated discovery only.
It no longer stores Codex endpoint configuration or bearer tokens in iOS
UserDefaults/Keychain. The view model resolves wildcard server hosts such as
`0.0.0.0` to the active paired server host, builds an in-memory endpoint, and
uses the bearer token returned by `codexApp.status` for the Codex WebSocket
handshake.

The Codex dashboard follows the normal Tron session dashboard shape. On entry it
refreshes managed-server status, connects to Codex, and loads `thread/list`
without requiring a visible Refresh button. It keeps the list fresh through
foreground/dashboard refreshes, periodic light polling, and turn/thread
notifications. Selecting a thread opens a full-screen detail route on iPhone and
the split-view detail column on iPad; the dashboard never embeds a composer or a
half-height transcript. The `+` button opens a draft Codex thread view and the
actual `thread/start` call is made when the first message is sent.
When iOS foregrounds while Codex mode is visible, `CodexAppModeView` calls
`CodexAppViewModel.recoverForeground()`: the direct Codex WebSocket is
disconnected, managed server status is refreshed through Tron engine protocol, `thread/list`
is reloaded, and the selected thread is resumed as a read-only snapshot. The
foreground path never replays `turn/start`, so a stale socket can be replaced
without duplicating user work.
Resuming an existing thread renders one chronological transcript stream, so text
messages and command/file/tool items keep the same order Codex returned. The
detail view starts from the newest history window and scrolls to the bottom after
lazy row heights settle. Older decoded entries stay outside the SwiftUI list
until the user taps Load Earlier Entries, which prepends a bounded batch and
preserves the prior scroll anchor. This keeps very long Codex threads responsive
even though the current Codex resume protocol returns the full thread snapshot.

Codex lifecycle/configuration controls live in the main Settings sheet under
Server settings. The in-mode setup/status screen appears only when there is no
active paired server. Disabled, failed, starting, stopped, unreachable, and
restarting server states stay in the dashboard as retryable connection states so
the thread list flow does not turn into a settings page.

The direct Codex transport is `CodexJSONRPCTransport`, not Tron
`EngineConnection`, because the wire protocol differs:

- requests are Codex JSON-RPC messages with `id`, `method`, and optional
  `params`;
- responses contain `result` or `error`, not Tron's `success` wrapper;
- server notifications are routed by top-level `method`;
- approval prompts are server-to-client requests and must be answered with the
  original request id.

The client sends `initialize`, follows with the `initialized` notification, then
uses `thread/*`, `turn/*`, and item notifications. Decoders tolerate unknown
future fields and unknown future notifications.

## Security

OpenAI's Codex App Server docs describe WebSocket mode as experimental and warn
against unauthenticated non-loopback listeners. Tron always launches the managed
listener with capability-token WebSocket auth and uses `--ws-token-file`, which
the docs prefer over putting the raw token on the command line. Use a trusted
private network, Tailscale, SSH forwarding, or another secure tunnel when using
an iPhone on a different network.

Riskier attachment support is intentionally text-only in v1. Local image paths
are not enabled until remote-machine path semantics are verified.

## Troubleshooting

- `failed` with "does not support the WebSocket App Server flags": upgrade
  Codex on the paired Mac until `codex app-server --help` lists `--listen`,
  `--ws-auth`, and `--ws-token-file`.
- `failed` with "failed to verify installed Codex CLI": install Codex on the
  paired Mac and ensure `codex` is on the LaunchAgent shell `PATH`.
- `failed` with "failed to start": check executable permissions and process
  launch failures after the startup capability probe passes.
- `failed` with "exited during startup": check for an old Codex CLI, unsupported
  App Server flags, auth flag changes, or a non-Tron process occupying the
  configured port. Tron cleans up stale managed children that use its own token
  file, but it will not kill unrelated listeners.
- iOS shows setup instead of the dashboard: pair or select an active Tron
  server. If a server is active but Codex is failed/unavailable, the dashboard
  should show a retryable connection state instead.
- WebSocket unauthorized: refresh Codex mode so iOS fetches the latest
  server-owned token from `codexApp.status`.
- Device cannot connect: confirm the paired server host is reachable from the
  phone, the configured port is open on the private network, and no VPN/Tailscale
  address changed.

## Tests

Rust lifecycle and settings capability tests:

```bash
cargo test --manifest-path packages/agent/Cargo.toml codex_app
cargo test --manifest-path packages/agent/Cargo.toml codex_app_server
```

iOS focused tests:

```bash
cd packages/ios-app
xcodegen generate
xcodebuild test \
  -scheme Tron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/CodexJSONRPCTests \
  -only-testing:TronMobileTests/CodexJSONRPCTransportTests \
  -only-testing:TronMobileTests/CodexAppReducerTests \
  -only-testing:TronMobileTests/CodexAppViewModelTests \
  -only-testing:TronMobileTests/CodexAppIntegrationTests \
  -only-testing:TronMobileTests/ServerSettingsTests \
  -only-testing:TronMobileTests/SettingsStateTests \
  -only-testing:TronMobileTests/SettingsParityTests \
  -only-testing:TronMobileTests/ServerSettingsPageTests
```
