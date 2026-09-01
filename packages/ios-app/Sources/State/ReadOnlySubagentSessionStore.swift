import Foundation
import Observation

struct ProcessTranscriptPage: Codable, Hashable, Sendable {
    let items: [TranscriptItem]
    let start: Int
    let end: Int
    let total: Int
    let nextEntryId: String?
    let leafEntryId: String?

    init(
        items: [TranscriptItem], start: Int, end: Int, total: Int,
        nextEntryId: String?, leafEntryId: String?
    ) throws {
        guard Self.valid(items: items, start: start, end: end, total: total,
                         nextEntryId: nextEntryId, leafEntryId: leafEntryId) else {
            throw GatewayFailure(code: "invalid_response", message: "Invalid read-only process transcript page", retryable: true, details: nil)
        }
        self.items = items; self.start = start; self.end = end; self.total = total
        self.nextEntryId = nextEntryId; self.leafEntryId = leafEntryId
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let items = try values.decode([TranscriptItem].self, forKey: .items)
        let start = try values.decode(Int.self, forKey: .start)
        let end = try values.decode(Int.self, forKey: .end)
        let total = try values.decode(Int.self, forKey: .total)
        let nextEntryId = try values.decodeIfPresent(String.self, forKey: .nextEntryId)
        let leafEntryId = try values.decodeIfPresent(String.self, forKey: .leafEntryId)
        guard Self.valid(items: items, start: start, end: end, total: total,
                         nextEntryId: nextEntryId, leafEntryId: leafEntryId) else {
            throw DecodingError.dataCorruptedError(forKey: .items, in: values, debugDescription: "Invalid read-only process transcript page")
        }
        self.items = items; self.start = start; self.end = end; self.total = total
        self.nextEntryId = nextEntryId; self.leafEntryId = leafEntryId
    }

    private static func valid(
        items: [TranscriptItem], start: Int, end: Int, total: Int,
        nextEntryId: String?, leafEntryId: String?
    ) -> Bool {
        start >= 0 && end >= start && total >= end && end - start == items.count
            && items.count <= ChatTranscriptPageRequest.maximumItemCount
            && Set(items.map(\.id)).count == items.count
            && (nextEntryId.map { !$0.isEmpty && $0.utf8.count <= 512 } ?? true)
            && (leafEntryId.map { !$0.isEmpty && $0.utf8.count <= 512 } ?? true)
    }

    private enum CodingKeys: String, CodingKey { case items, start, end, total, nextEntryId, leafEntryId }
}

private struct ProcessTranscriptOpenResponse: Decodable, Sendable {
    let leaseId: String
    let processId: String
    let childSessionRef: String
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
    let revision: String

    var page: ProcessTranscriptPage? {
        try? ProcessTranscriptPage(
            items: items, start: start, end: end, total: total,
            nextEntryId: nextEntryId, leafEntryId: leafEntryId
        )
    }
}

