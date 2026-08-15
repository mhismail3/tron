import Foundation
import Observation

struct ChatTranscriptProjectionTag: Hashable, Sendable {
    let sessionID: String
    let presentationGeneration: Int
    let runtimeGeneration: String
    let revision: Int
    let eventSequence: Int
    let transcriptStart: Int?
    let transcriptTotal: Int?
    let transcriptCount: Int
    let firstTranscriptID: String?
    let lastTranscriptID: String?

    init(snapshot: SessionSnapshot, presentationGeneration: Int) {
        sessionID = snapshot.sessionId
        self.presentationGeneration = presentationGeneration
        runtimeGeneration = snapshot.runtimeGeneration
        revision = snapshot.revision
        eventSequence = snapshot.eventSequence
        transcriptStart = snapshot.transcriptStart
        transcriptTotal = snapshot.transcriptTotal
        transcriptCount = snapshot.transcript.count
        firstTranscriptID = snapshot.transcript.first?.id
        lastTranscriptID = snapshot.transcript.last?.id
    }

    func matchesIdentity(of other: Self) -> Bool {
        sessionID == other.sessionID
            && presentationGeneration == other.presentationGeneration
            && runtimeGeneration == other.runtimeGeneration
    }
}

struct InstalledChatTranscript: Hashable, Sendable {
    let tag: ChatTranscriptProjectionTag
    let timeline: ChatTranscriptTimeline
}

enum ChatTranscriptPresentationStoreError: Error, Equatable, Sendable {
    case superseded
    case waiterLimitReached
    case invalidProjection
}

typealias ChatTranscriptProjectionBuilder = @Sendable (
    SessionSnapshot,
    ChatTranscriptProjectionTag
) -> ChatTranscriptTimeline

private struct BuiltChatTranscript: Sendable {
    let timeline: ChatTranscriptTimeline
    let isInternallyConsistent: Bool
}

private actor ChatTranscriptProjectionWorker {
    private let builder: ChatTranscriptProjectionBuilder

    init(builder: @escaping ChatTranscriptProjectionBuilder) {
        self.builder = builder
    }

    func build(
        snapshot: SessionSnapshot,
        tag: ChatTranscriptProjectionTag
    ) -> BuiltChatTranscript {
        let timeline = builder(snapshot, tag)
        return BuiltChatTranscript(
            timeline: timeline,
            isInternallyConsistent: timeline.isInternallyConsistent
        )
    }
}

/// Disposable exact-tagged transcript projection. Canonical session truth stays
/// in `SessionPresentationStore`; this owner serializes expensive formatting off
/// MainActor and atomically installs only the newest complete timeline.
@MainActor
@Observable
final class ChatTranscriptPresentationStore {
    typealias Builder = ChatTranscriptProjectionBuilder

    private struct PendingProjection: Sendable {
        let snapshot: SessionSnapshot
        let tag: ChatTranscriptProjectionTag
        let generation: Int
    }

    private struct Waiter {
        let id: UInt64
        let tag: ChatTranscriptProjectionTag
        let continuation: CheckedContinuation<InstalledChatTranscript, Error>
    }

    private(set) var installed: InstalledChatTranscript?

    @ObservationIgnored private let projectionWorker: ChatTranscriptProjectionWorker
    @ObservationIgnored private let maximumWaiters: Int
    @ObservationIgnored private var desiredTag: ChatTranscriptProjectionTag?
    @ObservationIgnored private var pending: PendingProjection?
    @ObservationIgnored private var buildingTag: ChatTranscriptProjectionTag?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var waiters: [Waiter] = []
    @ObservationIgnored private var nextWaiterID: UInt64 = 0

    init(
        maximumWaiters: Int = 32,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        builder: Builder? = nil
    ) {
        self.maximumWaiters = max(1, maximumWaiters)
        let admittedBuilder: Builder
        if let builder {
            admittedBuilder = builder
        } else {
            admittedBuilder = { snapshot, _ in
                ChatTranscriptPresentation.timeline(
                    in: snapshot,
                    performanceSignposts: performanceSignposts
                )
            }
        }
        projectionWorker = ChatTranscriptProjectionWorker(builder: admittedBuilder)
    }

