import Foundation

/// Stable identity contract for the one live-to-canonical boundary. A live
/// assistant row may be removed only when exactly one canonical successor is
/// provable; otherwise both sources remain visible until a later authoritative
/// frame makes the handoff unambiguous.
enum ChatLiveCanonicalIdentityPolicy {
    static func canonicalSuccessor(
        for streaming: TranscriptItem,
        in canonical: [TranscriptItem]
    ) -> TranscriptItem? {
        let matches = canonical.filter { item in
            guard item.kind == .message, item.role == streaming.role else { return false }
            return ChatLiveCanonicalIdentityPolicy.matches(
                streamingID: streaming.id,
                streamingPresentationID: streaming.presentationId,
                canonicalID: item.id,
                canonicalPresentationID: item.presentationId
            )
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func hasCanonicalSuccessor(
        for streaming: TranscriptItem,
        in canonical: [TranscriptItem]
    ) -> Bool {
        canonicalSuccessor(for: streaming, in: canonical) != nil
    }

    /// Identity values are optional at protocol boundaries. Two missing (or
    /// empty) presentation IDs are not evidence of a handoff.
    static func matches(
        streamingID: String,
        streamingPresentationID: String?,
        canonicalID: String,
        canonicalPresentationID: String?
    ) -> Bool {
        let exactID = !streamingID.isEmpty && streamingID == canonicalID
        let sharedPresentationID = streamingPresentationID.map { value in
            !value.isEmpty && canonicalPresentationID == value
        } ?? false
        return exactID || sharedPresentationID
    }
}
