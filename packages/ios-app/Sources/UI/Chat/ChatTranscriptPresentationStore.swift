import Foundation
import Observation

struct ChatTranscriptProjectionTag: Hashable, Sendable {
    let sessionID: String
    let presentationGeneration: Int
    let runtimeGeneration: String
    let canonicalGeneration: Int
    let timelineGeneration: Int
    let transcriptStart: Int?
    let transcriptTotal: Int?
    let transcriptCount: Int
    let firstTranscriptID: String?
    let lastTranscriptID: String?

    init(
        snapshot: SessionSnapshot,
        presentationGeneration: Int,
        canonicalGeneration: Int? = nil,
        timelineGeneration: Int? = nil
    ) {
        sessionID = snapshot.sessionId
        self.presentationGeneration = presentationGeneration
        runtimeGeneration = snapshot.runtimeGeneration
        self.canonicalGeneration = canonicalGeneration ?? snapshot.revision
        self.timelineGeneration = timelineGeneration ?? snapshot.eventSequence
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

enum ChatTranscriptEntranceState: Equatable, Sendable {
    case none
    case pending
    case admitted
}

struct ChatDisplayedTranscriptItems: RandomAccessCollection {
    typealias Index = Int
    let timeline: ChatTranscriptItems
    let runtime: [ChatTranscriptRenderItem]

    var startIndex: Int { 0 }
    var endIndex: Int { timeline.count + runtime.count }

    subscript(position: Int) -> ChatTranscriptRenderItem {
        precondition(indices.contains(position))
        return position < timeline.count
            ? timeline[position]
            : runtime[position - timeline.count]
    }
}

struct InstalledChatTranscript: Hashable, Sendable {
    struct SourceWindow: Hashable, Sendable {
        let originalStart: Int?
        let originalCount: Int
        let start: Int?
        let total: Int?
        let ids: [String]
        let hasExactBounds: Bool
        let hasUniqueIDs: Bool

        init(snapshot: SessionSnapshot) {
            let sourceStart = snapshot.transcriptStart
            let sourceCount = snapshot.transcript.count
            originalStart = sourceStart
            originalCount = sourceCount
            let maximum = ChatTranscriptPageRequest.maximumItemCount
            let dropped = max(0, sourceCount - maximum)
            ids = Array(snapshot.transcript.suffix(maximum).map(\.id))
            start = sourceStart.map { $0 + dropped }
            total = snapshot.transcriptTotal
            hasExactBounds = sourceStart.map {
                $0 + sourceCount == snapshot.transcriptTotal
            } == true
            hasUniqueIDs = Set(ids).count == ids.count
        }
    }

    let tag: ChatTranscriptProjectionTag
    let timeline: ChatTranscriptTimeline
    let runtimeItems: [ChatTranscriptRenderItem]
    let sourceWindow: SourceWindow
    let displayedIDSet: Set<String>

    init(
        tag: ChatTranscriptProjectionTag,
        timeline: ChatTranscriptTimeline,
        runtimeItems: [ChatTranscriptRenderItem],
        sourceWindow: SourceWindow
    ) {
        self.tag = tag
        self.timeline = timeline
        self.runtimeItems = runtimeItems
        self.sourceWindow = sourceWindow
        displayedIDSet = Set(timeline.ids).union(runtimeItems.map(\.id))
    }

    var displayedItems: ChatDisplayedTranscriptItems {
        ChatDisplayedTranscriptItems(timeline: timeline.items, runtime: runtimeItems)
    }
    var displayedIDs: [String] { timeline.ids + runtimeItems.map(\.id) }
    func containsDisplayedID(_ id: String) -> Bool { displayedIDSet.contains(id) }
}

enum ChatTranscriptTransitionPolicy {
    static func discreteInsertedIDs(
        previous: InstalledChatTranscript?,
        next: InstalledChatTranscript
    ) -> Set<String> {
        guard let previous,
              previous.tag.matchesIdentity(of: next.tag) else { return [] }
        let sameSource = previous.sourceWindow.originalStart == next.sourceWindow.originalStart
            && previous.sourceWindow.originalCount == next.sourceWindow.originalCount
            && previous.sourceWindow.start == next.sourceWindow.start
            && previous.sourceWindow.total == next.sourceWindow.total
            && previous.sourceWindow.ids == next.sourceWindow.ids
        let renderedPrefixExtension = next.timeline.items.canonical.map(\.id)
            .starts(with: previous.timeline.items.canonical.map(\.id))
        guard sameSource
                || isExactForwardEvolution(from: previous.sourceWindow, to: next.sourceWindow)
                || renderedPrefixExtension else { return [] }

        let previousIDs = Set(previous.displayedIDs)
        let inserted = next.displayedIDs.filter { !previousIDs.contains($0) }
        return Set(inserted.prefix(ChatTranscriptPageRequest.maximumItemCount))
    }

    /// Source ordinals, rather than rendered grouping, distinguish a forward
    /// bounded-tail rollover from prepend or replacement. Both windows are
    /// capped at the Gateway page bound before reaching MainActor publication.
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
              previousOffset + overlapCount <= previous.ids.count,
              nextOffset + overlapCount <= next.ids.count else { return false }
        return previous.ids[previousOffset..<(previousOffset + overlapCount)].elementsEqual(
            next.ids[nextOffset..<(nextOffset + overlapCount)]
        )
    }
}

enum ChatTranscriptPresentationStoreError: Error, Equatable, Sendable {
    case superseded
    case waiterLimitReached
    case invalidProjection
}

#if HOSTED_TEST
/// Deterministic `HOSTED_TEST`-only scheduling seam. It may delay the real
/// production kernel but cannot replace or manufacture projection output.
typealias ChatTranscriptProjectionWorkGate = @Sendable (ChatTranscriptProjectionTag) -> Void
#endif

private struct BuiltChatTranscript: Sendable {
    let timeline: ChatTranscriptTimeline
    let isInternallyConsistent: Bool
}

private actor ChatTranscriptProjectionWorker {
    private struct TimelineKey: Equatable, Sendable {
        let cacheEpoch: Int
        let sessionID: String
        let presentationGeneration: Int
        let runtimeGeneration: String
        let canonicalGeneration: Int
        let transcriptStart: Int?
        let transcriptTotal: Int?
        let transcriptCount: Int
        let firstTranscriptID: String?
        let lastTranscriptID: String?
        let phase: SessionPhase
        let streaming: TranscriptItem?
        let toolExecutions: [ToolExecutionState]

        init(tag: ChatTranscriptProjectionTag, snapshot: SessionSnapshot, cacheEpoch: Int) {
            self.cacheEpoch = cacheEpoch
            sessionID = tag.sessionID
            presentationGeneration = tag.presentationGeneration
            runtimeGeneration = tag.runtimeGeneration
            canonicalGeneration = tag.canonicalGeneration
            transcriptStart = tag.transcriptStart
            transcriptTotal = tag.transcriptTotal
            transcriptCount = tag.transcriptCount
            firstTranscriptID = tag.firstTranscriptID
            lastTranscriptID = tag.lastTranscriptID
            phase = snapshot.phase
            streaming = snapshot.streaming
            toolExecutions = snapshot.toolExecutions
        }
    }

    private struct CanonicalBaseKey: Equatable, Sendable {
        let cacheEpoch: Int
        let sessionID: String
        let presentationGeneration: Int
        let runtimeGeneration: String
        let canonicalGeneration: Int
        let transcriptStart: Int?
        let transcriptTotal: Int?
        let transcriptCount: Int
        let firstTranscriptID: String?
        let lastTranscriptID: String?
        let phase: SessionPhase
        let toolExecutions: [ToolExecutionState]

        init(tag: ChatTranscriptProjectionTag, snapshot: SessionSnapshot, cacheEpoch: Int) {
            self.cacheEpoch = cacheEpoch
            sessionID = tag.sessionID
            presentationGeneration = tag.presentationGeneration
            runtimeGeneration = tag.runtimeGeneration
            canonicalGeneration = tag.canonicalGeneration
            transcriptStart = tag.transcriptStart
            transcriptTotal = tag.transcriptTotal
            transcriptCount = tag.transcriptCount
            firstTranscriptID = tag.firstTranscriptID
            lastTranscriptID = tag.lastTranscriptID
            phase = snapshot.phase
            toolExecutions = snapshot.toolExecutions
        }
    }

    private let performanceSignposts: any PerformanceSignposting
    private let workRecorder: ChatTranscriptProjectionWorkRecorder?
    #if HOSTED_TEST
    private let workGate: ChatTranscriptProjectionWorkGate?
    #endif
    private var canonicalBaseKey: CanonicalBaseKey?
    private var canonicalBase: ChatTranscriptTimeline?
    private var canonicalBaseIsInternallyConsistent = false
    private var lastTimelineKey: TimelineKey?
    private var lastTimeline: ChatTranscriptTimeline?
    private var lastTimelineIsInternallyConsistent = false

    #if HOSTED_TEST
    init(
        performanceSignposts: any PerformanceSignposting,
        workRecorder: ChatTranscriptProjectionWorkRecorder?,
        workGate: ChatTranscriptProjectionWorkGate?
    ) {
        self.performanceSignposts = performanceSignposts
        self.workRecorder = workRecorder
        self.workGate = workGate
    }
    #else
    init(
        performanceSignposts: any PerformanceSignposting,
        workRecorder: ChatTranscriptProjectionWorkRecorder?
    ) {
        self.performanceSignposts = performanceSignposts
        self.workRecorder = workRecorder
    }
    #endif

    private func cold(snapshot: SessionSnapshot) -> ChatTranscriptTimeline {
        ChatTranscriptProjectionKernel.cold(
            snapshot: snapshot,
            performanceSignposts: performanceSignposts,
            workRecorder: workRecorder
        ).timeline
    }

    #if HOSTED_TEST
    private func hostedGatedCold(
        snapshot: SessionSnapshot,
        tag: ChatTranscriptProjectionTag
    ) -> ChatTranscriptTimeline {
        workGate?(tag)
        return cold(snapshot: snapshot)
    }
    #endif

    func build(
        snapshot: SessionSnapshot,
        tag: ChatTranscriptProjectionTag,
        cacheEpoch: Int
    ) -> BuiltChatTranscript {
        let timelineKey = TimelineKey(tag: tag, snapshot: snapshot, cacheEpoch: cacheEpoch)
        if lastTimelineKey == timelineKey, let lastTimeline {
            return BuiltChatTranscript(
                timeline: lastTimeline,
                isInternallyConsistent: lastTimelineIsInternallyConsistent
            )
        }

        let timeline: ChatTranscriptTimeline
        let isInternallyConsistent: Bool
        if snapshot.toolExecutions.allSatisfy({ $0.status != .running }),
           let streaming = snapshot.streaming,
           let live = ChatTranscriptPresentation.isolatedStreamingTimeline(streaming) {
            let key = CanonicalBaseKey(tag: tag, snapshot: snapshot, cacheEpoch: cacheEpoch)
            if canonicalBaseKey != key || canonicalBase == nil {
                var baseSnapshot = snapshot
                baseSnapshot.streaming = nil
                #if HOSTED_TEST
                canonicalBase = hostedGatedCold(snapshot: baseSnapshot, tag: tag)
                #else
                canonicalBase = cold(snapshot: baseSnapshot)
                #endif
                canonicalBaseKey = key
                canonicalBaseIsInternallyConsistent = canonicalBase!.isInternallyConsistent
            }
            timeline = canonicalBase!.appendingLive(live)
            isInternallyConsistent = canonicalBaseIsInternallyConsistent
                && live.isInternallyConsistent
        } else if snapshot.streaming == nil {
            let key = CanonicalBaseKey(tag: tag, snapshot: snapshot, cacheEpoch: cacheEpoch)
            if canonicalBaseKey != key || canonicalBase == nil {
                #if HOSTED_TEST
                canonicalBase = hostedGatedCold(snapshot: snapshot, tag: tag)
                #else
                canonicalBase = cold(snapshot: snapshot)
                #endif
                canonicalBaseKey = key
                canonicalBaseIsInternallyConsistent = canonicalBase!.isInternallyConsistent
            }
            timeline = canonicalBase!
            isInternallyConsistent = canonicalBaseIsInternallyConsistent
        } else {
            #if HOSTED_TEST
            timeline = hostedGatedCold(snapshot: snapshot, tag: tag)
            #else
            timeline = cold(snapshot: snapshot)
            #endif
            isInternallyConsistent = timeline.isInternallyConsistent
        }
        lastTimelineKey = timelineKey
        lastTimeline = timeline
        lastTimelineIsInternallyConsistent = isInternallyConsistent
        return BuiltChatTranscript(
            timeline: timeline,
            isInternallyConsistent: isInternallyConsistent
        )
    }
}

/// Disposable exact-tagged transcript projection. Canonical session truth stays
/// in `SessionPresentationStore`; this owner serializes expensive formatting off
/// MainActor and atomically installs only the newest complete timeline.
@MainActor
@Observable
final class ChatTranscriptPresentationStore {
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

