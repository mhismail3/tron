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
///     case .plugin(let type, _, _, let transform):
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

    /// Register all built-in event plugins.
    /// Call this at app startup to enable the plugin system.
    func registerAll() {
        // Streaming events
        register(TextDeltaPlugin.self)
        register(ThinkingDeltaPlugin.self)
        register(TurnStartPlugin.self)
        register(TurnEndPlugin.self)

        // Tool events
        register(ToolStartPlugin.self)
        register(ToolEndPlugin.self)

        // Lifecycle events
        register(CompletePlugin.self)
        register(ErrorPlugin.self)
        register(CompactionPlugin.self)
        register(ContextClearedPlugin.self)
        register(MessageDeletedPlugin.self)
        register(SkillRemovedPlugin.self)
        register(TurnFailedPlugin.self)

        // Session events
        register(ConnectedPlugin.self)

        // Subagent events
        register(SubagentSpawnedPlugin.self)
        register(SubagentStatusPlugin.self)
        register(SubagentCompletedPlugin.self)
        register(SubagentFailedPlugin.self)
        register(SubagentEventPlugin.self)

        // UI Canvas events
        register(UIRenderStartPlugin.self)
        register(UIRenderChunkPlugin.self)
        register(UIRenderCompletePlugin.self)
        register(UIRenderErrorPlugin.self)
        register(UIRenderRetryPlugin.self)

        // Browser events
        register(BrowserFramePlugin.self)
        register(BrowserClosedPlugin.self)

        // Todo events
        register(TodosUpdatedPlugin.self)

        // Agent turn events
        register(AgentTurnPlugin.self)

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
