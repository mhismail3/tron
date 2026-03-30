import Foundation

/// Plugin for `process.completed` events — a background process finished.
enum ProcessCompletedPlugin: DispatchableEventPlugin {
    static let eventType = "process.completed"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let parentSessionId: String?
            let processId: String?
            let label: String?
            let success: Bool?
            let exitCode: Int?
            let duration: Int?
            let resultSummary: String?
            let blobId: String?
            let completedAt: String?
        }
    }

    struct Result: EventResult {
        let processId: String
        let label: String
        let success: Bool
        let exitCode: Int?
        let durationMs: Int
        let resultSummary: String
        let blobId: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let payload = event.data,
              let processId = payload.processId,
              let label = payload.label else {
            return nil
        }

        return Result(
            processId: processId,
            label: label,
            success: payload.success ?? false,
            exitCode: payload.exitCode,
            durationMs: payload.duration ?? 0,
            resultSummary: payload.resultSummary ?? "",
            blobId: payload.blobId
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleProcessCompleted(r)
    }
}
