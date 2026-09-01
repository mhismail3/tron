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
            item.kind == .message
                && item.role == streaming.role
                && (item.id == streaming.id || item.presentationId == streaming.presentationId)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func hasCanonicalSuccessor(
        for streaming: TranscriptItem,
        in canonical: [TranscriptItem]
    ) -> Bool {
        canonicalSuccessor(for: streaming, in: canonical) != nil
    }
}
