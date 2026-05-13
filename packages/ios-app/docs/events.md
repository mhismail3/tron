# Event Handling

The iOS app handles events through two systems: **plugins** for live WebSocket events and **transformer** for reconstructing history.

## Architecture Overview

```
Live:   WebSocket → EventRegistry → Plugin.parse() → Plugin.dispatch() → ChatViewModel
Stored: EventDatabase → Transformer → ChatMessage array
```

## Event Plugin System

Plugins are self-contained handlers that parse WebSocket JSON, transform to UI-ready results, and dispatch to the appropriate handler.

### Plugin Structure

```swift
enum MyEventPlugin: DispatchableEventPlugin {
    static let eventType = "agent.my_event"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        // Event-specific fields
    }

    struct Result: EventResult {
        // UI-ready fields only
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(/* map fields */)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleMyEvent(r)
    }
}
```

### Plugin Categories

| Category | Location | Events |
|----------|----------|--------|
| Streaming | `Plugins/Streaming/` | text_delta, thinking_delta, turn_start, turn_end, agent_turn |
| Capability invocation | `Plugins/CapabilityInvocation/` | `capability.invocation.*` and `capability.resolution` transport labels carrying capability identity |
| Lifecycle | `Plugins/Lifecycle/` | complete, error, compaction, memory_updated, context_cleared, message_deleted, skill_deactivated, turn_failed |
| Session | `Plugins/Session/` | connected |
| Subagent | `Plugins/Subagent/` | spawned, status, completed, failed, event, result_available |
| Browser | `Plugins/Browser/` | browser_frame, browser_closed |
| Task | `Plugins/Task/` | task.created, task.updated, task.deleted |

### Registration

All plugins registered at app startup:

```swift
// EventRegistry.swift
func registerAll() {
    register(TextDeltaPlugin.self)
    register(CapabilityInvocationStartedPlugin.self)
    register(CapabilityInvocationCompletedPlugin.self)
    // ... all plugins
}
```

## Event Dispatch

`EventDispatchCoordinator` delegates to self-dispatching plugin boxes via `EventRegistry`:

```swift
func dispatch(type: String, transform: () -> (any EventResult)?, context: EventDispatchTarget) {
    guard let result = transform() else { return }
    guard let box = EventRegistry.shared.pluginBox(for: type) else { return }
    box.dispatch(result: result, context: context)
}
```

No switch statement — each plugin carries its own dispatch logic.

### Handler Protocols

Handlers are split into domain-specific protocols:

```swift
@MainActor protocol StreamingEventHandler: AnyObject {
    func handleTextDelta(_ delta: String)
    func handleThinkingDelta(_ delta: String)
}

@MainActor protocol CapabilityInvocationEventHandler: AnyObject {
    func handleCapabilityInvocationStarted(_ result: CapabilityInvocationStartedPlugin.Result)
    func handleCapabilityInvocationCompleted(_ result: CapabilityInvocationCompletedPlugin.Result)
}

// ... TurnLifecycleEventHandler, ContextEventHandler, BrowserEventHandler,
//     SubagentEventHandler, TaskEventHandler, EventDispatchLogger

// Composed target — ChatViewModel conforms to this
@MainActor protocol EventDispatchTarget:
    StreamingEventHandler, CapabilityInvocationEventHandler, TurnLifecycleEventHandler,
    ContextEventHandler, BrowserEventHandler, SubagentEventHandler,
    TaskEventHandler, EventDispatchLogger {}
```

### Implementation

ChatViewModel extensions implement handlers:

```swift
// ChatViewModel+EventDispatchContext.swift
extension ChatViewModel: EventDispatchTarget {
    func handleBrowserFrame(_ result: BrowserFramePlugin.Result) {
        handleBrowserFrameResult(result)
    }
    // ... wrapper methods for existing implementations
}
```

## Event Transformer

Reconstructs chat history from stored events.

### Key Components

| File | Purpose |
|------|---------|
| `UnifiedEventTransformer.swift` | Main transformation logic |
| `Handlers/MessageHandlers.swift` | Message event handling |
| `Handlers/CapabilityInvocationHandlers.swift` | Transport event handling for capability invocation/result records |
| `Reconstruction/` | State tracking during transform |

### Transformation Flow