    #if HOSTED_TEST
    private struct HostedCompletionWaiter {
        let id: UInt64
        let tag: ChatTranscriptProjectionTag
        let continuation: CheckedContinuation<Void, Error>
    }
    #endif

    private(set) var installed: InstalledChatTranscript?
    private(set) var pendingEntranceIDs: Set<String> = []
    private(set) var admittedEntranceIDs: Set<String> = []

    @ObservationIgnored private let projectionWorker: ChatTranscriptProjectionWorker
    @ObservationIgnored private let installationFrameScheduler: DisplayFrameScheduler?
    @ObservationIgnored private let maximumWaiters: Int
    @ObservationIgnored private var desiredTag: ChatTranscriptProjectionTag?
    @ObservationIgnored private var pending: PendingProjection?
    @ObservationIgnored private var buildingTag: ChatTranscriptProjectionTag?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var readyToInstall: InstalledChatTranscript?
    @ObservationIgnored private var installFrameTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var waiters: [Waiter] = []
    @ObservationIgnored private var nextWaiterID: UInt64 = 0
    #if HOSTED_TEST
    @ObservationIgnored private var hostedCompletionWaiters: [HostedCompletionWaiter] = []
    @ObservationIgnored private var nextHostedCompletionWaiterID: UInt64 = 0
    #endif

