# Tron-native engine redesign exploration

Status: exploration branch artifact.

Date: 2026-04-30.

Branch: `codex/iii-engine-redesign-exploration`.

## Purpose

This directory captures the first design deliverable for redesigning the Tron
agent server around engine primitives: workers, functions, and triggers. The
goal is not to vendor or embed iii. iii is the reference architecture; Tron
should own a native implementation that fits its local-first agent, event
store, settings, clients, and tool runtime.

The current server is reliable, but most capability changes require ordinary
Rust server edits, rebuilds, restarts, and manual harness wiring. The target
architecture moves those capabilities behind live engine primitives so agent
tools, backend workflows, cron jobs, streams, queues, state updates, and
future sandbox workers all participate in one discoverable system.

## Documents

- [iii teardown](iii-teardown.md) explains the iii architecture and what Tron
  should adopt, adapt, or avoid.
- [Tron capability matrix](tron-capability-matrix.md) inventories the current
  server and maps existing workflows to future engine primitives.
- [Target engine design](target-engine-design.md) specifies the proposed
  Tron-native primitives, interfaces, lifecycle, security model, state, queue,
  stream, discovery, and observability behavior.
- [Migration strategy](migration-strategy.md) defines the incremental cutover
  path, acceptance gates, and testing discipline.

## Source snapshot

iii sources analyzed:

- Documentation: <https://iii.dev/docs/quickstart> and linked architecture,
  worker, protocol, trigger-action, schema, sandbox, RBAC, and observability
  pages listed in <https://iii.dev/docs/llms.txt>.
- Repository: <https://github.com/iii-hq/iii> at commit
  `9eaf3737e8a5e86d12039d067f76bc208eb39def`
  (`fix(website): restore cleanUrls so /manifesto resolves to manifesto.html (#1579)`).

Tron sources analyzed:

- `packages/agent/src/main.rs`
- `packages/agent/src/lib.rs`
- `packages/agent/src/server/mod.rs`
- `packages/agent/src/server/app/server.rs`
- `packages/agent/src/server/rpc/handlers/mod.rs`
- `packages/agent/src/runtime/mod.rs`
- `packages/agent/src/runtime/agent/mod.rs`
- `packages/agent/src/runtime/orchestrator/mod.rs`
- `packages/agent/src/tool_factory.rs`
- `packages/agent/src/tools/mod.rs`
- `packages/agent/src/mcp/mod.rs`
- `packages/agent/src/cron/mod.rs`
- `packages/agent/src/events/mod.rs`
- `packages/agent/src/events/types/generated.rs`
- `packages/agent/src/settings/types/mod.rs`

Local runtime facts sampled directly from `~/.tron/system/database/log.db`:

- Tables: `sessions`, `events`, `blobs`, `branches`, `logs`,
  `device_tokens`, `notification_read_state`, `cron_jobs`, `cron_runs`,
  `prompt_history`, `prompt_snippets`, `workspaces`, `schema_version`.
- High-traffic event types at the time of sampling were session, message,
  stream, tool, hook, notification, config, worktree, and metadata events.

## Design defaults locked by this pass

- Use a Tron-native engine implementation. Do not copy iii engine code into
  Tron without separate license review.
- Keep the first deliverable as docs and inventories. Large code movement
  begins only after the primitive contracts are clear.
- Design server-first. Mac and iOS client rewrites are deferred until the
  server contract stabilizes, but client API impact must be documented.
- Allow compatibility to break in the final architecture. During migration,
  compatibility adapters exist only to validate and incrementally cut over.
- Preserve current behavior until a specific capability is migrated and tested.

## Documentation drift found during inventory

The source-of-truth handler registry currently contains 165 RPC registrations
in `server/rpc/handlers/mod.rs`, matching the root README count. The event type
source currently asserts 80 event types; this pass updated the stale
`events/mod.rs` module documentation that still described 60 variants.
