enum ChatViewportIntent: Equatable, Sendable {
    case userTookOver
    case userReturnedToTail
    case catchUpRequested
    case submitted
    case opened
    case prependBegan
    case prependEnded
    case presentationReset(retainingViewport: Bool)
}

enum ChatViewportMode: Equatable, Sendable {
    case pinned
    case anchored

    mutating func reduce(_ intent: ChatViewportIntent) {
        switch intent {
        case .userTookOver:
            self = .anchored
        case .userReturnedToTail, .catchUpRequested, .opened:
            self = .pinned
        case .submitted, .prependBegan, .prependEnded:
            break
        case .presentationReset(let retainingViewport):
            if !retainingViewport { self = .pinned }
        }
    }
}
