# Tron Capability Matrix

The current server capability inventory is canonical-first. Each row below is a
worker namespace that owns `namespace::function` capabilities in the live engine
catalog. The `/engine` protocol is the worker/client transport for discovery,
inspection, invocation, and stream subscription messages; the model-facing
harness sees the `capability` worker's `search`, `inspect`, and `execute`
primitives over that same catalog.

| Worker | Default Visibility | Primary Effect Classes | Idempotency | Authority / Risk Notes |
|--------|--------------------|------------------------|-------------|------------------------|
| `engine` | System | Pure read, delegated invocation, idempotent promotion | Explicit for promotion | Reserved namespace for worker/client transport; normal workers cannot override these functions, and providers do not see them as model tools. |
| `agent` | System, hidden apply internals | Reads, idempotent writes, external side effects | Session scoped writes | Prompt, abort, queue, confirmation, answers, subagent result delivery. High-risk autonomous prompt/abort paths require approval. |
| `approval` | System | Idempotent writes, reads | System scoped writes | User/system-authorized resolution only; agent self-resolution is rejected. |
| `auth` | System | Reads, reversible side effects | System scoped writes | Auth-file leases; secrets never logged or embedded in docs/tests. |
| `browser` / `display` | System | Reads, reversible stream controls | System scoped writes | Stream lifecycle records and local authority. |
| `capability` | System | Pure read, delegated invocation, operator mutations | Session scoped delegated execution; system scoped admin idempotency | Collapsed model harness; exposes only `search`, `inspect`, and `execute` while concrete work remains owned by live workers. Approval-required `execute` calls keep the original turn open until the engine approval record resolves; Engine Console admin mutations do not depend on a chat session id. |
| `config` / `model` / `settings` | System | Reads, reversible side effects | Session/system scoped writes | Resource leases protect session model/reasoning and settings profile writes. |
| `context` / `memory` | System | Reads, reversible/external side effects | Session scoped writes | Event-store truth remains authoritative; retain/compact flows are high risk. |
| `cron` | System plus hidden apply | Reads, high-risk side effects, scheduled triggers | System scoped writes/runs | `cron_schedule` triggers dispatch through the engine runtime. |
| `device` / `notifications` | System | Reads, idempotent writes, append-only events | System/session scoped writes | APNs/device broker semantics stay behind canonical functions. |
| `events` | System | Reads, append-only events, stream subscription controls | Session scoped writes | Event store remains durable session truth; streams are live delivery. |
| `filesystem` / `blob` | System | Pure reads, idempotent create | Explicit for create | Path normalization and root checks are enforced before side effects. |
| `git` / `worktree` / `repo` | System | Reads, idempotent writes, high-risk side effects | Resource-scoped writes | Leases and compensation metadata protect repo/worktree mutations. |
| `import` | System | Reads, append-only execution | System scoped execute | Import execution is high risk and resource-locked by canonical session path. |
| `job` / `queue` | System and hidden apply | Reads, idempotent writes, queued execution | System scoped writes | Queue receipt and attempt metadata preserve causality. |
| `logs` | System | Reads, append-only events | System scoped ingestion | Engine idempotency sits above row-level log deduplication. |
| `mcp` / discovered `mcp::*` tools | System/session as discovered | Conservative read/side-effect classification | Explicit for mutating tools | Unknown MCP tools default to approval-required side effects. |
| `plan` | Session/workspace | Reads, idempotent writes | Session/workspace scoped | Plan state is local execution state, not durable session truth. |
| `prompt_library` | System | Reads, idempotent writes, irreversible deletes | System scoped writes | Prompt history/snippets are local global state. |
| `process` | System | External side effects | Session-scoped idempotency and process lease | `process::run` uses a domain-owned conditional approval classifier: read-only checks such as date/status/test commands run directly without an extra inspect turn, while privileged, destructive, source-control mutating, package-installing, unknown shell commands, or redirection-based writes require fresh inspection and pause for approval. |
| `sandbox` | System | Reads, high-risk lifecycle side effects | Container scoped writes | Local-only authority; no remote sandbox execution in this branch. |
| `session` | System | Reads, idempotent/reversible lifecycle writes | Session/system scoped writes | Session truth is event-sourced; mutations are causally recorded. |
| `skills` | System/session | Reads, idempotent session writes | Session scoped writes | Activation state is reconstructed from events. |
| `state` / `stream` | Scoped primitive workers | Projection writes, stream append/poll | Scoped writes | Primitives support catalog watch, subscriptions, approvals, jobs, and runtime delivery. |
| `transcription` / `voice_notes` | System | Reads, high-risk media writes | File/model scoped writes | Audio/model-cache/file leases guard side effects. |
| `system` | System | Reads, critical lifecycle writes | Explicit writes | Shutdown/update/check/status are canonical functions with strict authority. |

## Required Contract Columns

Every canonical function definition must declare:

- function id and owning worker;
- contract id, implementation id, plugin/domain id, trust tier, runtime
  requirements, and context-primer level metadata when visible to agents;
- request and response schema;
- effect class and risk level;
- visibility and health;
- authority requirement;
- idempotency contract when mutating;
- approval metadata when autonomous execution is high risk;
- lease metadata when shared resources are touched;
- compensation notes for high-risk or irreversible effects;
- provenance and catalog revision.
