import Foundation
import Observation
import TronMobileCore

struct ProcessTranscriptPage: Codable, Hashable, Sendable {
    let items: [TranscriptItem]
    let start: Int
    let end: Int
    let total: Int
    let nextEntryId: String?
    let leafEntryId: String?
    let forkBoundary: TranscriptForkBoundary?

    init(
        items: [TranscriptItem], start: Int, end: Int, total: Int,
        nextEntryId: String?, leafEntryId: String?, forkBoundary: TranscriptForkBoundary? = nil
    ) throws {
        guard Self.valid(items: items, start: start, end: end, total: total,
                         nextEntryId: nextEntryId, leafEntryId: leafEntryId) else {
            throw GatewayFailure(code: "invalid_response", message: "Invalid read-only process transcript page", retryable: true, details: nil)
        }
        self.items = items; self.start = start; self.end = end; self.total = total
        self.nextEntryId = nextEntryId; self.leafEntryId = leafEntryId; self.forkBoundary = forkBoundary
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let items = try values.decode([TranscriptItem].self, forKey: .items)
        let start = try values.decode(Int.self, forKey: .start)
        let end = try values.decode(Int.self, forKey: .end)
        let total = try values.decode(Int.self, forKey: .total)
        let nextEntryId = try values.decodeIfPresent(String.self, forKey: .nextEntryId)
        let leafEntryId = try values.decodeIfPresent(String.self, forKey: .leafEntryId)
        let forkBoundary = try values.decodeIfPresent(TranscriptForkBoundary.self, forKey: .forkBoundary)
        guard Self.valid(items: items, start: start, end: end, total: total,
                         nextEntryId: nextEntryId, leafEntryId: leafEntryId) else {
            throw DecodingError.dataCorruptedError(forKey: .items, in: values, debugDescription: "Invalid read-only process transcript page")
        }
        self.items = items; self.start = start; self.end = end; self.total = total
        self.nextEntryId = nextEntryId; self.leafEntryId = leafEntryId; self.forkBoundary = forkBoundary
    }

    private static func valid(
        items: [TranscriptItem], start: Int, end: Int, total: Int,
        nextEntryId: String?, leafEntryId: String?
    ) -> Bool {
        start >= 0 && end >= start && total >= end && end - start == items.count
            && SessionSnapshotTranscriptAdmissionPolicy.admitsPage(items)
            && (nextEntryId.map { !$0.isEmpty && $0.utf8.count <= 512 } ?? true)
            && (leafEntryId.map { !$0.isEmpty && $0.utf8.count <= 512 } ?? true)
    }

    private enum CodingKeys: String, CodingKey { case items, start, end, total, nextEntryId, leafEntryId, forkBoundary }
}

private struct ProcessTranscriptOpenResponse: Decodable, Sendable {
    let leaseId: String
    let processId: String
    let childSessionRef: String
    let canAbort: Bool?
    let revision: String
    let page: ProcessTranscriptPage
}

private struct ProcessTranscriptPageResponse: Decodable, Sendable {
    let items: [TranscriptItem]
    let start: Int
    let end: Int
    let total: Int
    let nextEntryId: String?
    let leafEntryId: String?
    let forkBoundary: TranscriptForkBoundary?
    let revision: String

    var page: ProcessTranscriptPage? {
        try? ProcessTranscriptPage(
            items: items, start: start, end: end, total: total,
            nextEntryId: nextEntryId, leafEntryId: leafEntryId, forkBoundary: forkBoundary
        )
    }
}

enum ReadOnlyProcessTranscriptMerge {
    struct Result: Equatable, Sendable {
        let items: [TranscriptItem]
        let start: Int
        let total: Int
        let nextEntryId: String?
        let leafEntryId: String?
        let retainedLoadedPrefix: Bool
    }

