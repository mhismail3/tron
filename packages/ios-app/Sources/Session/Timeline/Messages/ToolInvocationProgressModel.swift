import Foundation

struct ToolProgressStep: Equatable, Identifiable {
    enum State: String, Equatable {
        case pending
        case current
        case completed
        case attention
    }

    let title: String
    let detail: String
    let iconName: String
    let state: State

    var id: String { title }
}

extension ToolInvocationDisplayModel {
    static func progressSteps(
        primitive _: String,
        data: ToolInvocationData,
        target _: String?,
        toolName: String,
        payloadSummary: String?,
        details _: [String: Any]
    ) -> [ToolProgressStep] {
        let terminal = terminalState(data.status)
        let requestDetail = payloadSummary?.nilIfEmpty ?? toolName
        let runDetail = data.progressMessage?.nilIfEmpty
            ?? payloadSummary?.nilIfEmpty
            ?? "Running tool"

        return [
            ToolProgressStep(
                title: "Request",
                detail: requestDetail,
                iconName: "paperplane",
                state: data.status == .generating ? .current : .completed
            ),
            ToolProgressStep(
                title: "Run",
                detail: runDetail,
                iconName: "play.circle",
                state: runState(data.status)
            ),
            ToolProgressStep(
                title: "Finish",
                detail: terminal?.detail ?? "Waiting for output",
                iconName: terminal?.iconName ?? "hourglass",
                state: terminal?.state ?? .pending
            )
        ]
    }

    private static func runState(_ status: ToolInvocationStatus) -> ToolProgressStep.State {
        switch status {
        case .success:
            return .completed
        case .error, .unavailable:
            return .attention
        case .running:
            return .current
        case .generating:
            return .pending
        }
    }

    private static func terminalState(
        _ status: ToolInvocationStatus
    ) -> (detail: String, iconName: String, state: ToolProgressStep.State)? {
        switch status {
        case .success:
            return ("Completed", "checkmark.seal", .completed)
        case .error:
            return ("Needs attention", "exclamationmark.triangle", .attention)
        case .unavailable:
            return ("Unavailable", "exclamationmark.triangle", .attention)
        case .generating, .running:
            return nil
        }
    }
}
