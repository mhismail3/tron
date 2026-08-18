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
            let store = ChatTranscriptPresentationStore(workGate: barrier.block)

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

    @Test("queue cards install atomically with their exact transcript source")
    func queueInstallsWithTranscript() async throws {
        try await withTestWatchdog { @MainActor in
            var queued = try SessionScenarioBuilder(seed: 1_211)
                .openingTail(targetEncodedBytes: 8_000)
            queued.queueRevision = 4
            queued.queuedItems = [
                .init(id: "queued", behavior: .steer, text: "next", attachmentCount: 1),
            ]
            queued.queued = .init(steering: ["next"], followUp: [])
            let queuedTag = ChatTranscriptProjectionTag(snapshot: queued, presentationGeneration: 7)
            let store = ChatTranscriptPresentationStore()

            store.submit(snapshot: queued, tag: queuedTag)
            let first = try await store.waitForInstall(of: queuedTag)
            #expect(first.queuedMessages == queued.queuedItems)
            #expect(first.queueRevision == 4)
            #expect(first.supportsQueueManagement)

            var consumed = queued
            consumed.revision += 1
            consumed.eventSequence += 1
            consumed.queueRevision = 5
            consumed.queuedItems = []
            consumed.queued = .init(steering: [], followUp: [])
            consumed.transcript.append(contentsOf: SessionScenarioBuilder(seed: 1_212)
                .historyPage(count: 1, longRowBytes: 16))
            consumed.transcriptTotal = consumed.transcript.count
            let consumedTag = ChatTranscriptProjectionTag(
                snapshot: consumed,
                presentationGeneration: 7
            )

            store.submit(snapshot: consumed, tag: consumedTag)
            let second = try await store.waitForInstall(of: consumedTag)
            #expect(second.queuedMessages == [])
            #expect(second.queueRevision == 5)
            #expect(second.timeline.items.count >= first.timeline.items.count)
            #expect(store.installed == second)
        }
    }

    @Test("installed text preparation is bounded to its exact source and drops on memory pressure")
    func preparedTextMemoryPressure() async throws {
        try await withTestWatchdog { @MainActor in
            let snapshot = try SessionScenarioBuilder(seed: 1_213)
                .openingTail(targetEncodedBytes: 16_000)
            #expect(!ChatTextPreparationPolicy.sources(in: snapshot).isEmpty)
            let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 7)
            let store = ChatTranscriptPresentationStore()

            store.submit(snapshot: snapshot, tag: tag)
            let installed = try await store.waitForInstall(of: tag)
            #expect(installed.preparedText != .empty)

            store.handleMemoryPressure()
            #expect(store.installed?.tag == tag)
            #expect(store.installed?.timeline == installed.timeline)
            #expect(store.installed?.preparedText == .empty)
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
            let store = ChatTranscriptPresentationStore(workGate: barrier.block)

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
            let store = ChatTranscriptPresentationStore(workGate: barrier.block)

            store.submit(snapshot: a, tag: aTag)
            await barrier.waitForBuildCount(1)
            store.submit(snapshot: b, tag: bTag)
            let registration = CompletionWaiterRegistration()
            let bCompletion = Task { @MainActor in
                try await store.hostedWaitForCompletedProjection(
                    of: bTag,
                    onRegistered: registration.signal
                )
            }
            await registration.wait()
            #expect(!store.submit(snapshot: a, tag: aTag))
            await #expect(throws: ChatTranscriptPresentationStoreError.superseded) {
                try await bCompletion.value
            }
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
            let store = ChatTranscriptPresentationStore(workGate: barrier.block)

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
                workGate: builds.block
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

    @Test("two completed projections before one frame publish only the newest")
    func newestCompletedProjectionWinsFrameRace() async throws {
        try await withTestWatchdog { @MainActor in
            var first = try SessionScenarioBuilder(seed: 1_223)
                .openingTail(targetEncodedBytes: 8_000)
            first.revision = 70
            first.eventSequence = 80
            var newest = first
            newest.revision = 71
            newest.eventSequence = 81
            newest.streaming = newest.transcript.last
            let firstTag = ChatTranscriptProjectionTag(
                snapshot: first,
                presentationGeneration: 22
            )
            let newestTag = ChatTranscriptProjectionTag(
                snapshot: newest,
                presentationGeneration: 22
            )
            let frames = ManualProjectionFrameScheduler()
            let store = ChatTranscriptPresentationStore(
                installationFrameScheduler: frames.scheduler
            )

            store.submit(snapshot: first, tag: firstTag)
            let firstWaiter = Task { @MainActor in
                try await store.waitForInstall(of: firstTag)
            }
            try await store.hostedWaitForCompletedProjection(of: firstTag)
            await frames.waitForRequest(count: 1)

            store.submit(snapshot: newest, tag: newestTag)
            try await store.hostedWaitForCompletedProjection(of: newestTag)
            #expect(store.installed == nil)
            #expect(frames.requestCount == 1)

            frames.releaseNext()
            let installed = try await store.waitForInstall(of: newestTag)
            #expect(installed.tag == newestTag)
            #expect(store.installed?.tag == newestTag)
            await #expect(throws: ChatTranscriptPresentationStoreError.superseded) {
                try await firstWaiter.value
            }
        }
    }

    @Test("reset after completion but before frame prevents install and rejects waiter")
    func resetWinsCompletedProjectionFrameRace() async throws {
        try await withTestWatchdog { @MainActor in
            let snapshot = try SessionScenarioBuilder(seed: 1_224)
                .openingTail(targetEncodedBytes: 8_000)
            let tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 23
            )
            let frames = ManualProjectionFrameScheduler()
            let store = ChatTranscriptPresentationStore(
                installationFrameScheduler: frames.scheduler
            )

            store.submit(snapshot: snapshot, tag: tag)
            let waiter = Task { @MainActor in
                try await store.waitForInstall(of: tag)
            }
            try await store.hostedWaitForCompletedProjection(of: tag)
            await frames.waitForRequest(count: 1)
            #expect(store.installed == nil)

            store.reset()
            frames.releaseNext()
            do {
                _ = try await waiter.value
                Issue.record("Reset projection waiter unexpectedly installed")
            } catch {
                #expect(
                    error is CancellationError
                        || error as? ChatTranscriptPresentationStoreError == .superseded
                )
            }
            #expect(store.installed == nil)
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
            #expect(signposts.events().filter { $0 == .begin(.chatProjection) }.count == 31)
        }
    }

    @Test("runtime-only updates reuse projection while hiding statuses and preserving working")
    func runtimeUpdatesReuseProjection() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_213)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.phase = .running
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

            snapshot.extensionPresentation.semanticState.statuses["sync"] = "Synchronizing"
            snapshot.extensionPresentation.semanticState.working = .init(message: "Still working", visible: true)
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 17,
                canonicalGeneration: 60,
                timelineGeneration: 2
            )
            store.submit(snapshot: snapshot, tag: tag)
            let installed = try await store.waitForInstall(of: tag)

            #expect(installed.runtimeItems.map(\.id) == ["runtime-working"])
            #expect(signposts.events().filter { $0 == .begin(.chatProjection) }.count == 1)
            #expect(store.pendingEntranceIDs == ["runtime-working"])
            #expect(store.entranceState(for: "runtime-working") == .pending)
            #expect(!store.resolveEntrance(
                id: "runtime-working",
                installationTag: tag,
                isVisible: false
            ))
            #expect(store.entranceState(for: "runtime-working") == .none)
        }
    }

    @Test("model-ahead completion cannot suppress displayed running-tool entrance")
    func desiredCompletionDoesNotSuppressDisplayedEntrance() async throws {
        try await withTestWatchdog { @MainActor in
            var baseline = try SessionScenarioBuilder(seed: 1_232)
                .openingTail(targetEncodedBytes: 8_000)
            baseline.phase = .idle
            baseline.streaming = nil
            baseline.toolExecutions = []
            let store = ChatTranscriptPresentationStore()
            let baselineTag = ChatTranscriptProjectionTag(
                snapshot: baseline,
                presentationGeneration: 31
            )
            store.submit(snapshot: baseline, tag: baselineTag)
            _ = try await store.waitForInstall(of: baselineTag)

            var running = baseline
            running.phase = .running
            running.toolExecutions = [storeRuntimeTool(
                id: "model-ahead",
                output: "running",
                progressSequence: 1
            )]
            running.eventSequence += 1
            let runningTag = ChatTranscriptProjectionTag(
                snapshot: running,
                presentationGeneration: 31
            )
            store.submit(snapshot: running, tag: runningTag)
            let runningInstall = try await store.waitForInstall(of: runningTag)
            let rowID = try #require(runningInstall.timeline.renderedIDBySemanticID["model-ahead"])
            #expect(store.entranceState(for: rowID) == .pending)

            var completed = running
            completed.toolExecutions = [storeRuntimeTool(
                id: "model-ahead",
                output: "done",
                progressSequence: 2,
                status: .completed
            )]
            completed.eventSequence += 1
            let completedTag = ChatTranscriptProjectionTag(
                snapshot: completed,
                presentationGeneration: 31
            )
            store.submit(snapshot: completed, tag: completedTag)

            // B is desired, but displayed A remains exact geometry authority.
            #expect(store.installed?.tag == runningTag)
            #expect(store.resolveEntrance(
                id: rowID,
                installationTag: runningTag,
                isVisible: true
            ))
            #expect(store.entranceState(for: rowID) == .admitted)

            let completedInstall = try await store.waitForInstall(of: completedTag)
            #expect(completedInstall.containsDisplayedID(rowID))
            #expect(store.entranceState(for: rowID) == .admitted)
        }
    }

    @Test("installed completion rejects stale running tag and reissues pending ownership")
    func installedReplacementRejectsStaleEntranceTag() async throws {
        try await withTestWatchdog { @MainActor in
            var baseline = try SessionScenarioBuilder(seed: 1_233)
                .openingTail(targetEncodedBytes: 8_000)
            baseline.phase = .idle
            baseline.streaming = nil
            baseline.toolExecutions = []
            let store = ChatTranscriptPresentationStore()
            let baselineTag = ChatTranscriptProjectionTag(
                snapshot: baseline,
                presentationGeneration: 32
            )
            store.submit(snapshot: baseline, tag: baselineTag)
            _ = try await store.waitForInstall(of: baselineTag)

            var running = baseline
            running.phase = .running
            running.toolExecutions = [storeRuntimeTool(
                id: "replacement",
                output: "running",
                progressSequence: 1
            )]
            running.eventSequence += 1
            let runningTag = ChatTranscriptProjectionTag(
                snapshot: running,
                presentationGeneration: 32
            )
            store.submit(snapshot: running, tag: runningTag)
            let runningInstall = try await store.waitForInstall(of: runningTag)
            let rowID = try #require(runningInstall.timeline.renderedIDBySemanticID["replacement"])

            var completed = running
            completed.toolExecutions = [storeRuntimeTool(
                id: "replacement",
                output: "done",
                progressSequence: 2,
                status: .completed
            )]
            completed.eventSequence += 1
            let completedTag = ChatTranscriptProjectionTag(
                snapshot: completed,
                presentationGeneration: 32
            )
            store.submit(snapshot: completed, tag: completedTag)
            _ = try await store.waitForInstall(of: completedTag)

            #expect(!store.resolveEntrance(
                id: rowID,
                installationTag: runningTag,
                isVisible: true
            ))
            #expect(store.resolveEntrance(
                id: rowID,
                installationTag: completedTag,
                isVisible: true
            ))
            #expect(store.entranceState(for: rowID) == .admitted)
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
            snapshot.extensionPresentation.semanticState.working = .init(message: nil, visible: true)
            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 19)
            store.submit(snapshot: snapshot, tag: tag)
            let pending = try await store.waitForInstall(of: tag)
            let pendingID = try #require(pending.runtimeItems.first?.id)

            snapshot.transcript.append(try compactionItem(id: "finished-compaction"))
            snapshot.transcriptTotal! += 1
            snapshot.phase = .idle
            snapshot.extensionPresentation.semanticState.working.visible = false
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
            #expect(store.resolveEntrance(
                id: appended.id,
                installationTag: tag,
                isVisible: true
            ))
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
            #expect(store.resolveEntrance(
                id: appended.id,
                installationTag: tag,
                isVisible: true
            ))

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

    @Test("reset session and runtime scope changes force cold projection after sparse work")
    func scopeRetirementForcesCold() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_225)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.phase = .running
            snapshot.toolExecutions = [ToolExecutionState(
                toolCallId: "runtime-tool",
                toolName: "read",
                order: 0,
                status: .running,
                arguments: .object([:]),
                partialResult: nil,
                result: nil,
                output: "first",
                isError: false,
                startedAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z",
                progressSequence: 1
            )]
            let reports = StoreProjectionWorkRecorder()
            let store = ChatTranscriptPresentationStore(workRecorder: reports.record)
            var tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 24)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            snapshot.toolExecutions = [ToolExecutionState(
                toolCallId: "runtime-tool",
                toolName: "read",
                order: 0,
                status: .running,
                arguments: .object([:]),
                partialResult: nil,
                result: nil,
                output: "second",
                isError: false,
                startedAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:01Z",
                progressSequence: 2
            )]
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 24)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)
            #expect(reports.modes == [.cold, .toolPayloadPatch])

            store.reset()
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 24)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            snapshot.sessionId = "replacement-session"
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 24)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            snapshot.runtimeGeneration = "replacement-runtime"
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 24)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            #expect(reports.modes == [
                .cold, .toolPayloadPatch, .cold, .cold, .cold,
            ])
            #expect(store.installed?.timeline == ChatTranscriptPresentation.timeline(in: snapshot))
        }
    }

    @Test("entrance bookkeeping retires oldest pending and admitted rows at the page bound")
    func entranceBookkeepingIsGloballyBounded() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) { @MainActor in
            let maximum = ChatTranscriptPageRequest.maximumItemCount
            func messages(prefix: String, count: Int) -> [TranscriptItem] {
                (0..<count).map { index in
                    .message(.init(
                        id: "\(prefix)-\(index)", parentId: nil,
                        timestamp: "2026-01-01T00:00:00Z", kind: .message, role: .user,
                        content: [.init(
                            id: "\(prefix)-\(index)-text", type: .text, text: "row",
                            attachment: nil, redacted: nil, mimeType: nil, blobId: nil,
                            toolCallId: nil, name: nil, arguments: nil
                        )],
                        provider: nil, modelId: nil, stopReason: nil, errorMessage: nil,
                        toolCallId: nil, toolName: nil, isError: nil, details: nil, usage: nil,
                        startedAt: nil, completedAt: nil, durationMs: nil, lastProgressAt: nil,
                        progressSequence: nil
                    ))
                }
            }
            let builder = SessionScenarioBuilder(seed: 1_230)
            var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
            snapshot.transcript = messages(prefix: "initial", count: 1)
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 1
            snapshot.phase = .idle
            snapshot.streaming = nil
            snapshot.toolExecutions = []
            let store = ChatTranscriptPresentationStore()

            var tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 26,
                canonicalGeneration: 1,
                timelineGeneration: 1
            )
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            let first = messages(prefix: "first", count: 400)
            snapshot.transcript.append(contentsOf: first)
            snapshot.transcriptTotal = snapshot.transcript.count
            tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 26,
                canonicalGeneration: 2,
                timelineGeneration: 2
            )
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)
            #expect(store.pendingEntranceIDs.count == 400)
            #expect(store.admittedEntranceIDs.isEmpty)

            let second = messages(prefix: "second", count: 400)
            snapshot.transcript.append(contentsOf: second)
            snapshot.transcriptTotal = snapshot.transcript.count
            tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 26,
                canonicalGeneration: 3,
                timelineGeneration: 3
            )
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            #expect(store.pendingEntranceIDs.count == maximum)
            #expect(store.admittedEntranceIDs.isEmpty)
            #expect(store.entranceState(for: first[0].id) == .none)
            #expect(store.entranceState(for: first[287].id) == .none)
            #expect(store.entranceState(for: first[288].id) == .pending)
            for item in first + second where store.entranceState(for: item.id) == .pending {
                #expect(store.resolveEntrance(
                    id: item.id,
                    installationTag: tag,
                    isVisible: true
                ))
            }
            #expect(store.pendingEntranceIDs.isEmpty)
            #expect(store.admittedEntranceIDs.count == maximum)

            let third = messages(prefix: "third", count: 400)
            snapshot.transcript.append(contentsOf: third)
            snapshot.transcriptTotal = snapshot.transcript.count
            tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 26,
                canonicalGeneration: 4,
                timelineGeneration: 4
            )
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)
            #expect(store.pendingEntranceIDs.count == 400)
            #expect(store.admittedEntranceIDs.count == maximum)
            for item in third {
                #expect(store.resolveEntrance(
                    id: item.id,
                    installationTag: tag,
                    isVisible: true
                ))
            }

            #expect(store.pendingEntranceIDs.isEmpty)
            #expect(store.admittedEntranceIDs.count == maximum)
            #expect(store.entranceState(for: first[288].id) == .none)
            #expect(store.entranceState(for: second[287].id) == .none)
            #expect(store.entranceState(for: second[288].id) == .admitted)
            #expect(store.entranceState(for: third.last?.id ?? "") == .admitted)
        }
    }

    @Test("one tool patch in ten thousand rows shares identity and creates no entrances")
    func tenThousandRowPatchUsesTransitionFastPath() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) { @MainActor in
            let builder = SessionScenarioBuilder(seed: 1_226)
            var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
            snapshot.transcript = builder.historyPage(count: 10_000, longRowBytes: 8)
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 10_000
            snapshot.phase = .running
            snapshot.toolExecutions = [storeRuntimeTool(output: "old", progressSequence: 1)]
            let reports = StoreProjectionWorkRecorder()
            let store = ChatTranscriptPresentationStore(workRecorder: reports.record)
            var tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 25,
                canonicalGeneration: 700,
                timelineGeneration: 1
            )
            store.submit(snapshot: snapshot, tag: tag)
            let initial = try await store.waitForInstall(of: tag)
            let initialIDs = initial.timeline.ids
            let initialPreferred = initial.timeline.preferredSemanticIDByRenderedID
            let initialReverse = initial.timeline.renderedIDBySemanticID

            snapshot.toolExecutions = [storeRuntimeTool(output: "new", progressSequence: 2)]
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 25,
                canonicalGeneration: 700,
                timelineGeneration: 2
            )
            store.submit(snapshot: snapshot, tag: tag)
            let patched = try await store.waitForInstall(of: tag)

            #expect(reports.values.last?.mode == .toolPayloadPatch)
            #expect(reports.values.last?.sourceEntriesExamined == 0)
            #expect(reports.values.last?.atomsAssembled == 0)
            #expect(reports.values.last?.toolsInspected == 1)
            #expect(patched.timeline.sharesCanonicalIdentitySpine(with: initial.timeline))
            #expect(patched.timeline.ids == initialIDs)
            #expect(patched.timeline.preferredSemanticIDByRenderedID == initialPreferred)
            #expect(patched.timeline.renderedIDBySemanticID == initialReverse)
            let initialDetail = try #require(initial.resolveToolDetails(
                callIDs: ["runtime-tool"], installationTag: initial.tag
            )?.first)
            let patchedDetail = try #require(patched.resolveToolDetails(
                callIDs: ["runtime-tool"], installationTag: patched.tag
            )?.first)
            #expect(initialDetail.content == "old")
            #expect(patchedDetail.content == "new")
            guard case .toolRun(let patchedRun) = patched.timeline.items.last,
                  let descriptor = patchedRun.tools.first else {
                Issue.record("Expected patched lightweight tool descriptor")
                return
            }
            #expect(Set(Mirror(reflecting: descriptor).children.compactMap(\.label)).isDisjoint(with: [
                "request", "response", "content", "fallbackContent",
            ]))
            let descriptorCount = patched.timeline.items.reduce(into: 0) { count, item in
                if case .toolRun(let run) = item { count += run.tools.count }
            }
            #expect(patched.toolPayloads.count == descriptorCount)
            #expect(store.pendingEntranceIDs.count <= ChatTranscriptPageRequest.maximumItemCount)
            #expect(store.admittedEntranceIDs.count <= ChatTranscriptPageRequest.maximumItemCount)
        }
    }

    @Test("installed payload owner resolves grouped details and rejects stale or missing identities")
    func installedPayloadResolutionIsExact() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_229)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.transcript = try JSONDecoder.gateway.decode(
                [TranscriptItem].self,
                from: Data("""
                [
                  {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
                    {"id":"call-a","type":"toolCall","toolCallId":"call-a","name":"read","arguments":{"path":"A.swift"}},
                    {"id":"call-b","type":"toolCall","toolCallId":"call-b","name":"bash","arguments":{"command":"pwd"}}
                  ]},
                  {"id":"result-a","parentId":"assistant","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"text-a","type":"text","text":"alpha"}],"toolCallId":"call-a","toolName":"read","isError":false,"details":{"lines":1}},
                  {"id":"result-b","parentId":"result-a","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"text-b","type":"text","text":"beta"}],"toolCallId":"call-b","toolName":"bash","isError":false,"details":{"exitCode":0}}
                ]
                """.utf8)
            )
            snapshot.streaming = nil
            snapshot.toolExecutions = []
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 3
            let store = ChatTranscriptPresentationStore()
            let firstTag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 31)
            store.submit(snapshot: snapshot, tag: firstTag)
            let first = try await store.waitForInstall(of: firstTag)

            let details = try #require(store.resolveToolDetails(
                callIDs: ["call-a", "call-b"],
                installationTag: firstTag
            ))
            #expect(details.map(\.request) == [
                .object(["path": .string("A.swift")]),
                .object(["command": .string("pwd")]),
            ])
            #expect(details.map(\.content) == ["alpha", "beta"])
            #expect(details.map(\.response) == [
                .object(["lines": .number(1)]),
                .object(["exitCode": .number(0)]),
            ])
            #expect(first.resolveToolDetails(callIDs: ["missing"], installationTag: firstTag) == nil)

            snapshot.eventSequence += 1
            let secondTag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 31)
            store.submit(snapshot: snapshot, tag: secondTag)
            _ = try await store.waitForInstall(of: secondTag)
            #expect(store.resolveToolDetails(callIDs: ["call-a"], installationTag: firstTag) == nil)
        }
    }

    @Test("maximum malformed source bounds are conservative")
    func maximumSourceWindowBounds() throws {
        var snapshot = try SessionScenarioBuilder(seed: 1_227)
            .openingTail(targetEncodedBytes: 8_000)
        snapshot.transcript = SessionScenarioBuilder(seed: 1_228)
            .historyPage(count: ChatTranscriptPageRequest.maximumItemCount + 1, longRowBytes: 8)
        snapshot.transcriptStart = Int.max
        snapshot.transcriptTotal = Int.max

        let window = InstalledChatTranscript.SourceWindow(snapshot: snapshot)
        #expect(window.start == nil)
        #expect(!window.hasExactBounds)
        #expect(window.ids.count == ChatTranscriptPageRequest.maximumItemCount)
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
            let store = ChatTranscriptPresentationStore(workGate: barrier.block)

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

private final class StoreProjectionWorkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [ChatTranscriptProjectionWorkReport] = []

    var modes: [ChatTranscriptProjectionMode] { lock.withLock { reports.map(\.mode) } }
    var values: [ChatTranscriptProjectionWorkReport] { lock.withLock { reports } }

    func record(_ report: ChatTranscriptProjectionWorkReport) {
        lock.withLock { reports.append(report) }
    }
}

private final class CompletionWaiterRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            registered = true
            defer { waiters.removeAll() }
            return waiters
        }
        ready.forEach { $0.resume() }
    }

    func wait() async {
        if lock.withLock({ registered }) { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if registered { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }
}

private func storeRuntimeTool(
    id: String = "runtime-tool",
    output: String,
    progressSequence: Int,
    status: ToolExecutionState.Status = .running
) -> ToolExecutionState {
    ToolExecutionState(
        toolCallId: id,
        toolName: "read",
        order: 0,
        status: status,
        arguments: .object([:]),
        partialResult: nil,
        result: status == .completed ? .object(["ok": .bool(true)]) : nil,
        output: output,
        isError: false,
        startedAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:0\(progressSequence)Z",
        lastProgressAt: "2026-01-01T00:00:0\(progressSequence)Z",
        completedAt: status == .completed ? "2026-01-01T00:00:02Z" : nil,
        durationMs: status == .completed ? 2_000 : nil,
        progressSequence: progressSequence
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

    func block(tag: ChatTranscriptProjectionTag) {
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
