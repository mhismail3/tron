# Migration strategy

The migration should move Tron from a traditional server plus agent harness to
a Tron-native engine without forcing a risky all-at-once rewrite.

## Phase 0: documentation and source reconciliation

Deliverables:

- Keep this design directory updated as the architecture evolves.
- Reconcile known README/module-doc drift before touching the affected
  source-of-truth areas.
- Add a living capability matrix that tracks each migrated subsystem.

Acceptance:

- Docs identify current behavior, target primitive, migration state, tests, and
  rollback path for every subsystem touched.
- `git diff --check` passes for docs-only changes.

## Phase 1: in-process engine skeleton

Build the smallest non-disruptive engine inside the Rust agent process.

Deliverables:

- Engine registry types for workers, functions, trigger types, and triggers.
- In-process worker trait.
- Function registration with owner tracking and metadata.
- Sync invocation path for in-process functions.
- Discovery functions for functions/workers/triggers.
- Unit tests for registration, overwrite rules, unregister, discovery, and
  sync invocation.

Acceptance:

- No current RPC behavior changes.
- No external worker protocol yet.
- Engine can be created in tests without starting the server.

## Phase 2: RPC compatibility mirror

Expose current RPC handlers through engine functions while keeping the existing
WebSocket RPC transport.

Deliverables:

- `rpc_compat` worker that registers one function per current RPC method.
- Metadata links each function to its legacy method name.
- Compatibility invocation can call the existing handler path.
- Discovery can list current RPC-compatible functions.

Acceptance:

- Existing client tests pass unchanged.
- New tests prove a selected RPC method works through both legacy dispatch and
  engine invocation.
- README RPC counts are reconciled with `server/rpc/handlers/mod.rs`.

## Phase 3: low-risk read functions

Migrate isolated read-only capabilities first.

Candidate functions:

- `system::ping`
- `system::get_info`
- `model::list`
- `skill::list`
- `settings::get`
- `events::get_history`
- `logs::recent`
- `filesystem::get_home`
- `prompt_snippet::list`
- `prompt_history::list`

Acceptance:

- Each migrated read has schema metadata.
- Legacy RPC adapters call the engine implementation, not duplicate logic.
- Focused tests cover direct engine invocation and legacy RPC compatibility.

## Phase 4: stream and event unification

Introduce engine streams while preserving WebSocket clients.

Deliverables:

- Stream worker abstraction with cursor/subscription model.
- Session event stream backed by event ids.
- Job/tool-output stream adapter.
- Topology stream for function/worker changes.
- Compatibility bridge from stream events to current WebSocket broadcasts.

Acceptance:

- Existing event broadcast tests pass.
- Stream tests cover subscribe, resume from cursor, disconnect, and multiple
  subscribers.
- Agent turn lifecycle ordering remains unchanged.

## Phase 5: queue primitive

Create durable queue semantics before migrating agent/background workflows.

Deliverables:

- Queue worker with enqueue, receipt, status, cancellation, retry, and DLQ.
- Queue events/logs include invocation id and trace id.
- Existing job manager can be adapted to queue-backed execution.

Acceptance:

- Unit tests for enqueue/dequeue, retry, cancellation, concurrency, and DLQ.
- Integration tests for a queued background job and a queued no-op function.
- No change to public client behavior until compatibility path is proven.

## Phase 6: cron as triggers

Convert cron execution to trigger semantics while keeping current automation
definition files.

Deliverables:

- Cron trigger type.
- Adapter from `automations.json` job definitions to trigger registrations.
- Cron execution invokes engine functions with queue policy where appropriate.
- Run history remains in SQLite.

Acceptance:

- Existing cron tests pass.
- Tests cover shell/webhook/agent/system-event payloads through the trigger
  path.
- Misfire, overlap, retry, and corrupt-row invariants remain documented and
  tested.

## Phase 7: tools, MCP, and approvals

Move tool invocation behind engine functions.

Deliverables:

- Tool worker registers built-in tool functions.
- MCP worker preserves `mcp::search` and `mcp::call` meta-tool behavior.
- Approval/question/device flows become functions plus stream/device triggers.
- Tool executor invokes engine functions instead of a private registry where
  migrated.

Acceptance:

- Existing tool unit tests pass.
- Agent can call migrated tools through the engine path.
- Approval-required tools preserve current client/device behavior.

## Phase 8: agent worker

Make the agent loop itself an engine worker.

Deliverables:

- `agent::run_turn` function.
- Prompt queue trigger for user prompts.
- Subagent spawn/handoff through queue functions.
- Context, memory, hooks, and guardrails represented as functions/triggers
  where useful.
- Agent discovery consumes engine function catalog.

Acceptance:

- Existing session and orchestrator tests pass.
- Agent turn persistence ordering is unchanged.
- Crash recovery and streaming journal behavior are preserved or replaced by
  stronger engine-backed tests.
- Trace id connects prompt, LLM stream, tool calls, queued work, events, and
  final client broadcast.

## Phase 9: external workers

Add external worker protocol only after the in-process model is proven.

Deliverables:

- Tron-owned JSON-over-WebSocket worker protocol.
- Scoped worker tokens and namespace registration policy.
- Reconnect and re-registration behavior.
- External worker SDK prototype only if needed for validation.

Acceptance:

- External worker cannot register outside its namespace.
- Disconnect cleanup removes only owned volatile registrations.
- Reconnect is idempotent.
- Invocation timeout/cancellation behavior is tested.

## Phase 10: client cutover and legacy removal

Cut clients over once the server contract is stable.

Deliverables:

- Mac/iOS consume discovery and streams for selected workflows.
- Legacy RPC compatibility functions are marked migration-only.
- Removed RPC methods are deleted from docs, tests, and clients together.

Acceptance:

- Server, Mac, and iOS targeted tests pass for migrated workflows.
- README API sections describe the final engine-native contract.
- No aspirational or removed methods remain in canonical docs.

## Commit discipline

Each implementation commit should include:

- Code change.
- Focused tests for the changed behavior.
- Progressive disclosure docs for touched modules.
- README updates when a source-of-truth file listed in the project guidelines
  changes.

Docs-only exploration commits can use `git diff --check` as verification.
Implementation commits should run the smallest high-signal command set first
and escalate to full CI when shared contracts, runtime behavior, or client
protocols change.
