import Foundation
import SwiftUI

/// Owns the one locally admitted earlier-page transaction. Model and scroll
/// reducers may corroborate loading, but neither can retire this token.
struct ChatEarlierMessagesOperationOwner: Equatable, Sendable {
    typealias Token = UInt64

    private(set) var activeToken: Token?
    private var nextToken: Token = 0

    var isActive: Bool { activeToken != nil }

    mutating func begin() -> Token? {
        guard activeToken == nil else { return nil }
        nextToken &+= 1
        if nextToken == 0 { nextToken = 1 }
        activeToken = nextToken
        return nextToken
    }

    /// Only the currently admitted request may settle the operation. A late
    /// completion from an older request cannot clear a newer page load.
    mutating func settle(_ token: Token) {
        guard activeToken == token else { return }
        activeToken = nil
    }

    mutating func cancel() {
        activeToken = nil
    }
}

enum ChatEarlierMessagesOperationPhase: Equatable, Sendable {
    case available
    case loading
}

enum ChatEarlierMessagesOperationPolicy {
    static func phase(
        owner: ChatEarlierMessagesOperationOwner,
        modelLoading: Bool,
        scrollLoading: Bool
    ) -> ChatEarlierMessagesOperationPhase {
        owner.isActive || modelLoading || scrollLoading ? .loading : .available
    }

    static func isLoading(
        owner: ChatEarlierMessagesOperationOwner,
        modelLoading: Bool,
        scrollLoading: Bool
    ) -> Bool {
        phase(owner: owner, modelLoading: modelLoading, scrollLoading: scrollLoading) == .loading
    }
}

/// `beginPrepend` invokes completion synchronously when strict anchor
/// admission rejects a request. This box distinguishes that rejection from a
/// later coordinator settlement without creating a second local operation.
@MainActor
final class ChatEarlierMessagesOperationAdmission {
    var coordinatorAdmitted = false
}

struct ExtensionInteractionScope: Equatable, Hashable, Sendable {
    let id: String
    let hostEpoch: String
    let presentationRevision: Int

    init(_ interaction: ExtensionInteraction) {
        id = interaction.id
        hostEpoch = interaction.hostEpoch
        presentationRevision = interaction.presentationRevision
    }
}

enum ChatExtensionForegroundPresentation: Equatable {
    case none
    case interaction
    case editorRequest
}

enum ChatExtensionPresentationArbiter {
    /// Semantic questions have deterministic priority over draft replacement
    /// confirmation. The lower-priority request remains in the authoritative
    /// store and is presented after the interaction settles.
    static func presentation(
        modelSettled: Bool,
        hasInteraction: Bool,
        hasEditorRequest: Bool
    ) -> ChatExtensionForegroundPresentation {
        guard modelSettled else { return .none }
        if hasInteraction { return .interaction }
        if hasEditorRequest { return .editorRequest }
        return .none
    }
}

enum ChatExtensionInteractionPolicy {
    static func presentedInteraction(
        _ interactions: [ExtensionInteraction],
        suppressing scope: ExtensionInteractionScope?
    ) -> ExtensionInteraction? {
        interactions.first { interaction in
            guard let scope else { return true }
            return ExtensionInteractionScope(interaction) != scope
        }
    }

    static func shouldClearSuppression(
        _ scope: ExtensionInteractionScope,
        from interactions: [ExtensionInteraction]
    ) -> Bool {
        !interactions.contains { ExtensionInteractionScope($0) == scope }
    }
}

/// Normalized behavior for every prompt lifecycle shell. Unknown wire values
/// are deliberately neutral rather than silently becoming steering.
enum ChatAttachmentEnvelopePolicy {
    /// Pi may retain a bounded attachment-context text part in canonical JSONL
    /// for an attachment-only prompt. It is not user-entered text and must be
    /// admitted only with exact typed attachment evidence.
    static func isBounded(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 4_096,
              value.hasPrefix("[Attached "),
              value.hasSuffix(" context]"),
              !value.contains("\n") else { return false }
        return value.count > "[Attached  context]".count
    }
}

enum ChatPromptLifecycleReplacementPolicy {
    /// Finds one unambiguous queue-to-canonical replacement from two
    /// authoritative projection boundaries. Multiple removals or candidates
    /// deliberately fail closed so a repeated prompt can never borrow the
    /// wrong queue card's visual identity.
    static func canonicalHandoffID(
        previousQueue: [SessionSnapshot.QueuedMessage],
        incomingQueue: [SessionSnapshot.QueuedMessage],
        excludedOperationIDs: Set<String> = [],
        previousCanonicalIDs: Set<String>,
        previousSourceWindow: InstalledChatTranscript.SourceWindow? = nil,
        incomingSourceWindow: InstalledChatTranscript.SourceWindow? = nil,
        incomingTranscript: [TranscriptItem]
    ) -> String? {
        guard Set(previousQueue.map(\.id)).count == previousQueue.count,
              Set(incomingQueue.map(\.id)).count == incomingQueue.count else { return nil }
        let incomingQueueIDs = Set(incomingQueue.map(\.id))
        let removed = previousQueue.enumerated().filter { !incomingQueueIDs.contains($0.element.id) }
        guard removed.count == 1 else { return nil }
        let queue = removed[0].element
        guard !excludedOperationIDs.contains(queue.id) else { return nil }
        let candidates = incomingTranscript.filter { item in
            guard !previousCanonicalIDs.contains(item.id),
                  item.kind == .message, item.role == .user else { return false }
            guard matches(queue: queue, item: item) else { return false }
            return admitsForwardTailCandidate(
                itemID: item.id,
                incomingTranscript: incomingTranscript,
                previousSourceWindow: previousSourceWindow,
                incomingSourceWindow: incomingSourceWindow
            )
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0].id
    }

    private static func admitsForwardTailCandidate(
        itemID: String,
        incomingTranscript: [TranscriptItem],
        previousSourceWindow: InstalledChatTranscript.SourceWindow?,
        incomingSourceWindow: InstalledChatTranscript.SourceWindow?
    ) -> Bool {
        guard let previousSourceWindow, let incomingSourceWindow else {
            // Keep the pure policy usable by legacy fixtures; mounted ChatView
            // always supplies both authoritative source windows.
            return true
        }
        guard isExactForwardEvolution(
            from: previousSourceWindow,
            to: incomingSourceWindow
        ) else { return false }
        guard !previousSourceWindow.ids.isEmpty else { return true }
        return isForwardTailCandidate(
            itemID: itemID,
            previousSourceIDs: previousSourceWindow.ids,
            incomingSourceIDs: incomingTranscript.map(\.id)
        )
    }

    static func isForwardTailCandidate(
        itemID: String,
        previousSourceIDs: [String],
        incomingSourceIDs: [String]
    ) -> Bool {
        guard let previousTailID = previousSourceIDs.last,
              let previousTailIndex = incomingSourceIDs.firstIndex(of: previousTailID),
              let candidateIndex = incomingSourceIDs.firstIndex(of: itemID) else {
            return false
        }
        return candidateIndex > previousTailIndex
    }

    private static func isExactForwardEvolution(
        from previous: InstalledChatTranscript.SourceWindow,
        to next: InstalledChatTranscript.SourceWindow
    ) -> Bool {
        guard previous.hasExactBounds, next.hasExactBounds,
              previous.hasUniqueIDs, next.hasUniqueIDs,
              let previousOriginalStart = previous.originalStart,
              let nextOriginalStart = next.originalStart,
              nextOriginalStart >= previousOriginalStart,
              let previousStart = previous.start, let previousTotal = previous.total,
              let nextStart = next.start, let nextTotal = next.total,
              nextStart >= previousStart,
              nextTotal >= previousTotal else { return false }

        let overlapStart = max(previousStart, nextStart)
        let overlapEnd = min(previousTotal, nextTotal)
        if overlapStart == overlapEnd {
            return previous.ids.isEmpty && nextStart == previousTotal
        }
        guard overlapStart < overlapEnd else { return false }
        let overlapCount = overlapEnd - overlapStart
        let previousOffset = overlapStart - previousStart
        let nextOffset = overlapStart - nextStart
        guard previousOffset >= 0, nextOffset >= 0,
              previousOffset <= previous.ids.count,
              nextOffset <= next.ids.count,
              overlapCount <= previous.ids.count - previousOffset,
              overlapCount <= next.ids.count - nextOffset else { return false }
        let previousEnd = previousOffset + overlapCount
        let nextEnd = nextOffset + overlapCount
        return previous.ids[previousOffset..<previousEnd].elementsEqual(
            next.ids[nextOffset..<nextEnd]
        )
    }

