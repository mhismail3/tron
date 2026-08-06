/// Server-history state shared by the transcript shell and prompt composer.
///
/// Cached rows are useful immediately, but only an authoritative reconstruction
/// may enable operations that mutate the server session. Keeping this as one
/// model-owned phase prevents the transcript and composer from presenting
/// contradictory loading states.
enum ConversationHistoryPhase: Equatable, Sendable {
    case loading
    case cachedSynchronizing
    case authoritative
    case recoverableFailure(hasCachedTranscript: Bool)

    var hasAuthoritativeSnapshot: Bool {
        self == .authoritative
    }

    var showsCachedTranscript: Bool {
        switch self {
        case .cachedSynchronizing, .recoverableFailure(hasCachedTranscript: true):
            true
        case .loading, .authoritative, .recoverableFailure(hasCachedTranscript: false):
            false
        }
    }

    var allowsDraftEditing: Bool {
        switch self {
        case .cachedSynchronizing, .authoritative, .recoverableFailure(hasCachedTranscript: true):
            true
        case .loading, .recoverableFailure(hasCachedTranscript: false):
            false
        }
    }

    var placeholderText: String {
        switch self {
        case .loading:
            "Loading latest messages"
        case .cachedSynchronizing, .authoritative, .recoverableFailure(hasCachedTranscript: true):
            "Type here"
        case .recoverableFailure(hasCachedTranscript: false):
            "Conversation unavailable"
        }
    }

    var placeholderShowsProgress: Bool {
        self == .loading
    }
}
