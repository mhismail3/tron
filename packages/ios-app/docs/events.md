# Event Handling

> Last verified: 2026-06-12 (IOSTC-5 generic chat/timeline/runtime rendering; FSC-8 canonical failure parity).

The iOS app handles engine events through two paths:

```
Live:   Engine transport -> SessionEventRepository -> EventRegistry -> Plugin -> ChatViewModel
Stored: EventDatabase -> Session/Timeline/Reconstruction -> ChatMessage array
```

The live path updates the mounted session UI. The stored path reconstructs
history from durable event rows. Neither path owns repository workflow state,
assistant-management state, curated prompt state, skill state, prompt-queue
state, hook suggestion state, or fixed audit panels on the primitive teardown
branch.

The transport and subscription details stay in the Engine layer. Session view
models subscribe through `SessionEventRepository`, so event plugins receive
parsed event contracts without SwiftUI/session code importing concrete engine
transport or raw settings/auth protocol DTOs.

## Plugin Boundary

Each live plugin parses one server event family into a UI-ready result and
dispatches itself through `EventDispatchCoordinator`. Plugins may render
transport facts, progress, errors, and generic runtime data. They must not
restore deleted product modes or synthesize retired event names.

Current retained plugin groups:

| Group | Directory | Purpose |
|-------|-----------|---------|
| Streaming | `Sources/Engine/Events/Plugins/Streaming/` | Text, thinking, and turn lifecycle deltas. |
| Capability invocation | `Sources/Engine/Events/Plugins/CapabilityInvocation/` | Generic `capability.invocation.*` lifecycle evidence for chat. |
| Lifecycle | `Sources/Engine/Events/Plugins/Lifecycle/` | Agent readiness, completion, compaction, context clearing, message deletion, and turn failure labels that still reach the shell. |
| Session | `Sources/Engine/Events/Plugins/Session/` | Connection and session list/update/archive/delete state. |
| Display | `Sources/Engine/Events/Plugins/Display/` | Generic display frames for runtime surfaces. |
| Server | `Sources/Engine/Events/Plugins/Server/` | Server/auth/restart status messages. |

Deleted workflow-specific plugin roots, including prompt queue and hook
suggestion plugins, must stay absent. Static tests keep their retired names out
of ordinary source and docs.

## DRC-9 replay manifest/event parity

`model.provider_request` is a persisted metadata-only session event used by the
server replay manifest. It is decoded in the stored event enum and summarized as
non-chat audit evidence; it does not have a live plugin or render a chat
message. `replay_manifest` is not an event at all: it is a pure-read
capability/session result (`format: "tron.replay.v1"`), so no iOS persisted event case or live plugin is required for replay manifest exports.

## Failure Envelope Parity

Server-authored failures use one canonical envelope. iOS represents it with
`CanonicalFailurePayload` in `Sources/Engine/Protocol/Core/FailurePayload.swift`
and reads it from `/engine` protocol errors and nested `details.failure`
objects.

The live `error` plugin and `agent.turn_failed` plugin do not synthesize
placeholder codes, messages, turns, or recoverability. If the current server
payload omits required failure fields, the plugin transform drops the malformed
event. Persisted `error.*` and `turn.failed` projections, provider error pills,
session summaries, expanded event content, and capability error rows prefer the
server envelope whenever it is present.

Local reachability and pairing failures may still be classified locally when no
server response exists. Server-authored categories, retryability,
recoverability, provider/model/status/error-type fields, and trace references
must flow from the canonical envelope rather than a client taxonomy.

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
extensions. The root state object owns orchestration; streaming, UI queue,
capability-completion, and live event callback installation lives in
`ChatViewModel+RuntimeCallbacks.swift`. The target exposes chat/session
primitives, not fixed product session-list APIs.

## Stored Reconstruction

`Session/Timeline/Reconstruction/UnifiedEventTransformer.swift` reconstructs
messages from `SessionEvent` rows. Engine reconstruction helpers own persisted
event decoding support; the transformer is Session-owned because it projects
durable events into chat timeline state. The retained reconstruction state
tracks message content, capability invocation lifecycles, streaming state, turn
grouping, generated runtime data, and compact session metadata needed for chat.
Capability identity fields stay primitive: model primitive, operation,
trace/root invocation ids, theme color, and presentation hints. Reconstruction
must not recover retired contract, implementation, worker, risk, or binding
metadata from old payloads.

Unsupported event payloads should remain visible as diagnostics or
transport-only facts. They should not be converted into fixed panels,
repository, assistant-management, skill, curated prompt, or media workflow
models.

## Session Updates

`session.updated` updates only fields the server sends. iOS persists the
resulting `CachedSession` and uses it for the session list and active-session
metadata. The client does not synthesize missing counts from unrelated local
state and does not reconstruct product panels from session metadata.

## Guardrails

PET-8 source guards enforce:

- deleted fixed view roots remain absent;
- deleted clients/state objects remain absent;
- primitive shell files remain present;
- push authorization is gated by active pairing;
- removed product names do not reappear in ordinary source or tests.
