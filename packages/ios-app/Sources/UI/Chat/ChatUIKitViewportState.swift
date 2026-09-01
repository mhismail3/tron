import Foundation

struct ChatUIKitSemanticAnchor: Equatable, Sendable {
    let rowID: String
    let topOffset: CGFloat
}

enum ChatUIKitViewportIntent: Equatable, Sendable {
    case followTail
    case preserve(ChatUIKitSemanticAnchor)
}

enum ChatUIKitInteractionPhase: Equatable, Sendable {
    case idle
    case tracking
    case decelerating
}

struct ChatUIKitViewportState: Equatable, Sendable {
    var intent: ChatUIKitViewportIntent = .followTail
    var interaction: ChatUIKitInteractionPhase = .idle
    var appliedVersion: UInt64?
    var transactionID: UInt64 = 0
}

enum ChatUIKitViewportTransactionOutcome: Equatable, Sendable {
    case applied(UInt64)
    case recovered(UInt64)
    case cancelled(UInt64)
}
