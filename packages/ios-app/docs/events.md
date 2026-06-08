# Event Handling

> Last verified: 2026-06-08 (primitive cleanup setup).

The iOS app handles engine events through two paths:

```
Live:   WebSocket -> EngineClient -> EventRegistry -> Plugin -> ChatViewModel
Stored: EventDatabase -> UnifiedEventTransformer -> ChatMessage array
```

The live path updates the mounted session UI. The stored path reconstructs
history from durable event rows. Neither path owns repository workflow state,
assistant-management state, curated prompt state, skill state, or fixed audit
dashboard state on the primitive teardown branch.

## Plugin Boundary

Each live plugin parses one server event family into a UI-ready result and
dispatches itself through `EventDispatchCoordinator`. Plugins may render
transport facts, progress, errors, and generic runtime data. They must not
restore deleted product modes or synthesize retired event names.

Current retained plugin groups:

| Group | Directory | Purpose |
|-------|-----------|---------|
| Streaming | `Plugins/Streaming/` | Text, thinking, and turn lifecycle deltas. |
| Capability invocation | `Plugins/CapabilityInvocation/` | Generic `capability.invocation.*` lifecycle evidence for chat. |
| Lifecycle | `Plugins/Lifecycle/` | Agent readiness, completion, compaction, context clearing, message deletion, and turn failure labels that still reach the shell. |
| Session | `Plugins/Session/` | Connection and session list/update/archive/delete state. |
| Queue | `Plugins/Queue/` | Prompt queue/dequeue/send status. |
| Display | `Plugins/Display/` | Generic display frames for runtime surfaces. |
| Server | `Plugins/Server/` | Server/auth/restart status messages. |
| Hook | `Plugins/Hook/` | Generic LLM hook result display while cleanup audits remaining hook labels. |

Deleted workflow-specific plugin roots must stay absent. Static tests keep
their exact retired names out of ordinary source and docs.

## Registration

`EventRegistry.shared.registerAll()` runs at app startup. Registration is the
only place a live event plugin enters the shell, so deleted roots should be
removed from both disk and registration instead of left dormant.

## Dispatch

The dispatch model stays switch-free at the central coordinator:

```swift
func dispatch(type: String, transform: () -> (any EventResult)?, context: EventDispatchTarget) {
    guard let result = transform() else { return }
    guard let box = EventRegistry.shared.pluginBox(for: type) else { return }
    box.dispatch(result: result, context: context)
}
```

`ChatViewModel` conforms to the composed dispatch target through small handler
extensions. The target exposes chat/session primitives, not fixed product
dashboard APIs.

## Stored Reconstruction

`UnifiedEventTransformer` reconstructs messages from `SessionEvent` rows. The
retained reconstruction state tracks message content, capability invocation
lifecycles, streaming state, turn grouping, generated runtime data, and compact
session metadata needed for chat. Capability identity fields stay primitive:
model primitive, operation, trace/root invocation ids, theme color, and
presentation hints. Reconstruction must not recover retired contract,
implementation, worker, risk, or binding metadata from old payloads.

Unsupported event payloads should remain visible as diagnostics or no-op
transport facts. They should not be converted into fixed dashboard,
repository, assistant-management, skill, curated prompt, or media workflow
models.

## Session Updates

`session.updated` updates only fields the server sends. iOS persists the
resulting `CachedSession` and uses it for the session list and active-session
metadata. The client does not synthesize missing counts from unrelated local
state and does not reconstruct product dashboards from session metadata.

## Guardrails

PET-8 source guards enforce:

- deleted fixed view roots remain absent;
- deleted clients/state objects remain absent;
- primitive shell files remain present;
- push authorization is gated by active pairing;
- removed product names do not reappear in ordinary source or tests.
