import Foundation
import Observation
import PhotosUI
import SwiftUI

/// Disposable, session-scoped presentation state. Canonical session facts stay
/// in AppModel and the transcript store; this owner is abandoned on route
/// retirement and rebuilt from canonical snapshot plus bounded draft facts.
@MainActor
@Observable
final class ChatSessionPresentation {
    let sessionID: String

    var photos: [PhotosPickerItem] = []
    var photoImportTarget: SessionPresentationIdentity?
    var attachmentDestination: ChatAttachmentDestination?
    var queuedAttachmentDestination: ChatAttachmentDestination?

    var showContext = false
    var showExtensionDetails = false
    var extensionDetailsGroupID: String?
    var showSettings = false
    var queuedMessageEditor: QueuedMessageEditorRoute?
    var suppressedInteractionScope: ExtensionInteractionScope?

    var mutatingQueuedMessageIDs: Set<String> = []
    var locallyMutatedQueueOperationIDs: Set<String> = []
    var deferredQueueMutationProjection: ChatTranscriptProjectionCapture?
    var queueMutationCommandIsPending = false
    var pendingQueueMutationRevision: Int?
    var queueMutationResolution = ChatQueueMutationResolutionOwner()
    var earlierMessagesOperation = ChatEarlierMessagesOperationOwner()

    var open: ChatOpenPresentationState
    var modelPresentationGeneration: Int?
    var canonicalSubmissionHandoffs = BoundedChatIdentityLedger()

    @ObservationIgnored var photoImportTask: Task<Void, Never>?
    @ObservationIgnored var attachmentPresentationTask: Task<Void, Never>?
    @ObservationIgnored var openingTask: Task<Void, Never>?
    @ObservationIgnored private var unanchoredPrependTask: Task<Void, Never>?
    private var unanchoredPrependGeneration = 0

    init(sessionID: String) {
        self.sessionID = sessionID
        open = ChatOpenPresentationState(sessionID: sessionID)
    }

    func cancelImports() {
        photoImportTask?.cancel()
        photoImportTask = nil
        photoImportTarget = nil
        photos = []
    }

    private func suspendTransientInteractions() {
        attachmentPresentationTask?.cancel()
        attachmentPresentationTask = nil
        attachmentDestination = nil
        queuedAttachmentDestination = nil
        cancelImports()
    }

    /// Backgrounding retires only disposable UI work. An admitted composer
    /// transport is owned by ComposerDraftCoordinator and intentionally remains
    /// alive so an accepted prompt can reconcile after reconnect.
    var needsOpeningResume: Bool {
        open.phase != .ready && openingTask == nil
    }

    func startUnanchoredPrepend(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        unanchoredPrependTask?.cancel()
        unanchoredPrependGeneration &+= 1
        let generation = unanchoredPrependGeneration
        unanchoredPrependTask = Task { [weak self] in
            await operation()
            guard let self, self.unanchoredPrependGeneration == generation else { return }
            self.unanchoredPrependTask = nil
        }
    }

    func suspendForBackground() {
        openingTask?.cancel()
        openingTask = nil
        earlierMessagesOperation.cancel()
        unanchoredPrependGeneration &+= 1
        unanchoredPrependTask?.cancel()
        unanchoredPrependTask = nil
        suspendTransientInteractions()
    }

}

struct ChatTranscriptProjectionCapture: Sendable {
    let snapshot: SessionSnapshot
    let handoff: ChatTranscriptHandoffCommit
    let queuePresentationIDByOperationID: [String: String]
    let tag: ChatTranscriptProjectionTag
}

struct BoundedChatIdentityLedger: Equatable {
    private(set) var ids: Set<String> = []
    private var order: [String] = []

    mutating func formUnion(_ incoming: Set<String>) {
        for id in incoming.sorted() where ids.insert(id).inserted { order.append(id) }
        let excess = order.count - ChatTranscriptPageRequest.maximumItemCount
        guard excess > 0 else { return }
        for id in order.prefix(excess) { ids.remove(id) }
        order.removeFirst(excess)
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    mutating func remove(_ id: String) {
        ids.remove(id)
        order.removeAll { $0 == id }
    }

    mutating func removeAll() {
        ids.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }
}
