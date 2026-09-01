import Foundation

enum ChatTranscriptLayoutConstants {
    static let rowSpacing: CGFloat = 8
    /// The marker owns the final composer affordance with zero stack spacing.
    static let tailAffordanceHeight: CGFloat = 12
}

enum ChatTranscriptUnderflowLayoutPolicy {
    static func minimumContentHeight(containerHeight: CGFloat, bottomInset: CGFloat) -> CGFloat {
        guard containerHeight.isFinite, bottomInset.isFinite else { return 0 }
        return max(0, containerHeight - bottomInset)
    }

    static func isPhysicallyInstalled(_ geometry: ChatTranscriptGeometry) -> Bool {
        guard geometry.isValid else { return false }
        let visibleHeight = max(0, geometry.containerHeight - geometry.bottomInset)
        let minimum = minimumContentHeight(
            containerHeight: geometry.containerHeight,
            bottomInset: geometry.bottomInset
        )
        let contentBottom = geometry.contentHeight + geometry.bottomInset
        let maximumOffset = max(0, contentBottom - geometry.containerHeight)
        if let visibleBottomY = geometry.visibleBottomY {
            guard visibleBottomY.isFinite else { return false }
            if visibleBottomY <= contentBottom + 2,
               geometry.offsetY > maximumOffset + 2 {
                return false
            }
        } else if geometry.offsetY > maximumOffset + 2 {
            return false
        }
        return geometry.contentHeight + 2 >= minimum
            && geometry.contentHeight <= visibleHeight + 2
    }
}

struct ChatQueuedMessageRenderEntry: Identifiable, Hashable {
    let id: String
    let index: Int
    let message: SessionSnapshot.QueuedMessage
}

/// One bounded physical row namespace for canonical, live/runtime, local
/// submission, and authoritative queue presentation. `id` is SwiftUI identity;
/// `semanticID` remains the canonical anchor/geometry identity.
struct ChatPhysicalTranscriptRow: Identifiable, Hashable {
    enum Content: Hashable {
        case transcript(ChatTranscriptRenderItem, isCommitted: Bool)
        case pending(ChatPendingPromptPresentation)
        case outgoing(ChatOutgoingSubmissionPresentation, [PendingAttachment])
        case queued(ChatQueuedMessageRenderEntry)
    }

    let id: String
    let semanticID: String
    let content: Content

    var isPromptLifecycle: Bool {
        switch content {
        case .pending, .outgoing, .queued: true
        case .transcript: false
        }
    }

    var isCanonicalUser: Bool {
        guard case .transcript(let item, _) = content else { return false }
        return switch item {
        case .transcript(let transcript): transcript.role == .user
        case .message(let message): message.item.role == .user
        case .toolRun, .notification: false
        }
    }
}

/// Zero-copy row spine. Ordinary body evaluation constructs only this small
/// adapter; committed/live arrays stay in their installed projection storage.
struct ChatPhysicalTranscriptRows: RandomAccessCollection {
    typealias Index = Int

    let installed: InstalledChatTranscript
    let canonicalAliases: [String: String]

    private var canonicalCount: Int { installed.committedLedger.items.count }
    private var liveCount: Int { installed.liveRegion.items.count }

    /// Canonical and live authority remain separate in `InstalledChatTranscript`.
    /// The installed commit precomputes its one optional display-only boundary
    /// composition so collection indexing stays O(1).
    private var boundaryFusion: ChatPhysicalToolRunFusion? { installed.toolBoundaryFusion }
    private var hasBoundaryFusion: Bool { installed.toolBoundaryFusion != nil }

    var startIndex: Int { 0 }
    var endIndex: Int {
        canonicalCount
            + liveCount
            - (hasBoundaryFusion ? 1 : 0)
            + handoffCount
            + installed.queuedMessages.count
    }

    subscript(position: Int) -> ChatPhysicalTranscriptRow {
        precondition(indices.contains(position))
        var index = position
        if index < canonicalCount {
            if index == canonicalCount - 1, let fusion = boundaryFusion {
                return transcriptRow(.toolRun(fusion.run), isCommitted: true)
            }
            return transcriptRow(installed.committedLedger.items[index], isCommitted: true)
        }
        index -= canonicalCount
        if hasBoundaryFusion { index += 1 }
        if index < liveCount {
            return transcriptRow(installed.liveRegion.items[index], isCommitted: false)
        }
        index -= liveCount
        if handoffCount == 1 {
            if index == 0 { return handoffRow }
            index -= 1
        }
        let message = installed.queuedMessages[index]
        let physicalID = installed.queuePresentationIDByOperationID[message.id]
            ?? "queued-message-\(message.id)"
        let entry = ChatQueuedMessageRenderEntry(
            id: physicalID,
            index: index,
            message: message
        )
        return ChatPhysicalTranscriptRow(
            id: physicalID,
            semanticID: physicalID,
            content: .queued(entry)
        )
    }

    private var handoffCount: Int {
        if case .none = installed.handoff { return 0 }
        return 1
    }

