# Tron

<p align="center">
  <img src="packages/ios-app/docs/assets/tron-logo.png" width="112" alt="Tron logo">
</p>

**A persistent, local-first coding agent for Mac and iPhone.**

Tron runs an AI agent as a background service on your Mac and gives you a
native iOS interface for starting work, following progress, inspecting evidence,
and controlling sessions. Conversations and execution history are durable, so
the agent can continue across app launches without treating each message as a
new process.

The project is built around a small engine and governed capabilities. The model
sees one execution surface, discovers the operations available through it, and
receives structured results rather than a growing collection of unrelated
tools. Filesystem, Git, web, jobs, memory, modules, and diagnostics remain
separately owned behind that contract.

## Why Tron

- **Persistent** — sessions, events, traces, and resources survive reconnects.
- **Local-first** — the server, workspace, and durable state live on your Mac.
- **Inspectable** — capability calls and agent activity retain bounded evidence.
- **Modular** — operations have explicit owners, authority, lifecycle, and
  replacement policy.
- **Native** — SwiftUI apps provide the user experience; Rust owns the engine.
- **Fail-closed** — unknown operations, stale authority, and unsafe routes are
  rejected instead of silently falling back.

## System Shape

```text
 iPhone / iPad                       Mac
┌────────────────┐          ┌─────────────────────────┐
│ SwiftUI client │──/engine─▶│ Rust agent server       │
│ chat + cockpit │          │ provider + capabilities │
└────────────────┘          └────────────┬────────────┘
                                        │
                              ┌─────────▼─────────┐
                              │ SQLite event store│
                              │ traces + resources│
                              └───────────────────┘
```

The iOS app is a thin client. The Rust server owns provider communication,
session orchestration, capability execution, authority, compaction, and durable
state. SQLite records the event history used to reconstruct sessions and audit
work. The Mac app packages the server, manages its login item, and handles
pairing.

The provider-visible model tool remains `execute`. Tron can discover and invoke
the operations behind it, while kernel and governance boundaries stay explicit.
Module-owned replacements must pass validation, supervised runtime checks, and
rollback policy before they can route real work.

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
- Rust through `rustup` (version and components are pinned in
  [`rust-toolchain.toml`](rust-toolchain.toml))
- Xcode 26 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Clone this repository, then set up and start a development server:

```bash
cd tron
scripts/tron setup
scripts/tron dev --background
scripts/tron login
```

Useful commands:

```bash
scripts/tron dev --background   # start in the background
scripts/tron dev --stop         # stop development takeover
scripts/tron status --json      # inspect the active server
scripts/tron logs               # query bounded local logs
scripts/tron ci                 # run full local Rust validation
```

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

Use `scripts/tron dev` for development. Production deployment is deliberately
manual and is not part of the normal contributor workflow.

## Validate

Run the smallest focused tests while iterating. Before a broad change or PR,
run:

```bash
scripts/tron ci fmt check clippy test
scripts/personal-info-guard.sh
```

GitHub Actions runs the same warning-denied Rust path plus iOS and Mac validation
on `main`. The required branch check is `CI summary`.

## Documentation

Start with the document closest to the work:

- [Technical project reference](packages/agent/docs/project-reference.md) —
  protocol, capabilities, events, settings, storage, CLI, and operations.
- [Contributing](CONTRIBUTING.md) — development workflow, testing, commits, and
  releases.
- [Rust module map](packages/agent/src/lib.rs) — server ownership and entry
  points; each `mod.rs` progressively documents its subtree.
- [iOS architecture](packages/ios-app/docs/architecture.md) and
  [development guide](packages/ios-app/docs/development.md).
- [Mac architecture](packages/mac-app/docs/architecture.md) and
  [development guide](packages/mac-app/docs/development.md).
- [Capability operation contracts](packages/agent/src/domains/capability/operations/operation_contract/mod.rs)
  and their [ownership metadata](packages/agent/src/domains/capability/operations/operation_contract/metadata.rs).

The root README intentionally stays short. Detailed contracts belong with
their owning source or technical reference rather than on the project front
page.

## Project Rules

- Code, tests, and documentation ship together.
- Root-cause fixes take priority over compatibility shims and fallbacks.
- Secrets and personal information never belong in the repository.
- The engine owns authority and durable truth; clients do not invent state.
- Production deployment is manual-only.

See [AGENTS.md](AGENTS.md) for the complete engineering rules.

## License

MIT
