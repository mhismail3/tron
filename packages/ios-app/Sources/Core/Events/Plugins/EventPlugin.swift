import Foundation

/// Marker protocol for event handler results.
/// Each plugin can define its own Result type conforming to this protocol.
protocol EventResult: Sendable {}

// MARK: - Standard Event Data

/// Protocol for event data with standard session identification fields.
/// ALL EventPlugin.EventData types MUST conform to this protocol.
/// Provides default sessionId extraction - override only if returning nil or different field.
protocol StandardEventData: Decodable, Sendable {
    var type: String { get }
    var sessionId: String? { get }
    var timestamp: String? { get }
}

// MARK: - Default Implementations

extension EventPlugin where EventData: StandardEventData {
    /// Default implementation extracts sessionId from standard field.
    /// Override in plugin ONLY if sessionId should return nil or comes from different field.
    static func sessionId(from event: EventData) -> String? {
        event.sessionId
    }
}

// MARK: - Event Plugin Protocol

/// Protocol for self-contained event types.
/// Each event type is defined as a single conforming type that handles:
/// - Parsing from raw JSON data
/// - Session ID extraction for filtering
/// - Transformation to UI-ready results
///
/// Example usage:
/// ```swift
/// enum TextDeltaPlugin: EventPlugin {
///     static let eventType = "agent.text_delta"
///
///     struct EventData: StandardEventData {
///         let type: String
///         let sessionId: String?
///         let timestamp: String?
///         let data: DataPayload
///         struct DataPayload: Decodable, Sendable { let delta: String }
///     }
///
///     struct Result: EventResult { let delta: String }
///
///     // sessionId(from:) is provided by default extension
///     static func transform(_ event: EventData) -> (any EventResult)? {
///         Result(delta: event.data.delta)
///     }
/// }
/// ```
protocol EventPlugin {
    /// The event type string this plugin handles (e.g., "agent.text_delta").
    /// Must be unique across all registered plugins.
    static var eventType: String { get }

    /// The Decodable event struct type representing the raw server event.
    associatedtype EventData: Decodable & Sendable

    /// Parse raw JSON data into typed event.
    /// Default implementation uses JSONDecoder.
    /// Override for custom parsing (e.g., ToolEndPlugin with flexible output formats).
    static func parse(from data: Data) throws -> EventData

    /// Extract sessionId from the parsed event for filtering.
    /// Returns nil for events that don't have a sessionId (e.g., connected, system events).
    static func sessionId(from event: EventData) -> String?

    /// Transform the parsed event to a UI-ready result.
    /// Returns nil if no transformation is needed or the event should be ignored.
    static func transform(_ event: EventData) -> (any EventResult)?
}

/// Default implementation using JSONDecoder for standard events.
extension EventPlugin {
    static func parse(from data: Data) throws -> EventData {
        try JSONDecoder().decode(EventData.self, from: data)
    }
}

// MARK: - Type Erasure for Registry Storage

/// Type-erased wrapper to store heterogeneous EventPlugin types in a collection.
/// This enables the registry to store plugins with different associated types.
protocol EventPluginBox: Sendable {
    var eventType: String { get }
    func parse(data: Data) -> ParsedEventV2?
}

/// Concrete implementation of EventPluginBox for a specific plugin type.
struct EventPluginBoxImpl<P: EventPlugin>: EventPluginBox, Sendable {
    var eventType: String { P.eventType }

    func parse(data: Data) -> ParsedEventV2? {
        do {
            let event = try P.parse(from: data)
            let sessionId = P.sessionId(from: event)
            // Wrap the event in ParsedEventData for Sendable compliance.
            // The actual event is Sendable (per EventPlugin protocol), but we need
            // type erasure so we wrap it.
            let wrappedEvent = ParsedEventData(value: event)
            // Note: The closure captures P.Type which is technically non-Sendable,
            // but metatypes are inherently thread-safe. This is a known Swift
            // limitation that will be addressed in future Swift versions.
            return .plugin(
                type: P.eventType,
                event: wrappedEvent,
                sessionId: sessionId,
                transform: { P.transform(event) }
            )
        } catch {
            logger.warning("Failed to decode \(P.eventType): \(error.localizedDescription)", category: .events)
            return nil
        }
    }
}