    #if HOSTED_TEST
    init(
        maximumWaiters: Int = 32,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        workRecorder: ChatTranscriptProjectionWorkRecorder? = nil,
        installationFrameScheduler: DisplayFrameScheduler? = nil,
        workGate: ChatTranscriptProjectionWorkGate? = nil
    ) {
        self.maximumWaiters = max(1, maximumWaiters)
        self.installationFrameScheduler = installationFrameScheduler
        projectionWorker = ChatTranscriptProjectionWorker(
            performanceSignposts: performanceSignposts,
            workRecorder: workRecorder,
            workGate: workGate
        )
    }
    #else
    init(
        maximumWaiters: Int = 32,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        workRecorder: ChatTranscriptProjectionWorkRecorder? = nil,
        installationFrameScheduler: DisplayFrameScheduler? = nil
    ) {
        self.maximumWaiters = max(1, maximumWaiters)
        self.installationFrameScheduler = installationFrameScheduler
        projectionWorker = ChatTranscriptProjectionWorker(
            performanceSignposts: performanceSignposts,
            workRecorder: workRecorder
        )
    }
    #endif

    /// Returns true only when this exact source introduced new projection work.
    @discardableResult
    func submit(snapshot: SessionSnapshot, tag: ChatTranscriptProjectionTag) -> Bool {
        precondition(
            ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: tag.presentationGeneration,
                canonicalGeneration: tag.canonicalGeneration,
                timelineGeneration: tag.timelineGeneration
            ) == tag
        )
        if installed?.tag == tag || buildingTag == tag || readyToInstall?.tag == tag {
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
            pendingEntranceIDs.removeAll(keepingCapacity: true)
            admittedEntranceIDs.removeAll(keepingCapacity: true)
        }
        desiredTag = tag
        pending = PendingProjection(snapshot: snapshot, tag: tag, generation: generation)
        failWaiters(except: tag, error: .superseded)
        #if HOSTED_TEST
        failHostedCompletionWaiters(except: tag, error: .superseded)
        #endif
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

