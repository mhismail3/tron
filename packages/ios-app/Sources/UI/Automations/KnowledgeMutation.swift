import SwiftUI
import TronMobileCore

struct XSetupDiagnosticContext: Sendable {
    let viewID: String
    let actionID: String?
    let lifecycleGeneration: Int?
    let connectionID: Int?

    func action(_ actionID: String, lifecycleGeneration: Int?, connectionID: Int?) -> Self {
        Self(viewID: viewID, actionID: actionID,
             lifecycleGeneration: lifecycleGeneration, connectionID: connectionID)
    }
}

enum XSetupDiagnosticEvent: String, Sendable {
    case viewAppeared = "xsetup.view.appeared"
    case viewDisappeared = "xsetup.view.disappeared"
    case bindingSetFalse = "xsetup.binding.set-false"
    case explicitFinish = "xsetup.explicit-finish"
    case destinationRetired = "xsetup.destination-retired"
    case beginAdmitted = "xsetup.begin.admitted"
    case beginReturned = "xsetup.begin.returned"
    case beginStateAssigned = "xsetup.begin.state-assigned"
    case beginRejected = "xsetup.begin.rejected"
    case observerNotObserving = "xsetup.observer.not-observing"
    case observerStarted = "xsetup.observer.started"
    case observerSuppressed = "xsetup.observer.suppressed"
    case observerPublished = "xsetup.observer.published"
}

enum XSetupDiagnosticOrigin: String, Sendable {
    case beginExecutorReturn = "begin-executor-return"
    case explicitStatusRecoveryReturn = "explicit-status-recovery-return"
}

enum XSetupDiagnosticReason: String, Sendable {
    case invalidInput = "invalid-input"
    case destinationUnavailable = "destination-unavailable"
    case destinationChanged = "destination-changed"
    case requestFailed = "request-failed"
    case taskCancelled = "task-cancelled"
    case presentationInactive = "presentation-inactive"
    case mutationReplaced = "mutation-replaced"
    case unknownOrigin = "unknown-origin"
}

enum XSetupDiagnosticOutcome: String, Sendable {
    case appeared
    case disappeared
    case admitted
    case success
    case assigned
    case rejected
    case notObserving = "not-observing"
    case observing
    case suppressed
    case published
}

enum XSetupDiagnostic {
    static func record(
        _ event: XSetupDiagnosticEvent,
        context: XSetupDiagnosticContext,
        appLog: AppLog,
        outcome: XSetupDiagnosticOutcome? = nil,
        origin: XSetupDiagnosticOrigin? = nil,
        reason: XSetupDiagnosticReason? = nil,
        observerAttemptID: String? = nil,
        currentGeneration: Int? = nil,
        currentConnectionID: Int? = nil
    ) {
        let boundaryAt = ISO8601DateFormatter().string(from: Date())
        var fields = [
            "boundaryAt=\(boundaryAt)",
            "viewID=\(context.viewID)"
        ]
        if let actionID = context.actionID { fields.append("actionID=\(actionID)") }
        if let generation = context.lifecycleGeneration { fields.append("lifecycleGeneration=\(generation)") }
        if let connectionID = context.connectionID { fields.append("connectionID=\(connectionID)") }
        if let origin { fields.append("returnOrigin=\(origin.rawValue)") }
        if let reason { fields.append("reason=\(reason.rawValue)") }
        if let observerAttemptID { fields.append("observerAttemptID=\(observerAttemptID)") }
        if let currentGeneration { fields.append("currentGeneration=\(currentGeneration)") }
        if let currentConnectionID { fields.append("currentConnectionID=\(currentConnectionID)") }
        let details = fields.joined(separator: " ")

        // Logger work is deliberately detached from the owner's synchronous state boundary.
        Task {
            await appLog.recordCausal(
                name: event.rawValue, outcome: outcome?.rawValue,
                connectionID: context.connectionID,
                lifecycleGeneration: context.lifecycleGeneration,
                details: details
            )
        }
    }
}

/// The receipt executor owns the accepted command. The sheet retains only its
/// task handle; activity-scoped observers may leave/rejoin without replaying it.
struct KnowledgeMutation {
    let id = UUID()
    let identity: KnowledgeDestinationIdentity
    let task: Task<Void, Error>
    let xSetupDiagnostic: XSetupDiagnosticContext?

    init(identity: KnowledgeDestinationIdentity, task: Task<Void, Error>,
         xSetupDiagnostic: XSetupDiagnosticContext? = nil) {
        self.identity = identity
        self.task = task
        self.xSetupDiagnostic = xSetupDiagnostic
    }
}

struct KnowledgeMutationObserver: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Binding var mutation: KnowledgeMutation?
    @Binding var error: String?
    var failed: (Error) -> Void = { _ in }
    let completed: () -> Void

    func body(content: Content) -> some View {
        content.task(id: PresentationActivityTaskID(source: mutation?.id, presentationActive: activity.allowsPresentationPublication)) {
            guard activity.allowsPresentationPublication else {
                if let context = mutation?.xSetupDiagnostic {
                    XSetupDiagnostic.record(
                        .observerNotObserving, context: context, appLog: model.appLog,
                        outcome: .notObserving,
                        currentGeneration: model.knowledgeDestinationIdentity.lifecycleGeneration,
                        currentConnectionID: model.knowledgePresentationIdentity.connectionID
                    )
                }
                return
            }
            guard let accepted = mutation else { return }
            let context = accepted.xSetupDiagnostic
            let observerAttemptID = context == nil ? nil : UUID().uuidString
            if let context, let observerAttemptID {
                XSetupDiagnostic.record(
                    .observerStarted, context: context, appLog: model.appLog,
                    outcome: .observing, observerAttemptID: observerAttemptID,
                    currentGeneration: model.knowledgeDestinationIdentity.lifecycleGeneration,
                    currentConnectionID: model.knowledgePresentationIdentity.connectionID
                )
            }

            let result = await accepted.task.result
            if Task.isCancelled {
                recordSuppression(.taskCancelled)
                return
            }
            if !activity.allowsPresentationPublication {
                recordSuppression(.presentationInactive)
                return
            }
            if model.knowledgeDestinationIdentity != accepted.identity {
                recordSuppression(.destinationChanged)
                return
            }
            if mutation?.id != accepted.id {
                recordSuppression(.mutationReplaced)
                return
            }
            if let context, let observerAttemptID {
                XSetupDiagnostic.record(
                    .observerPublished, context: context, appLog: model.appLog,
                    outcome: .published, observerAttemptID: observerAttemptID,
                    currentGeneration: model.knowledgeDestinationIdentity.lifecycleGeneration,
                    currentConnectionID: model.knowledgePresentationIdentity.connectionID
                )
            }
            mutation = nil
            switch result {
            case .success: completed()
            case .failure(let failure):
                failed(failure)
                if !(failure is CancellationError) { error = failure.localizedDescription }
            }

            @MainActor func recordSuppression(_ reason: XSetupDiagnosticReason) {
                if let context, let observerAttemptID {
                    XSetupDiagnostic.record(
                        .observerSuppressed, context: context, appLog: model.appLog,
                        outcome: .suppressed, reason: reason,
                        observerAttemptID: observerAttemptID,
                        currentGeneration: model.knowledgeDestinationIdentity.lifecycleGeneration,
                        currentConnectionID: model.knowledgePresentationIdentity.connectionID
                    )
                }
            }
        }
    }
}