    static func matches(queue: SessionSnapshot.QueuedMessage, item: TranscriptItem) -> Bool {
        let text = (item.content ?? []).compactMap { part -> String? in
            guard part.type == .text, part.attachment == nil else { return nil }
            return part.text
        }.joined()
        if queue.text.isEmpty {
            guard queue.attachmentCount > 0,
                  queue.photoCount != nil,
                  queue.fileAttachmentCount != nil,
                  ChatAttachmentEnvelopePolicy.isBounded(text) else { return false }
        } else {
            guard text == queue.text else { return false }
        }
        let attachments = (item.content ?? []).filter {
            $0.type == .image || $0.attachment != nil
        }
        let photos = attachments.count(where: { $0.type == .image })
        let files = attachments.count - photos
        guard attachments.count == queue.attachmentCount else { return false }
        if let expected = queue.photoCount, expected != photos { return false }
        if let expected = queue.fileAttachmentCount, expected != files { return false }
        // A rich queue with attachments but no typed facts is not exact enough
        // to animate as a card replacement. Empty prompts remain exact.
        if queue.attachmentCount > 0,
           queue.photoCount == nil, queue.fileAttachmentCount == nil {
            return false
        }
        return true
    }
}

enum ChatPromptBehavior: Hashable, Sendable {
    case ordinary
    case steer
    case followUp
    case unknown

    init(rawValue: String?) {
        switch rawValue {
        case nil: self = .ordinary
        case "steer": self = .steer
        case "followUp": self = .followUp
        default: self = .unknown
        }
    }

    init(_ behavior: SessionSnapshot.QueuedMessage.Behavior?) {
        switch behavior {
        case .steer: self = .steer
        case .followUp: self = .followUp
        case nil: self = .ordinary
        }
    }

    var isQueuedKind: Bool {
        self == .steer || self == .followUp
    }

    var title: String {
        switch self {
        case .ordinary: return "Message"
        case .steer: return "Steer next"
        case .followUp: return "Follow up"
        case .unknown: return "Message"
        }
    }

    var queueBehavior: SessionSnapshot.QueuedMessage.Behavior? {
        switch self {
        case .steer: return .steer
        case .followUp: return .followUp
        case .ordinary, .unknown: return nil
        }
    }
}

/// Exact-target presentation-only outgoing state. This is never inserted into
/// the canonical transcript or JSONL; it disappears only after canonical user
/// message reconciliation (or a definitive rejection).
struct ChatOutgoingSubmissionPresentation: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let text: String
    let attachmentIDs: [String]
    let behavior: String?
    let transportActive: Bool
    let preflightCompacting: Bool

    init(
        snapshot: ComposerSubmissionSnapshot,
        transportActive: Bool,
        preflightCompacting: Bool = false
    ) {
        id = snapshot.presentationID
        text = snapshot.outgoingText
        attachmentIDs = snapshot.attachmentIDs
        behavior = snapshot.behavior
        self.transportActive = transportActive
        self.preflightCompacting = preflightCompacting
    }

    var promptBehavior: ChatPromptBehavior { ChatPromptBehavior(rawValue: behavior) }
    var usesQueuedCardVisual: Bool { promptBehavior.isQueuedKind || preflightCompacting }
    var cardBehavior: ChatPromptBehavior { preflightCompacting ? .steer : promptBehavior }
    var cardTitle: String { preflightCompacting ? "Message" : promptBehavior.title }
    var cardDetail: String { preflightCompacting ? "After compaction" : "Sending" }

    var statusTitle: String? {
        switch promptBehavior {
        case .steer: return "Steering next"
        case .followUp: return "Follow-up pending"
        case .ordinary, .unknown: return nil
        }
    }
}

/// Authoritative prompt admission that has not reached canonical JSONL yet.
/// Unlike the composer-owned outgoing row, this survives chat re-navigation
/// because it is reconstructed from the Gateway session snapshot.
struct ChatPendingPromptPresentation: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let createdAt: String?
    let text: String
    let behavior: SessionSnapshot.QueuedMessage.Behavior?
    let attachmentCount: Int
    let photoCount: Int?
    let fileAttachmentCount: Int?
    var attachments: [SessionSnapshot.PromptAttachment]? = nil
    let isCompacting: Bool

    init(snapshot: SessionSnapshot.PendingPrompt, isCompacting: Bool) {
        id = snapshot.id
        createdAt = snapshot.createdAt
        behavior = snapshot.behavior
        text = snapshot.text
        attachmentCount = snapshot.attachmentCount
        photoCount = snapshot.photoCount
        fileAttachmentCount = snapshot.fileAttachmentCount
        attachments = snapshot.attachments
        self.isCompacting = isCompacting
    }

    var promptBehavior: ChatPromptBehavior { ChatPromptBehavior(behavior) }
    var usesQueuedCardVisual: Bool { promptBehavior.isQueuedKind || (isCompacting && behavior == nil) }
    var cardBehavior: ChatPromptBehavior { isCompacting && behavior == nil ? .steer : promptBehavior }
    var cardTitle: String { isCompacting && behavior == nil ? "Message" : promptBehavior.title }
    var cardDetail: String {
        if isCompacting { return "After compaction" }
        return promptBehavior.isQueuedKind ? "Sending" : statusTitle
    }

    var statusTitle: String {
        if isCompacting {
            switch promptBehavior {
            case .steer: return "Steering after compaction"
            case .followUp: return "Follow-up after compaction"
            case .ordinary, .unknown: return "Sending after compaction"
            }
        }
        switch promptBehavior {
        case .steer: return "Steering next"
        case .followUp: return "Follow-up pending"
        case .ordinary, .unknown: return "Sending"
        }
    }
}

/// Suppresses a pending runtime row only when canonical evidence identifies the
/// same prompt. Legacy pending rows without a valid timestamp use one bounded
/// candidate (the newest canonical user message), never an arbitrary history
/// match for repeated text.
struct ChatCanonicalSubmissionAlias: Equatable, Sendable {
    let canonicalID: String
    let presentationID: String
}

enum ChatCanonicalSubmissionAliasPolicy {
    static func alias(
        for receipt: CanonicalSubmissionHandoffReceipt,
        in transcript: [TranscriptItem]
    ) -> ChatCanonicalSubmissionAlias? {
        guard let presentationID = receipt.submission?.presentationID,
              let operationID = receipt.operationID,
              transcript.contains(where: {
                  $0.id == receipt.canonicalID
                      && $0.kind == .message
                      && $0.role == .user
                      && $0.presentationId == operationID
              }) else { return nil }
        return ChatCanonicalSubmissionAlias(
            canonicalID: receipt.canonicalID,
            presentationID: presentationID
        )
    }
}

enum ChatPendingCanonicalSuppressionPolicy {
    /// Returns canonical IDs that replace this exact pending prompt. The IDs
    /// remain canonical; callers use them only in the existing entrance
    /// suppression ledger so the replacement does not replay an insertion.
    static func canonicalIDs(
        for pending: SessionSnapshot.PendingPrompt,
        in transcript: [TranscriptItem]
    ) -> Set<String> {
        let exact = transcript.compactMap { item -> String? in
            guard item.kind == .message,
                  item.role == .user,
                  item.presentationId == pending.id else { return nil }
            return item.id
        }
        if !exact.isEmpty { return exact.count == 1 ? Set(exact) : [] }

        if let pendingDate = pending.createdAt.flatMap(GatewayTimestamp.parse) {
            let candidates: [String] = transcript.compactMap { item in
                guard item.kind == .message,
                      item.role == .user,
                      let itemDate = GatewayTimestamp.parse(item.timestamp),
                      itemDate >= pendingDate,
                      matches(pending, item: item) else { return nil }
                return item.id
            }
            return candidates.count == 1 ? Set(candidates) : []
        }

        // Canonical transcript projections are page-bounded. Restrict the
        // compatibility fallback to that bounded tail and exactly one user row.
        guard let latest = transcript
            .suffix(ChatTranscriptPageRequest.maximumItemCount)
            .reversed()
            .first(where: { $0.kind == .message && $0.role == .user }),
              matches(pending, item: latest) else {
            return []
        }
        return [latest.id]
    }

    static func canonicalIDs(
        for pending: ChatPendingPromptPresentation,
        in transcript: [TranscriptItem]
    ) -> Set<String> {
        canonicalIDs(
            for: SessionSnapshot.PendingPrompt(
                id: pending.id,
                createdAt: pending.createdAt,
                behavior: pending.behavior,
                text: pending.text,
                attachmentCount: pending.attachmentCount,
                photoCount: pending.photoCount,
                fileAttachmentCount: pending.fileAttachmentCount,
                attachments: pending.attachments
            ),
            in: transcript
        )
    }