    static func refreshing(
        existing: [TranscriptItem],
        existingStart: Int,
        existingTotal: Int,
        with page: ProcessTranscriptPage
    ) -> Result {
        let replacement = Result(
            items: page.items,
            start: page.start,
            total: page.total,
            nextEntryId: page.nextEntryId,
            leafEntryId: page.leafEntryId,
            retainedLoadedPrefix: false
        )
        guard page.end == page.total,
              existingStart >= 0,
              existingTotal >= existingStart,
              existing.count == existingTotal - existingStart,
              page.total >= existingTotal,
              page.start >= existingStart,
              page.start <= existingTotal else { return replacement }

        let overlapStart = page.start
        let overlapEnd = min(existingTotal, page.end)
        if overlapStart < overlapEnd {
            let oldOffset = overlapStart - existingStart
            let newCount = overlapEnd - overlapStart
            let oldIDs = existing[oldOffset..<(oldOffset + newCount)].map(\.id)
            let newIDs = page.items.prefix(newCount).map(\.id)
            guard oldIDs == newIDs else { return replacement }
        } else if page.start != existingTotal {
            return replacement
        }

        let prefixCount = page.start - existingStart
        let combined = Array(existing.prefix(prefixCount)) + page.items
        guard Set(combined.map(\.id)).count == combined.count else { return replacement }
        return Result(
            items: combined,
            start: existingStart,
            total: page.total,
            nextEntryId: page.nextEntryId,
            leafEntryId: page.leafEntryId,
            retainedLoadedPrefix: prefixCount > 0
        )
    }
}

@MainActor
@Observable
final class ReadOnlySubagentSessionStore {
    enum Status: Equatable, Sendable {
        case idle, waiting, opening, open, loadingEarlier, reconnecting, unavailable, failed(String)
    }

    private let client: GatewayClient
    private let textPreparationCache = ChatTextPreparationCache()
    private var generation = 0
    private var textPreparationGeneration = 0
    private var openTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var textPreparationTask: Task<Void, Never>?
    private var pendingRefreshRevision: String?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0

    private static let maximumRecoveryAttempts = 3
    private static let recoveryRetryBaseDelay = Duration.milliseconds(150)

    private(set) var status: Status = .idle
    private(set) var parentSessionID: String?
    private(set) var parentSubscriptionToken: String?
    private(set) var processID: String?
    private var selectedToolCallID: String?
    private var selectedRunID: String?
    private(set) var presentationGeneration: Int?
    private(set) var leaseID: String?
    private var openingViewerID: String?
    private var viewerConnectionAdmission: GatewayConnectionAdmission?
    private(set) var childSessionRef: String?
    private(set) var canAbort = false
    private(set) var revision: String?
    private(set) var items: [TranscriptItem] = []
    private var installedItems: [TranscriptItem] = []
    private var viewportMode: ChatViewportMode = .pinned
    private(set) var presentation: ChatReadOnlyTranscriptProjection = .empty
    private(set) var preparedText: ChatTextPreparationSnapshot = .empty
    private(set) var transcriptStart = 0
    private(set) var transcriptTotal = 0
    private(set) var nextEntryID: String?
    private(set) var leafEntryID: String?
    private(set) var forkBoundary: TranscriptForkBoundary?
    private(set) var liveActivity: PresentedProcessActivity?

    init(client: GatewayClient) { self.client = client }

    var canLoadEarlier: Bool {
        status == .open && recoveryTask == nil && transcriptStart > 0
            && (!viewportMode.defersAutomaticProjectionIntake() || installedItems.first?.id == items.first?.id)
    }

    func updateViewportMode(_ mode: ChatViewportMode) {
        guard viewportMode != mode else { return }
        viewportMode = mode
        if mode.defersAutomaticProjectionIntake() {
            textPreparationTask?.cancel(); textPreparationTask = nil
            textPreparationGeneration &+= 1
        } else if !rebuildPresentation() {
            status = .failed("The canonical subagent transcript is inconsistent.")
        }
    }