    #if HOSTED_TEST
    /// Deterministic observation for frame-publication race tests. This exposes
    /// no production scheduling control and resumes only after MainActor admits
    /// a complete, validated projection for frame-gated installation.
    func hostedWaitForCompletedProjection(of tag: ChatTranscriptProjectionTag) async throws {
        if installed?.tag == tag || readyToInstall?.tag == tag { return }
        guard desiredTag == tag || pending?.tag == tag || buildingTag == tag else {
            throw ChatTranscriptPresentationStoreError.superseded
        }

        nextHostedCompletionWaiterID &+= 1
        let waiterID = nextHostedCompletionWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if readyToInstall?.tag == tag {
                    continuation.resume()
                } else if desiredTag == tag || pending?.tag == tag || buildingTag == tag {
                    hostedCompletionWaiters.append(.init(
                        id: waiterID,
                        tag: tag,
                        continuation: continuation
                    ))
                } else {
                    continuation.resume(
                        throwing: ChatTranscriptPresentationStoreError.superseded
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelHostedCompletionWaiter(id: waiterID)
            }
        }
    }
    #endif

    func entranceState(for id: String) -> ChatTranscriptEntranceState {
        if admittedEntranceIDs.contains(id) { return .admitted }
        if pendingEntranceIDs.contains(id) { return .pending }
        return .none
    }