    /// Physical identity continuity is stricter than compatibility suppression:
    /// only one canonical user row carrying the exact Gateway operation ID may
    /// inherit the pending row's SwiftUI identity.
    static func exactCanonicalID(
        for pending: ChatPendingPromptPresentation,
        in transcript: [TranscriptItem]
    ) -> String? {
        let matches = transcript.compactMap { item -> String? in
            guard item.kind == .message,
                  item.role == .user,
                  item.presentationId == pending.id else { return nil }
            return item.id
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func suppresses(
        _ pending: SessionSnapshot.PendingPrompt,
        in transcript: [TranscriptItem]
    ) -> Bool {
        !canonicalIDs(for: pending, in: transcript).isEmpty
    }

    private static func matches(
        _ pending: SessionSnapshot.PendingPrompt,
        item: TranscriptItem
    ) -> Bool {
        if pending.text.isEmpty {
            guard pending.attachmentCount > 0,
                  pending.photoCount != nil,
                  pending.fileAttachmentCount != nil,
                  ChatAttachmentEnvelopePolicy.isBounded(item.text) else { return false }
        } else {
            guard item.text == pending.text else { return false }
        }
        let attachments = (item.content ?? []).filter {
            $0.type == .image || $0.attachment != nil
        }
        let photoCount = attachments.count(where: { $0.type == .image })
        let fileAttachmentCount = attachments.count - photoCount
        guard attachments.count == pending.attachmentCount else { return false }
        if let expected = pending.photoCount, expected != photoCount { return false }
        if let expected = pending.fileAttachmentCount, expected != fileAttachmentCount { return false }
        return true
    }
}

/// One exact, already-decoded local thumbnail admitted for a canonical media blob.
struct ChatCanonicalMediaPreviewSeed: Equatable, Sendable {
    let blobID: String
    let attachment: PendingAttachment
}

enum ChatCanonicalMediaPreviewPolicy {
    /// Maps only exact local/canonical attachment facts. File blobs preserve the
    /// upload identity on the wire. Images receive content-addressed blob IDs,
    /// so their bounded previews may transfer by order only when the complete
    /// image count and MIME sequence agree.
    static func seeds(
        attachments: [PendingAttachment],
        canonicalItem: TranscriptItem
    ) -> [ChatCanonicalMediaPreviewSeed] {
        guard canonicalItem.kind == .message, canonicalItem.role == .user else { return [] }
        let content = canonicalItem.content ?? []
        var result: [ChatCanonicalMediaPreviewSeed] = []

        let pendingImages = attachments.filter { $0.mimeType.hasPrefix("image/") }
        let canonicalImages = content.filter { $0.type == .image }
        if pendingImages.count == canonicalImages.count,
           zip(pendingImages, canonicalImages).allSatisfy({ pending, canonical in
               pending.previewData != nil
                   && canonical.mimeType == pending.mimeType
                   && canonical.blobId != nil
           }) {
            for (pending, canonical) in zip(pendingImages, canonicalImages) {
                if let blobID = canonical.blobId {
                    result.append(.init(blobID: blobID, attachment: pending))
                }
            }
        }

        for pending in attachments where !pending.mimeType.hasPrefix("image/") {
            guard pending.previewData != nil,
                  let blobID = pending.transportBlobID else { continue }
            let matches = content.filter {
                $0.attachment?.mimeType == pending.mimeType && $0.blobId == blobID
            }
            guard matches.count == 1 else { continue }
            result.append(.init(blobID: blobID, attachment: pending))
        }
        return result
    }
}

/// One immutable presentation commit for the interval before a submitted
/// prompt is represented by canonical JSONL. The outgoing attachment DTOs are
/// copied into this commit so a composer mutation cannot alter an installed row.
enum ChatTranscriptHandoffCommit: Hashable, Sendable {
    case none
    case pending(ChatPendingPromptPresentation)
    case outgoing(
        presentation: ChatOutgoingSubmissionPresentation,
        attachments: [PendingAttachment]
    )

    var outgoingPresentation: ChatOutgoingSubmissionPresentation? {
        guard case .outgoing(let presentation, _) = self else { return nil }
        return presentation
    }

    var outgoingAttachments: [PendingAttachment] {
        guard case .outgoing(_, let attachments) = self else { return [] }
        return attachments
    }

    var pendingPromptPresentation: ChatPendingPromptPresentation? {
        guard case .pending(let presentation) = self else { return nil }
        return presentation
    }

    var promptBehavior: ChatPromptBehavior {
        switch self {
        case .none: return .ordinary
        case .pending(let presentation): return presentation.promptBehavior
        case .outgoing(let presentation, _): return presentation.promptBehavior
        }
    }

    /// Strips upload-only bytes before this value crosses into transcript
    /// presentation. Installed projections retain only row metadata and the
    /// bounded thumbnail preview.
    func frozenForHandoff() -> Self {
        guard case .outgoing(let presentation, let attachments) = self else { return self }
        return .outgoing(
            presentation: presentation,
            attachments: attachments.map { $0.frozenForHandoff() }
        )
    }
}

/// The single ephemeral runtime row shown after the canonical transcript while
/// an active session reports visible working state.
struct ChatRuntimeWorkingPresentation: Equatable {
    let message: String
    let retryMessage: String?
    let phase: SessionPhase
    let usesAmbientBottomIndicator: Bool

    init?(phase: SessionPhase, retry: RetryState?) {
        guard phase.isActive else { return nil }
        self.phase = phase
        message = Self.defaultMessage(for: phase)
        retryMessage = retry.map {
            "Attempt \($0.attempt)\($0.maxAttempts.map { " of \($0)" } ?? "")"
        }
        usesAmbientBottomIndicator = phase == .running && retry == nil
    }

    private static func defaultMessage(for phase: SessionPhase) -> String {
        switch phase {
        case .running: "Tron is working"
        case .compacting: "Compacting context"
        case .retrying: "Retrying provider"
        case .interrupted, .idle: ""
        }
    }
}

enum ChatPhysicalTailClassification: Equatable, Sendable {
    case aligned
    case belowViewport
    case aboveViewport
    case incomplete
    case stale
}

/// Presentation-only physical proof for the mounted tail marker. It is never
/// a second scroll position: the native scroll anchor remains the routine
/// owner and this evidence only permits a bounded repair of proven drift.
struct ChatPhysicalTailEvidence: Equatable, Sendable {
    let presentationEpoch: Int
    let layoutEpoch: Int
    let semanticFrameRevision: Int
    let markerFrame: CGRect
    let visibleBounds: CGRect
    let signedDisplacement: CGFloat
    let classification: ChatPhysicalTailClassification

    static func make(
        presentationEpoch: Int,
        layoutEpoch: Int,
        semanticFrameRevision: Int,
        markerFrame: CGRect?,
        visibleBounds: CGRect?,
        tolerance: CGFloat = 2
    ) -> Self {
        guard let markerFrame, let visibleBounds,
              markerFrame.minX.isFinite, markerFrame.maxX.isFinite,
              markerFrame.minY.isFinite, markerFrame.maxY.isFinite,
              visibleBounds.minX.isFinite, visibleBounds.maxX.isFinite,
              visibleBounds.minY.isFinite, visibleBounds.maxY.isFinite else {
            return Self(
                presentationEpoch: presentationEpoch,
                layoutEpoch: layoutEpoch,
                semanticFrameRevision: semanticFrameRevision,
                markerFrame: markerFrame ?? .zero,
                visibleBounds: visibleBounds ?? .zero,
                signedDisplacement: .nan,
                classification: .incomplete
            )
        }
        let displacement = markerFrame.maxY - visibleBounds.maxY
        let classification: ChatPhysicalTailClassification
        if abs(displacement) <= tolerance { classification = .aligned }
        else if displacement < 0 { classification = .belowViewport }
        else { classification = .aboveViewport }
        return Self(
            presentationEpoch: presentationEpoch,
            layoutEpoch: layoutEpoch,
            semanticFrameRevision: semanticFrameRevision,
            markerFrame: markerFrame,
            visibleBounds: visibleBounds,
            signedDisplacement: displacement,
            classification: classification
        )
    }
}

struct ChatTranscriptGeometry: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    /// Native visible content edges in the scroll content coordinate space.
    /// Synthetic tests may omit them and use the legacy-field fallback.
    let visibleTopY: CGFloat?
    let visibleBottomY: CGFloat?

    init(
        offsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat = 0,
        visibleTopY: CGFloat? = nil,
        visibleBottomY: CGFloat? = nil
    ) {
        self.offsetY = offsetY
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.bottomInset = bottomInset
        self.visibleTopY = visibleTopY
        self.visibleBottomY = visibleBottomY
    }

    init(_ geometry: ScrollGeometry) {
        self.init(
            offsetY: geometry.contentOffset.y,
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height,
            bottomInset: geometry.contentInsets.bottom,
            visibleTopY: geometry.visibleRect.minY,
            visibleBottomY: geometry.visibleRect.maxY
        )
    }

    static let zero = ChatTranscriptGeometry(offsetY: 0, contentHeight: 0, containerHeight: 0)
    // Zero-height content is a valid empty pinned presentation. The mounted
    // tail marker supplies the physical proof once SwiftUI has laid it out.
    var isValid: Bool { contentHeight >= 0 && containerHeight > 0 }
    var distanceFromBottom: CGFloat {
        // `visibleRect` is SwiftUI's native, atomically derived content-space
        // viewport. Do not reconstruct it from offset/container/inset fields,
        // which can settle in different LazyVStack/keyboard layout frames.
        let rawDistance = if let visibleBottomY {
            contentHeight + bottomInset - visibleBottomY
        } else {
            contentHeight + bottomInset - offsetY - containerHeight
        }
        guard rawDistance.isFinite else { return .greatestFiniteMagnitude }
        return max(0, rawDistance)
    }
    static let catchUpDistance: CGFloat = 16
    /// A marker frame, rather than clamped distance, is authoritative for
    /// short content. Under-sized content is bottom-aligned by the native
    /// anchor, so blank space after its edge is expected rather than drift.
    var isPastBottomEdge: Bool {
        guard isValid else { return false }
        let contentBottom = contentHeight + bottomInset
        guard contentBottom.isFinite, offsetY.isFinite else { return false }
        // A visible edge beyond a short content edge is normal bottom-aligned
        // blank space. Physical tail evidence handles deliberate overshoot.
        if contentBottom <= containerHeight + 2 { return false }
        if let visibleBottomY {
            return visibleBottomY.isFinite && visibleBottomY > contentBottom + 2
        }
        return offsetY > contentBottom - containerHeight + 2
    }
    var isAtBottom: Bool { isValid && !isPastBottomEdge && distanceFromBottom <= 80 }
    var isAtExactBottom: Bool { isValid && !isPastBottomEdge && distanceFromBottom <= 2 }
    /// Physical scroll settling commonly stops a few points above the computed
    /// edge because content insets and pixel rounding update in separate frames.
    /// This tighter-than-"near bottom" boundary is user-equivalent to reaching
    /// the tail and is used to dismiss catch-up without requiring a tap.
    var isAtCatchUpBoundary: Bool {
        isValid && !isPastBottomEdge && distanceFromBottom <= Self.catchUpDistance
    }

    /// Opening accepts short content at the native bottom anchor. For overflow
    /// content the visible tail edge still rejects a transient overshoot.
    var isPlausibleOpeningViewport: Bool {
        guard isValid else { return false }
        let contentBottom = contentHeight + bottomInset
        guard contentBottom.isFinite, offsetY.isFinite else { return false }
        if contentBottom <= containerHeight + 2 { return true }
        if let visibleBottomY {
            return visibleBottomY.isFinite && visibleBottomY <= contentBottom + 2
        }
        let maximumOffset = contentBottom - containerHeight
        return offsetY <= maximumOffset + 2
    }

    func hasViewportChange(from previous: Self) -> Bool {
        abs(containerHeight - previous.containerHeight) > 0.5
            || abs(bottomInset - previous.bottomInset) > 0.5
    }
}

enum ChatOpenPresentationPhase: Equatable {
    case opening
    case positioning
    case ready
    case failed(String)
}

struct ChatOpenPresentationState: Equatable {
    let sessionID: String
    private(set) var epoch: Int = 0
    private(set) var phase: ChatOpenPresentationPhase = .opening

