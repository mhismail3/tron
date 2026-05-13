import Foundation

/// Plugin for `agent.job_backgrounded` events — job promoted to background
/// (auto-timeout or user action from iOS).
enum JobBackgroundedPlugin: DispatchableEventPlugin {
    static let eventType = "agent.job_backgrounded"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let jobId: String?
            let reason: String?
            let label: String?
            let invocationId: String?
        }
    }

    struct Result: EventResult {
        let jobId: String
        let reason: String
        let label: String
        let invocationId: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let payload = event.data,
              let jobId = payload.jobId,
              let reason = payload.reason,
              let label = payload.label,
              let invocationId = payload.invocationId else {
            return nil
        }

        return Result(
            jobId: jobId,
            reason: reason,
            label: label,
            invocationId: invocationId
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleJobBackgrounded(r)
    }
}
