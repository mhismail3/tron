# Tron

<p align="center">
  <img src="packages/ios-app/docs/assets/tron-logo.png" width="112" alt="Tron logo">
</p>

**A persistent, local-first agent for Mac and iPhone that can teach itself new workers.**

Tron runs an AI agent as a background service on your Mac and provides a native
iOS interface for conversations, durable sessions, and worker operations. The
current worker-first POC deliberately favors useful proactive adaptation over
permission ceremony: a model can research, author, test, activate, and reuse an
engine-global worker through one atomic operation.

## Why Tron

- Natural-language work can become an immediately active, persistent typed tool.
- Agent, command, and lazy resident-service workers share one durable runtime.
- Manual calls, schedules, engine events, and authenticated local webhooks share
  one at-least-once dispatcher.
- Runtime-managed scheduler, reminder, and notification-policy workers divide
  time calculation, occurrence lifecycle, and delivery relevance. The engine
  durably hands work between them and transports narrow notification intents;
  iOS owns permission, presentation, deep links, and read state.
- Local agents and workers use the Mac user's normal authority without
  per-call permission objects or proposal-only activation steps.
- Provenance, immutable versions, dependency locks, audit history, secret
  isolation, execution ceilings, failure disablement, rollback, and stop-all
  remain because they improve reliability.
- Core source changes are prepared and tested in isolated Git worktrees. A
  later explicit user-authored message is required before application.

## System Shape

```text
 iPhone / iPad                         Mac
┌──────────────────┐         ┌──────────────────────────┐
│ SwiftUI client   │─/engine▶│ Rust agent + worker core │
│ chat + workers   │         │ model, runners, dispatch │
└──────────────────┘         └────────────┬─────────────┘
                                         │
                 schedules → reminders → notification policy
                                         │
                              relay or direct APNs transport
```

The Rust server owns model execution, authenticated transport, durable session
truth, atomic worker handoffs, worker storage, and provider-acceptance evidence.
The iOS app is a thin client with a Worker Console for health, versions,
triggers, typed invocation, runs, inbox, rollback, retirement, cancellation,
and stop controls, plus synchronized native notification and Artifact Inboxes.
Artifact content stays in engine-owned content-addressed custody until explicit
deletion; preview, share, export, and Attach to Draft use the existing native
attachment pipeline.
The Mac app packages and supervises the server and owns pairing; it is not a
second engine client. Its signed wrapper also hosts the narrow Mac Operator
actuator for explicitly requested foreground-app work; the ordinary worker
owns the plan and confirmation policy, while native code enforces permissions,
fresh-window identity, serialized actions, and the user-controlled emergency
stop.

Worker bundles live under:

```text
~/.tron/workspace/workers/<worker-id>/versions/<content-hash>/
```

Worker-owned mutable data lives separately under
`~/.tron/workspace/worker-state/<worker-id>/`; verified profile and purge
archives live under `~/.tron/internal/backups/`.

Each version contains its schemas, runner, source or instructions, dependency
lock, provenance, triggers, secret-binding names, smoke tests, health checks,
and sealed verification evidence. SQLite holds rebuildable routes and trigger
indexes plus durable attempts, causal traces, inbox results, health, and audit
history.

## Install

The supported end-user path is the Mac app plus the iOS beta:

1. Install and sign in to [Tailscale](https://tailscale.com) on the Mac.
2. Download the latest Tron DMG from this repository's Releases page.
3. Move `Tron.app` to `/Applications` and complete its setup wizard.
4. Install the iOS beta from the wizard and scan the pairing code.

The Mac app installs and monitors the local server. Normal use does not require
the command line.

## Develop

Requirements:

- macOS 15 or newer
- Rust through `rustup` using [`rust-toolchain.toml`](rust-toolchain.toml)
- Xcode 26 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
scripts/tron setup
scripts/tron dev --background
scripts/tron login
```

Useful commands:

```bash
scripts/tron status --json
scripts/tron logs
scripts/tron ci fmt check clippy test
```

Worker-first execution is the engine architecture: trusted local sessions can
create, activate, discover, and run persistent workers without enabling a
separate mode.

Build the iOS app:

```bash
cd packages/ios-app
xcodegen generate
open TronMobile.xcodeproj
```

Build the Mac wrapper:

```bash
cd packages/mac-app
./scripts/bundle-agent.sh --profile debug
xcodegen generate
open TronMac.xcodeproj
```

Use `scripts/tron dev` for development. Production deployment is manual-only;
the agent must never invoke `tron deploy`.

## Validate

Run focused tests while iterating. For a broad checkpoint:

```bash
scripts/tron ci fmt check clippy test
scripts/personal-info-guard.sh
```

The deterministic `last30days` replay and a natural-language model-loop proof
of proactive create → immediate typed call → report are part of the Rust
library suite. Its real upstream dependency proof is deliberately opt-in:

```bash
TRON_WORKER_LIVE_NETWORK=1 \
  cargo test --manifest-path packages/agent/Cargo.toml \
  last30days_upstream_live_network_dependency_is_locked_and_activates -- --ignored
```

## Documentation

- [Technical project reference](packages/agent/docs/project-reference.md) —
  worker contracts, dispatch, storage, authority, protocol, and POC
  acceptance.
- [Contributing](CONTRIBUTING.md) — development, testing, commits, and releases.
- [Rust module map](packages/agent/src/lib.rs) — server ownership and entry
  points; each `mod.rs` documents its subtree.
- [iOS architecture](packages/ios-app/docs/architecture.md) and
  [development guide](packages/ios-app/docs/development.md).
- [Mac architecture](packages/mac-app/docs/architecture.md) and
  [development guide](packages/mac-app/docs/development.md).

## Project Rules

- Code, tests, and documentation ship together.
- Root-cause fixes take priority over transitional adapters.
- Secrets and personal information never belong in the repository.
- Filesystem bundles are canonical worker state; clients do not invent truth.
- Production code must have an independent production consumer; tests and
  self-description do not justify inert runtime surfaces.
- Re-hardening must respond to an observed failure and preserve accepted worker
  workflows.
- Production deployment is manual-only.

See [AGENTS.md](AGENTS.md) for the complete engineering rules.

## License

MIT