    func resolveThinkingTrace(_ identity: String) -> ChatThinkingTraceContent? {
        guard let resolved = ChatTranscriptDetailResolution.thinkingTrace(
            in: presentation.timeline.items,
            identity: identity
        ) else { return nil }
        return ChatThinkingTraceContent(
            segments: resolved.segments,
            preparedText: preparedText.slice(for: resolved.item),
            streaming: false
        )
    }

    func resolveNotificationDetail(_ eventID: String) -> ChatNotificationPresentation? {
        ChatTranscriptDetailResolution.notificationDetail(
            in: presentation.timeline.items,
            eventID: eventID
        )
    }

    func open(
        parentSessionID: String,
        processID: String,
        presentationGeneration: Int,
        parentSubscriptionToken: String,
        activity: PresentedProcessActivity? = nil
    ) {
        recoveryAttempts = 0
        selectedToolCallID = activity?.processId == processID ? activity?.toolCallId : nil
        selectedRunID = activity?.processId == processID ? activity?.runId : nil
        startOpen(
            parentSessionID: parentSessionID,
            processID: processID,
            presentationGeneration: presentationGeneration,
            parentSubscriptionToken: parentSubscriptionToken,
            activity: activity
        )
    }

    private func startOpen(
        parentSessionID: String,
        processID: String,
        presentationGeneration: Int,
        parentSubscriptionToken: String,
        activity: PresentedProcessActivity?
    ) {
        let retainTranscript = self.parentSessionID == parentSessionID && self.processID == processID
            && self.presentationGeneration == presentationGeneration
            && self.parentSubscriptionToken == parentSubscriptionToken && !items.isEmpty
        retire(sendClose: true, preserveTranscript: retainTranscript)
        generation &+= 1
        let ownedGeneration = generation
        let viewerID = UUID().uuidString
        openingViewerID = viewerID
        let admittedParentSubscriptionToken = parentSubscriptionToken
        self.parentSessionID = parentSessionID
        self.parentSubscriptionToken = admittedParentSubscriptionToken
        self.processID = processID
        self.presentationGeneration = presentationGeneration
        if let activity,
           activity.processId == processID,
           SessionProcessAdmissionPolicy.admits(activity) {
            liveActivity = activity
        }
        status = retainTranscript ? .reconnecting : .opening
        openTask = Task { [weak self, client] in
            defer { Task { @MainActor [weak self] in
                guard let self, self.generation == ownedGeneration else { return }
                self.openTask = nil
            } }
            let connectionAdmission = await client.activeConnectionAdmission()
            do {
                guard (await client.info?.capabilities.contains(SessionProcessAdmissionPolicy.transcriptCapability)) == true else {
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == ownedGeneration else { return }
                        self.status = .unavailable
                    }
                    return
                }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == ownedGeneration else { return }
                    self.viewerConnectionAdmission = connectionAdmission
                }
                struct Params: Encodable { let sessionId, processId, viewerId, subscriptionToken: String }
                let response: ProcessTranscriptOpenResponse = try await client.request(
                    "session.processTranscript.open",
                    Params(sessionId: parentSessionID, processId: processID, viewerId: viewerID, subscriptionToken: admittedParentSubscriptionToken),
                    expectedConnection: connectionAdmission
                )
                guard !Task.isCancelled else {
                    Self.closeDetached(client: client, leaseID: viewerID, connectionAdmission: connectionAdmission)
                    return
                }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generation == ownedGeneration,
                          self.parentSessionID == parentSessionID,
                          self.processID == processID,
                          self.presentationGeneration == presentationGeneration else {
                        Self.closeDetached(client: client, leaseID: viewerID, connectionAdmission: connectionAdmission)
                        return
                    }
                    guard response.processId == processID,
                          response.leaseId == viewerID,
                          Self.admits(response) else {
                        self.status = .failed("The Gateway returned an invalid subagent viewer lease.")
                        Self.closeDetached(client: client, leaseID: viewerID, connectionAdmission: connectionAdmission)
                        return
                    }
                    self.leaseID = response.leaseId
                    self.openingViewerID = nil
                    self.childSessionRef = response.childSessionRef
                    self.canAbort = response.canAbort == true
                    self.revision = response.revision
                    guard self.install(response.page) else {
                        self.leaseID = nil
                        self.canAbort = false
                        self.status = .failed("The canonical subagent transcript is inconsistent.")
                        Self.closeDetached(client: client, leaseID: viewerID, connectionAdmission: connectionAdmission)
                        return
                    }
                    self.recoveryAttempts = 0
                    self.status = .open
                    self.refreshNewestPageIfNeeded()
                }
            } catch is CancellationError {
                Self.closeDetached(client: client, leaseID: viewerID, connectionAdmission: connectionAdmission)
                return
            } catch is GatewayPossiblySentError {
                Self.closeDetached(client: client, leaseID: viewerID, connectionAdmission: connectionAdmission)
                await MainActor.run { [weak self] in
                    guard let self, self.generation == ownedGeneration else { return }
                    self.status = .unavailable
                }
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == ownedGeneration else { return }
                    if let failure = error as? GatewayFailure,
                       failure.code == "busy", failure.retryable {
                        self.status = self.items.isEmpty ? .waiting : .reconnecting
                        self.scheduleRecovery(for: .opening, generation: ownedGeneration)
                    } else if let failure = error as? GatewayFailure,
                       ["not_found", "unavailable"].contains(failure.code),
                       self.liveActivity?.lifecycle.isActiveWork == true {
                        self.status = self.items.isEmpty ? .waiting : .reconnecting
                        if self.liveActivity?.childSessionRef != nil {
                            self.scheduleRecovery(for: .opening, generation: ownedGeneration)
                        }
                    } else if let failure = error as? GatewayFailure,
                              ["not_found", "unavailable", "unsupported"].contains(failure.code) {
                        self.status = .unavailable
                    } else {
                        self.status = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    func loadEarlier() {
        guard pageTask == nil, canLoadEarlier, let leaseID, let revision else { return }
        let ownedGeneration = generation
        guard let connectionAdmission = viewerConnectionAdmission else { return }
        let before = transcriptStart
        let expectedNext = items.first?.id ?? nextEntryID
        let existingIDs = Set(items.map(\.id))
        status = .loadingEarlier
        pageTask = Task { [weak self, client] in
            defer { Task { @MainActor [weak self] in
                guard let self, self.generation == ownedGeneration else { return }
                self.pageTask = nil
                self.refreshNewestPageIfNeeded()
            } }
            do {
                struct Params: Encodable {
                    let leaseId: String
                    let before: Int
                    let expectedNextEntryId: String?
                    let expectedRevision: String
                }
                let response: ProcessTranscriptPageResponse = try await client.request(
                    "session.processTranscript.page",
                    Params(leaseId: leaseID, before: before,
                           expectedNextEntryId: expectedNext, expectedRevision: revision),
                    expectedConnection: connectionAdmission
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generation == ownedGeneration,
                          self.leaseID == leaseID,
                          self.revision == revision else { return }
                    guard let page = response.page,
                          response.revision == revision,
                          page.end == before,
                          page.start < page.end,
                          page.total == self.transcriptTotal,
                          page.nextEntryId == expectedNext,
                          page.items.allSatisfy({ !existingIDs.contains($0.id) }) else {
                        self.reopenCanonicalTail(ownedGeneration: ownedGeneration)
                        return
                    }
                    self.items = page.items + self.items
                    self.transcriptStart = page.start
                    self.nextEntryID = page.nextEntryId
                    self.forkBoundary = page.forkBoundary
                    guard self.rebuildPresentation(prepending: page.items) else {
                        self.status = .failed("The canonical subagent transcript is inconsistent.")
                        return
                    }
                    self.recoveryAttempts = 0
                    self.status = .open
                }
            } catch is CancellationError {
                return
            } catch is GatewayPossiblySentError {
                guard let self, self.generation == ownedGeneration else { return }
                self.status = .open
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == ownedGeneration else { return }
                    if let failure = error as? GatewayFailure,
                       failure.code == "busy", failure.retryable {
                        self.status = .open
                        self.scheduleRecovery(for: .earlier, generation: ownedGeneration)
                    } else if let failure = error as? GatewayFailure, failure.code == "conflict" {
                        self.reopenCanonicalTail(ownedGeneration: ownedGeneration)
                    } else {
                        self.status = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    func invalidate(_ change: PresentedProcessTranscriptChanged) {
        let ownsLiveLease = change.leaseId == leaseID
        let ownsOpening = change.leaseId == openingViewerID
        guard ownsLiveLease || ownsOpening else { return }
        if change.closed == true {
            if ownsOpening && !ownsLiveLease {
                openTask?.cancel(); openTask = nil
                openingViewerID = nil
                status = .unavailable
            } else {
                retire(sendClose: false)
                status = .unavailable
            }
            return
        }
        guard let changedRevision = change.revision else { return }
        guard changedRevision != revision else { return }
        pendingRefreshRevision = changedRevision
        refreshNewestPageIfNeeded()
    }

    private enum RecoveryIntent { case opening, earlier, newest }

    private func scheduleRecovery(for intent: RecoveryIntent, generation ownedGeneration: Int) {
        guard recoveryTask == nil else { return }
        guard recoveryAttempts < Self.maximumRecoveryAttempts else {
            status = .failed("The subagent session is still unavailable. Retry to load it.")
            return
        }
        recoveryAttempts += 1
        let delay = Self.recoveryRetryBaseDelay * recoveryAttempts
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == ownedGeneration else { return }
                self.recoveryTask = nil
                switch intent {
                case .opening:
                    guard let parent = self.parentSessionID, let process = self.processID,
                          let presentation = self.presentationGeneration,
                          let token = self.parentSubscriptionToken else { return }
                    self.startOpen(parentSessionID: parent, processID: process,
                                   presentationGeneration: presentation,
                                   parentSubscriptionToken: token, activity: self.liveActivity)
                case .earlier:
                    self.loadEarlier()
                case .newest:
                    self.refreshNewestPageIfNeeded()
                }
            }
        }
    }

    private func refreshNewestPageIfNeeded() {
        guard status == .open, recoveryTask == nil, pageTask == nil, refreshTask == nil,
              let targetRevision = pendingRefreshRevision,
              targetRevision != revision,
              let leaseID,
              let expectedRevision = revision else { return }
        let ownedGeneration = generation
        guard let connectionAdmission = viewerConnectionAdmission else { return }
        status = .reconnecting
        refreshTask = Task { [weak self, client] in
            struct Params: Encodable {
                let leaseId: String
                let expectedRevision: String
            }
            do {
                let response: ProcessTranscriptPageResponse = try await client.request(
                    "session.processTranscript.page",
                    Params(leaseId: leaseID, expectedRevision: expectedRevision),
                    expectedConnection: connectionAdmission
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generation == ownedGeneration,
                          self.leaseID == leaseID else { return }
                    guard let page = response.page,
                          self.revision == expectedRevision else {
                        self.refreshTask = nil
                        self.status = .failed("The canonical subagent transcript is invalid.")
                        return
                    }
                    guard response.revision != expectedRevision else {
                        self.refreshTask = nil
                        if self.pendingRefreshRevision == targetRevision { self.pendingRefreshRevision = nil }
                        self.recoveryAttempts = 0
                        self.status = .open
                        self.refreshNewestPageIfNeeded()
                        return
                    }
                    let merged = ReadOnlyProcessTranscriptMerge.refreshing(
                        existing: self.items,
                        existingStart: self.transcriptStart,
                        existingTotal: self.transcriptTotal,
                        with: page
                    )
                    self.items = merged.items
                    self.transcriptStart = merged.start
                    self.transcriptTotal = merged.total
                    self.nextEntryID = merged.nextEntryId
                    self.leafEntryID = merged.leafEntryId
                    self.forkBoundary = page.forkBoundary
                    self.revision = response.revision
                    guard self.rebuildPresentation() else {
                        self.status = .failed("The canonical subagent transcript is inconsistent.")
                        self.refreshTask = nil
                        return
                    }
                    self.recoveryAttempts = 0
                    if self.pendingRefreshRevision == targetRevision
                        || self.pendingRefreshRevision == response.revision {
                        self.pendingRefreshRevision = nil
                    }
                    self.status = .open
                    self.refreshTask = nil
                    self.refreshNewestPageIfNeeded()
                }
            } catch is CancellationError {
                return
            } catch is GatewayPossiblySentError {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == ownedGeneration else { return }
                    self.refreshTask = nil
                    self.status = .open
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == ownedGeneration else { return }
                    self.refreshTask = nil
                    if let failure = error as? GatewayFailure,
                              failure.code == "busy", failure.retryable {
                        self.status = .open
                        self.scheduleRecovery(for: .newest, generation: ownedGeneration)
                    } else if let failure = error as? GatewayFailure, failure.code == "conflict" {
                        self.reopenCanonicalTail(ownedGeneration: ownedGeneration)
                    } else if let failure = error as? GatewayFailure,
                              ["not_found", "unavailable", "unsupported"].contains(failure.code) {
                        self.status = .unavailable
                    } else {
                        self.status = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func reopenCanonicalTail(ownedGeneration: Int) {
        guard generation == ownedGeneration else { return }
        scheduleRecovery(for: .opening, generation: ownedGeneration)
    }

    func retry() {
        guard let parentSessionID, let processID, let presentationGeneration, let parentSubscriptionToken else { return }
        open(parentSessionID: parentSessionID, processID: processID,
             presentationGeneration: presentationGeneration, parentSubscriptionToken: parentSubscriptionToken,
             activity: liveActivity)
    }

    func updateLiveActivity(_ activity: PresentedProcessActivity?) {
        guard let processID else { return }
        let wasActive = liveActivity?.lifecycle.isActiveWork == true
        let hadChildBinding = liveActivity?.childSessionRef != nil
        guard let activity else {
            liveActivity = nil
            if wasActive { rebuildPresentation() }
            if status == .waiting { status = .unavailable }
            return
        }
        guard SessionProcessAdmissionPolicy.admits(activity) else { return }
        if activity.processId != processID {
            guard [.opening, .waiting].contains(status),
                  activity.kind == .subagent,
                  activity.toolCallId == selectedToolCallID,
                  activity.runId == selectedRunID,
                  selectedToolCallID != nil,
                  selectedRunID != nil else { return }
            self.processID = activity.processId
            if let parentSessionID, let parentSubscriptionToken, let presentationGeneration {
                startOpen(
                    parentSessionID: parentSessionID,
                    processID: activity.processId,
                    presentationGeneration: presentationGeneration,
                    parentSubscriptionToken: parentSubscriptionToken,
                    activity: activity
                )
            }
            return
        }
        guard selectedRunID == nil || activity.runId == selectedRunID else { return }
        liveActivity = activity
        if wasActive != activity.lifecycle.isActiveWork { rebuildPresentation() }
        guard status == .waiting || status == .unavailable else { return }
        if activity.childSessionRef != nil && !hadChildBinding,
           let parentSessionID, let parentSubscriptionToken, let presentationGeneration {
            startOpen(parentSessionID: parentSessionID, processID: processID,
                      presentationGeneration: presentationGeneration,
                      parentSubscriptionToken: parentSubscriptionToken, activity: activity)
        } else if activity.childSessionRef == nil && !activity.lifecycle.isActiveWork {
            status = .unavailable
        }
    }

    func close() {
        selectedToolCallID = nil
        selectedRunID = nil
        retire(sendClose: true)
    }

    private func retire(sendClose: Bool, preserveTranscript: Bool = false) {
        let oldLease = leaseID
        let oldOpeningViewer = openingViewerID
        let oldConnection = viewerConnectionAdmission
        generation &+= 1
        openTask?.cancel(); openTask = nil
        pageTask?.cancel(); pageTask = nil
        refreshTask?.cancel(); refreshTask = nil
        recoveryTask?.cancel(); recoveryTask = nil
        textPreparationTask?.cancel(); textPreparationTask = nil
        textPreparationGeneration &+= 1
        pendingRefreshRevision = nil
        leaseID = nil; openingViewerID = nil; viewerConnectionAdmission = nil; parentSubscriptionToken = nil; canAbort = false; revision = nil
        if !preserveTranscript {
            childSessionRef = nil
            items.removeAll(); installedItems.removeAll(); viewportMode = .pinned
            presentation = .empty; preparedText = .empty
            transcriptStart = 0; transcriptTotal = 0
            nextEntryID = nil; leafEntryID = nil; forkBoundary = nil
        }
        liveActivity = nil
        status = .idle
        if sendClose {
            if let oldLease { Self.closeDetached(client: client, leaseID: oldLease, connectionAdmission: oldConnection) }
            if let oldOpeningViewer { Self.closeDetached(client: client, leaseID: oldOpeningViewer, connectionAdmission: oldConnection) }
        }
    }

    private func install(_ page: ProcessTranscriptPage) -> Bool {
        items = page.items; transcriptStart = page.start; transcriptTotal = page.total
        nextEntryID = page.nextEntryId; leafEntryID = page.leafEntryId; forkBoundary = page.forkBoundary
        return rebuildPresentation()
    }

    @discardableResult
    private func rebuildPresentation(prepending earlierItems: [TranscriptItem]? = nil) -> Bool {
        let deferred = viewportMode.defersAutomaticProjectionIntake()
        if deferred {
            guard let earlierItems else { return true }
            installedItems = earlierItems + installedItems
        } else {
            installedItems = items
        }
        let next = ChatTranscriptProjectionKernel.readOnlyTranscript(
            installedItems,
            transcriptStart: transcriptStart,
            transcriptTotal: deferred ? transcriptStart + installedItems.count : transcriptTotal,
            isActive: liveActivity?.lifecycle.isActiveWork == true,
            forkBoundary: forkBoundary
        )
        guard next.isValid else {
            presentation = .empty
            return false
        }
        presentation = next
        prepareText()
        return true
    }

    private func prepareText() {
        textPreparationGeneration &+= 1
        let ownedPreparationGeneration = textPreparationGeneration
        textPreparationTask?.cancel()
        let sources = ChatTextPreparationPolicy.sources(in: installedItems)
        guard !sources.isEmpty else {
            textPreparationTask = nil
            preparedText = .empty
            return
        }
        textPreparationTask = Task { [weak self, textPreparationCache] in
            let snapshot = await textPreparationCache.prepare(sources)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.textPreparationGeneration == ownedPreparationGeneration else { return }
                self.preparedText = snapshot
                self.textPreparationTask = nil
            }
        }
    }

    private static func admits(_ response: ProcessTranscriptOpenResponse) -> Bool {
        !response.leaseId.isEmpty && response.leaseId.utf8.count <= 256
            && !response.childSessionRef.isEmpty && response.childSessionRef.utf8.count <= 512
            && !response.childSessionRef.contains("/") && !response.childSessionRef.contains("\\")
            && !response.revision.isEmpty && response.revision.utf8.count <= 256
    }

    nonisolated private static func closeDetached(client: GatewayClient, leaseID: String, connectionAdmission: GatewayConnectionAdmission?) {
        guard let connectionAdmission else { return }
        Task {
            struct Params: Encodable { let leaseId: String }
            struct Response: Decodable { let closed: Bool }
            let _: Response? = try? await client.request(
                "session.processTranscript.close", Params(leaseId: leaseID),
                expectedConnection: connectionAdmission
            )
        }
    }
}
