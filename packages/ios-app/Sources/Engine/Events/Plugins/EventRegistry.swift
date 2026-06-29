import Foundation

/// Central registry for event plugins.
/// Provides plugin registration and event parsing dispatch.
///
/// Usage:
/// ```swift
/// // At app startup
/// EventRegistry.shared.registerAll()
///
/// // When parsing events
/// if let event = EventRegistry.shared.parse(type: "agent.text_delta", data: data) {
///     switch event {
///     case .plugin(let type, _, _, _, let transform):
///         // Handle plugin event
///     case .unknown(let type):
///         // Unknown event type
///     }
/// }
/// ```
final class EventRegistry: @unchecked Sendable {
    /// Shared singleton instance.
    static let shared = EventRegistry()

    /// Registered plugins keyed by event type.
    ///
    /// INVARIANT: the registry MUST NOT hold strong references to
    /// ViewModels, state objects, or any reference type that owns UI
    /// state. Keys are strings, values are `any EventPluginBox` —
    /// concrete boxes (`EventPluginBoxImpl<P>`, `DispatchablePluginBoxImpl<P>`)
    /// are stateless structs carrying only static metadata about a
    /// plugin type `P`. Plugins themselves are stateless (enums /
    /// types with only static methods), and the dispatch context
    /// (ChatViewModel) is passed as a method parameter per call,
    /// never stored. This shape is deliberate: the registry is a
    /// process-lifetime singleton, so any stored reference would
    /// outlive the ViewModel and create a cycle (ChatViewModel →
    /// EventDispatchCoordinator → EventRegistry → … →
    /// ChatViewModel).
    ///
    /// Guard test: `EventRegistryReferenceCycleTests` in
    /// `Tests/Core/Events/`. If you're about to add a closure or a
    /// reference-typed property to an `EventPluginBox` impl, stop and
    /// re-read this block — almost every such "just add a sidecar
    /// here" change has been the root cause of a retain cycle in
    /// similar event systems.
    private var plugins: [String: any EventPluginBox] = [:]

    /// Lock for thread-safe access to plugins dictionary.
    private let lock = NSLock()

    private init() {}

    // MARK: - Registration

    /// Register a plugin for its event type.
    /// Logs a warning if a plugin is already registered for the same event type.
    func register<P: EventPlugin>(_ plugin: P.Type) {
        lock.lock()
        defer { lock.unlock() }

        if plugins[P.eventType] != nil {
            logger.warning("Overwriting existing plugin for event type: \(P.eventType)", category: .events)
        }
        plugins[P.eventType] = EventPluginBoxImpl<P>()
    }

    /// Register a dispatchable plugin (supports self-dispatch).
    func register<P: DispatchableEventPlugin>(_ plugin: P.Type) {
        lock.lock()
        defer { lock.unlock() }

        if plugins[P.eventType] != nil {
            logger.warning("Overwriting existing plugin for event type: \(P.eventType)", category: .events)
        }
        plugins[P.eventType] = DispatchablePluginBoxImpl<P>()
    }

    /// Get the plugin box for a given event type (used for self-dispatch).
    func pluginBox(for type: String) -> (any EventPluginBox)? {
        lock.lock()
        defer { lock.unlock() }
        return plugins[type]
    }

    /// Register all built-in event plugins.
    /// Call this at app startup to enable the plugin system.
    func registerAll() {
        // Streaming events
        register(TextDeltaPlugin.self)
        register(ThinkingStartPlugin.self)
        register(ThinkingDeltaPlugin.self)
        register(ThinkingEndPlugin.self)
        register(TurnStartPlugin.self)
        register(TurnEndPlugin.self)

        // Capability invocation events
        register(CapabilityInvocationBatchPlugin.self)
        register(CapabilityInvocationGeneratingPlugin.self)
        register(CapabilityInvocationStartedPlugin.self)
        register(CapabilityInvocationOutputPlugin.self)
        register(CapabilityInvocationProgressPlugin.self)
        register(CapabilityInvocationCompletedPlugin.self)
        register(CapabilityRunStatusPlugin.self)

        // Lifecycle events
        register(AgentStartPlugin.self)
        register(CompletePlugin.self)
        register(AgentResponseCompletePlugin.self)
        register(AgentReadyPlugin.self)
        register(ErrorPlugin.self)
        register(CompactionStartedPlugin.self)
        register(CompactionPlugin.self)
        register(ContextClearedPlugin.self)
        register(MessageDeletedPlugin.self)
        register(TurnFailedPlugin.self)

        // Session events
        register(ConnectedPlugin.self)
        register(SessionCreatedPlugin.self)
        register(SessionUpdatedPlugin.self)
        register(SessionArchivedPlugin.self)
        register(SessionUnarchivedPlugin.self)
        register(SessionDeletedPlugin.self)
        register(SessionProcessingChangedPlugin.self)

        // Server events
        register(ServerRestartingPlugin.self)
        register(AuthUpdatedPlugin.self)

        // Display streaming events
        register(DisplayFramePlugin.self)

        logger.info("Registered \(pluginCount) event plugins", category: .events)
    }

    // MARK: - Parsing

    /// Parse event data using the registered plugin for the given type.
    /// Returns nil if parsing fails.
    func parse(type: String, data: Data) -> ParsedEventV2? {
        lock.lock()
        let box = plugins[type]
        lock.unlock()

        guard let box = box else {
            return .unknown(type)
        }
        return box.parse(data: data)
    }

    /// Check if a plugin is registered for the given event type.
    func hasPlugin(for type: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return plugins[type] != nil
    }

    /// Get the number of registered plugins.
    var pluginCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return plugins.count
    }

    /// Get all registered event types.
    var registeredTypes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(plugins.keys).sorted()
    }

    // MARK: - Testing Support

    /// Clear all registered plugins. Only for testing.
    func clearForTesting() {
        lock.lock()
        defer { lock.unlock() }
        plugins.removeAll()
    }
}
