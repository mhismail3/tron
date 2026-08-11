# Event Handling

> Last verified: 2026-08-11 (registry-owned live dispatch; 16-event durable server catalog including `message.agent`; client-local completed-thinking row; source/client stream-loss recovery; response-complete finality; canonical-failure parity).

The iOS app handles engine events through two paths:

```
Live:   Engine transport -> SessionEventRepository -> EventRegistry -> Plugin -> ChatViewModel
Stored: EventDatabase -> Session/Timeline/UnifiedEventTransformer -> immediate cached ChatMessage array
Fresh:  session::reconstruct -> authoritative ChatMessage array + EventDatabase refresh
```

The live path updates the mounted session UI. The stored path reconstructs
history from durable event rows before network reconstruction completes. A
successful server reconstruction refreshes those immutable cached rows, and a
connected interactive chat starts an incremental event-cache sync when its
presentation closes. Cache projection never declares an empty session or
releases buffered live events; only the fresh server snapshot does. Neither
path owns repository workflow state,
assistant-management state, curated prompt state, skill state, prompt-queue
state, hook suggestion state, or fixed audit panels on the primitive teardown
branch.

The transport and subscription details stay in the Engine layer. Session view
models subscribe through `SessionEventRepository`, so event plugins receive
parsed event contracts without SwiftUI/session code importing concrete engine
transport or raw settings/auth protocol DTOs.

Tool execution chips are server-truth-backed. Live
`tool.invocation.started` and `tool.invocation.completed` events
come from persisted session rows and carry those row sequences; when the server
receives several parallel invocation requests, it broadcasts every persisted
`started` row before execution begins. iOS treats
`tool.invocation.generating` as pre-execution draft state only, but still
renders it immediately so the user sees pending parallel work before execution
finishes. `tool.invocation.progress` is the only transient progress
surface; terminal state comes from `tool.invocation.completed`. There is
no separate async-run lifecycle or paused invocation state. Reconnect
reconstruction preserves generating, running, completed, and failed invocation
state directly from the server accumulator.

## Stream Ownership and Terminal Drain

`EventStoreManager` owns the current global event subscription without owning
the shared `AsyncEventStream` bus. The idle subscription task captures the
manager weakly. Direct and filtered consumers register at that same bus owner;
filter predicates run before the consumer's single bounded buffer, so filtering
does not create a second hidden queue or task. Releasing the final bus owner
finishes every subscriber. `finish()` owns both explicit and deinitializer cleanup:
it removes the continuation snapshot under lock, then notifies subscribers
after unlocking. Client replacement is predecessor-chained—including the first
load—so rapid A→B→C replacement cannot let events or direct projection loads
from an older origin overtake the latest lane. Session-list refresh completion
is separately client-identity fenced before reconciliation, projection loads,
retry registration, and user-visible errors. The refresh awaits its captured
load generation; server processing flags seed the published projection unless
a newer accepted live or optimistic per-session override must be preserved.
Those origin-bound overrides retain explicit true and false values and retire
only when a later refresh supplies processing state for that session; partial
or omitted processing truth cannot erase them. Reconnect refresh stays behind
`SessionRefreshService`'s single coalescing owner.

Live continuity failures are explicit. If the server projection receiver lags,
it publishes a global `stream.recovery_required` marker. If an iOS subscriber
buffer evicts an older delivery, `EngineClient` queues the same marker before
acknowledging the upstream cursor. A mounted chat turns the marker into a
generation change observed by `ChatView`, which routes reconstruction through
the existing connection-refresh task. Replacement cancels and joins its keyed
predecessor before new state mutation. Only a committed server snapshot clears
reconstruction mode and drains the buffered live suffix; retryable failures and
cancellation retain both the gate and buffer. The snapshot sequence cut commits
before cancellable projection work, and the keyed view task retries transient
failures with capped backoff while connected. Marker bursts retain at most one
follow-up reconstruction behind the current repair rather than repeatedly
cancelling it. The global event owner also requests a coalesced session-list
refresh. Neither event handler opens a second socket or owns retry tasks.

Acceptance is the boundary for shutdown semantics: after the lane accepts an
event, its database mutation and completion callback are awaited inline. The
manager's shared terminal drain cancels and joins the global lane, awaits the
refresh coordinator's terminal drain, then cancels and joins the replacement
and load chain before fixture-owned database close. Late refresh requests are
rejected, repeated shutdown callers await the same drain, and neither manager
shutdown nor deinitialization finishes the shared event bus.

## Plugin Boundary

Each live plugin parses one server event family into a UI-ready result and
dispatches itself through `EventRegistry`. Plugins may render
transport facts, progress, errors, and generic runtime data. They must not
restore deleted product modes or synthesize retired event names.

Current retained plugin groups:

