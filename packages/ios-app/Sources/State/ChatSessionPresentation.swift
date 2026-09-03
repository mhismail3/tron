import Foundation
import Observation
import PhotosUI
import SwiftUI

enum ChatOpeningSurfaceAction: Equatable {
    case none
    case begin
    case waitForCurrentThenBeginIfNeeded
}

enum ChatOpeningSurfacePolicy {
    static func action(
        surfaceActive: Bool,
        hasOpeningTask: Bool,
        needsOpeningResume: Bool
    ) -> ChatOpeningSurfaceAction {
        guard surfaceActive else { return .none }
        if hasOpeningTask { return .waitForCurrentThenBeginIfNeeded }
        return needsOpeningResume ? .begin : .none
    }
}

enum ChatOpeningAttemptPolicy {
    /// Bounds the complete open → synchronize → local projection → ready-frame
    /// transaction. Inner Gateway and physical-tail operations retain their
    /// narrower deadlines; this is the final fail-closed presentation boundary.
    static let deadline: Duration = .seconds(30)
    static let timeoutMessage = "Opening took too long. The session is safe; retry this conversation."
    static let unsettledMessage = "The conversation changed while opening. Please retry."

    static func isUnsettled(_ phase: ChatOpenPresentationPhase) -> Bool {
        phase == .opening
            || phase == .positioning
            || phase == .revealing
            || phase == .presenting
            || phase == .presented
    }

    static func shouldFailUnsettledAttempt(
        completedOwnedTask: Bool,
        taskCancelled: Bool,
        sceneActive: Bool,
        presentationActive: Bool,
        modelAdmitsOpen: Bool,
        phase: ChatOpenPresentationPhase
    ) -> Bool {
        completedOwnedTask
            && !taskCancelled
            && sceneActive
            && presentationActive
            && modelAdmitsOpen
            && isUnsettled(phase)
    }
}

enum ChatSessionVisibilityPolicy {
    static func isVisible(
        sceneActive: Bool,
        surfaceActive: Bool,
        hasMountedAuthority: Bool
    ) -> Bool {
        sceneActive && surfaceActive && hasMountedAuthority
    }
}

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
    var showProcesses = false
    var showSettings = false
    var queuedMessageEditor: QueuedMessageEditorRoute?
    var displaySheet: DisplayRoute?
    var floatingDisplay: DisplayRoute?
    var pendingFloatingDisplay: DisplayRoute?
    var automaticallyPresentedDisplayIDs = BoundedChatIdentityLedger()
    var suppressedInteractionScope: ExtensionInteractionScope?
    var requestedInteractionScope: ExtensionInteractionScope?
    /// Turns true only after the mounted transcript has crossed its first ready
    /// frame. A pending interaction must never cover and cancel session opening.
    var permitsExtensionInteractionPresentation = false

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
    var canonicalSubmissionAliases = BoundedChatIdentityAliasLedger()

    @ObservationIgnored var photoImportTask: Task<Void, Never>?
    @ObservationIgnored var attachmentPresentationTask: Task<Void, Never>?
    @ObservationIgnored private(set) var openingTask: Task<Void, Never>?
    private var openingTaskGeneration = 0
    private var cancelledOpeningTaskGeneration: Int?

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
        displaySheet = nil
        floatingDisplay = nil
        pendingFloatingDisplay = nil
    }

    /// Backgrounding retires only disposable UI work. An admitted composer
    /// transport is owned by ComposerDraftCoordinator and intentionally remains
    /// alive so an accepted prompt can reconcile after reconnect.
    var needsOpeningResume: Bool {
        (open.phase != .ready || modelPresentationGeneration == nil)
            && openingTask == nil
    }

    struct OpeningTaskLease {
        let task: Task<Void, Never>
        let generation: Int
    }

    var activeOpeningTaskLease: OpeningTaskLease? {
        openingTask.map { OpeningTaskLease(task: $0, generation: openingTaskGeneration) }
    }

    func installOpeningTask(_ task: Task<Void, Never>) -> Int? {
        guard openingTask == nil else { return nil }
        openingTaskGeneration &+= 1
        cancelledOpeningTaskGeneration = nil
        openingTask = task
        return openingTaskGeneration
    }

    func openingTaskWasCancelled(_ generation: Int) -> Bool {
        cancelledOpeningTaskGeneration == generation
    }

    @discardableResult
    func finishOpeningTask(_ generation: Int) -> Bool {
        guard openingTaskGeneration == generation, openingTask != nil else { return false }
        openingTask = nil
        return true
    }

    /// Cancels only the exact task that installed the deadline, but retains its
    /// lease until the task has actually drained. Retry/foreground resume joins
    /// that lease instead of overlapping a second session.open.
    @discardableResult
    func expireOpeningTask(_ generation: Int) -> Bool {
        guard openingTaskGeneration == generation, let openingTask else { return false }
        cancelledOpeningTaskGeneration = generation
        openingTask.cancel()
        return true
    }

    func cancelOpeningTask() {
        guard let openingTask else { return }
        cancelledOpeningTaskGeneration = openingTaskGeneration
        openingTask.cancel()
    }

    func requestInteractionPresentation(_ interaction: ExtensionInteraction) {
        requestedInteractionScope = ExtensionInteractionScope(interaction)
    }

    func closeInteractionPresentation(_ interaction: ExtensionInteraction) {
        let scope = ExtensionInteractionScope(interaction)
        suppressedInteractionScope = scope
        if requestedInteractionScope == scope { requestedInteractionScope = nil }
    }

    func reconcileInteractionPresentation(with interactions: [ExtensionInteraction]) {
        if let suppressedInteractionScope,
           ChatExtensionInteractionPolicy.shouldClearSuppression(
               suppressedInteractionScope,
               from: interactions
           ) {
            self.suppressedInteractionScope = nil
        }
        if let requestedInteractionScope,
           !interactions.contains(where: {
               ExtensionInteractionScope($0) == requestedInteractionScope
           }) {
            self.requestedInteractionScope = nil
        }
    }

    func suspendForBackground() {
        cancelOpeningTask()
        earlierMessagesOperation.cancel()
        suspendTransientInteractions()
    }

}

struct ChatTranscriptProjectionCapture: Sendable {
    let snapshot: SessionSnapshot
    let handoff: ChatTranscriptHandoffCommit
    let queuePresentationIDByOperationID: [String: String]
    let tag: ChatTranscriptProjectionTag
}

struct BoundedChatIdentityAliasLedger: Equatable {
    private(set) var aliases: [String: String] = [:]
    private var order: [String] = []

    /// Installs only one-to-one causal aliases. Ambiguity fails closed without
    /// changing an already admitted identity.
    @discardableResult
    mutating func insert(canonicalID: String, presentationID: String) -> Bool {
        guard !canonicalID.isEmpty, !presentationID.isEmpty else { return false }
        if let existing = aliases[canonicalID] { return existing == presentationID }
        guard !aliases.values.contains(presentationID) else { return false }
        aliases[canonicalID] = presentationID
        order.append(canonicalID)
        let excess = order.count - ChatTranscriptPageRequest.maximumItemCount
        if excess > 0 {
            for id in order.prefix(excess) { aliases[id] = nil }
            order.removeFirst(excess)
        }
        return true
    }

    mutating func removeAll() {
        aliases.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }
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