    private var handoffRow: ChatPhysicalTranscriptRow {
        switch installed.handoff {
        case .none:
            preconditionFailure("No lifecycle row exists")
        case .pending(let pending):
            let id = "pending-prompt-\(pending.id)"
            return ChatPhysicalTranscriptRow(
                id: id,
                semanticID: id,
                content: .pending(pending)
            )
        case .outgoing(let outgoing, let attachments):
            return ChatPhysicalTranscriptRow(
                id: outgoing.id,
                semanticID: outgoing.id,
                content: .outgoing(outgoing, attachments)
            )
        }
    }

    private func transcriptRow(
        _ item: ChatTranscriptRenderItem,
        isCommitted: Bool
    ) -> ChatPhysicalTranscriptRow {
        let canonicalID = ChatPhysicalTranscriptRowPolicy.canonicalSemanticID(item)
        let promptAlias = canonicalID.flatMap { canonicalAliases[$0] }
        let toolAlias = installed.toolPhysicalID(forRenderedID: item.id)
        return ChatPhysicalTranscriptRow(
            id: promptAlias ?? toolAlias ?? item.id,
            semanticID: promptAlias == nil ? item.id : (canonicalID ?? item.id),
            content: .transcript(item, isCommitted: isCommitted)
        )
    }
}

struct ChatPhysicalToolRunFusion: Hashable {
    let canonicalRenderedID: String
    let liveRenderedID: String
    let run: ChatToolRunPresentation

    init?(canonical: ChatToolRunPresentation, live: ChatToolRunPresentation) {
        guard let segment = Self.segmentID(for: canonical),
              Self.segmentID(for: live) == segment else { return nil }
        var tools = canonical.tools
        let canonicalIDs = Set(tools.map(\.id))
        // Canonical descriptors win for a handoff duplicate. New live calls
        // retain their exact order after the canonical membership.
        tools.append(contentsOf: live.tools.filter { !canonicalIDs.contains($0.id) })
        guard !tools.isEmpty else { return nil }
        canonicalRenderedID = canonical.id
        liveRenderedID = live.id
        run = ChatToolRunPresentation(tools: tools, anchorID: canonical.anchorID)
    }

    private static func segmentID(for run: ChatToolRunPresentation) -> String? {
        let segments = Set(run.tools.compactMap { tool -> String? in
            guard let segment = tool.toolSegmentId, !segment.isEmpty else { return nil }
            return segment
        })
        guard segments.count == 1,
              run.tools.allSatisfy({ $0.toolSegmentId == segments.first }) else { return nil }
        return segments.first
    }
}

enum ChatPhysicalTranscriptRowPolicy {
    static func rows(
        installed: InstalledChatTranscript,
        canonicalAliases: [String: String]
    ) -> ChatPhysicalTranscriptRows {
        ChatPhysicalTranscriptRows(
            installed: installed,
            canonicalAliases: admittedAliases(
                installed: installed,
                candidates: canonicalAliases
            )
        )
    }

    /// Empty aliases take the O(1) path. Nonempty aliases are page-bounded and
    /// validated through the installed projection's prebuilt identity indexes.
    static func admittedAliases(
        installed: InstalledChatTranscript,
        candidates: [String: String]
    ) -> [String: String] {
        guard !candidates.isEmpty,
              candidates.count <= ChatTranscriptPageRequest.maximumItemCount,
              Set(candidates.values).count == candidates.count else { return [:] }
        var admitted: [String: String] = [:]
        for (canonicalID, physicalID) in candidates {
            guard let item = installed.displayedItem(for: canonicalID) else { continue }
            guard isCanonicalUser(item),
                  canonicalID != physicalID,
                  !installed.containsUnaliasedPhysicalID(physicalID) else { return [:] }
            admitted[canonicalID] = physicalID
        }
        return admitted
    }

    static func canonicalSemanticID(_ item: ChatTranscriptRenderItem) -> String? {
        switch item {
        case .transcript(let transcript): transcript.id
        case .message(let message): message.semanticID
        case .toolRun, .notification: nil
        }
    }

    private static func isCanonicalUser(_ item: ChatTranscriptRenderItem) -> Bool {
        switch item {
        case .transcript(let transcript): transcript.role == .user
        case .message(let message): message.item.role == .user
        case .toolRun, .notification: false
        }
    }
}

enum ChatPhysicalTranscriptReplacementKind: Equatable {
    case none
    case prompt
    case notification
}

enum ChatPhysicalTranscriptReplacementPolicy {
    static func replacement(
        from previous: ChatPhysicalTranscriptRow,
        to next: ChatPhysicalTranscriptRow
    ) -> ChatPhysicalTranscriptReplacementKind {
        guard previous.id == next.id else { return .none }
        if previous.isPromptLifecycle && next.isCanonicalUser { return .prompt }
        if case .transcript(.notification(let old), _) = previous.content,
           case .transcript(.notification(let new), _) = next.content,
           old.showsProgress,
           !new.showsProgress {
            return .notification
        }
        return .none
    }
}

/// A unified ForEach preserves this host while runtime/local content becomes
/// canonical. Exact physical row identity owns admitted in-place updates.