| Group | Directory | Purpose |
|-------|-----------|---------|
| Streaming | `Sources/Engine/Events/Plugins/Streaming/` | Text, thinking, and turn lifecycle deltas. |
| Tool invocation | `Sources/Engine/Events/Plugins/ToolInvocation/` | Generic `tool.invocation.*` lifecycle evidence for chat. |
| Lifecycle | `Sources/Engine/Events/Plugins/Lifecycle/` | Agent readiness, completion, compaction, context clearing, message deletion, turn failure labels, and coordination invalidations that still reach the shell. |
| Session | `Sources/Engine/Events/Plugins/Session/` | Connection, session list/update/archive/delete state, and live typed `message.agent` audit rows. |
| Server | `Sources/Engine/Events/Plugins/Server/` | Server/auth/restart status messages. |

Deleted workflow-specific plugin roots, including prompt queue and hook
suggestion plugins, must stay absent. Static tests keep their retired names out
of ordinary source and docs.

Server stream event labels under `packages/agent/src/transport/runtime/streams`
must have an iOS plugin entry even when they intentionally render no UI. Marker
plugins such as `agent.start`, `agent.thinking_start`, `agent.interrupted`,
`agent.retry`, `context.warning`, `session.forked`,
`tool.invocation.batch`, and `tool.invocation.arguments_delta`
parse only the routing envelope when their payload can contain partial
arguments or diagnostic material. A registered plugin returning `nil` after a
successful parse is a no-op, not a transform warning; malformed payload decode
still logs at the parser boundary. `SourceGuardTests+EventSurface` compares the
Rust stream labels with `EventRegistry.registerAll()` so new server events
cannot silently become unknown in the app.

`agent.lifecycle`, `agent.assignment`, and `agent.message` are registered
session-scoped markers for reusable-agent management. They never mutate UI
state from their payloads. `EngineClient` coalesces adjacent markers for 200 ms
into one `agentCoordinationProjectionInvalidated` hint carrying only affected
owning-session IDs; Manage Session then rereads `agent::relations` or the
mounted agent-detail projections. An unscoped marker conservatively invalidates
every mounted agent manager. Exact bidirectional communication history is read
through authorized `agent::messages` and `agent::message_detail` operations and
is not copied into the invalidation notification. The recipient's canonical
transcript also contains each incoming `message.agent` row. That durable event
has a separate dispatchable live plugin: it preserves message/source/
assignment/reply IDs plus kind and Engine-authored authority, and renders a
read-only `.agent` timeline row rather than user intent. Audit sheets retain
the session subscription before fetching their reconstruction snapshot,
buffer the live suffix behind the sequence cut, and drain it only after the
snapshot commits. Agent rows do not reset user turn boundaries and cannot
become delete, edit, retry, or user-fork targets. Reconnect, cached replay, and
live presentation therefore converge without an audit gap or event-driven
management-read storm.

`worker.role_review` is a content-free Worker Console invalidation marker with
only action, proposal, target-worker, and status identifiers. It joins the
existing 200 ms worker-projection coalescer and lifecycle refresh lane; its
payload never supplies proposal content, permissions, reviewer availability,
or UI state. A mounted Manage Workers view rereads
`worker_kernel::role_reviews`, while a selected proposal is refreshed through
`worker_kernel::role_review_inspect`. Reconnect and foreground reconciliation
perform the same reads, so duplicate or replayed markers cannot duplicate a
proposal or authorize a mutation.

The marker `agent.interrupted` remains diagnostics-only. A cancelled turn's
authoritative UI evidence is the durable `agent.turn_failed` event classified
as `RUNTIME_CANCELLED` / `cancelled`. Its live plugin appends the existing
Session interrupted notification, and stored reconstruction projects the same
notification instead of a retryable failure pill. The later `agent.complete`
event alone finalizes streaming state and returns the mounted chat to idle.

`agent.response_complete` is dispatched lifecycle evidence rather than a
marker. Its server-owned tool count identifies the conservative subset
of responses that are final clean text: zero-tool responses may be
marked final, while tool-bearing responses never own a metadata footer.
The matching `agent.turn_end` supplies token, model, and latency presentation
facts, and accounting still updates for every turn. Stored reconstruction
applies the same policy from `message.assistant`:
text must exist, the payload must not be interrupted, and no
tool-invocation block may be present. Neither path treats provider
stop-reason spelling or rendered item order as finality evidence.

`agent.thinking_end` is not a marker: it carries the server-authoritative final
thinking-like text for the visible block. The live plugin replaces any
delta-accumulated text with that final snapshot and marks the block
non-streaming so live display converges with `message.assistant` replay.
Providers that expose append-only extended thinking use the default `thinking`
contract. Provider-authored reasoning summaries use `reasoning_summary`; those
summaries may be compressed or non-verbatim and are labeled separately in the
detail UI rather than presented as raw chain-of-thought. Compact chat previews
show only the reasoning text and omit both kind headers. Every persisted
thinking block carries its explicit `kind`; missing values use the ordinary
thinking presentation.

