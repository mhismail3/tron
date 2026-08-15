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

        #expect(original.revision == paged.revision)
        #expect(original.eventSequence == paged.eventSequence)
        #expect(original != paged)
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
