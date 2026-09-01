import Foundation

/// The only presentation fact a viewport needs from a transcript install.
/// Rows are immutable; the transition describes identity continuity without
/// asking the viewport to compare model snapshots or infer authority lineage.
struct ChatTranscriptPresentationTransition: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case initial
        case payloadUpdate
        case append
        case prepend
        case shrink
        case replacement
    }

    let kind: Kind
    let previousTag: ChatTranscriptProjectionTag?
    let nextTag: ChatTranscriptProjectionTag
    let previousRowIDs: [String]
    let nextRowIDs: [String]
    let retainedRowIDs: Set<String>
    let removedRowIDs: Set<String>

    init(previous: InstalledChatTranscript?, next: InstalledChatTranscript) {
        self.init(
            previousTag: previous?.tag,
            nextTag: next.tag,
            previousRowIDs: previous?.displayedItems.map(\.id) ?? [],
            nextRowIDs: next.displayedItems.map(\.id)
        )
    }

    init(
        previousTag: ChatTranscriptProjectionTag?,
        nextTag: ChatTranscriptProjectionTag,
        previousRowIDs: [String],
        nextRowIDs: [String]
    ) {
        self.previousTag = previousTag
        self.nextTag = nextTag
        self.previousRowIDs = previousRowIDs
        self.nextRowIDs = nextRowIDs
        retainedRowIDs = Set(previousRowIDs).intersection(nextRowIDs)
        removedRowIDs = Set(previousRowIDs).subtracting(nextRowIDs)

        guard let previousTag else {
            kind = .initial
            return
        }
        guard previousTag.matchesIdentity(of: nextTag) else {
            kind = .replacement
            return
        }
        if previousRowIDs == nextRowIDs {
            kind = .payloadUpdate
        } else if nextRowIDs.starts(with: previousRowIDs) {
            kind = .append
        } else if previousRowIDs.starts(with: nextRowIDs) {
            kind = .shrink
        } else if retainedRowIDs.count > 0,
                  nextRowIDs.first.map({ !previousRowIDs.contains($0) }) == true {
            kind = .prepend
        } else {
            kind = .replacement
        }
    }
}