    /// Row geometry is the admission evidence. Visible inserted rows reveal once;
    /// realized offscreen rows become immediately visible and never replay later.
    @discardableResult
    func resolveEntrance(id: String, isVisible: Bool) -> Bool {
        guard pendingEntranceIDs.remove(id) != nil else { return false }
        if isVisible { admittedEntranceIDs.insert(id) }
        return isVisible
    }

    /// Direct/native interaction is stronger than a pending visual entrance.
    /// Clearing here prevents lazily realized offscreen rows from replaying later.
    func discardPendingEntrances() {
        pendingEntranceIDs.removeAll(keepingCapacity: true)
    }

    func reset() {
        generation &+= 1
        desiredTag = nil
        pending = nil
        buildingTag = nil
        readyToInstall = nil
        installFrameTask?.cancel()
        installFrameTask = nil
        installed = nil
        pendingEntranceIDs.removeAll(keepingCapacity: false)
        admittedEntranceIDs.removeAll(keepingCapacity: false)
        failAllWaiters(with: CancellationError())
        #if HOSTED_TEST
        failAllHostedCompletionWaiters(with: CancellationError())
        #endif
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
                    tag: next.tag,
                    cacheEpoch: next.generation
                )
                guard !Task.isCancelled else { break }
                self.buildingTag = nil
                guard self.generation == next.generation else { continue }

