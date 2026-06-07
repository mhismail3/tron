import Foundation

/// Plugin for handling auto-retain failure events.
/// Emitted by the server when an auto-retain pipeline started
/// (`memory_auto_retain_triggered` was persisted) but the summarizer
/// failed to produce a clean output. The pipeline still writes
/// a reduced-quality summary, but iOS needs to signal that the
/// retain quality is low by replacing the "Auto-retaining…" pill with
/// a clear failure label instead of silently transitioning to
/// "retained".
enum MemoryAutoRetainFailedPlugin: DispatchableEventPlugin {
    static let eventType = "agent.memory_auto_retain_failed"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let intervalFired: Int
            let reason: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let intervalFired: Int
        let reason: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(intervalFired: event.data.intervalFired, reason: event.data.reason)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleMemoryAutoRetainFailed(r)
    }
}
