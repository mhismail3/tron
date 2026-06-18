import Foundation

enum ChatTimelineAuxiliaryState: Equatable {
    case loading
    case none

    static func derive(
        initialLoadComplete: Bool,
        messagesIsEmpty: Bool
    ) -> ChatTimelineAuxiliaryState {
        guard messagesIsEmpty else { return .none }
        if !initialLoadComplete {
            return .loading
        }
        return .none
    }

    var title: String {
        switch self {
        case .loading:
            return "Loading messages"
        case .none:
            return ""
        }
    }
}