    mutating func begin(retainingVisiblePresentation: Bool = false) -> Int {
        epoch &+= 1
        phase = retainingVisiblePresentation ? .ready : .opening
        return epoch
    }

    mutating func beginPinnedResumePositioning(sessionID: String) -> Int? {
        guard sessionID == self.sessionID, phase == .ready else { return nil }
        epoch &+= 1
        // A retained native scroll view may resume at a displaced offset. Put
        // the opaque cover back before issuing the exact tail correction so no
        // intermediate top-origin motion can become a presented chat frame.
        phase = .positioning
        return epoch
    }

    mutating func installAuthoritativeBaseline(sessionID: String, epoch: Int) -> Bool {
        guard sessionID == self.sessionID, epoch == self.epoch, phase == .opening else { return false }
        // Keep the opaque opening surface mounted while the exact physical tail
        // is positioned. Authoritative installation alone is not proof that a
        // lazy transcript has a valid visible viewport.
        phase = .positioning
        return true
    }

    mutating func installPositionedViewport(sessionID: String, epoch: Int) -> Bool {
        guard sessionID == self.sessionID, epoch == self.epoch, phase == .positioning else { return false }
        phase = .ready
        return true
    }

    mutating func fail(sessionID: String, epoch: Int, message: String) -> Bool {
        guard sessionID == self.sessionID, epoch == self.epoch else { return false }
        phase = .failed(message)
        return true
    }
}

struct ChatTranscriptPageRequest: Equatable {
    static let maximumItemCount = 512

    let sessionID: String
    let presentationGeneration: Int
    let runtimeGeneration: String
    let before: Int
    let expectedTotal: Int
    let expectedNextEntryID: String?

    func canInstall(
        sessionID: String,
        presentationGeneration: Int,
        runtimeGeneration: String,
        transcriptStart: Int?,
        transcriptTotal: Int?,
        firstTranscriptID: String?
    ) -> Bool {
        self.sessionID == sessionID
            && self.presentationGeneration == presentationGeneration
            && self.runtimeGeneration == runtimeGeneration
            && transcriptStart == before
            && transcriptTotal == expectedTotal
            && firstTranscriptID == expectedNextEntryID
    }

    func canInstallPage(
        start: Int,
        end: Int,
        total: Int,
        itemCount: Int,
        visibleItemCount: Int
    ) -> Bool {
        end == before
            && start >= 0
            && start <= end
            && itemCount == end - start
            && itemCount <= Self.maximumItemCount
            && total == expectedTotal
            && total >= before
            && total - before == visibleItemCount
    }
}

struct ChatStreamingResponseSignature: Equatable {
    let itemID: String
    let parts: [ChatMessagePart]
    let errorMessage: String?

    init?(_ item: TranscriptItem?) {
        guard let item else { return nil }
        let visibleParts = ChatTranscriptPresentation.messageParts(in: item).filter { part in
            guard case .content(let content) = part else { return true }
            return content.type != .toolCall
        }
        let visibleError = (item.errorMessage ?? "").isEmpty ? nil : item.errorMessage
        guard !visibleParts.isEmpty || visibleError != nil else { return nil }
        itemID = item.id
        parts = visibleParts
        errorMessage = visibleError
    }
}

struct ChatResponseState: Equatable {
    let sessionID: String
    let canonicalEntryCount: Int
    let tailEntryID: String?
    let streaming: ChatStreamingResponseSignature?

    init(snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionId
        canonicalEntryCount = snapshot.transcriptTotal ?? snapshot.transcript.count
        tailEntryID = snapshot.transcript.last?.id
        streaming = ChatStreamingResponseSignature(snapshot.streaming)
    }
}

/// Heavy protocol values are owned separately from the timeline descriptor
/// spine and are combined only when an installed transcript resolves a detail.
struct ChatToolPayload: Hashable, Sendable {
    let request: JSONValue?
    let response: JSONValue?
    let content: String
    let fallbackContent: JSONValue?
}

struct ChatToolDescriptor: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let error: Bool
    let startedAt: String?
    let completedAt: String?
    let durationMs: Int?
    let lastProgressAt: String?
    let progressSequence: Int?
    let outputTruncated: Bool
    let extensionOrigin: ExtensionToolOrigin?
    let toolSegmentId: String?
    let groupId: String?
    let groupIndex: Int?
    let groupCount: Int?
    let groupFinalized: Bool?

    init(_ tool: ChatToolPresentation) {
        id = tool.id
        title = tool.title
        subtitle = tool.subtitle
        error = tool.error
        startedAt = tool.startedAt
        completedAt = tool.completedAt
        durationMs = tool.durationMs
        lastProgressAt = tool.lastProgressAt
        progressSequence = tool.progressSequence
        outputTruncated = tool.outputTruncated
        extensionOrigin = tool.extensionOrigin
        toolSegmentId = tool.toolSegmentId
        groupId = tool.groupId
        groupIndex = tool.groupIndex
        groupCount = tool.groupCount
        groupFinalized = tool.groupFinalized
    }

    var isRunning: Bool { subtitle == "Running" || subtitle == "Invocation" }

    func elapsedMilliseconds(at date: Date = .now) -> Int? {
        if isRunning, let durationMs {
            return max(0, durationMs)
        }
        guard let start = ToolTiming.date(startedAt) else {
            return durationMs.map { max(0, $0) }
        }
        if isRunning {
            return ToolTiming.milliseconds(from: start, to: date)
        }
        return ToolTiming.resolvedDuration(
            startedAt: startedAt,
            completedAt: completedAt,
            fallback: durationMs
        )
    }
}

struct ChatToolPayloadIndex: Hashable, Sendable {
    private let values: [String: ChatToolPayload]

    init(_ values: [String: ChatToolPayload] = [:]) {
        self.values = values
    }

    var callIDs: Set<String> { Set(values.keys) }
    var count: Int { values.count }

    func payload(for callID: String) -> ChatToolPayload? { values[callID] }

    func resolving(_ descriptor: ChatToolDescriptor) -> ChatToolPresentation? {
        guard let payload = values[descriptor.id] else { return nil }
        return ChatToolPresentation(descriptor: descriptor, payload: payload)
    }

    func replacing(_ replacements: [String: ChatToolPayload]) -> Self {
        var updated = values
        for (callID, payload) in replacements { updated[callID] = payload }
        return Self(updated)
    }
}

