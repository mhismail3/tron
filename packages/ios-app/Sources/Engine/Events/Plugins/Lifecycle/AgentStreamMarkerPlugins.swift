import Foundation

/// Plugin for the projected agent error event.
///
/// Older stream paths can still produce the plain `error` event handled by
/// `ErrorPlugin`; the runtime session stream projects agent failures as
/// `agent.error`.
enum AgentErrorPlugin: DispatchableEventPlugin {
    static let eventType = "agent.error"

    typealias EventData = ErrorPlugin.EventData

    static func transform(_ event: EventData) -> (any EventResult)? {
        ErrorPlugin.transform(event)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        ErrorPlugin.dispatch(result: result, context: context)
    }
}

/// Plugin for explicit agent interruption markers.
///
/// Interruption UI is driven by higher-level chat state. This parser keeps the
/// server event known without surfacing raw partial content.
enum AgentInterruptedPlugin: EventPlugin {
    static let eventType = "agent.interrupted"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        nil
    }
}

/// Plugin for provider/API retry markers.
///
/// Retries are diagnostics-only in the live chat UI; detailed failure rendering
/// happens on terminal error events.
enum AgentRetryPlugin: EventPlugin {
    static let eventType = "agent.retry"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        nil
    }
}

/// Plugin for context warning markers.
///
/// Context warning payloads can include policy/debug details. The client keeps
/// the event recognized and session-scoped without promoting it to UI state.
enum ContextWarningPlugin: EventPlugin {
    static let eventType = "context.warning"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        nil
    }
}
