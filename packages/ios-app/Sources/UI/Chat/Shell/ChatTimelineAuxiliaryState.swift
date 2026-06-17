import Foundation

enum ChatTimelineAuxiliaryState: Equatable {
    case loading
    case empty
    case none

    static func derive(
        initialLoadComplete: Bool,
        messagesIsEmpty: Bool,
        workspaceDeleted: Bool
    ) -> ChatTimelineAuxiliaryState {
        guard messagesIsEmpty else { return .none }
        if !initialLoadComplete {
            return .loading
        }
        if workspaceDeleted {
            return .none
        }
        return .empty
    }

    var title: String {
        switch self {
        case .loading:
            return "Loading messages"
        case .empty:
            return "Start talking"
        case .none:
            return ""
        }
    }
}
