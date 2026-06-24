import Foundation

struct CapabilityProgressStep: Equatable, Identifiable {
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

extension CapabilityInvocationDisplayModel {
    static func progressSteps(
        primitive _: String,
        data: CapabilityInvocationData,
        target _: String?,
        capabilityName: String,
        payloadSummary: String?,
        details _: [String: Any]
    ) -> [CapabilityProgressStep] {
        let terminal = terminalState(data.status)
        let requestDetail = payloadSummary?.nilIfEmpty ?? capabilityName
        let runDetail = data.progressMessage?.nilIfEmpty
            ?? payloadSummary?.nilIfEmpty
            ?? "Running execute"

        return [
            CapabilityProgressStep(
                title: "Request",
                detail: requestDetail,
                iconName: "paperplane",
                state: data.status == .generating ? .current : .completed
            ),
            CapabilityProgressStep(
                title: "Run",
                detail: runDetail,
                iconName: "play.circle",
                state: runState(data.status)
            ),
            CapabilityProgressStep(
                title: "Finish",
                detail: terminal?.detail ?? "Waiting for output",
                iconName: terminal?.iconName ?? "hourglass",
                state: terminal?.state ?? .pending
            )
        ]
    }

    private static func runState(_ status: CapabilityInvocationStatus) -> CapabilityProgressStep.State {
        switch status {
        case .success:
            return .completed
        case .error, .unavailable:
            return .attention
        case .running, .paused:
            return .current
        case .generating:
            return .pending
        }
    }

    private static func terminalState(
        _ status: CapabilityInvocationStatus
    ) -> (detail: String, iconName: String, state: CapabilityProgressStep.State)? {
        switch status {
        case .success:
            return ("Completed", "checkmark.seal", .completed)
        case .error:
            return ("Needs attention", "exclamationmark.triangle", .attention)
        case .unavailable:
            return ("Unavailable", "exclamationmark.triangle", .attention)
        case .generating, .running, .paused:
            return nil
        }
    }
}
