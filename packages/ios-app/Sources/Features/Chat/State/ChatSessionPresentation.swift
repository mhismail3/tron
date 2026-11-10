import Foundation
import Observation
import PhotosUI
import SwiftUI
import TronMobileCore

enum ChatOpeningSurfaceAction: Equatable {
    case none
    case begin
    case waitForCurrentThenBeginIfNeeded
}

struct ChatOpeningSurfaceTaskID: Hashable {
    let surfaceActive: Bool
    let openingTaskRevision: Int
}

enum ChatOpeningSurfacePolicy {
    static func showsOpaqueCover(phase: ChatOpenPresentationPhase) -> Bool {
        switch phase {
        case .opening, .positioning, .revealing, .presenting: true
        case .waitingForConnection, .presented, .ready, .failed: false
        }
    }

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

    static func isFailed(_ phase: ChatOpenPresentationPhase) -> Bool {
        if case .failed = phase { return true }
        return false
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

@MainActor
@Observable
final class ChatSessionPresentation {
    let sessionID: String

    var photos: [PhotosPickerItem] = []
    var photoImportTarget: SessionPresentationIdentity?
    var attachmentDestination: ChatAttachmentDestination?
    var queuedAttachmentDestination: ChatAttachmentDestination?

    var showContext = false
    var showActivity = false
    var showSettings = false
    var queuedMessageEditor: QueuedMessageEditorRoute?
    var displaySheet: DisplayRoute?
    var floatingDisplay: DisplayRoute?
    var pendingFloatingDisplay: DisplayRoute?
    var automaticallyPresentedDisplayIDs = BoundedChatIdentityLedger()
    var suppressedInteractionScope: ExtensionInteractionScope?
    var requestedInteractionScope: ExtensionInteractionScope?
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
    @ObservationIgnored var pastedImageImports: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var attachmentPresentationTask: Task<Void, Never>?
    @ObservationIgnored private(set) var openingTask: Task<Void, Never>?
    private(set) var openingTaskRevision = 0
    private var openingTaskGeneration = 0
    private var cancelledOpeningTaskGeneration: Int?
    @ObservationIgnored private var readyOpeningTaskGeneration: Int?

    init(sessionID: String) {
        self.sessionID = sessionID
        open = ChatOpenPresentationState(sessionID: sessionID)
    }

    func presentDisplay(_ command: DisplayPresentationCommand) {
        let route: DisplayRoute
        switch command {
        case .showSheet(let value), .showFloating(let value): route = value
        }
        guard route.sessionID == sessionID else { return }
        automaticallyPresentedDisplayIDs.formUnion([route.display.presentationIdentity])
        if pendingFloatingDisplay?.id == route.id { pendingFloatingDisplay = nil }
        switch command {
        case .showSheet:
            if displaySheet?.id != route.id { displaySheet = route }
        case .showFloating:
            if floatingDisplay?.id != route.id { floatingDisplay = route }
        }
    }

    func cancelImports() {
        pastedImageImports.values.forEach { $0.cancel() }
        pastedImageImports.removeAll()
        photoImportTask?.cancel()
        photoImportTask = nil
        photoImportTarget = nil
        photos = []
    }

    private func suspendTransientInteractions(preservingReadonlyPreviews: Bool) {
        attachmentPresentationTask?.cancel()
        attachmentPresentationTask = nil
        attachmentDestination = nil
        queuedAttachmentDestination = nil
        cancelImports()
        if !preservingReadonlyPreviews || displaySheet.map({ !Self.isReadonlyAttachment($0) }) == true { displaySheet = nil }
        floatingDisplay = nil
        pendingFloatingDisplay = nil
    }

    private static func isReadonlyAttachment(_ route: DisplayRoute) -> Bool {
        route.display.artifact != nil && [.image, .markdown, .text, .code, .pdf, .document].contains(route.display.kind)
    }

    var needsOpeningResume: Bool { shouldBeginOpening(retryingFailure: false) }

    func shouldBeginOpening(retryingFailure: Bool) -> Bool {
        guard openingTask == nil else { return false }
        if ChatOpeningAttemptPolicy.isFailed(open.phase) { return retryingFailure }
        return open.phase != .ready || modelPresentationGeneration == nil
            || cancelledOpeningTaskGeneration == openingTaskGeneration
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

    var ownsUnsettledOpening: Bool {
        openingTask != nil && readyOpeningTaskGeneration != openingTaskGeneration
    }

    func markOpeningReady() {
        guard openingTask != nil else { return }
        readyOpeningTaskGeneration = openingTaskGeneration
    }

    func openingTaskWasCancelled(_ generation: Int) -> Bool {
        cancelledOpeningTaskGeneration == generation
    }

    @discardableResult
    func finishOpeningTask(_ generation: Int) -> Bool {
        guard openingTaskGeneration == generation, openingTask != nil else { return false }
        openingTask = nil
        openingTaskRevision &+= 1
        return true
    }

    @discardableResult
    func expireOpeningTask(_ generation: Int) -> Bool {
        guard openingTaskGeneration == generation, ownsUnsettledOpening,
              let openingTask else { return false }
        cancelledOpeningTaskGeneration = generation
        openingTask.cancel()
        return true
    }

    func cancelOpeningTask() {
        guard ownsUnsettledOpening, let openingTask else { return }
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
        suspendTransientInteractions(preservingReadonlyPreviews: true)
    }

    func retirePresentation() {
        cancelOpeningTask()
        earlierMessagesOperation.cancel()
        suspendTransientInteractions(preservingReadonlyPreviews: false)
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