                let runtimeItems = ChatTranscriptProjectionKernel.runtimeItems(in: next.snapshot)
                let output = InstalledChatTranscript(
                    tag: next.tag,
                    timeline: built.timeline,
                    runtimeItems: runtimeItems,
                    sourceWindow: .init(snapshot: next.snapshot)
                )
                guard built.isInternallyConsistent,
                      output.displayedIDSet.count == output.displayedItems.count else {
                    if self.desiredTag == next.tag {
                        self.desiredTag = nil
                        self.failWaiters(for: next.tag, error: .invalidProjection)
                        #if HOSTED_TEST
                        self.failHostedCompletionWaiters(
                            for: next.tag,
                            error: .invalidProjection
                        )
                        #endif
                    }
                    continue
                }
                if self.desiredTag == next.tag {
                    self.admitCompleted(output)
                }
            }
            self.buildingTag = nil
            self.worker = nil
            if self.pending != nil { self.startWorkerIfNeeded() }
        }
    }

    private func admitCompleted(_ output: InstalledChatTranscript) {
        #if HOSTED_TEST
        resumeHostedCompletionWaiters(for: output.tag)
        #endif
        guard installationFrameScheduler != nil else {
            install(output)
            resumeWaiters(with: output)
            return
        }
        readyToInstall = output
        guard installFrameTask == nil else { return }
        let admittedGeneration = generation
        installFrameTask = Task { [weak self] in
            guard let self, let installationFrameScheduler else { return }
            do {
                try await installationFrameScheduler.nextFrame()
            } catch {
                guard !Task.isCancelled, self.generation == admittedGeneration else { return }
                self.installReadyOutputIfAdmitted()
                return
            }
            guard !Task.isCancelled, self.generation == admittedGeneration else { return }
            self.installReadyOutputIfAdmitted()
        }
    }

    private func installReadyOutputIfAdmitted() {
        let output = readyToInstall
        readyToInstall = nil
        installFrameTask = nil
        guard let output, desiredTag == output.tag else { return }
        install(output)
        resumeWaiters(with: output)
    }

    private func install(_ output: InstalledChatTranscript) {
        let inserted = ChatTranscriptTransitionPolicy.discreteInsertedIDs(
            previous: installed,
            next: output
        )
        let displayedIDs = output.displayedIDSet
        pendingEntranceIDs.formIntersection(displayedIDs)
        admittedEntranceIDs.formIntersection(displayedIDs)
        pendingEntranceIDs.formUnion(inserted.subtracting(admittedEntranceIDs))
        installed = output
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

    #if HOSTED_TEST
    private func resumeHostedCompletionWaiters(for tag: ChatTranscriptProjectionTag) {
        let completed = hostedCompletionWaiters.filter { $0.tag == tag }
        hostedCompletionWaiters.removeAll { $0.tag == tag }
        completed.forEach { $0.continuation.resume() }
    }

    private func failHostedCompletionWaiters(
        for tag: ChatTranscriptProjectionTag,
        error: ChatTranscriptPresentationStoreError
    ) {
        let rejected = hostedCompletionWaiters.filter { $0.tag == tag }
        hostedCompletionWaiters.removeAll { $0.tag == tag }
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func failHostedCompletionWaiters(
        except tag: ChatTranscriptProjectionTag,
        error: ChatTranscriptPresentationStoreError
    ) {
        let rejected = hostedCompletionWaiters.filter { $0.tag != tag }
        hostedCompletionWaiters.removeAll { $0.tag != tag }
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func failAllHostedCompletionWaiters(with error: Error) {
        let rejected = hostedCompletionWaiters
        hostedCompletionWaiters.removeAll(keepingCapacity: false)
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func cancelHostedCompletionWaiter(id: UInt64) {
        guard let index = hostedCompletionWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        hostedCompletionWaiters.remove(at: index).continuation.resume(
            throwing: CancellationError()
        )
    }
    #endif
}