struct ChatToolPresentation: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let request: JSONValue?
    let response: JSONValue?
    let content: String
    let fallbackContent: JSONValue?
    let error: Bool
    let startedAt: String?
    let completedAt: String?
    let durationMs: Int?
    let lastProgressAt: String?
    let progressSequence: Int?
    let outputTruncated: Bool
    let extensionOrigin: ExtensionToolOrigin?
    let toolSegmentId: String?
    let groupId: String?
    let groupIndex: Int?
    let groupCount: Int?
    let groupFinalized: Bool?

    init(
        id: String,
        title: String,
        subtitle: String,
        request: JSONValue?,
        response: JSONValue?,
        content: String,
        fallbackContent: JSONValue?,
        error: Bool,
        startedAt: String?,
        completedAt: String?,
        durationMs: Int?,
        lastProgressAt: String?,
        progressSequence: Int?,
        outputTruncated: Bool = false,
        extensionOrigin: ExtensionToolOrigin? = nil,
        toolSegmentId: String? = nil,
        groupId: String? = nil,
        groupIndex: Int? = nil,
        groupCount: Int? = nil,
        groupFinalized: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.request = request
        self.response = response
        self.content = content
        self.fallbackContent = fallbackContent
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
        self.lastProgressAt = lastProgressAt
        self.progressSequence = progressSequence
        self.outputTruncated = outputTruncated || response?.hasToolOutputTruncationMetadata == true
        self.extensionOrigin = extensionOrigin
        self.toolSegmentId = toolSegmentId
        self.groupId = groupId
        self.groupIndex = groupIndex
        self.groupCount = groupCount
        self.groupFinalized = groupFinalized
    }

    init(descriptor: ChatToolDescriptor, payload: ChatToolPayload) {
        id = descriptor.id
        title = descriptor.title
        subtitle = descriptor.subtitle
        request = payload.request
        response = payload.response
        content = payload.content
        fallbackContent = payload.fallbackContent
        error = descriptor.error
        startedAt = descriptor.startedAt
        completedAt = descriptor.completedAt
        durationMs = descriptor.durationMs
        lastProgressAt = descriptor.lastProgressAt
        progressSequence = descriptor.progressSequence
        outputTruncated = descriptor.outputTruncated
        extensionOrigin = descriptor.extensionOrigin
        toolSegmentId = descriptor.toolSegmentId
        groupId = descriptor.groupId
        groupIndex = descriptor.groupIndex
        groupCount = descriptor.groupCount
        groupFinalized = descriptor.groupFinalized
    }

    var descriptor: ChatToolDescriptor { ChatToolDescriptor(self) }
    var payload: ChatToolPayload {
        ChatToolPayload(
            request: request,
            response: response,
            content: content,
            fallbackContent: fallbackContent
        )
    }

    var isRunning: Bool { subtitle == "Running" || subtitle == "Invocation" }

    func elapsedMilliseconds(at date: Date = .now) -> Int? {
        if isRunning, let durationMs {
            return max(0, durationMs)
        }
        guard let start = ToolTiming.date(startedAt) else {
            return durationMs.map { max(0, $0) }
        }
        if isRunning {
            return ToolTiming.milliseconds(from: start, to: date)
        }
        return ToolTiming.resolvedDuration(
            startedAt: startedAt,
            completedAt: completedAt,
            fallback: durationMs
        )
    }

}

private extension JSONValue {
    var hasToolOutputTruncationMetadata: Bool {
        guard let object = objectValue else { return false }
        if object["truncation"]?.objectValue?["truncated"]?.boolValue == true { return true }
        return object["details"]?.objectValue?["truncation"]?.objectValue?["truncated"]?.boolValue == true
    }
}

/// Runtime timestamps are authoritative for live/current-Gateway calls. Pi JSONL
/// does not yet persist execution timing, so older canonical calls use their call
/// and result entry timestamps as a conservative observed interval.
enum ToolTiming {
    static func date(_ value: String?) -> Date? {
        value.flatMap(GatewayTimestamp.parse)
    }

    static func intervalMilliseconds(start: String?, end: String?) -> Int? {
        guard let start = date(start), let end = date(end) else { return nil }
        return milliseconds(from: start, to: end)
    }

    static func milliseconds(from start: Date, to end: Date) -> Int {
        let interval = end.timeIntervalSince(start)
        guard interval.isFinite else { return 0 }
        let milliseconds = interval * 1_000
        guard milliseconds.isFinite else { return interval.sign == .minus ? 0 : Int.max }
        let rounded = milliseconds.rounded()
        guard rounded <= Double(Int.max) else { return Int.max }
        guard rounded >= Double(Int.min) else { return 0 }
        return max(0, Int(rounded))
    }

    /// Runtime duration is authoritative when supplied by the Gateway because
    /// it is measured from the tool callback with a monotonic clock. Timestamp
    /// subtraction is only the compatibility fallback for older canonical
    /// history that has no retained execution metadata.
    static func resolvedDuration(
        startedAt: String?,
        completedAt: String?,
        fallback: Int?
    ) -> Int? {
        if let fallback { return max(0, fallback) }
        return intervalMilliseconds(start: startedAt, end: completedAt)
    }

    static func format(milliseconds: Int) -> String {
        let milliseconds = max(0, milliseconds)
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        if milliseconds < 60_000 { return String(format: "%.1fs", Double(milliseconds) / 1_000) }
        let totalSeconds = milliseconds / 1_000
        if totalSeconds < 3_600 { return "\(totalSeconds / 60)m \(totalSeconds % 60)s" }
        return "\(totalSeconds / 3_600)h \((totalSeconds % 3_600) / 60)m"
    }

    static func observedDuration(callTimestamp: String, result: TranscriptItem) -> Int? {
        resolvedDuration(
            startedAt: result.startedAt ?? callTimestamp,
            completedAt: result.completedAt ?? result.timestamp,
            fallback: result.durationMs
        )
    }
}

enum ChatTokenCountPresentation {
    static func compact(_ count: Int) -> String {
        let count = max(0, count)
        guard count >= 1_000 else { return String(count) }

        let thousands = Double(count) / 1_000
        let precision = thousands >= 100 ? 0 : 1
        var value = String(format: "%.*f", precision, thousands)
        if value.hasSuffix(".0") { value.removeLast(2) }
        return "\(value)K"
    }

    static func beforeCompaction(_ count: Int) -> String {
        "\(compact(count)) \(count == 1 ? "token" : "tokens") before compaction"
    }
}

enum ChatNotificationTone: Hashable, Sendable {
    case accent
    case information
    case warning
    case error
    case neutral
}

enum ChatNotificationMaterial: Hashable, Sendable {
    case flat
    case glass
}

struct ChatNotificationPresentation: Hashable, Identifiable, Sendable {
    let id: String
    let semanticID: String?
    let icon: String
    let title: String
    let detail: String?
    let body: String?
    let tone: ChatNotificationTone
    let material: ChatNotificationMaterial

    var hasDetailSheet: Bool { material == .glass && body?.isEmpty == false }
    var showsProgress: Bool {
        semanticID == nil && (
            id == "runtime-working"
                || id.hasPrefix("notification-compaction-slot-")
                || id.hasPrefix("notification-compaction-operation-")
        )
    }

    static func canonical(
        _ item: TranscriptItem,
        globalOrdinal: Int?
    ) -> ChatNotificationPresentation? {
        let summaryBody = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let admittedSummary = summaryBody?.isEmpty == false ? summaryBody : nil
        switch item.kind {
        case .compaction:
            let operationIdentity = item.presentationId == item.id
                ? nil
                : "notification-compaction-operation-\(item.presentationId)"
            return ChatNotificationPresentation(
                id: operationIdentity
                    ?? globalOrdinal.map { "notification-compaction-slot-\($0)" }
                    ?? "notification-compaction-\(item.id)",
                semanticID: item.id,
                icon: "arrow.down.right.and.arrow.up.left",
                title: "Context compacted",
                detail: item.tokensBefore.map(ChatTokenCountPresentation.beforeCompaction),
                body: admittedSummary,
                tone: .accent,
                material: admittedSummary == nil ? .flat : .glass
            )
        case .branchSummary:
            return ChatNotificationPresentation(
                id: "notification-\(item.id)", semanticID: item.id,
                icon: "arrow.triangle.branch", title: "Branch summary",
                detail: nil, body: admittedSummary, tone: .accent,
                material: admittedSummary == nil ? .flat : .glass
            )
        case .modelChange:
            return ChatNotificationPresentation(
                id: "notification-\(item.id)", semanticID: item.id,
                icon: "cpu", title: "Model changed",
                detail: item.modelRef?.displayDescription ?? "Changed",
                body: nil, tone: .accent, material: .flat
            )
        case .thinkingChange:
            return ChatNotificationPresentation(
                id: "notification-\(item.id)", semanticID: item.id,
                icon: "brain", title: "Thinking changed",
                detail: item.level?.capitalized ?? "Changed",
                body: nil, tone: .accent, material: .flat
            )
        case .label:
            return ChatNotificationPresentation(
                id: "notification-\(item.id)", semanticID: item.id,
                icon: "bookmark",
                title: item.label.map { "Bookmark: \($0)" } ?? "Bookmark removed",
                detail: nil, body: nil, tone: .neutral, material: .flat
            )
        case .message, .bash, .customMessage, .customEntry:
            return nil
        }
    }

