import SwiftUI
import TronMobileCore

/// The receipt executor owns the accepted command. The sheet retains only its
/// task handle; activity-scoped observers may leave/rejoin without replaying it.
struct KnowledgeMutation {
    let id = UUID()
    let identity: KnowledgeDestinationIdentity
    let task: Task<Void, Error>
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
            guard activity.allowsPresentationPublication, let accepted = mutation else { return }
            let result = await accepted.task.result
            guard !Task.isCancelled, activity.allowsPresentationPublication,
                  model.knowledgeDestinationIdentity == accepted.identity,
                  mutation?.id == accepted.id else { return }
            mutation = nil
            switch result {
            case .success: completed()
            case .failure(let failure):
                failed(failure)
                if !(failure is CancellationError) { error = failure.localizedDescription }
            }
        }
    }
}

