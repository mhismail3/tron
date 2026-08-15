import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Chat transcript presentation store")
struct ChatTranscriptPresentationStoreTests {
    @Test("same exact source coalesces to one detached build")
    func sameSourceCoalesces() async throws {
        try await withTestWatchdog { @MainActor in
            let snapshot = try SessionScenarioBuilder(seed: 1_201)
                .openingTail(targetEncodedBytes: 8_000)
            let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 7)
            let barrier = TranscriptProjectionBarrier()
            let store = ChatTranscriptPresentationStore(builder: barrier.build)

            #expect(store.submit(snapshot: snapshot, tag: tag))
            #expect(!store.submit(snapshot: snapshot, tag: tag))
            await barrier.waitForBuildCount(1)
            barrier.releaseBuild(at: 0)
            let installed = try await store.waitForInstall(of: tag)

            #expect(installed.tag == tag)
            #expect(installed.timeline.isInternallyConsistent)
            #expect(barrier.buildCount == 1)
        }
    }

    @Test("newest exact source wins while detached work stays serial")
    func newestWinsSerially() async throws {
        try await withTestWatchdog { @MainActor in
            var first = try SessionScenarioBuilder(seed: 1_202)
                .openingTail(targetEncodedBytes: 8_000)
            first.revision = 10
            first.eventSequence = 20
            var newest = first
            newest.revision = 11
            newest.eventSequence = 21
            newest.streaming = newest.transcript.last
            let firstTag = ChatTranscriptProjectionTag(snapshot: first, presentationGeneration: 8)
            let newestTag = ChatTranscriptProjectionTag(snapshot: newest, presentationGeneration: 8)
            let barrier = TranscriptProjectionBarrier()
            let store = ChatTranscriptPresentationStore(builder: barrier.build)

            store.submit(snapshot: first, tag: firstTag)
            await barrier.waitForBuildCount(1)
            store.submit(snapshot: newest, tag: newestTag)
            barrier.releaseBuild(at: 0)
            await barrier.waitForBuildCount(2)
            #expect(barrier.maximumConcurrentBuilds == 1)
            barrier.releaseBuild(at: 1)

            let installed = try await store.waitForInstall(of: newestTag)
            #expect(installed.tag == newestTag)
            #expect(store.installed?.tag == newestTag)
            #expect(barrier.maximumConcurrentBuilds == 1)
            await #expect(throws: ChatTranscriptPresentationStoreError.superseded) {
                try await store.waitForInstall(of: firstTag)
            }
        }
    }

    @Test("A B A admission reuses the in-flight A and discards B")
    func ABAAdmission() async throws {
        try await withTestWatchdog { @MainActor in
            var a = try SessionScenarioBuilder(seed: 1_203)
                .openingTail(targetEncodedBytes: 8_000)
            a.revision = 30
            var b = a
            b.revision = 31
            b.eventSequence += 1
            let aTag = ChatTranscriptProjectionTag(snapshot: a, presentationGeneration: 9)
            let bTag = ChatTranscriptProjectionTag(snapshot: b, presentationGeneration: 9)
            let barrier = TranscriptProjectionBarrier()
            let store = ChatTranscriptPresentationStore(builder: barrier.build)

            store.submit(snapshot: a, tag: aTag)
            await barrier.waitForBuildCount(1)
            store.submit(snapshot: b, tag: bTag)
            #expect(!store.submit(snapshot: a, tag: aTag))
            barrier.releaseBuild(at: 0)

            let installed = try await store.waitForInstall(of: aTag)
            #expect(installed.tag == aTag)
            #expect(barrier.buildCount == 1)
            await #expect(throws: ChatTranscriptPresentationStoreError.superseded) {
                try await store.waitForInstall(of: bTag)
            }
        }
    }

    @Test("paging bounds distinguish projections without revision advancement")
    func pagingTagDistinction() throws {
        var snapshot = try SessionScenarioBuilder(seed: 1_204)
            .openingTail(targetEncodedBytes: 8_000)
        snapshot.transcriptStart = 10
        snapshot.transcriptTotal = snapshot.transcript.count + 10
        let original = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 10)

        snapshot.transcript.insert(
            contentsOf: SessionScenarioBuilder(seed: 1_205)
                .historyPage(count: 2, longRowBytes: 16),
            at: 0
        )
        snapshot.transcriptStart = 8
        let paged = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 10)

        #expect(original.canonicalGeneration == paged.canonicalGeneration)
        #expect(original.timelineGeneration == paged.timelineGeneration)
        #expect(original != paged)
    }

    @Test("warm canonical cache rejects changed paging bounds and edge identity")
    func warmCachePagingParity() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_211)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.transcriptStart = 10
            snapshot.transcriptTotal = snapshot.transcript.count + 10
            let signposts = RecordingPerformanceSignposts()
            let store = ChatTranscriptPresentationStore(performanceSignposts: signposts)
            var tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 16,
                canonicalGeneration: 50,
                timelineGeneration: 1
            )
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            snapshot.transcript.insert(
                contentsOf: SessionScenarioBuilder(seed: 1_212)
                    .historyPage(count: 2, longRowBytes: 16),
                at: 0
            )
            snapshot.transcriptStart = 8
            tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 16,
                canonicalGeneration: 50,
                timelineGeneration: 1
            )
            store.submit(snapshot: snapshot, tag: tag)
            let installed = try await store.waitForInstall(of: tag)

            #expect(installed.timeline == ChatTranscriptPresentation.timeline(in: snapshot))
            #expect(signposts.events().filter { $0 == .begin(.chatProjection) }.count == 2)
        }
    }

    @Test("reset rejects late detached completion and exact waiters")
    func resetRejectsLateCompletion() async throws {
        try await withTestWatchdog { @MainActor in
            let snapshot = try SessionScenarioBuilder(seed: 1_206)
                .openingTail(targetEncodedBytes: 8_000)
            let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 11)
            var obsoleteReplacement = snapshot
            obsoleteReplacement.eventSequence += 1
            let obsoleteReplacementTag = ChatTranscriptProjectionTag(
                snapshot: obsoleteReplacement,
                presentationGeneration: 11
            )
            var replacement = snapshot
            replacement.eventSequence += 2
            let replacementTag = ChatTranscriptProjectionTag(
                snapshot: replacement,
                presentationGeneration: 11
            )
            let barrier = TranscriptProjectionBarrier()
            let store = ChatTranscriptPresentationStore(builder: barrier.build)

            store.submit(snapshot: snapshot, tag: tag)
            await barrier.waitForBuildCount(1)
            let waiter = Task { @MainActor in try await store.waitForInstall(of: tag) }
            store.reset()
            store.submit(snapshot: obsoleteReplacement, tag: obsoleteReplacementTag)
            store.reset()
            store.submit(snapshot: replacement, tag: replacementTag)
            barrier.releaseBuild(at: 0)
            await barrier.waitForBuildCount(2)
            #expect(barrier.maximumConcurrentBuilds == 1)
            barrier.releaseBuild(at: 1)
            let replacementInstall = try await store.waitForInstall(of: replacementTag)

            do {
                _ = try await waiter.value
                Issue.record("reset waiter unexpectedly installed")
            } catch {
                #expect(
                    error is CancellationError
                        || error as? ChatTranscriptPresentationStoreError == .superseded
                )
            }
            #expect(replacementInstall.tag == replacementTag)
            #expect(store.installed?.tag == replacementTag)
            #expect(barrier.buildCount == 2)
        }
    }

    @Test("completed projection remains atomic until its controlled frame boundary")
    func frameGatesCompletedProjection() async throws {
        try await withTestWatchdog { @MainActor in
            let snapshot = try SessionScenarioBuilder(seed: 1_210)
                .openingTail(targetEncodedBytes: 8_000)
            let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 15)
            let builds = TranscriptProjectionBarrier()
            let frames = ManualProjectionFrameScheduler()
            let store = ChatTranscriptPresentationStore(
                installationFrameScheduler: frames.scheduler,
                builder: builds.build
            )

            store.submit(snapshot: snapshot, tag: tag)
            await builds.waitForBuildCount(1)
            builds.releaseBuild(at: 0)
            await frames.waitForRequest(count: 1)
            #expect(store.installed == nil)

            frames.releaseNext()
            let installed = try await store.waitForInstall(of: tag)
            #expect(installed.tag == tag)
            #expect(store.installed?.tag == tag)
        }
    }

    @Test("text streaming reuses one maximum-page canonical projection")
    func textStreamingReusesCanonicalProjection() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) { @MainActor in
            let builder = SessionScenarioBuilder(seed: 1_209)
            var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
            let totalEntries = 10_000
            snapshot.transcript = builder.pagedMixedSession(totalEntries: totalEntries).page(
                before: totalEntries,
                count: totalEntries
            )
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = totalEntries
            let signposts = RecordingPerformanceSignposts()
            let store = ChatTranscriptPresentationStore(performanceSignposts: signposts)
            var tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 14,
                canonicalGeneration: 40,
                timelineGeneration: 0
            )
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            for update in 1...30 {
                snapshot.streaming = try streamingMessage(update: update)
                tag = ChatTranscriptProjectionTag(
                    snapshot: snapshot,
                    presentationGeneration: 14,
                    canonicalGeneration: 40,
                    timelineGeneration: update
                )
                store.submit(snapshot: snapshot, tag: tag)
                _ = try await store.waitForInstall(of: tag)
            }

            let installed = try #require(store.installed)
            let cold = ChatTranscriptPresentation.timeline(in: snapshot)
            #expect(installed.timeline == cold)
            #expect(installed.timeline.items.canonical.count == cold.items.count - 1)
            #expect(installed.timeline.items.live.count == 1)
            #expect(signposts.events().filter { $0 == .begin(.chatProjection) }.count == 1)
        }
    }

    @Test("runtime-only updates reuse transcript projection and install exact pills")
    func runtimeUpdatesReuseProjection() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_213)
                .openingTail(targetEncodedBytes: 8_000)
            let signposts = RecordingPerformanceSignposts()
            let store = ChatTranscriptPresentationStore(performanceSignposts: signposts)
            var tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 17,
                canonicalGeneration: 60,
                timelineGeneration: 1
            )
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            snapshot.extensionUI.statuses["sync"] = "Synchronizing"
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 17,
                canonicalGeneration: 60,
                timelineGeneration: 2
            )
            store.submit(snapshot: snapshot, tag: tag)
            let installed = try await store.waitForInstall(of: tag)

            #expect(installed.runtimeItems.map(\.id) == ["runtime-status-sync"])
            #expect(signposts.events().filter { $0 == .begin(.chatProjection) }.count == 1)
            #expect(store.pendingEntranceIDs == ["runtime-status-sync"])
            #expect(store.entranceState(for: "runtime-status-sync") == .pending)
            #expect(!store.resolveEntrance(id: "runtime-status-sync", isVisible: false))
            #expect(store.entranceState(for: "runtime-status-sync") == .none)
        }
    }

    @Test("exact pending compaction becomes canonical in place")
    func compactionTransitionIdentity() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_217)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = snapshot.transcript.count
            snapshot.phase = .compacting
            snapshot.extensionUI.working = .init(message: nil, visible: true)
            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 19)
            store.submit(snapshot: snapshot, tag: tag)
            let pending = try await store.waitForInstall(of: tag)
            let pendingID = try #require(pending.runtimeItems.first?.id)

            snapshot.transcript.append(try compactionItem(id: "finished-compaction"))
            snapshot.transcriptTotal! += 1
            snapshot.phase = .idle
            snapshot.extensionUI.working.visible = false
            snapshot.revision += 1
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 19)
            store.submit(snapshot: snapshot, tag: tag)
            let completed = try await store.waitForInstall(of: tag)

            #expect(completed.runtimeItems.isEmpty)
            #expect(completed.timeline.items.last?.id == pendingID)
            #expect(store.pendingEntranceIDs.isEmpty)
        }
    }

    @Test("discrete entrances admit tail extension but never prepend or initial load")
    func entranceClassification() async throws {
        try await withTestWatchdog { @MainActor in
            let builder = SessionScenarioBuilder(seed: 1_214)
            var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
            snapshot.transcriptStart = 4
            snapshot.transcriptTotal = 4 + snapshot.transcript.count
            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 18)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)
            #expect(store.pendingEntranceIDs.isEmpty)

            let appended = SessionScenarioBuilder(seed: 1_216)
                .historyPage(count: 1, longRowBytes: 24)[0]
            snapshot.transcript.append(appended)
            snapshot.transcriptTotal! += 1
            snapshot.revision += 1
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 18)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)
            #expect(store.pendingEntranceIDs.contains(appended.id))
            #expect(store.resolveEntrance(id: appended.id, isVisible: true))
            #expect(store.entranceState(for: appended.id) == .admitted)

            let older = SessionScenarioBuilder(seed: 1_215)
                .historyPage(count: 1, longRowBytes: 24)[0]
            snapshot.transcript.insert(older, at: 0)
            snapshot.transcriptStart! -= 1
            snapshot.revision += 1
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 18)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)
            #expect(store.pendingEntranceIDs.isEmpty)
            #expect(store.entranceState(for: appended.id) == .admitted)
        }
    }

    @Test("exact bounded-tail rollover admits only the appended row")
    func boundedTailRolloverEntrance() async throws {
        try await withTestWatchdog { @MainActor in
            let builder = SessionScenarioBuilder(seed: 1_218)
            var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
            snapshot.transcript = builder.historyPage(
                count: ChatTranscriptPageRequest.maximumItemCount,
                longRowBytes: 16
            )
            snapshot.transcriptStart = 100
            snapshot.transcriptTotal = 100 + snapshot.transcript.count
            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 20)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            let appended = try #require(
                SessionScenarioBuilder(seed: 1_219).historyPage(count: 1, longRowBytes: 16).first
            )
            snapshot.transcript.removeFirst()
            snapshot.transcript.append(appended)
            snapshot.transcriptStart! += 1
            snapshot.transcriptTotal! += 1
            snapshot.revision += 1
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 20)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            #expect(store.pendingEntranceIDs == [appended.id])
            #expect(store.resolveEntrance(id: appended.id, isVisible: true))

            var rewritten = snapshot
            rewritten.transcript[10] = try #require(
                SessionScenarioBuilder(seed: 1_220).historyPage(count: 1, longRowBytes: 16).first
            )
            rewritten.revision += 1
            rewritten.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: rewritten, presentationGeneration: 20)
            store.submit(snapshot: rewritten, tag: tag)
            _ = try await store.waitForInstall(of: tag)
            #expect(store.pendingEntranceIDs.isEmpty)
        }
    }

    @Test("prepending into a full retained window never becomes an entrance")
    func fullWindowPrependDoesNotAnimate() async throws {
        try await withTestWatchdog { @MainActor in
            let builder = SessionScenarioBuilder(seed: 1_221)
            var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
            snapshot.transcript = builder.historyPage(
                count: ChatTranscriptPageRequest.maximumItemCount,
                longRowBytes: 16
            )
            snapshot.transcriptStart = 100
            snapshot.transcriptTotal = 100 + snapshot.transcript.count
            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 21)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            let older = try #require(
                SessionScenarioBuilder(seed: 1_222).historyPage(count: 1, longRowBytes: 16).first
            )
            snapshot.transcript.insert(older, at: 0)
            snapshot.transcriptStart! -= 1
            snapshot.revision += 1
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 21)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            #expect(store.pendingEntranceIDs.isEmpty)
            #expect(store.entranceState(for: older.id) == .none)
        }
    }

    @Test("maximum canonical page prepares off-main and installs one complete timeline")
    func maximumPageProjection() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) { @MainActor in
            let builder = SessionScenarioBuilder(seed: 1_208)
            var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
            let totalEntries = 10_000
            snapshot.transcript = builder.pagedMixedSession(totalEntries: totalEntries).page(
                before: totalEntries,
                count: totalEntries
            )
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = totalEntries
            let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 13)
            let store = ChatTranscriptPresentationStore()

            store.submit(snapshot: snapshot, tag: tag)
            var mainActorMutation = 0
            mainActorMutation += 1
            #expect(mainActorMutation == 1)
            let installed = try await store.waitForInstall(of: tag)
            #expect(installed.timeline.isInternallyConsistent)
            #expect(!installed.timeline.items.isEmpty)
        }
    }

    @Test("blocked detached projection never blocks MainActor responsiveness")
    func mainActorRemainsResponsive() async throws {
        try await withTestWatchdog { @MainActor in
            let snapshot = try SessionScenarioBuilder(seed: 1_207)
                .openingTail(targetEncodedBytes: 8_000)
            let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 12)
            let barrier = TranscriptProjectionBarrier()
            let store = ChatTranscriptPresentationStore(builder: barrier.build)

            store.submit(snapshot: snapshot, tag: tag)
            await barrier.waitForBuildCount(1)
            var mainActorMutation = 0
            mainActorMutation += 1
            #expect(mainActorMutation == 1)
            #expect(store.installed == nil)

            barrier.releaseBuild(at: 0)
            _ = try await store.waitForInstall(of: tag)
        }
    }
}