    /// Returns true only when this exact source introduced new projection work.
    @discardableResult
    func submit(snapshot: SessionSnapshot, tag: ChatTranscriptProjectionTag) -> Bool {
        precondition(
            ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: tag.presentationGeneration
            ) == tag
        )
        if installed?.tag == tag || buildingTag == tag {
            desiredTag = tag
            pending = nil
            failWaiters(except: tag, error: .superseded)
            return false
        }
        if pending?.tag == tag {
            desiredTag = tag
            return false
        }

        if let installed, !installed.tag.matchesIdentity(of: tag) {
            self.installed = nil
        }
        desiredTag = tag
        pending = PendingProjection(snapshot: snapshot, tag: tag, generation: generation)
        failWaiters(except: tag, error: .superseded)
        startWorkerIfNeeded()
        return true
    }

    func waitForInstall(of tag: ChatTranscriptProjectionTag) async throws -> InstalledChatTranscript {
        if let installed, installed.tag == tag { return installed }
        guard desiredTag == tag || pending?.tag == tag || buildingTag == tag else {
            throw ChatTranscriptPresentationStoreError.superseded
        }

        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let installed, installed.tag == tag {
                    continuation.resume(returning: installed)
                    return
                }
                guard desiredTag == tag || pending?.tag == tag || buildingTag == tag else {
                    continuation.resume(throwing: ChatTranscriptPresentationStoreError.superseded)
                    return
                }
                if waiters.count >= maximumWaiters {
                    let evicted = waiters.removeFirst()
                    evicted.continuation.resume(
                        throwing: ChatTranscriptPresentationStoreError.waiterLimitReached
                    )
                }
                waiters.append(.init(id: waiterID, tag: tag, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id: waiterID) }
        }
    }

    func reset() {
        generation &+= 1
        desiredTag = nil
        pending = nil
        buildingTag = nil
        installed = nil
        failAllWaiters(with: CancellationError())
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let next = self.pending {
                self.pending = nil
                self.buildingTag = next.tag
                let built = await self.projectionWorker.build(
                    snapshot: next.snapshot,
                    tag: next.tag
                )
                guard !Task.isCancelled else { break }
                self.buildingTag = nil
                guard self.generation == next.generation else { continue }

                let output = InstalledChatTranscript(tag: next.tag, timeline: built.timeline)
                guard built.isInternallyConsistent else {
                    if self.desiredTag == next.tag {
                        self.desiredTag = nil
                        self.failWaiters(for: next.tag, error: .invalidProjection)
                    }
                    continue
                }
                if self.desiredTag == next.tag {
                    self.installed = output
                    self.resumeWaiters(with: output)
                }
            }
            self.buildingTag = nil
            self.worker = nil
            if self.pending != nil { self.startWorkerIfNeeded() }
        }
    }

    private func resumeWaiters(with output: InstalledChatTranscript) {
        let admitted = waiters.filter { $0.tag == output.tag }
        waiters.removeAll { $0.tag == output.tag }
        admitted.forEach { $0.continuation.resume(returning: output) }
    }

    private func failWaiters(
        for tag: ChatTranscriptProjectionTag,
        error: ChatTranscriptPresentationStoreError
    ) {
        let rejected = waiters.filter { $0.tag == tag }
        waiters.removeAll { $0.tag == tag }
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func failWaiters(
        except tag: ChatTranscriptProjectionTag,
        error: ChatTranscriptPresentationStoreError
    ) {
        let rejected = waiters.filter { $0.tag != tag }
        waiters.removeAll { $0.tag != tag }
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func failAllWaiters(with error: Error) {
        let rejected = waiters
        waiters.removeAll(keepingCapacity: false)
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func cancelWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