```swift
// Input: [SessionEvent] or [RawEvent]
// Output: [ChatMessage]

let messages = UnifiedEventTransformer.transform(events: events)
```

### EventTransformable Protocol

Unifies different event types:

```swift
protocol EventTransformable {
    var id: String { get }
    var parentId: String? { get }
    var sessionId: String { get }
    var workspaceId: String { get }
    var type: String { get }
    var timestamp: String { get }
    var sequence: Int { get }
    var payload: [String: AnyCodable] { get }
}
```

Note: `sessionId`, `timestamp`, and `sequence` are non-optional. Both `RawEvent`
and `SessionEvent` conform trivially since they already have all required fields.

### Shared First-Pass Helper: buildCapabilityInvocationMaps

Both `transformPersistedEvents` and `reconstructSessionState` run a shared first
pass over the event array via `buildCapabilityInvocationMaps(from:)`. This builds lookup
dictionaries for transport-level `capability.invocation.started` / `capability.invocation.completed` rows and consumed
subagent event IDs so downstream handlers can resolve provider `tool_use`
content blocks into capability-native invocation messages and filter
already-consumed notifications in a single pass.

`capability.invocation.started`, `capability.invocation.progress`, and
`capability.invocation.completed` are capability lifecycle labels, not renderer
dispatch keys. Payloads carry `CapabilityIdentity` fields when available:
`modelToolName`, `contractId`, `implementationId`, `functionId`, `pluginId`,
`workerId`, `schemaDigest`, `catalogRevision`, `trustTier`, `riskLevel`,
`effectClass`, `traceId`, `rootInvocationId`, and `bindingDecisionId`. Active
chat, dashboard, and detail views render from those fields and generic
schema/result metadata. Unsupported or malformed clean-slate events become
client diagnostics; the app does not synthesize capability identity from retired
built-in names.

### Payload Compatibility

History reconstruction must accept the payload shape emitted by the server, not
only the shape used by local tests. In particular, persisted `message.user`
events from prompt and subagent paths may contain only `content`; their `turn`
field is optional during reconstruction. Renderable persisted event types are
guarded by transformer fixtures so messages, capability invocation chips, notifications, memory
cards, errors, and configuration chips keep reconstructing when payload contracts
change. The test suite also requires every persisted event type to have an
explicit reconstruction disposition: rendered, state-handled, consumed through
assistant content, streaming replay-only, or intentionally no-state.

### Reconstruction Pagination

The `session::reconstruct` engine protocol supports cursor-based pagination:

| Field | Type | Purpose |
|-------|------|---------|
| `limit` | `Int?` | Max events to return per page |
| `beforeSequence` | `Int64?` | Fetch events older than this sequence number |
| `hasMoreEvents` | `Bool` | Whether older pages exist |
| `oldestSequence` | `Int64?` | Sequence of the earliest event in the response (use as next `beforeSequence`) |

`ChatViewModel+Reconstruction.swift` drives the pagination loop: on initial
load it requests the most recent page, then on scroll-up it passes
`oldestSequence` as `beforeSequence` to fetch the next older page.

## Adding a New Event

### 1. Create Self-Dispatching Plugin

```swift
// Core/Events/Plugins/<Category>/MyEventPlugin.swift
enum MyEventPlugin: DispatchableEventPlugin {
    static let eventType = "agent.my_event"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let customField: String
    }

    struct Result: EventResult {
        let customField: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(customField: event.customField)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleMyEvent(r)
    }
}
```

### 2. Register Plugin

```swift
// EventRegistry.swift — registerAll()
register(MyEventPlugin.self)
```

### 3. Add Handler to Domain Protocol

```swift
// EventDispatchContext.swift — add to appropriate domain protocol
func handleMyEvent(_ result: MyEventPlugin.Result)
```

### 4. Implement Handler

```swift
// ChatViewModel+EventDispatchContext.swift
func handleMyEvent(_ result: MyEventPlugin.Result) {
    // Update state based on event
}
```

## Rules

- Plugins handle live WebSocket events only
- Transformer handles history reconstruction only
- All live events flow through `eventPublisherV2`
- Payloads are shared between systems - changes affect both
- Use `StandardEventData` for automatic sessionId extraction
- Keep Result structs flat and UI-ready
- Use `DispatchableEventPlugin` for all new plugins