private func compactionItem(id: String) throws -> TranscriptItem {
    try JSONDecoder.gateway.decode(
        TranscriptItem.self,
        from: Data("""
        {"id":"\(id)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"Compacted summary","tokensBefore":1200}
        """.utf8)
    )
}

private func streamingMessage(update: Int) throws -> TranscriptItem {
    try JSONDecoder.gateway.decode(
        TranscriptItem.self,
        from: Data("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"thinking","type":"thinking","text":"Working"},{"id":"answer","type":"text","text":"update-\(update)"}]}
        """.utf8)
    )
}

private final class TranscriptProjectionBarrier: @unchecked Sendable {
    private struct Build {
        let tag: ChatTranscriptProjectionTag
        let semaphore: DispatchSemaphore
    }

    private let lock = NSLock()
    private var builds: [Build] = []
    private struct BuildWaiter {
        let id: Int
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var buildWaiters: [BuildWaiter] = []
    private var nextBuildWaiterID = 0
    private var activeBuilds = 0
    private var maximumActiveBuilds = 0

    var buildCount: Int {
        lock.withLock { builds.count }
    }

    var maximumConcurrentBuilds: Int {
        lock.withLock { maximumActiveBuilds }
    }

    func build(
        snapshot: SessionSnapshot,
        tag: ChatTranscriptProjectionTag
    ) -> ChatTranscriptTimeline {
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        builds.append(.init(tag: tag, semaphore: semaphore))
        activeBuilds += 1
        maximumActiveBuilds = max(maximumActiveBuilds, activeBuilds)
        let count = builds.count
        let ready = buildWaiters.filter { $0.targetCount <= count }
        buildWaiters.removeAll { $0.targetCount <= count }
        lock.unlock()
        ready.forEach { $0.continuation.resume() }

        semaphore.wait()
        lock.withLock { activeBuilds -= 1 }
        return ChatTranscriptPresentation.timeline(in: snapshot)
    }

    func waitForBuildCount(_ target: Int) async {
        if buildCount >= target { return }
        let id = lock.withLock {
            defer { nextBuildWaiterID += 1 }
            return nextBuildWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled || builds.count >= target {
                    lock.unlock()
                    continuation.resume()
                } else {
                    buildWaiters.append(.init(
                        id: id,
                        targetCount: target,
                        continuation: continuation
                    ))
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancelBuildWaiter(id: id)
        }
    }

    func releaseBuild(at index: Int) {
        let semaphore = lock.withLock { builds[index].semaphore }
        semaphore.signal()
    }

    private func cancelBuildWaiter(id: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let index = buildWaiters.firstIndex(where: { $0.id == id }) else { return nil }
            return buildWaiters.remove(at: index).continuation
        }
        continuation?.resume()
    }
}

@MainActor
private final class ManualProjectionFrameScheduler {
    private struct RequestWaiter {
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var requestWaiters: [RequestWaiter] = []
    private(set) var requestCount = 0

    lazy var scheduler = DisplayFrameScheduler { [weak self] in
        guard let self else { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation in
            requestCount += 1
            continuations.append(continuation)
            let ready = requestWaiters.filter { $0.targetCount <= requestCount }
            requestWaiters.removeAll { $0.targetCount <= requestCount }
            ready.forEach { $0.continuation.resume() }
        }
    }

    func waitForRequest(count: Int) async {
        if requestCount >= count { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(.init(targetCount: count, continuation: continuation))
        }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}