    static func runtime(in snapshot: SessionSnapshot) -> [ChatNotificationPresentation] {
        var values: [ChatNotificationPresentation] = []
        let canonicalCompactionInstalled = currentCanonicalCompactionIsInstalled(in: snapshot)
        if snapshot.compactionQueued == true, !canonicalCompactionInstalled {
            values.append(ChatNotificationPresentation(
                id: "runtime-compaction-queued",
                semanticID: nil,
                icon: "arrow.down.right.and.arrow.up.left",
                title: "Compaction queued",
                detail: "After current work",
                body: nil,
                tone: .accent,
                material: .flat
            ))
        }
        // The Gateway can publish the canonical compaction entry one commit
        // before phase and queued metadata settle. Exact tail ordinals prove
        // the current entry even when bounded configuration metadata follows
        // it; inexact windows deliberately retain runtime chrome.
        if let working = ChatRuntimeWorkingPresentation(
            phase: snapshot.phase,
            retry: snapshot.retry
        ), !working.usesAmbientBottomIndicator,
           !canonicalCompactionInstalled {
            let exactNextOrdinal: Int? = {
                guard snapshot.phase == .compacting,
                      let start = snapshot.transcriptStart,
                      let total = snapshot.transcriptTotal,
                      start >= 0, total >= start,
                      total - start == snapshot.transcript.count else { return nil }
                return total
            }()
            let operationIdentity = snapshot.operation.flatMap { operation in
                operation.kind == .compaction
                    ? operation.id.map { "notification-compaction-operation-\($0)" }
                    : nil
            }
            values.append(ChatNotificationPresentation(
                id: operationIdentity
                    ?? exactNextOrdinal.map { "notification-compaction-slot-\($0)" }
                    ?? "runtime-working",
                semanticID: nil,
                icon: working.phase == .compacting
                    ? "arrow.down.right.and.arrow.up.left"
                    : working.phase == .retrying ? "arrow.clockwise" : "sparkles",
                title: working.message,
                detail: working.retryMessage,
                body: nil,
                tone: working.phase == .retrying ? .warning : .accent,
                material: .flat
            ))
        }
        // Ambient extension status/widget/service chrome is intentionally
        // retired. Canonical runtime phase remains the only ephemeral row owner.
        return values
    }

    private static func currentCanonicalCompactionIsInstalled(
        in snapshot: SessionSnapshot
    ) -> Bool {
        guard snapshot.phase == .compacting || snapshot.compactionQueued == true,
              let start = snapshot.transcriptStart,
              let total = snapshot.transcriptTotal,
              start >= 0, total >= start,
              total - start == snapshot.transcript.count,
              Set(snapshot.transcript.map(\.id)).count == snapshot.transcript.count else {
            return false
        }
        for item in snapshot.transcript.reversed() {
            switch item.kind {
            case .modelChange, .thinkingChange, .label:
                continue
            case .compaction:
                return true
            case .message, .bash, .branchSummary, .customMessage, .customEntry:
                return false
            }
        }
        return false
    }
}

enum ChatToolInvocationOrdering {
    /// Detail surfaces reverse canonical/group order only at the final
    /// presentation boundary. Mutable timestamps never relocate an invocation.
    static func reverseChronological(_ tools: [ChatToolDescriptor]) -> [ChatToolDescriptor] {
        tools.reversed()
    }

    static func reverseChronological(_ tools: [ChatToolPresentation]) -> [ChatToolPresentation] {
        tools.reversed()
    }
}

struct ChatToolRunPresentation: Hashable, Identifiable, Sendable {
    let tools: [ChatToolDescriptor]
    let anchorID: String

    init(tools: [ChatToolDescriptor], anchorID: String? = nil) {
        self.tools = tools
        // Finalized Gateway group identity is stable before execution starts
        // and survives live-to-canonical settlement. Legacy rows retain their
        // first call only when no finalized group metadata exists.
        self.anchorID = anchorID ?? tools.first(where: { $0.groupFinalized == true })?.groupId
            ?? tools.first?.id ?? "empty"
    }

    init(tools: [ChatToolPresentation], anchorID: String? = nil) {
        self.init(tools: tools.map(\.descriptor), anchorID: anchorID)
    }


    var id: String { "tool-run-" + anchorID }
    var reverseChronologicalTools: [ChatToolDescriptor] {
        ChatToolInvocationOrdering.reverseChronological(tools)
    }
    var groupIDs: [String] {
        var seen = Set<String>()
        return tools.compactMap(\.groupId).filter { seen.insert($0).inserted }
    }
    var displayCount: Int {
        var countByGroup: [String: Int] = [:]
        var ungrouped = 0
        for tool in tools {
            if let groupId = tool.groupId, tool.groupFinalized == true {
                countByGroup[groupId] = max(countByGroup[groupId] ?? 0, tool.groupCount ?? 0)
            } else {
                ungrouped += 1
            }
        }
        return max(tools.count, ungrouped + countByGroup.values.reduce(0, +))
    }
    /// Group cardinality describes declaration completeness, not execution
    /// liveness. A paged or temporarily partial finalized group is still
    /// historical evidence when every visible descriptor is terminal.
    var isRunning: Bool { tools.contains(where: \.isRunning) }
    var failureCount: Int { tools.filter(\.error).count }
    var title: String {
        if displayCount == 1, let tool = tools.first {
            return ToolDetailPresentation.displayTitle(for: tool.title)
        }
        return "\(isRunning ? "Using" : "Used") \(displayCount) tools"
    }
    var status: String? {
        if failureCount > 0 { return "\(failureCount) failed" }
        return isRunning ? "in progress" : nil
    }
    /// Accumulated tool time is the sum of each invocation, rather than the
    /// wall-clock span of the run. This remains correct when tools overlap and
    /// keeps the Used tools detail surface consistent with its individual rows.
    func elapsedMilliseconds(at date: Date = .now) -> Int? {
        let values = tools.compactMap { $0.elapsedMilliseconds(at: date) }
        guard !values.isEmpty else { return nil }
        return values.reduce(into: 0) { total, value in
            total = total > Int.max - value ? Int.max : total + value
        }
    }
}

struct ChatThinkingSegment: Hashable, Identifiable, Sendable {
    let id: String
    let text: String
}

struct ChatThinkingRun: Hashable, Identifiable, Sendable {
    /// The contiguous-run ordinal is stable when bounded live frames drop
    /// leading thinking parts. Word-level reveal remains row-local state.
    let id: String
    let segments: [ChatThinkingSegment]
}

enum ChatTranscriptRowIdentity {
    static func assistantMessage(_ item: TranscriptItem) -> String {
        item.role == .assistant ? item.presentationId : item.id
    }

    static func messageSlice(
        _ item: TranscriptItem,
        parts: [ChatMessagePart],
        slice: Int
    ) -> String {
        let first = assistantMessage(item)
        if slice == 0 { return first }
        if let part = parts.first { return "\(first)-slice-\(part.id)" }
        return "\(first)-footer-\(slice)"
    }
}

enum ChatMessagePart: Hashable, Identifiable, Sendable {
    case content(ContentPart)
    case thinking(ChatThinkingRun)

    var id: String {
        switch self {
        case .content(let part): "content-\(part.ordinal)"
        case .thinking(let run): "thinking-\(run.id)"
        }
    }
}

struct ChatMessagePresentation: Hashable, Identifiable, Sendable {
    let id: String
    let semanticID: String
    let item: TranscriptItem
    let parts: [ChatMessagePart]
    let streaming: Bool
    let showsFooter: Bool

}

enum ChatTranscriptRenderItem: Hashable, Identifiable, Sendable {
    case transcript(TranscriptItem)
    case message(ChatMessagePresentation)
    case toolRun(ChatToolRunPresentation)
    case notification(ChatNotificationPresentation)

    var id: String {
        switch self {
        case .transcript(let item): item.id
        case .message(let message): message.id
        case .toolRun(let run): run.id
        case .notification(let notification): notification.id
        }
    }
}

/// A flat immutable row spine. Sparse tool updates share the assembly-produced
/// base and replace only affected indexes; an assembly always starts a fresh
/// base, so overlays never form a chain.
struct ChatTranscriptItems: RandomAccessCollection, Hashable, Sendable {
    typealias Index = Int

    private let canonicalBase: [ChatTranscriptRenderItem]
    private let canonicalOverrides: [Int: ChatTranscriptRenderItem]
    private let liveBase: [ChatTranscriptRenderItem]
    private let liveOverrides: [Int: ChatTranscriptRenderItem]

    init(canonical: [ChatTranscriptRenderItem], live: [ChatTranscriptRenderItem] = []) {
        canonicalBase = canonical
        canonicalOverrides = [:]
        liveBase = live
        liveOverrides = [:]
    }

