# Event Handling

> Last verified: 2026-07-13 (response-complete finality dispatch and live/replay metadata parity; thinking vs reasoning-summary stream contracts; generating capability chip reconstruction; server stream event-surface coverage; marker no-op dispatch; FSC-8 canonical failure parity).

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

Capability execution chips are server-truth-backed. Live
`capability.invocation.started` and `capability.invocation.completed` events
come from persisted session rows and carry those row sequences; when the server
receives several parallel invocation requests, it broadcasts every persisted
`started` row before execution begins. iOS treats
`capability.invocation.generating` as pre-execution draft state only, but still
renders it immediately so the user sees pending parallel work before execution
finishes. Reconnect reconstruction preserves that `generating` state when the
server reports an in-flight invocation.

## Stream Ownership and Terminal Drain

`EventStoreManager` owns the current global event subscription without owning
the shared `AsyncEventStream` bus. The idle subscription task captures the
manager weakly. Client replacement is predecessor-chained—including the first
load—so rapid A→B→C replacement cannot let events or projection loads from an
older origin overtake the latest lane. Reconnect refresh stays behind
`SessionRefreshService`'s single coalescing owner.

Acceptance is the boundary for shutdown semantics: after the lane accepts an
event, its database mutation and completion callback are awaited inline. The
manager's shared terminal drain cancels and joins the global lane, awaits the
refresh coordinator's terminal drain, then cancels and joins the replacement
and load chain before fixture-owned database close. Late refresh requests are
rejected, repeated shutdown callers await the same drain, and neither manager
shutdown nor deinitialization finishes the shared event bus.

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

Server stream event labels under `packages/agent/src/transport/runtime/streams`
must have an iOS plugin entry even when they intentionally render no UI. Marker
plugins such as `agent.start`, `agent.thinking_start`, `agent.interrupted`,
`agent.retry`, `context.warning`, `session.forked`,
`capability.invocation.batch`, and `capability.invocation.arguments_delta`
parse only the routing envelope when their payload can contain partial
arguments or diagnostic material. A registered plugin returning `nil` after a
successful parse is a no-op, not a transform warning; malformed payload decode
still logs at the parser boundary. `SourceGuardTests+EventSurface` compares the
Rust stream labels with `EventRegistry.registerAll()` so new server events
cannot silently become unknown in the app.

`agent.response_complete` is dispatched lifecycle evidence rather than a
marker. Its server-owned capability count identifies the conservative subset
of responses that are final clean text: zero-capability responses may be
marked final, while capability-bearing responses never own a metadata footer.
The matching `agent.turn_end` supplies token, model, and latency presentation
facts, and accounting still updates for every turn. Stored reconstruction
applies the same policy from `message.assistant`:
text must exist, the payload must not be interrupted, and no
capability-invocation block may be present. Neither path treats provider
stop-reason spelling or rendered item order as finality evidence.

`agent.thinking_end` is not a marker: it carries the server-authoritative final
thinking-like text for the visible block. The live plugin replaces any
delta-accumulated text with that final snapshot and marks the block
non-streaming so live display converges with `message.assistant` replay.
Providers that expose append-only extended thinking use the default `thinking`
contract. Provider-authored reasoning summaries use `reasoning_summary`; those
summaries may be compressed or non-verbatim and must be labeled separately in
the UI rather than presented as raw chain-of-thought. Legacy OpenAI
`message.assistant` replay blocks that predate the explicit `kind` field are
also rendered as reasoning summaries based on their persisted `providerType`
so old sessions do not overpromise raw thinking.

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
Events that are intentionally diagnostics-only should still register a parser
that returns no `EventResult`; unknown event types are reserved for genuine
drift, not for known server markers.

## Dispatch

The dispatch model stays switch-free at the central coordinator:

```swift
func dispatch(type: String, transform: () -> (any EventResult)?, context: EventDispatchTarget) {
    guard let box = EventRegistry.shared.pluginBox(for: type) else { return }
    guard let result = transform() else { return }
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
