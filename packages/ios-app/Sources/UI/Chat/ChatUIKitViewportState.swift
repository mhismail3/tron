import Foundation

struct ChatUIKitSemanticAnchor: Equatable, Sendable {
    let rowID: String
    /// The pre-mutation ordinal is the bounded fallback when a row is removed
    /// or its physical identity changes during a gesture.
    let ordinal: Int
    /// Pixel distance from the captured row's top to the viewport top.
    let topOffset: CGFloat

    init(rowID: String, ordinal: Int = 0, topOffset: CGFloat) {
        self.rowID = rowID
        self.ordinal = max(0, ordinal)
        self.topOffset = topOffset.isFinite ? topOffset : 0
    }
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

struct ChatUIKitPresentationActivity: Equatable, Sendable {
    let isPresented: Bool
    let isSceneActive: Bool
    let isCovered: Bool
    let generation: UInt64

    var isActive: Bool { isPresented && isSceneActive && !isCovered }

    static func active(generation: UInt64) -> Self {
        Self(isPresented: true, isSceneActive: true, isCovered: false, generation: generation)
    }

    static func inactive(generation: UInt64) -> Self {
        Self(isPresented: false, isSceneActive: false, isCovered: true, generation: generation)
    }
}

struct ChatUIKitViewportState: Equatable, Sendable {
    var intent: ChatUIKitViewportIntent = .followTail
    var interaction: ChatUIKitInteractionPhase = .idle
    var appliedGeneration: UInt64?
    var appliedVersion: UInt64?
    var transactionID: UInt64 = 0
}

enum ChatUIKitViewportTransactionOutcome: Equatable, Sendable {
    case applied(UInt64)
    case recovered(UInt64)
    case stale(UInt64)
    case failed(UInt64, String)
}