    private init(
        canonicalBase: [ChatTranscriptRenderItem],
        canonicalOverrides: [Int: ChatTranscriptRenderItem],
        liveBase: [ChatTranscriptRenderItem],
        liveOverrides: [Int: ChatTranscriptRenderItem]
    ) {
        self.canonicalBase = canonicalBase
        self.canonicalOverrides = canonicalOverrides
        self.liveBase = liveBase
        self.liveOverrides = liveOverrides
    }

    /// Materializes the canonical spine with sparse replacements for hashing,
    /// projection comparison, and the bounded ledger; render paths use the
    /// collection directly.
    var canonical: [ChatTranscriptRenderItem] {
        guard !canonicalOverrides.isEmpty else { return canonicalBase }
        var result = canonicalBase
        for (index, item) in canonicalOverrides { result[index] = item }
        return result
    }

    var live: [ChatTranscriptRenderItem] {
        guard !liveOverrides.isEmpty else { return liveBase }
        var result = liveBase
        for (index, item) in liveOverrides { result[index] = item }
        return result
    }

    var canonicalCount: Int { canonicalBase.count }
    var sparseOverrideCount: Int { canonicalOverrides.count + liveOverrides.count }
    var startIndex: Int { 0 }
    var endIndex: Int { canonicalBase.count + liveBase.count }

    subscript(position: Int) -> ChatTranscriptRenderItem {
        precondition(indices.contains(position))
        if position < canonicalBase.count {
            return canonicalOverrides[position] ?? canonicalBase[position]
        }
        let liveIndex = position - canonicalBase.count
        return liveOverrides[liveIndex] ?? liveBase[liveIndex]
    }

    func replacingCanonical(
        _ replacements: [Int: ChatTranscriptRenderItem]
    ) -> ChatTranscriptItems {
        guard !replacements.isEmpty else { return self }
        var overrides = canonicalOverrides
        for (index, item) in replacements {
            precondition(canonicalBase.indices.contains(index))
            if item == canonicalBase[index] {
                overrides.removeValue(forKey: index)
            } else {
                overrides[index] = item
            }
        }
        return ChatTranscriptItems(
            canonicalBase: canonicalBase,
            canonicalOverrides: overrides,
            liveBase: liveBase,
            liveOverrides: liveOverrides
        )
    }

    func replacingLive(_ live: [ChatTranscriptRenderItem]) -> ChatTranscriptItems {
        ChatTranscriptItems(
            canonicalBase: canonicalBase,
            canonicalOverrides: canonicalOverrides,
            liveBase: live,
            liveOverrides: [:]
        )
    }

    func replacingLiveRows(
        _ replacements: [Int: ChatTranscriptRenderItem]
    ) -> ChatTranscriptItems {
        guard !replacements.isEmpty else { return self }
        var overrides = liveOverrides
        for (index, item) in replacements {
            precondition(liveBase.indices.contains(index))
            if item == liveBase[index] {
                overrides.removeValue(forKey: index)
            } else {
                overrides[index] = item
            }
        }
        return ChatTranscriptItems(
            canonicalBase: canonicalBase,
            canonicalOverrides: canonicalOverrides,
            liveBase: liveBase,
            liveOverrides: overrides
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.count == rhs.count && lhs.elementsEqual(rhs)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        for item in self { hasher.combine(item) }
    }
}

struct ChatSemanticIndex: Hashable, Sendable {
    let canonical: [String: String]
    let live: [String: String]

    init(canonical: [String: String], live: [String: String] = [:]) {
        self.canonical = canonical
        self.live = live
    }

    subscript(key: String) -> String? { live[key] ?? canonical[key] }

    func allKeysSatisfy(_ predicate: (String) -> Bool) -> Bool {
        canonical.keys.allSatisfy(predicate) && live.keys.allSatisfy(predicate)
    }

    func allValuesSatisfy(_ predicate: (String) -> Bool) -> Bool {
        canonical.values.allSatisfy(predicate) && live.values.allSatisfy(predicate)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.canonical == rhs.canonical, lhs.live == rhs.live { return true }
        let keys = Set(lhs.canonical.keys)
            .union(lhs.live.keys)
            .union(rhs.canonical.keys)
            .union(rhs.live.keys)
        return keys.allSatisfy { lhs[$0] == rhs[$0] }
    }

    func hash(into hasher: inout Hasher) {
        let keys = Set(canonical.keys).union(live.keys).sorted()
        hasher.combine(keys.count)
        for key in keys {
            hasher.combine(key)
            hasher.combine(self[key])
        }
    }
}

struct ChatTranscriptIDs: RandomAccessCollection, Hashable, Sendable {
    typealias Index = Int

    private final class CanonicalStorage: @unchecked Sendable {
        let values: [String]
        let identityDigest: UInt64

        init(_ values: [String]) {
            self.values = values
            identityDigest = ChatTranscriptIDs.digest(values)
        }
    }

    private let canonicalStorage: CanonicalStorage
    let live: [String]

    init(canonical: [String], live: [String]) {
        canonicalStorage = CanonicalStorage(canonical)
        self.live = live
    }

    private init(canonicalStorage: CanonicalStorage, live: [String]) {
        self.canonicalStorage = canonicalStorage
        self.live = live
    }

    var canonical: [String] { canonicalStorage.values }
    var startIndex: Int { 0 }
    var endIndex: Int { canonicalStorage.values.count + live.count }

    subscript(position: Int) -> String {
        precondition(indices.contains(position))
        return position < canonicalStorage.values.count
            ? canonicalStorage.values[position]
            : live[position - canonicalStorage.values.count]
    }

    func replacingLive(_ live: [String]) -> ChatTranscriptIDs {
        ChatTranscriptIDs(canonicalStorage: canonicalStorage, live: live)
    }

    func sharesCanonicalStorage(with other: ChatTranscriptIDs) -> Bool {
        canonicalStorage === other.canonicalStorage
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.canonicalStorage === rhs.canonicalStorage {
            return lhs.live == rhs.live
        }
        return lhs.count == rhs.count && lhs.elementsEqual(rhs)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        hasher.combine(Self.digest(live, startingAt: canonicalStorage.identityDigest))
    }

    private static func digest(
        _ values: [String],
        startingAt initial: UInt64 = 14_695_981_039_346_656_037
    ) -> UInt64 {
        var result = initial
        for value in values {
            for byte in value.utf8 {
                result ^= UInt64(byte)
                result &*= 1_099_511_628_211
            }
            result ^= 0xff
            result &*= 1_099_511_628_211
        }
        return result
    }
}

func == (lhs: ChatTranscriptIDs, rhs: [String]) -> Bool {
    lhs.count == rhs.count && lhs.elementsEqual(rhs)
}

func == (lhs: [String], rhs: ChatTranscriptIDs) -> Bool { rhs == lhs }

struct ChatTranscriptTimeline: Hashable, Sendable {
    let items: ChatTranscriptItems
    let preferredSemanticIDByRenderedID: ChatSemanticIndex
    let renderedIDBySemanticID: ChatSemanticIndex
    private let renderedIDs: ChatTranscriptIDs
    private let canonicalRenderedIDSet: Set<String>
    private let liveRenderedIDSet: Set<String>
    private let internallyConsistent: Bool

    init(
        items: ChatTranscriptItems,
        preferredSemanticIDByRenderedID: ChatSemanticIndex,
        renderedIDBySemanticID: ChatSemanticIndex
    ) {
        self.items = items
        self.preferredSemanticIDByRenderedID = preferredSemanticIDByRenderedID
        self.renderedIDBySemanticID = renderedIDBySemanticID
        let canonicalIDs = (0..<items.canonicalCount).map { items[$0].id }
        let liveIDs = items.live.map(\.id)
        let ids = ChatTranscriptIDs(canonical: canonicalIDs, live: liveIDs)
        let canonicalIDSet = Set(canonicalIDs)
        let liveIDSet = Set(liveIDs)
        renderedIDs = ids
        canonicalRenderedIDSet = canonicalIDSet
        liveRenderedIDSet = liveIDSet
        let containsID = { canonicalIDSet.contains($0) || liveIDSet.contains($0) }
        internallyConsistent = canonicalIDSet.count == canonicalIDs.count
            && liveIDSet.count == liveIDs.count
            && canonicalIDSet.isDisjoint(with: liveIDSet)
            && preferredSemanticIDByRenderedID.allKeysSatisfy(containsID)
            && renderedIDBySemanticID.allValuesSatisfy(containsID)
    }

    private init(
        items: ChatTranscriptItems,
        preferredSemanticIDByRenderedID: ChatSemanticIndex,
        renderedIDBySemanticID: ChatSemanticIndex,
        renderedIDs: ChatTranscriptIDs,
        canonicalRenderedIDSet: Set<String>,
        liveRenderedIDSet: Set<String>,
        internallyConsistent: Bool
    ) {
        self.items = items
        self.preferredSemanticIDByRenderedID = preferredSemanticIDByRenderedID
        self.renderedIDBySemanticID = renderedIDBySemanticID
        self.renderedIDs = renderedIDs
        self.canonicalRenderedIDSet = canonicalRenderedIDSet
        self.liveRenderedIDSet = liveRenderedIDSet
        self.internallyConsistent = internallyConsistent
    }