/// Pure append-aware reconciliation for canonical-live child transcripts.
/// Existing loaded prefix pages survive an append whenever the refreshed tail
/// overlaps them exactly. Branch replacement or an unbridgeable gap fails over
/// to the new canonical tail rather than fabricating continuity.
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
    private var bindingRetryTask: Task<Void, Never>?
    private var textPreparationTask: Task<Void, Never>?
    private var bindingRetryAttempts = 0
    private var pendingRefreshRevision: String?

    private static let maximumBindingRetryAttempts = 2

    private(set) var status: Status = .idle
    private(set) var parentSessionID: String?
    private(set) var processID: String?
    private var selectedToolCallID: String?
    private var selectedRunID: String?
    private(set) var presentationGeneration: Int?
    private(set) var leaseID: String?
    private(set) var childSessionRef: String?
    private(set) var revision: String?
    private(set) var items: [TranscriptItem] = []
    private(set) var presentation: ChatReadOnlyTranscriptProjection = .empty
    private(set) var preparedText: ChatTextPreparationSnapshot = .empty
    private(set) var transcriptStart = 0
    private(set) var transcriptTotal = 0
    private(set) var nextEntryID: String?
    private(set) var leafEntryID: String?
    private(set) var liveActivity: SessionProcessActivity?

    init(client: GatewayClient) { self.client = client }

    var canLoadEarlier: Bool { status == .open && transcriptStart > 0 }

    func open(
        parentSessionID: String,
        processID: String,
        presentationGeneration: Int,
        activity: SessionProcessActivity? = nil
    ) {
        bindingRetryAttempts = 0
        selectedToolCallID = activity?.processId == processID ? activity?.toolCallId : nil
        selectedRunID = activity?.processId == processID ? activity?.runId : nil
        startOpen(
            parentSessionID: parentSessionID,
            processID: processID,
            presentationGeneration: presentationGeneration,
            activity: activity
        )
    }

    private func startOpen(
        parentSessionID: String,
        processID: String,
        presentationGeneration: Int,
        activity: SessionProcessActivity?
    ) {
        retire(sendClose: true)
        generation &+= 1
        let ownedGeneration = generation
        self.parentSessionID = parentSessionID
        self.processID = processID
        self.presentationGeneration = presentationGeneration
        if let activity,
           activity.processId == processID,
           SessionProcessAdmissionPolicy.admits(activity) {
            liveActivity = activity
        }
        status = .opening
        openTask = Task { [weak self, client] in
            defer { Task { @MainActor [weak self] in
                guard let self, self.generation == ownedGeneration else { return }
                self.openTask = nil
            } }
            do {
                // The RPC is the capability authority. Avoid waiting on a separate
                // system.info projection before opening the latency-sensitive sheet;
                // older Gateways return a bounded unsupported response directly.
                struct Params: Encodable { let sessionId, processId: String }
                let response: ProcessTranscriptOpenResponse = try await client.request(
                    "session.processTranscript.open",
                    Params(sessionId: parentSessionID, processId: processID),
                    timeout: .seconds(15)
                )
                guard !Task.isCancelled else {
                    Self.closeDetached(client: client, leaseID: response.leaseId)
                    return
                }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generation == ownedGeneration,
                          self.parentSessionID == parentSessionID,
                          self.processID == processID,
                          self.presentationGeneration == presentationGeneration,
                          response.processId == processID,
                          Self.admits(response) else {
                        Self.closeDetached(client: client, leaseID: response.leaseId)
                        return
                    }
                    self.leaseID = response.leaseId
                    self.childSessionRef = response.childSessionRef
                    self.revision = response.revision
                    guard self.install(response.page) else {
                        self.leaseID = nil
                        self.status = .failed("The canonical subagent transcript is inconsistent.")
                        Self.closeDetached(client: client, leaseID: response.leaseId)
                        return
                    }
                    self.status = .open
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == ownedGeneration else { return }
                    if let failure = error as? GatewayFailure,
                       ["not_found", "unavailable"].contains(failure.code),
                       self.liveActivity?.lifecycle.state.isActive == true {
                        // Active subagents can publish their child binding after the
                        // activity row. The RPC remains the capability authority, so
                        // two short retries may also trigger Gateway reconciliation
                        // before a process delta arrives; no path or identity is
                        // inferred on-device.
                        self.status = .waiting
                        if let activity = self.liveActivity {
                            self.scheduleBindingRetry(activity: activity, delay: .milliseconds(200))
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
        guard pageTask == nil, status == .open, let leaseID, let revision, transcriptStart > 0 else { return }
        let ownedGeneration = generation
        let before = transcriptStart
        let expectedNext = items.first?.id ?? nextEntryID
        let existingIDs = Set(items.map(\.id))
        status = .loadingEarlier
        pageTask = Task { [weak self, client] in
            defer { Task { @MainActor [weak self] in
                guard let self, self.generation == ownedGeneration else { return }
                self.pageTask = nil
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
                    timeout: .seconds(15)
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
                    guard self.rebuildPresentation() else {
                        self.status = .failed("The canonical subagent transcript is inconsistent.")
                        return
                    }
                    self.prepareText()
                    self.status = .open
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == ownedGeneration else { return }
                    if let failure = error as? GatewayFailure, failure.code == "conflict" {
                        self.reopenCanonicalTail(ownedGeneration: ownedGeneration)
                    } else {
                        self.status = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    func invalidate(_ change: ProcessTranscriptChanged) {
        guard change.leaseId == leaseID else { return }
        if change.closed == true {
            retire(sendClose: false)
            status = .unavailable
            return
        }
        guard let changedRevision = change.revision, changedRevision != revision else { return }
        pendingRefreshRevision = changedRevision
        pageTask?.cancel()
        pageTask = nil
        refreshNewestPageIfNeeded()
    }

    private func refreshNewestPageIfNeeded() {
        guard refreshTask == nil,
              let targetRevision = pendingRefreshRevision,
              targetRevision != revision,
              let leaseID,
              let expectedRevision = revision else { return }
        let ownedGeneration = generation
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
                    timeout: .seconds(15)
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generation == ownedGeneration,
                          self.leaseID == leaseID else { return }
                    guard let page = response.page,
                          self.revision == expectedRevision,
                          response.revision != expectedRevision else {
                        self.refreshTask = nil
                        self.status = .reconnecting
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
                    self.revision = response.revision
                    guard self.rebuildPresentation() else {
                        self.status = .failed("The canonical subagent transcript is inconsistent.")
                        self.refreshTask = nil
                        return
                    }
                    self.prepareText()
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
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == ownedGeneration else { return }
                    self.refreshTask = nil
                    if let failure = error as? GatewayFailure, failure.code == "conflict" {
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
        guard generation == ownedGeneration,
              let parentSessionID,
              let processID,
              let presentationGeneration else { return }
        let activity = liveActivity
        open(
            parentSessionID: parentSessionID,
            processID: processID,
            presentationGeneration: presentationGeneration,
            activity: activity
        )
    }

    func updateLiveActivity(_ activity: SessionProcessActivity?) {
        guard let processID else { return }
        let wasActive = liveActivity?.lifecycle.state.isActive == true
        let hadChildBinding = liveActivity?.childSessionRef != nil
        guard let activity else {
            liveActivity = nil
            if wasActive { rebuildPresentation() }
            bindingRetryTask?.cancel()
            bindingRetryTask = nil
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
            // Gateway can replace a short-lived aggregate with the sole exact
            // child. Retarget only under the immutable tool/run correlation;
            // ambiguous candidates are filtered by SessionProcessProjection.
            self.processID = activity.processId
            bindingRetryAttempts = 0
            bindingRetryTask?.cancel()
            bindingRetryTask = nil
            if let parentSessionID, let presentationGeneration {
                startOpen(
                    parentSessionID: parentSessionID,
                    processID: activity.processId,
                    presentationGeneration: presentationGeneration,
                    activity: activity
                )
            }
            return
        }
        liveActivity = activity
        if wasActive != activity.lifecycle.state.isActive { rebuildPresentation() }
        guard status == .waiting else { return }
        if activity.childSessionRef != nil {
            if !hadChildBinding {
                bindingRetryAttempts = 0
                bindingRetryTask?.cancel()
                bindingRetryTask = nil
            }
            if activity.lifecycle.state.isActive {
                scheduleBindingRetry(activity: activity, delay: .zero)
            } else if let parentSessionID,
                      let presentationGeneration {
                open(
                    parentSessionID: parentSessionID,
                    processID: processID,
                    presentationGeneration: presentationGeneration,
                    activity: activity
                )
            }
        } else if !activity.lifecycle.state.isActive {
            bindingRetryTask?.cancel()
            bindingRetryTask = nil
            status = .unavailable
        }
    }

    private func scheduleBindingRetry(activity: SessionProcessActivity, delay: Duration) {
        guard bindingRetryTask == nil,
              bindingRetryAttempts < Self.maximumBindingRetryAttempts,
              activity.lifecycle.state.isActive,
              let parentSessionID,
              let processID,
              let presentationGeneration else {
            if bindingRetryAttempts >= Self.maximumBindingRetryAttempts,
               activity.childSessionRef != nil {
                status = .failed("The live subagent session is not ready yet. Try opening it again.")
            }
            return
        }
        bindingRetryAttempts += 1
        let ownedGeneration = generation
        bindingRetryTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.generation == ownedGeneration,
                      self.status == .waiting else { return }
                self.bindingRetryTask = nil
                let currentActivity = self.liveActivity ?? activity
                self.startOpen(
                    parentSessionID: parentSessionID,
                    processID: processID,
                    presentationGeneration: presentationGeneration,
                    activity: currentActivity
                )
            }
        }
    }

    func close() {
        bindingRetryAttempts = 0
        selectedToolCallID = nil
        selectedRunID = nil
        retire(sendClose: true)
    }

    private func retire(sendClose: Bool) {
        let oldLease = leaseID
        generation &+= 1
        openTask?.cancel(); openTask = nil
        pageTask?.cancel(); pageTask = nil
        refreshTask?.cancel(); refreshTask = nil
        bindingRetryTask?.cancel(); bindingRetryTask = nil
        textPreparationTask?.cancel(); textPreparationTask = nil
        textPreparationGeneration &+= 1
        pendingRefreshRevision = nil
        leaseID = nil; childSessionRef = nil; revision = nil
        items.removeAll(); presentation = .empty; preparedText = .empty
        transcriptStart = 0; transcriptTotal = 0
        nextEntryID = nil; leafEntryID = nil; liveActivity = nil
        status = .idle
        if sendClose, let oldLease { Self.closeDetached(client: client, leaseID: oldLease) }
    }

    private func install(_ page: ProcessTranscriptPage) -> Bool {
        items = page.items; transcriptStart = page.start; transcriptTotal = page.total
        nextEntryID = page.nextEntryId; leafEntryID = page.leafEntryId
        guard rebuildPresentation() else { return false }
        prepareText()
        return true
    }

    @discardableResult
    private func rebuildPresentation() -> Bool {
        let next = ChatTranscriptProjectionKernel.readOnlyTranscript(
            items,
            transcriptStart: transcriptStart,
            transcriptTotal: transcriptTotal,
            isActive: liveActivity?.lifecycle.state.isActive == true
        )
        guard next.isValid else {
            presentation = .empty
            return false
        }
        presentation = next
        return true
    }

    private func prepareText() {
        textPreparationGeneration &+= 1
        let ownedPreparationGeneration = textPreparationGeneration
        textPreparationTask?.cancel()
        let sources = ChatTextPreparationPolicy.sources(in: items)
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

    nonisolated private static func closeDetached(client: GatewayClient, leaseID: String) {
        Task {
            struct Params: Encodable { let leaseId: String }
            struct Response: Decodable { let closed: Bool }
            let _: Response? = try? await client.request(
                "session.processTranscript.close", Params(leaseId: leaseID), timeout: .seconds(5)
            )
        }
    }
}