## Replay manifest/event parity

`model.provider_request` is a persisted metadata-only session event used by the
server replay manifest. It is decoded in the stored event enum and summarized as
non-chat audit evidence; it does not have a live plugin or render a chat
message. `replay_manifest` is not an event at all: it is a pure-read
tool/session result (`format: "tron.replay.v1"`), so no iOS persisted event case or live plugin is required for replay manifest exports.

`session.model_changed` and `session.reasoning_changed` are persisted session
configuration events. Their local action result updates the mounted composer
immediately; stored reconstruction restores the latest effective values and
the same visible timeline notices after leaving the chat, reconnecting, or
relaunching. A changed write emits the ordinary `session.updated` catch-up hint
with the new authoritative event count. They need no parallel live-plugin state
or client-authored event.

## Failure Envelope Parity

Server-authored failures use one canonical envelope. iOS represents it with
`CanonicalFailurePayload` in `Sources/Engine/Protocol/Core/FailurePayload.swift`
and reads it from `/engine` protocol errors and nested `details.failure`
objects.

The live `error` plugin and `agent.turn_failed` plugin do not synthesize
placeholder codes, messages, turns, or recoverability. If the current server
payload omits required failure fields, the plugin transform drops the malformed
event. `turn.failed` is the durable failed-turn record; individual tool
failures remain in `tool.invocation.completed`. The client does not retain
unwritten `error.agent`, `error.tool`, or `error.provider` storage cases.
Cancellation presentation is selected only from the canonical cancellation
code/category, never from an abort RPC or client-authored error string.

Local reachability and pairing failures may still be classified locally when no
server response exists. Server-authored categories, retryability,
recoverability, provider/model/status/error-type fields, and trace references
must flow from the canonical envelope rather than a client taxonomy.

## Registration

`EventRegistry.shared.registerAll()` runs at app startup. The shared production
instance owns the live plugin map; focused tests create isolated registry
instances and register through the same APIs instead of mutating production
state through a reset hook. Registration is the only place a live event plugin
enters the shell, so deleted roots should be removed from both disk and
registration instead of left dormant.
Events that are intentionally diagnostics-only should still register a parser
that returns no `EventResult`; unknown event types are reserved for genuine
drift, not for known server markers.

## Dispatch

The registry owns plugin lookup and keeps dispatch switch-free:

```swift
func dispatch(type: String, transform: () -> (any EventResult)?, context: EventDispatchTarget) {
    guard let box = pluginBox(for: type) else { return }
    guard let result = transform() else { return }
    box.dispatch(result: result, context: context)
}
```

`ChatViewModel` passes itself as the per-call dispatch target and the shared
production registry never retains it. `ChatViewModel+Events.swift` owns
the composed target conformance, while small handler extensions implement its
requirements. The root state object owns
orchestration; streaming, UI queue,
tool-completion, and live event callback installation lives in
`ChatViewModel+RuntimeCallbacks.swift`. The target exposes chat/session
primitives, not fixed product session-list APIs.

Turn completion accumulates token totals and cost in `ContextTrackingState`
before `TurnLifecycleContext` persists those totals with the current turn's
context-window value; the coordinator does not pass a duplicate token snapshot.

## Stored Reconstruction

`Session/Timeline/UnifiedEventTransformer.swift` reconstructs
messages from `SessionEvent` rows. Engine reconstruction helpers own persisted
event decoding support; the transformer is Session-owned because it projects
durable events into chat timeline state. Its transient reconstruction result
contains only messages, accumulated token usage, and the last context size.
`SessionEventType.serverDurableCases` mirrors the server's 13-event storage
contract. The only additional cached type is the explicitly client-local
`stream.thinking_complete` row used to retain expanded thinking across app
restarts. Tool lifecycle rows are joined into their rendered assistant
content; compact boundaries retain their rendered message and update the
context size. Session lifecycle, turn boundaries, and provider-request audits
remain available as durable diagnostics without creating parallel mounted
client state.
Tool identity fields stay primitive: tool, operation,
trace/root invocation ids, theme color, and presentation hints. Reconstruction
projects only those current fields.
When persisted tool lifecycle rows already establish success or error,
that terminal chip remains authoritative over any lower-fidelity current-turn
projection returned in the same reconstruction snapshot.

Unsupported event payloads should remain visible as diagnostics or
transport-only facts. They should not be converted into fixed panels,
repository, assistant-management, skill, curated prompt, or media workflow
models.

## Session Updates

`session.updated` updates only fields the server sends. iOS persists the
resulting `CachedSession` and uses it for the session list and active-session
metadata. The client does not synthesize missing counts from unrelated local
state and does not reconstruct product panels from session metadata.

## Source Guards

Source guards enforce agreement between event registration, the primitive
shell, push authorization, and the current client source tree.