    var ids: ChatTranscriptIDs { renderedIDs }
    var isInternallyConsistent: Bool { internallyConsistent }
    func sharesCanonicalIdentitySpine(with other: ChatTranscriptTimeline) -> Bool {
        renderedIDs.sharesCanonicalStorage(with: other.renderedIDs)
    }
    func containsID(_ id: String) -> Bool {
        canonicalRenderedIDSet.contains(id) || liveRenderedIDSet.contains(id)
    }

    /// Sparse replacements are permitted only after the kernel proves every row
    /// identity unchanged, so the cached identity spine and semantic maps remain
    /// the exact canonical values rather than being rebuilt or guessed.
    func replacingCanonicalRows(
        _ replacements: [Int: ChatTranscriptRenderItem]
    ) -> ChatTranscriptTimeline {
        ChatTranscriptTimeline(
            items: items.replacingCanonical(replacements),
            preferredSemanticIDByRenderedID: preferredSemanticIDByRenderedID,
            renderedIDBySemanticID: renderedIDBySemanticID,
            renderedIDs: renderedIDs,
            canonicalRenderedIDSet: canonicalRenderedIDSet,
            liveRenderedIDSet: liveRenderedIDSet,
            internallyConsistent: internallyConsistent
        )
    }

    func replacingLiveRows(
        _ replacements: [Int: ChatTranscriptRenderItem]
    ) -> ChatTranscriptTimeline {
        ChatTranscriptTimeline(
            items: items.replacingLiveRows(replacements),
            preferredSemanticIDByRenderedID: preferredSemanticIDByRenderedID,
            renderedIDBySemanticID: renderedIDBySemanticID,
            renderedIDs: renderedIDs,
            canonicalRenderedIDSet: canonicalRenderedIDSet,
            liveRenderedIDSet: liveRenderedIDSet,
            internallyConsistent: internallyConsistent
        )
    }

    func appendingLive(_ live: ChatTranscriptTimeline) -> ChatTranscriptTimeline {
        precondition(live.items.canonicalCount == 0)
        let canonicalIDSet = canonicalRenderedIDSet
        // Canonical rows win collisions individually. A single reconnect
        // collision must not discard unrelated live activity rows.
        let admittedLiveItems = live.items.live.filter { !canonicalIDSet.contains($0.id) }
        let admittedLiveIDs = live.renderedIDs.live.filter { !canonicalIDSet.contains($0) }
        let liveIDSet = Set(admittedLiveItems.map(\.id))
        let ids = renderedIDs.replacingLive(admittedLiveIDs)
        let preferred = ChatSemanticIndex(
            canonical: preferredSemanticIDByRenderedID.canonical,
            live: live.preferredSemanticIDByRenderedID.live.filter {
                liveIDSet.contains($0.key)
            }
        )
        let reverse = ChatSemanticIndex(
            canonical: renderedIDBySemanticID.canonical,
            live: live.renderedIDBySemanticID.live.filter {
                liveIDSet.contains($0.value)
            }
        )
        return ChatTranscriptTimeline(
            items: items.replacingLive(admittedLiveItems),
            preferredSemanticIDByRenderedID: preferred,
            renderedIDBySemanticID: reverse,
            renderedIDs: ids,
            canonicalRenderedIDSet: canonicalIDSet,
            liveRenderedIDSet: liveIDSet,
            internallyConsistent: internallyConsistent && live.internallyConsistent
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items
            && lhs.preferredSemanticIDByRenderedID == rhs.preferredSemanticIDByRenderedID
            && lhs.renderedIDBySemanticID == rhs.renderedIDBySemanticID
    }

    func hash(into hasher: inout Hasher) {
        // Equality implies identical rendered identities. Hashing the cached
        // split spine keeps sparse/live publications shallow; content and maps
        // may legally collide and are still compared exactly by `==`.
        hasher.combine(renderedIDs)
    }
}

enum ChatToolbarTitleLayout {
    static let defaultContainerWidth: CGFloat = 402
    static let horizontalControlReservation: CGFloat = 152
    static let minimumWidth: CGFloat = 80
    static let maximumWidth: CGFloat = 360

    static func width(containerWidth: CGFloat) -> CGFloat {
        min(maximumWidth, max(minimumWidth, containerWidth - horizontalControlReservation))
    }
}

struct ChatAttachmentMenuIdentity: Hashable {
    let sessionID: String
    let actionsEnabled: Bool
}

struct ChatAttachmentMenuState: Hashable {
    let sessionID: String
    let phase: SessionPhase?
    let isTranscriptReady: Bool
    let isSending: Bool

    var actionsEnabled: Bool {
        ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: isTranscriptReady,
            phase: phase,
            isSending: isSending
        )
    }

    var identity: ChatAttachmentMenuIdentity {
        ChatAttachmentMenuIdentity(sessionID: sessionID, actionsEnabled: actionsEnabled)
    }
}

enum ChatAttachmentAvailabilityPolicy {
    static func actionsEnabled(
        isTranscriptReady: Bool,
        phase: SessionPhase?,
        isSending: Bool
    ) -> Bool {
        guard isTranscriptReady, phase != nil else { return false }
        // Uploads stage independently of prompt transport. Keep the attachment
        // menu enabled while a send is being acknowledged and throughout active
        // steering; otherwise SwiftUI dims the Menu label and blocks legitimate
        // staging even though no attachment mutation is in flight.
        return true
    }
}

enum ChatUnreadResponsePolicy {
    static func shouldMarkUnread(
        previous: ChatResponseState?,
        current: ChatResponseState,
        userScrolledAway: Bool
    ) -> Bool {
        guard let previous, previous.sessionID == current.sessionID, userScrolledAway else { return false }
        return previous.canonicalEntryCount != current.canonicalEntryCount
            || previous.tailEntryID != current.tailEntryID
            || previous.streaming != current.streaming
    }
}

/// Presentation-only filtering for Pi's canonical transcript. Configuration
/// entries before the first conversational entry describe session bootstrap
/// state and belong in Manage Session, not in the chat transcript. Later
/// configuration entries remain visible as compact change notifications.
enum ChatTranscriptPresentation {
    static func items(in snapshot: SessionSnapshot) -> [TranscriptItem] {
        ChatTranscriptProjectionKernel.visibleItems(in: snapshot)
    }

    /// The public cold oracle delegates to the one raw-fragment/global-assembler
    /// kernel. No view constructs or repairs a timeline independently.
    static func timeline(
        in snapshot: SessionSnapshot,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        workRecorder: ChatTranscriptProjectionWorkRecorder? = nil
    ) -> ChatTranscriptTimeline {
        ChatTranscriptProjectionKernel.cold(
            snapshot: snapshot,
            performanceSignposts: performanceSignposts,
            workRecorder: workRecorder
        ).timeline
    }

    /// Attachment extraction remains a pure presentation helper; the projection
    /// kernel owns streaming suffix assembly.
    static func attachmentParts(in item: TranscriptItem) -> [ContentPart] {
        (item.content ?? []).filter { $0.type == .image || $0.attachment != nil }
    }

    /// Coalesces only adjacent canonical thinking parts. The transcript remains
    /// authoritative; this projection simply turns line-oriented progress into
    /// one readable paragraph while preserving stable identities for animation.
    static func messageParts(in item: TranscriptItem) -> [ChatMessagePart] {
        var projected: [ChatMessagePart] = []
        var thinkingSegments: [ChatThinkingSegment] = []
        var thinkingRunID: String?

        func flushThinking() {
            guard let thinkingRunID, !thinkingSegments.isEmpty else { return }
            projected.append(.thinking(ChatThinkingRun(id: thinkingRunID, segments: thinkingSegments)))
            thinkingSegments.removeAll(keepingCapacity: true)
        }

        for part in item.content ?? [] {
            guard part.type == .thinking else {
                flushThinking()
                thinkingRunID = nil
                projected.append(.content(part))
                continue
            }
            guard let runOrdinal = part.thinkingRunOrdinal else { continue }
            let runID = "thinking-run-\(runOrdinal)"
            if let thinkingRunID, thinkingRunID != runID {
                flushThinking()
            }
            thinkingRunID = runID
            let segments = normalizedThinkingSegments(in: part)
            guard !segments.isEmpty else { continue }
            thinkingSegments.append(contentsOf: segments)
        }
        flushThinking()
        return projected
    }

    private static func normalizedThinkingSegments(in part: ContentPart) -> [ChatThinkingSegment] {
        (part.text ?? "")
            .split(whereSeparator: \.isNewline)
            .enumerated()
            .compactMap { lineIndex, line in
                let words = line.split(whereSeparator: \.isWhitespace)
                guard !words.isEmpty else { return nil }
                let presentation = words.joined(separator: " ")
                return ChatThinkingSegment(id: "thinking-\(part.ordinal):line:\(lineIndex)", text: presentation)
            }
    }

}
