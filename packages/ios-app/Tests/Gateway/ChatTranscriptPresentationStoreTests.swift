import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Chat transcript presentation store")
struct ChatTranscriptPresentationStoreTests {
    @Test("runtime and streaming rows install in live region, never committed ledger")
    func runtimeRowsNeverEnterCommittedLedger() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_199)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.transcript = []
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 0
            snapshot.phase = .running
            snapshot.streaming = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"text","type":"text","text":"working"}]}
            """.utf8))
            snapshot.toolExecutions = [ToolExecutionState(
                toolCallId: "runtime-call", toolName: "read", order: 0, status: .completed,
                arguments: .object([:]), partialResult: nil,
                result: .object(["ok": .bool(true)]), output: "done", isError: false,
                startedAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
                lastProgressAt: "2026-01-01T00:00:01Z", completedAt: "2026-01-01T00:00:01Z",
                durationMs: 1, progressSequence: 1, toolSegmentId: nil, groupId: nil,
                groupIndex: nil, groupCount: nil, groupFinalized: nil
            )]
            let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 1)
            let store = ChatTranscriptPresentationStore()
            #expect(store.submit(snapshot: snapshot, tag: tag))
            let installed = try await store.waitForInstall(of: tag)

            #expect(installed.committedLedger.items.isEmpty)
            #expect(installed.liveRegion.items.map(\.id) == ["streaming", "tool-run-runtime-call"])
            #expect(installed.displayedItems.map(\.id) == ["streaming", "tool-run-runtime-call"])
        }
    }

    @Test("rejected handoff does not strand installation work")
    func rejectedHandoffDoesNotStrandWork() throws {
        let snapshot = try SessionScenarioBuilder(seed: 1_200)
            .openingTail(targetEncodedBytes: 8_000)
        let tag = ChatTranscriptProjectionTag(
            snapshot: snapshot,
            presentationGeneration: 7
        )
        let submission = ComposerSubmissionSnapshot(
            target: .init(sessionID: snapshot.sessionId, generation: 7),
            textRevision: 1,
            outgoingText: "rejected",
            attachmentIDs: [],
            behavior: nil,
            localNonce: 1
        )
        let handoff = ChatTranscriptHandoffCommit.outgoing(
            presentation: .init(snapshot: submission, transportActive: true),
            attachments: []
        )
        let store = ChatTranscriptPresentationStore()

        #expect(!store.submit(snapshot: snapshot, handoff: handoff, tag: tag))
        #expect(!store.hasInstallWork(for: tag))
    }

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

    @Test("transcript-coupled composer phase is frozen with its exact source")
    func visibleSessionFactsAreAtomicWithProjection() throws {
        var snapshot = try SessionScenarioBuilder(seed: 1_204)
            .openingTail(targetEncodedBytes: 8_000)
        let baseline = ChatTranscriptProjectionTag(
            snapshot: snapshot,
            presentationGeneration: 7
        )
        snapshot.phase = snapshot.phase == .running ? .idle : .running
        let replacement = ChatTranscriptProjectionTag(
            snapshot: snapshot,
            presentationGeneration: 7
        )

        #expect(baseline.layoutIdentity != replacement.layoutIdentity)
        #expect(replacement.layoutIdentity.visibleSessionFacts.sessionID == snapshot.sessionId)
        #expect(replacement.layoutIdentity.visibleSessionFacts.phase == snapshot.phase)
        #expect(replacement.responseState == ChatResponseState(snapshot: snapshot))
    }

    @Test("opening admits complete same-runtime churn but rejects replacement authority")
    func openingProjectionAdmissionIsBounded() throws {
        var snapshot = try SessionScenarioBuilder(seed: 1_203)
            .openingTail(targetEncodedBytes: 8_000)
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = snapshot.transcript.count
        let installed = ChatTranscriptProjectionTag(
            snapshot: snapshot,
            presentationGeneration: 7
        )
        snapshot.phase = snapshot.phase == .running ? .idle : .running
        snapshot.revision &+= 1
        let advanced = ChatTranscriptProjectionTag(
            snapshot: snapshot,
            presentationGeneration: 7
        )
        let advancedTranscript = snapshot.transcript
        var appendedSnapshot = snapshot
        let appendedItem = try #require(SessionScenarioBuilder(seed: 1_204)
            .openingTail(targetEncodedBytes: 8_000).transcript.last)
        appendedSnapshot.transcript.append(appendedItem)
        appendedSnapshot.transcriptTotal = (appendedSnapshot.transcriptTotal ?? 0) + 1
        let appended = ChatTranscriptProjectionTag(
            snapshot: appendedSnapshot,
            presentationGeneration: 7
        )
        var changedWindowSnapshot = snapshot
        changedWindowSnapshot.transcript[0] = appendedItem
        let changedWindow = ChatTranscriptProjectionTag(
            snapshot: changedWindowSnapshot,
            presentationGeneration: 7
        )
        snapshot.runtimeGeneration = "replacement-runtime"
        let replacementRuntime = ChatTranscriptProjectionTag(
            snapshot: snapshot,
            presentationGeneration: 7
        )
        let replacementPresentation = ChatTranscriptProjectionTag(
            snapshot: snapshot,
            presentationGeneration: 8
        )

        #expect(ChatProjectionTransactionAdmissionPolicy.admitsOpening(
            installed: installed,
            desired: advanced
        ))
        #expect(ChatProjectionTransactionAdmissionPolicy.admitsTranscriptWindow(
            installed: installed,
            desired: advanced,
            desiredTranscript: advancedTranscript
        ))
        #expect(ChatProjectionTransactionAdmissionPolicy.admitsTranscriptWindow(
            installed: advanced,
            desired: appended,
            desiredTranscript: appendedSnapshot.transcript
        ))
        #expect(!ChatProjectionTransactionAdmissionPolicy.admitsTranscriptWindow(
            installed: installed,
            desired: changedWindow,
            desiredTranscript: changedWindowSnapshot.transcript
        ))
        #expect(!ChatProjectionTransactionAdmissionPolicy.admitsOpening(
            installed: installed,
            desired: replacementRuntime
        ))
        #expect(!ChatProjectionTransactionAdmissionPolicy.admitsOpening(
            installed: installed,
            desired: replacementPresentation
        ))
        #expect(!ChatProjectionTransactionAdmissionPolicy.admitsOpening(
            installed: installed,
            desired: nil
        ))
    }

    @Test("handoff identity freezes outgoing text and attachment preview facts")
    func handoffIdentityFreezesOutgoingFacts() throws {
        let target = SessionPresentationIdentity(sessionID: "session", generation: 3)
        let submission = ComposerSubmissionSnapshot(
            target: target,
            textRevision: 1,
            outgoingText: "first",
            attachmentIDs: ["attachment"],
            behavior: "steer",
            localNonce: 1
        )
        let attachment = PendingAttachment(
            id: "attachment",
            name: "photo.png",
            mimeType: "image/png",
            size: 3,
            previewData: Data([1, 2, 3])
        )
        let commit = ChatTranscriptHandoffCommit.outgoing(
            presentation: ChatOutgoingSubmissionPresentation(
                snapshot: submission,
                transportActive: true
            ),
            attachments: [attachment]
        )
        let snapshot = try SessionScenarioBuilder(seed: 1_205).openingTail(targetEncodedBytes: 8_000)
        let firstTag = ChatTranscriptProjectionTag(
            snapshot: snapshot,
            presentationGeneration: 7,
            handoff: commit
        )
        let changed = ChatTranscriptHandoffCommit.outgoing(
            presentation: ChatOutgoingSubmissionPresentation(
                snapshot: ComposerSubmissionSnapshot(
                    target: target,
                    textRevision: 2,
                    outgoingText: "second",
                    attachmentIDs: ["attachment"],
                    behavior: "steer",
                    localNonce: 2
                ),
                transportActive: true
            ),
            attachments: [attachment]
        )
        let secondTag = ChatTranscriptProjectionTag(
            snapshot: snapshot,
            presentationGeneration: 7,
            handoff: changed
        )
        #expect(firstTag.handoffIdentity != secondTag.handoffIdentity)
        #expect(firstTag.handoffIdentity.outgoingAttachments[0].previewIdentity != nil)
        #expect(firstTag.handoffIdentity.outgoingAttachments[0].previewIdentity == secondTag.handoffIdentity.outgoingAttachments[0].previewIdentity)
        let pending = ChatPendingPromptPresentation(
            snapshot: .init(id: "pending", createdAt: nil, behavior: .steer, text: "next", attachmentCount: 1, photoCount: 1, fileAttachmentCount: 0),
            isCompacting: false
        )
        let compacting = ChatPendingPromptPresentation(
            snapshot: .init(id: "pending", createdAt: nil, behavior: .steer, text: "next", attachmentCount: 1, photoCount: 1, fileAttachmentCount: 0),
            isCompacting: true
        )
        #expect(ChatTranscriptProjectionTag.HandoffIdentity(commit: .pending(pending)) != ChatTranscriptProjectionTag.HandoffIdentity(commit: .pending(compacting)))
    }

    @Test("maximum full preview bytes are excluded from frozen identity and installed handoff")
    func fullPreviewBytesNeverEnterFrozenHandoff() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 1_207).openingTail(targetEncodedBytes: 8_000)
        let target = SessionPresentationIdentity(sessionID: snapshot.sessionId, generation: 1)
        let submission = ComposerSubmissionSnapshot(
            target: target, textRevision: 1, outgoingText: "photo", attachmentIDs: ["attachment"],
            behavior: nil, localNonce: 1
        )
        let preview = Data([1, 2, 3])
        let first = PendingAttachment(
            id: "attachment", name: "photo.png", mimeType: "image/png", size: 3,
            previewData: preview,
            fullPreviewData: Data(repeating: 0xA5, count: ComposerAttachmentPolicy.maximumTotalBytes)
        )
        let second = PendingAttachment(
            id: "attachment", name: "photo.png", mimeType: "image/png", size: 3,
            previewData: preview,
            fullPreviewData: Data(repeating: 0x5A, count: ComposerAttachmentPolicy.maximumTotalBytes)
        )
        func commit(_ attachment: PendingAttachment) -> ChatTranscriptHandoffCommit {
            .outgoing(
                presentation: ChatOutgoingSubmissionPresentation(snapshot: submission, transportActive: true),
                attachments: [attachment]
            )
        }
        let firstCommit = commit(first)
        let secondCommit = commit(second)
        let firstTag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 7, handoff: firstCommit)
        let secondTag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 7, handoff: secondCommit)
        #expect(firstCommit == secondCommit)
        #expect(firstTag == secondTag)
        #expect(firstTag.handoffIdentity == secondTag.handoffIdentity)

        let store = ChatTranscriptPresentationStore()
        #expect(store.submit(snapshot: snapshot, handoff: firstCommit, tag: firstTag))
        let installed = try await store.waitForInstall(of: firstTag)
        #expect(installed.handoff.outgoingAttachments.count == 1)
        #expect(installed.handoff.outgoingAttachments[0].previewData == preview)
        #expect(installed.handoff.outgoingAttachments[0].fullPreviewData == nil)
        #expect(installed == installed)
    }

    @Test("metadata-only authority settlement replaces lifecycle without projection churn")
    func metadataOnlyAuthoritySettlementIsSynchronous() async throws {
        try await withTestWatchdog { @MainActor in
            let snapshot = try SessionScenarioBuilder(seed: 1_206).openingTail(targetEncodedBytes: 8_000)
            let target = SessionPresentationIdentity(sessionID: snapshot.sessionId, generation: 1)
            let submission = ComposerSubmissionSnapshot(
                target: target, textRevision: 1, outgoingText: "pending", attachmentIDs: [],
                behavior: nil, localNonce: 1
            )
            let handoff = ChatTranscriptHandoffCommit.outgoing(
                presentation: ChatOutgoingSubmissionPresentation(snapshot: submission, transportActive: true),
                attachments: []
            )
            let firstTag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 7, handoff: handoff)
            let barrier = TranscriptProjectionBarrier()
            let store = ChatTranscriptPresentationStore(workGate: barrier.block)
            #expect(store.submit(snapshot: snapshot, handoff: handoff, tag: firstTag))
            await barrier.waitForBuildCount(1)
            barrier.releaseBuild(at: 0)
            _ = try await store.waitForInstall(of: firstTag)

            var canonical = snapshot
            canonical.revision += 1
            canonical.eventSequence += 1
            let canonicalTag = ChatTranscriptProjectionTag(snapshot: canonical, presentationGeneration: 7)
            #expect(!store.submit(snapshot: canonical, handoff: .none, tag: canonicalTag))
            let settled = try #require(store.installed)
            #expect(settled.tag == canonicalTag)
            #expect(settled.handoff == ChatTranscriptHandoffCommit.none)
            #expect(barrier.buildCount == 1)
        }
    }

    @Test("handoff-only replacement reuses the complete installed payload synchronously")
    func handoffOnlyReplacementIsSynchronous() async throws {
        try await withTestWatchdog { @MainActor in
            let snapshot = try SessionScenarioBuilder(seed: 1_208)
                .openingTail(targetEncodedBytes: 8_000)
            let baselineTag = ChatTranscriptProjectionTag(
                snapshot: snapshot, presentationGeneration: 7
            )
            let barrier = TranscriptProjectionBarrier()
            let store = ChatTranscriptPresentationStore(workGate: barrier.block)
            #expect(store.submit(snapshot: snapshot, tag: baselineTag))
            await barrier.waitForBuildCount(1)
            barrier.releaseBuild(at: 0)
            let baseline = try await store.waitForInstall(of: baselineTag)

            let submission = ComposerSubmissionSnapshot(
                target: .init(sessionID: snapshot.sessionId, generation: 7),
                textRevision: 1,
                outgoingText: "steer now",
                attachmentIDs: [],
                behavior: "steer",
                localNonce: 1
            )
            let handoff = ChatTranscriptHandoffCommit.outgoing(
                presentation: .init(snapshot: submission, transportActive: true),
                attachments: []
            )
            let handoffTag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7,
                handoff: handoff
            )
            #expect(!store.submit(snapshot: snapshot, handoff: handoff, tag: handoffTag))
            let installed = try #require(store.installed)
            #expect(installed.tag == handoffTag)
            #expect(installed.handoff == handoff)
            #expect(installed.timeline == baseline.timeline)
            #expect(installed.preparedTextByRenderedID == baseline.preparedTextByRenderedID)
            #expect(barrier.buildCount == 1)
        }
    }

    @Test("local lifecycle graft survives an older in-flight worker")
    func localGraftRejectsStaleWorker() async throws {
        try await withTestWatchdog { @MainActor in
            let baselineSnapshot = try SessionScenarioBuilder(seed: 1_209)
                .openingTail(targetEncodedBytes: 8_000)
            let baselineTag = ChatTranscriptProjectionTag(
                snapshot: baselineSnapshot, presentationGeneration: 7
            )
            let barrier = TranscriptProjectionBarrier()
            let store = ChatTranscriptPresentationStore(workGate: barrier.block)
            #expect(store.submit(snapshot: baselineSnapshot, tag: baselineTag))
            await barrier.waitForBuildCount(1)
            barrier.releaseBuild(at: 0)
            let baseline = try await store.waitForInstall(of: baselineTag)

            var newerSnapshot = baselineSnapshot
            newerSnapshot.revision += 1
            newerSnapshot.eventSequence += 1
            // This case needs actual layout work in flight. Authority-only
            // sequence changes now take the synchronous metadata path.
            newerSnapshot.streaming = try streamingMessage(update: 99)
            let staleTag = ChatTranscriptProjectionTag(
                snapshot: newerSnapshot, presentationGeneration: 7
            )
            #expect(store.submit(snapshot: newerSnapshot, tag: staleTag))
            await barrier.waitForBuildCount(2)

            let submission = ComposerSubmissionSnapshot(
                target: .init(sessionID: baselineSnapshot.sessionId, generation: 7),
                textRevision: 1,
                outgoingText: "race-safe",
                attachmentIDs: [],
                behavior: "steer",
                localNonce: 1
            )
            let handoff = ChatTranscriptHandoffCommit.outgoing(
                presentation: .init(snapshot: submission, transportActive: true),
                attachments: []
            )
            #expect(store.graftLocalLifecycle(
                handoff: handoff,
                queuePresentationIDByOperationID: [:]
            ))
            #expect(store.installed?.handoff == handoff)
            #expect(store.installed?.timeline == baseline.timeline)

            let newestTag = ChatTranscriptProjectionTag(
                snapshot: newerSnapshot,
                presentationGeneration: 7,
                handoff: handoff
            )
            #expect(store.submit(
                snapshot: newerSnapshot,
                handoff: handoff,
                tag: newestTag
            ))
            barrier.releaseBuild(at: 1)
            // The completed layout is identical to the newest desired source,
            // so it may install directly with the newer lifecycle instead of
            // launching a redundant third projection.
            let newest = try await store.waitForInstall(of: newestTag)
            #expect(barrier.buildCount == 2)
            #expect(newest.tag == newestTag)
            #expect(newest.handoff == handoff)
            #expect(newest.timeline != baseline.timeline)
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
            let queuedTag = ChatTranscriptProjectionTag(
                snapshot: queued,
                presentationGeneration: 7,
                queueManagementCapability: true
            )
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
            consumed.transcript.append(contentsOf: SessionScenarioBuilder(seed: 1_212)
                .historyPage(count: 1, longRowBytes: 16))
            consumed.transcriptTotal = consumed.transcript.count
            let consumedTag = ChatTranscriptProjectionTag(
                snapshot: consumed,
                presentationGeneration: 7,
                queueManagementCapability: true
            )

            store.submit(snapshot: consumed, tag: consumedTag)
            let second = try await store.waitForInstall(of: consumedTag)
            #expect(second.queuedMessages == [])
            #expect(second.queueRevision == 5)
            #expect(second.timeline.items.count >= first.timeline.items.count)
            #expect(store.installed == second)
        }
    }

    @Test("duplicate authoritative queue IDs fail closed before installation")
    func duplicateQueueIDsRejectProjection() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_213)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.queueRevision = 4
            snapshot.queuedItems = [
                .init(id: "duplicate", behavior: .steer, text: "one", attachmentCount: 0),
                .init(id: "duplicate", behavior: .followUp, text: "two", attachmentCount: 0),
            ]
            let tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7,
                queueManagementCapability: true
            )
            let store = ChatTranscriptPresentationStore()
            store.submit(snapshot: snapshot, tag: tag)
            await #expect(throws: ChatTranscriptPresentationStoreError.invalidProjection) {
                try await store.waitForInstall(of: tag)
            }
            #expect(store.installed == nil)
        }
    }

    @Test("duplicate canonical row IDs fail closed without trapping projection preparation")
    func duplicateCanonicalRowsRejectProjection() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_214)
                .openingTail(targetEncodedBytes: 8_000)
            let duplicate = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"duplicate","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"summary","tokensBefore":10}
            """.utf8))
            snapshot.transcript = [duplicate, duplicate]
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 2
            let tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7
            )
            let store = ChatTranscriptPresentationStore()

            store.submit(snapshot: snapshot, tag: tag)

            await #expect(throws: ChatTranscriptPresentationStoreError.invalidProjection) {
                try await store.waitForInstall(of: tag)
            }
            #expect(store.installed == nil)
        }
    }

    @Test("presentation-only queue and tail IDs cannot collide with canonical rows")
    func physicalRowNamespaceRejectsQueueTailCollision() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_215)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.queueRevision = 4
            snapshot.queuedItems = [
                .init(id: "collision", behavior: .steer, text: "collision", attachmentCount: 0)
            ]
            let aliases = ["collision": "transcript-bottom"]
            let tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7,
                queueManagementCapability: true,
                queuePresentationIDByOperationID: aliases
            )
            let store = ChatTranscriptPresentationStore()
            store.submit(
                snapshot: snapshot,
                handoff: .none,
                queuePresentationIDByOperationID: aliases,
                tag: tag
            )
            await #expect(throws: ChatTranscriptPresentationStoreError.invalidProjection) {
                try await store.waitForInstall(of: tag)
            }
        }
    }

    @Test("oversized authoritative queues fail closed before installation")
    func oversizedQueueRejectsProjection() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_214)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.queueRevision = 4
            snapshot.queuedItems = (0..<SessionSnapshot.maximumQueuedMessages + 1).map { index in
                .init(id: "queued-\(index)", behavior: .steer, text: "message-\(index)", attachmentCount: 0)
            }
            let tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7,
                queueManagementCapability: true
            )
            let store = ChatTranscriptPresentationStore()
            store.submit(snapshot: snapshot, tag: tag)
            await #expect(throws: ChatTranscriptPresentationStoreError.invalidProjection) {
                try await store.waitForInstall(of: tag)
            }
            #expect(store.installed == nil)
        }
    }

    @Test("supported capability replacement revokes queue management atomically")
    func supportedToUnsupportedCapabilityReplacement() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_216)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.queueRevision = 4
            snapshot.queuedItems = [
                .init(id: "queued", behavior: .steer, text: "next", attachmentCount: 0),
            ]
            let store = ChatTranscriptPresentationStore()
            let supportedTag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7,
                queueManagementCapability: true
            )
            store.submit(snapshot: snapshot, tag: supportedTag)
            let supported = try await store.waitForInstall(of: supportedTag)
            #expect(supported.supportsQueueManagement)

            let unsupportedTag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7,
                queueManagementCapability: false
            )
            #expect(unsupportedTag != supportedTag)
            #expect(store.submit(snapshot: snapshot, tag: unsupportedTag))
            let unsupported = try await store.waitForInstall(of: unsupportedTag)
            #expect(!unsupported.supportsQueueManagement)
            #expect(store.installed?.tag == unsupportedTag)

            var mutationInvoked = false
            let revokedCommit = try QueuedMessageManagementPolicy.mutationCommit(
                for: unsupported
            ) { _ in
                mutationInvoked = true
            }
            #expect(revokedCommit == nil)
            #expect(!mutationInvoked)
        }
    }

    @Test("unsupported capability replacement enables queue management atomically")
    func unsupportedToSupportedCapabilityReplacement() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_217)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.queueRevision = 4
            snapshot.queuedItems = [
                .init(id: "queued", behavior: .steer, text: "next", attachmentCount: 0),
            ]
            let store = ChatTranscriptPresentationStore()
            let unsupportedTag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7,
                queueManagementCapability: false
            )
            store.submit(snapshot: snapshot, tag: unsupportedTag)
            let unsupported = try await store.waitForInstall(of: unsupportedTag)
            #expect(!unsupported.supportsQueueManagement)

            let supportedTag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7,
                queueManagementCapability: true
            )
            #expect(supportedTag != unsupportedTag)
            #expect(store.submit(snapshot: snapshot, tag: supportedTag))
            let supported = try await store.waitForInstall(of: supportedTag)
            #expect(supported.supportsQueueManagement)

            var mutationInvoked = false
            let restoredCommit = try QueuedMessageManagementPolicy.mutationCommit(
                for: supported
            ) { items in
                mutationInvoked = true
                items.removeAll()
            }
            #expect(restoredCommit?.expectedRevision == 4)
            #expect(restoredCommit?.items == [])
            #expect(mutationInvoked)
            #expect(store.installed?.tag == supportedTag)
        }
    }

    @Test("ordinary timeline replacement preserves installed queue availability until commit")
    func ordinaryTimelineReplacementPreservesInstalledAvailability() async throws {
        try await withTestWatchdog { @MainActor in
            var baseline = try SessionScenarioBuilder(seed: 1_218)
                .openingTail(targetEncodedBytes: 8_000)
            baseline.queueRevision = 4
            baseline.queuedItems = [
                .init(id: "queued", behavior: .steer, text: "next", attachmentCount: 0),
            ]
            let barrier = TranscriptProjectionBarrier()
            let store = ChatTranscriptPresentationStore(workGate: barrier.block)
            let baselineTag = ChatTranscriptProjectionTag(
                snapshot: baseline,
                presentationGeneration: 7,
                queueManagementCapability: true
            )
            store.submit(snapshot: baseline, tag: baselineTag)
            await barrier.waitForBuildCount(1)
            barrier.releaseBuild(at: 0)
            let installed = try await store.waitForInstall(of: baselineTag)
            #expect(installed.supportsQueueManagement)

            var replacement = baseline
            replacement.revision += 1
            replacement.eventSequence += 1
            replacement.transcript.append(contentsOf: SessionScenarioBuilder(seed: 1_219)
                .historyPage(count: 1, longRowBytes: 16))
            replacement.transcriptTotal = replacement.transcript.count
            let replacementTag = ChatTranscriptProjectionTag(
                snapshot: replacement,
                presentationGeneration: 7,
                queueManagementCapability: true
            )
            #expect(store.submit(snapshot: replacement, tag: replacementTag))
            await barrier.waitForBuildCount(2)
            #expect(store.installed?.tag == baselineTag)
            #expect(store.installed?.supportsQueueManagement == true)
            barrier.releaseBuild(at: 1)
            let committed = try await store.waitForInstall(of: replacementTag)
            #expect(committed.supportsQueueManagement)
        }
    }

    @Test("covered suspension preserves the installed frame and reconciles once without entrances")
    func coveredSuspensionPreservesAndReconciles() async throws {
        try await withTestWatchdog { @MainActor in
            var baseline = try SessionScenarioBuilder(seed: 1_220)
                .openingTail(targetEncodedBytes: 8_000)
            let barrier = TranscriptProjectionBarrier()
            let store = ChatTranscriptPresentationStore(workGate: barrier.block)
            let baselineTag = ChatTranscriptProjectionTag(snapshot: baseline, presentationGeneration: 7)
            store.submit(snapshot: baseline, tag: baselineTag)
            await barrier.waitForBuildCount(1)
            barrier.releaseBuild(at: 0)
            _ = try await store.waitForInstall(of: baselineTag)

            let added = SessionScenarioBuilder(seed: 1_221)
                .historyPage(count: 1, longRowBytes: 16)[0]
            baseline.transcript.append(added)
            baseline.transcriptTotal = baseline.transcript.count
            baseline.revision += 1
            baseline.eventSequence += 1
            let coveredTag = ChatTranscriptProjectionTag(snapshot: baseline, presentationGeneration: 7)
            #expect(store.submit(snapshot: baseline, tag: coveredTag))
            await barrier.waitForBuildCount(2)
            let (waiterRegistered, waiterRegistration) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let waiter = Task { @MainActor in
                try await store.hostedWaitForInstall(of: coveredTag) {
                    waiterRegistration.yield()
                    waiterRegistration.finish()
                }
            }
            for await _ in waiterRegistered { break }

            store.suspendPendingWork()
            barrier.releaseBuild(at: 1)
            #expect(store.installed?.tag == baselineTag)
            do {
                _ = try await waiter.value
                Issue.record("covered projection unexpectedly installed")
            } catch is CancellationError {
                // Covered derivation is disposable; authority remains elsewhere.
            }

            #expect(store.submit(snapshot: baseline, tag: coveredTag))
            await barrier.waitForBuildCount(3)
            barrier.releaseBuild(at: 2)
            _ = try await store.waitForInstall(of: coveredTag)
            #expect(store.suppressesEntrances(for: coveredTag))
            #expect(store.pendingEntranceIDs.isEmpty)
            #expect(!store.installed!.timeline.items.isEmpty)
        }
    }

    @Test("foreground aggregate reconciliation suppresses row entrance replay")
    func foregroundReconciliationSuppressesEntrances() async throws {
        try await withTestWatchdog { @MainActor in
            var baseline = try SessionScenarioBuilder(seed: 1_214)
                .openingTail(targetEncodedBytes: 8_000)
            let store = ChatTranscriptPresentationStore()
            let baselineTag = ChatTranscriptProjectionTag(snapshot: baseline, presentationGeneration: 7)
            store.submit(snapshot: baseline, tag: baselineTag)
            _ = try await store.waitForInstall(of: baselineTag)

            baseline.transcript.append(contentsOf: SessionScenarioBuilder(seed: 1_215)
                .historyPage(count: 1, longRowBytes: 16))
            baseline.transcriptTotal = baseline.transcript.count
            baseline.revision += 1
            baseline.eventSequence += 1
            let foregroundTag = ChatTranscriptProjectionTag(
                snapshot: baseline,
                presentationGeneration: 7,
                entranceSuppressionGeneration: 1
            )
            store.submit(snapshot: baseline, tag: foregroundTag)
            let installed = try await store.waitForInstall(of: foregroundTag)
            #expect(installed.timeline.items.count > 0)
            #expect(store.suppressesEntrances(for: foregroundTag))
            #expect(store.pendingEntranceIDs.isEmpty)
            #expect(store.admittedEntranceIDs.isEmpty)

            let liveItem = SessionScenarioBuilder(seed: 1_216)
                .historyPage(count: 1, longRowBytes: 16)[0]
            baseline.transcript.append(liveItem)
            baseline.transcriptTotal = baseline.transcript.count
            baseline.revision += 1
            baseline.eventSequence += 1
            let liveTag = ChatTranscriptProjectionTag(
                snapshot: baseline,
                presentationGeneration: 7,
                entranceSuppressionGeneration: 1
            )
            store.submit(snapshot: baseline, tag: liveTag)
            _ = try await store.waitForInstall(of: liveTag)
            #expect(!store.suppressesEntrances(for: liveTag))
            #expect(store.pendingEntranceIDs.contains(liveItem.id))
        }
    }

    @Test("installed text preparation is bounded to its exact source and drops on memory pressure")
    func preparedTextMemoryPressure() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_213)
                .openingTail(targetEncodedBytes: 16_000)
            snapshot.queuedItems = [
                .init(id: "queued", behavior: .steer, text: "next", attachmentCount: 0),
            ]
            #expect(!ChatTextPreparationPolicy.sources(in: snapshot).isEmpty)
            let aliases = ["queued": "local-presentation"]
            let tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7,
                queuePresentationIDByOperationID: aliases
            )
            let store = ChatTranscriptPresentationStore()

            store.submit(
                snapshot: snapshot,
                handoff: .none,
                queuePresentationIDByOperationID: aliases,
                tag: tag
            )
            let installed = try await store.waitForInstall(of: tag)
            let textRow = try #require(installed.timeline.items.first(where: {
                if case .message = $0 { return true }
                return false
            }))
            #expect(installed.preparedText(for: textRow) != .empty)
            store.consumeLifecycleEntrance(id: "local-presentation")

            store.handleMemoryPressure()
            #expect(store.installed?.tag == tag)
            #expect(store.installed?.timeline == installed.timeline)
            #expect(store.installed?.preparedText(for: textRow) == .empty)
            #expect(store.installed?.queuePresentationIDByOperationID == aliases)
            #expect(store.lifecycleEntranceIsConsumed(id: "local-presentation"))
        }
    }

    @Test("lifecycle entrance receipt survives replacement and retires with its row")
    func lifecycleEntranceReceiptIsProjectionOwned() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_214)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.queuedItems = [
                .init(id: "queued", behavior: .steer, text: "next", attachmentCount: 0),
            ]
            let aliases = ["queued": "local-presentation"]
            let firstTag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7,
                queuePresentationIDByOperationID: aliases
            )
            let store = ChatTranscriptPresentationStore()
            store.submit(
                snapshot: snapshot,
                handoff: .none,
                queuePresentationIDByOperationID: aliases,
                tag: firstTag
            )
            _ = try await store.waitForInstall(of: firstTag)
            store.consumeLifecycleEntrance(id: "local-presentation")
            #expect(store.lifecycleEntranceIsConsumed(id: "local-presentation"))

            snapshot.revision += 1
            snapshot.eventSequence += 1
            let replacementTag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7,
                queuePresentationIDByOperationID: aliases
            )
            store.submit(
                snapshot: snapshot,
                handoff: .none,
                queuePresentationIDByOperationID: aliases,
                tag: replacementTag
            )
            _ = try await store.waitForInstall(of: replacementTag)
            #expect(store.lifecycleEntranceIsConsumed(id: "local-presentation"))

            snapshot.revision += 1
            snapshot.eventSequence += 1
            snapshot.queuedItems = []
            let retiredTag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 7
            )
            store.submit(snapshot: snapshot, tag: retiredTag)
            _ = try await store.waitForInstall(of: retiredTag)
            #expect(!store.lifecycleEntranceIsConsumed(id: "local-presentation"))
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

    @Test("previous installed projection remains visible until replacement installs")
    func retainsPreviousInstalledProjectionDuringReplacement() async throws {
        try await withTestWatchdog { @MainActor in
            let first = try SessionScenarioBuilder(seed: 1_225)
                .openingTail(targetEncodedBytes: 8_000)
            var replacement = first
            replacement.runtimeGeneration = "runtime-replacement"
            replacement.revision &+= 1
            replacement.eventSequence &+= 1
            let firstTag = ChatTranscriptProjectionTag(
                snapshot: first,
                presentationGeneration: 24
            )
            let replacementTag = ChatTranscriptProjectionTag(
                snapshot: replacement,
                presentationGeneration: 25
            )
            let frames = ManualProjectionFrameScheduler()
            let store = ChatTranscriptPresentationStore(
                installationFrameScheduler: frames.scheduler
            )

            store.submit(snapshot: first, tag: firstTag)
            try await store.hostedWaitForCompletedProjection(of: firstTag)
            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            _ = try await store.waitForInstall(of: firstTag)

            store.submit(snapshot: replacement, tag: replacementTag)
            try await store.hostedWaitForCompletedProjection(of: replacementTag)
            await frames.waitForRequest(count: 2)
            #expect(store.installed?.tag == firstTag)

            frames.releaseNext()
            _ = try await store.waitForInstall(of: replacementTag)
            #expect(store.installed?.tag == replacementTag)
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

    @Test("hidden thinking label changes rebuild row preparation in the same scope")
    func hiddenThinkingLabelUpdatesRebuildPreparation() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_212)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.phase = .running
            snapshot.streaming = try streamingMessage(update: 0)
            snapshot.extensionPresentation.semanticState.hiddenThinkingLabel = "Reasoning"
            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 12)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            snapshot.extensionPresentation.semanticState.hiddenThinkingLabel = "Thoughts"
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 12)
            store.submit(snapshot: snapshot, tag: tag)
            let updated = try await store.waitForInstall(of: tag)
            #expect(updated.preparedTextByRenderedID.values.contains { $0.hiddenThinkingLabel == "Thoughts" })
        }
    }

    @Test("cached projection mode changes rebuild running-tool normalization in the same scope")
    func cachedProjectionModeRebuildsRunningTools() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_216)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.phase = .idle
            snapshot.transcript = [try decodeTranscriptFixture(
                TranscriptItem.self,
                from: Data("""
                {"id":"assistant-tool","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call","ordinal":0,"type":"toolCall","toolCallId":"runtime-tool","name":"read","arguments":{}}]}
                """.utf8)
            )]
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 1
            snapshot.toolExecutions = [storeRuntimeTool(output: "working", progressSequence: 1)]
            snapshot.isCachedProjection = false
            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 13)
            store.submit(snapshot: snapshot, tag: tag)
            let active = try await store.waitForInstall(of: tag)
            let interrupted = try #require(active.timeline.items.compactMap { item -> ChatToolDescriptor? in
                guard case .toolRun(let run) = item else { return nil }
                return run.tools.first
            }.first)
            #expect(interrupted.subtitle == "Interrupted")

            snapshot.isCachedProjection = true
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 13)
            store.submit(snapshot: snapshot, tag: tag)
            let cached = try await store.waitForInstall(of: tag)
            let preserved = try #require(cached.timeline.items.compactMap { item -> ChatToolDescriptor? in
                guard case .toolRun(let run) = item else { return nil }
                return run.tools.first
            }.first)
            #expect(preserved.subtitle == "Running")
        }
    }

    @Test("retired extension working state reuses projection without creating transcript rows")
    func retiredExtensionStateDoesNotCreateRuntimeRows() async throws {
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

            #expect(installed.runtimeItems.isEmpty)
            #expect(signposts.events().filter { $0 == .begin(.chatProjection) }.count == 1)
            #expect(store.pendingEntranceIDs.isEmpty)
            #expect(store.entranceState(for: "runtime-working") == .none)
            #expect(!store.resolveEntrance(
                id: "runtime-working",
                installationTag: tag,
                isVisible: false
            ))
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
            // Once the mounted running row is admitted, rapid terminal state
            // cannot truncate its local entrance. The view retires the exact
            // entitlement only after animation completion.
            #expect(completedInstall.containsDisplayedID(rowID))
            #expect(store.entranceState(for: rowID) == .admitted)
            store.consumeTranscriptEntrance(id: rowID)
            #expect(store.entranceState(for: rowID) == .none)
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
            #expect(!store.resolveEntrance(
                id: rowID,
                installationTag: completedTag,
                isVisible: true
            ))
            #expect(store.entranceState(for: rowID) == .none)
        }
    }

    @Test("pending, canonical-overlap, and idle compaction installs retain one physical row")
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
            let pendingRows = ChatPhysicalTranscriptRowPolicy.rows(
                installed: pending,
                canonicalAliases: [:]
            )
            let pendingPhysical = try #require(pendingRows.first { $0.id == pendingID })
            guard case .transcript(.notification(let pendingNotification), _) = pendingPhysical.content else {
                Issue.record("runtime compaction did not occupy the unified transcript owner")
                return
            }
            #expect(pendingNotification.title == "Compacting context")
            #expect(pendingNotification.showsProgress)

            snapshot.transcript.append(try compactionItem(id: "finished-compaction"))
            snapshot.transcriptTotal! += 1
            snapshot.revision += 1
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 19)
            store.submit(snapshot: snapshot, tag: tag)
            let overlapping = try await store.waitForInstall(of: tag)

            #expect(snapshot.phase == .compacting)
            #expect(overlapping.runtimeItems.isEmpty)
            #expect(overlapping.timeline.items.last?.id == pendingID)
            #expect(overlapping.hasUniqueDisplayedIDs)
            let overlappingRows = ChatPhysicalTranscriptRowPolicy.rows(
                installed: overlapping,
                canonicalAliases: [:]
            )
            let resolvedPhysical = try #require(overlappingRows.first { $0.id == pendingID })
            guard case .transcript(.notification(let resolvedNotification), _) = resolvedPhysical.content else {
                Issue.record("canonical compaction did not replace the unified physical row")
                return
            }
            #expect(resolvedNotification.title == "Context compacted")
            #expect(!resolvedNotification.showsProgress)
            #expect(resolvedPhysical.id == pendingPhysical.id)
            #expect(resolvedPhysical.content != pendingPhysical.content)
            #expect(ChatPhysicalTranscriptReplacementPolicy.replacement(
                from: pendingPhysical,
                to: resolvedPhysical
            ) == .notification)
            #expect(ChatContentTransitionPolicy.notificationReplacementAnimation(
                reduceMotion: false
            ) != nil)

            snapshot.phase = .idle
            snapshot.extensionPresentation.semanticState.working.visible = false
            snapshot.revision += 1
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 19)
            store.submit(snapshot: snapshot, tag: tag)
            let completed = try await store.waitForInstall(of: tag)

            #expect(completed.runtimeItems.isEmpty)
            #expect(completed.timeline.items.last?.id == pendingID)
            #expect(completed.hasUniqueDisplayedIDs)
            #expect(store.pendingEntranceIDs.isEmpty)
        }
    }

    @Test("causal submission alias retains one physical row and collisions fail closed")
    func causalSubmissionPhysicalIdentity() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_239)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = snapshot.transcript.count
            let target = SessionPresentationIdentity(
                sessionID: snapshot.sessionId,
                generation: 9
            )
            let submission = ComposerSubmissionSnapshot(
                target: target,
                textRevision: 1,
                outgoingText: "queued during compaction",
                attachmentIDs: [],
                behavior: "steer",
                localNonce: 44
            )
            let outgoing = ChatTranscriptHandoffCommit.outgoing(
                presentation: ChatOutgoingSubmissionPresentation(
                    snapshot: submission,
                    transportActive: false
                ),
                attachments: []
            )
            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 9,
                handoff: outgoing
            )
            store.submit(snapshot: snapshot, handoff: outgoing, tag: tag)
            let local = try await store.waitForInstall(of: tag)
            let localRows = ChatPhysicalTranscriptRowPolicy.rows(
                installed: local,
                canonicalAliases: [:]
            )
            #expect(localRows.contains { $0.id == submission.presentationID })
            let coordinator = ChatScrollCoordinator()
            #expect(coordinator.discreteTailInserted(
                renderedID: submission.presentationID,
                layoutTransactionID: 44
            ))
            let materialization = try #require(coordinator.command)
            #expect(coordinator.commandApplied(materialization))

            let canonicalID = "canonical-owned"
            let canonical = try decodeTranscriptFixture(
                TranscriptItem.self,
                from: Data("""
                {"id":"canonical-owned","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","presentationId":"operation-owned","content":[{"id":"text","ordinal":0,"type":"text","text":"queued during compaction"}]}
                """.utf8)
            )
            snapshot.transcript.append(canonical)
            snapshot.transcriptTotal! += 1
            snapshot.eventSequence += 1
            snapshot.revision += 1
            tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 9
            )
            store.submit(snapshot: snapshot, tag: tag)
            let settled = try await store.waitForInstall(of: tag)
            let aliased = ChatPhysicalTranscriptRowPolicy.rows(
                installed: settled,
                canonicalAliases: [canonicalID: submission.presentationID]
            )
            let replacement = try #require(aliased.first { $0.id == submission.presentationID })
            guard case .transcript(let item, _) = replacement.content else {
                Issue.record("canonical submission did not replace lifecycle content")
                return
            }
            #expect(item.id == canonicalID)
            #expect(replacement.semanticID == canonicalID)
            #expect(replacement.id == submission.presentationID)
            let admittedPhysicalIDs = ChatPhysicalTranscriptRowPolicy.admittedPhysicalIDs(
                installed: settled,
                canonicalAliases: [canonicalID: submission.presentationID]
            )
            #expect(admittedPhysicalIDs.contains(submission.presentationID))
            #expect(!admittedPhysicalIDs.contains(canonicalID))
            #expect(admittedPhysicalIDs.contains("transcript-bottom"))
            coordinator.reconcileMaterializationRows { admittedPhysicalIDs.contains($0) }
            #expect(coordinator.ownsTailMaterializationTarget(
                renderedID: submission.presentationID
            ))
            #expect(!coordinator.consumeTargetRelease())
            let outgoingPhysical = try #require(
                localRows.first { $0.id == submission.presentationID }
            )
            #expect(ChatPhysicalTranscriptReplacementPolicy.replacement(
                from: outgoingPhysical,
                to: replacement
            ) == .none)
            let queuedMessage = SessionSnapshot.QueuedMessage(
                id: "operation-owned",
                behavior: .steer,
                text: submission.outgoingText,
                attachmentCount: 0
            )
            let queuedPhysical = ChatPhysicalTranscriptRow(
                id: submission.presentationID,
                semanticID: submission.presentationID,
                content: .queued(ChatQueuedMessageRenderEntry(
                    id: submission.presentationID,
                    index: 0,
                    message: queuedMessage
                ))
            )
            #expect(ChatPhysicalTranscriptReplacementPolicy.replacement(
                from: outgoingPhysical,
                to: queuedPhysical
            ) == .none)
            let existingPhysicalID = try #require(
                settled.committedLedger.items.first { $0.id != canonicalID }?.id
            )
            let collision = ChatPhysicalTranscriptRowPolicy.rows(
                installed: settled,
                canonicalAliases: [canonicalID: existingPhysicalID]
            )
            #expect(collision.contains { $0.id == canonicalID })
            #expect(collision.filter { $0.id == existingPhysicalID }.count == 1)

            for reserved in ["transcript-bottom"] {
                let markerCollision = ChatPhysicalTranscriptRowPolicy.rows(
                    installed: settled,
                    canonicalAliases: [canonicalID: reserved]
                )
                #expect(markerCollision.contains { $0.id == canonicalID })
                #expect(!markerCollision.contains { $0.id == reserved })
            }

            var prefixedSnapshot = snapshot
            prefixedSnapshot.transcriptStart = 1
            prefixedSnapshot.transcriptTotal = prefixedSnapshot.transcript.count + 1
            prefixedSnapshot.eventSequence += 1
            prefixedSnapshot.revision += 1
            let prefixedTag = ChatTranscriptProjectionTag(
                snapshot: prefixedSnapshot,
                presentationGeneration: 9
            )
            store.submit(snapshot: prefixedSnapshot, tag: prefixedTag)
            let prefixed = try await store.waitForInstall(of: prefixedTag)
            let earlierCollision = ChatPhysicalTranscriptRowPolicy.rows(
                installed: prefixed,
                canonicalAliases: [canonicalID: "earlier-messages"]
            )
            #expect(earlierCollision.contains { $0.id == canonicalID })
            #expect(!earlierCollision.contains { $0.id == "earlier-messages" })
            coordinator.cancel()
        }
    }

    @Test("live, settled-running, and idle installs retain one semantic row")
    func streamingSettlementInstallIdentity() async throws {
        try await withTestWatchdog { @MainActor in
            var baseline = try SessionScenarioBuilder(seed: 1_240)
                .openingTail(targetEncodedBytes: 8_000)
            baseline.phase = .idle
            baseline.streaming = nil
            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(snapshot: baseline, presentationGeneration: 40)
            store.submit(snapshot: baseline, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            var live = baseline
            live.phase = .running
            live.eventSequence += 1
            live.streaming = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"streaming","parentId":"parent","presentationId":"stream:install","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"stream:install:0","ordinal":0,"type":"text","text":"answer"},{"id":"stream:install:1","ordinal":1,"type":"toolCall","toolCallId":"settling-call","name":"read","arguments":{"path":"README.md"},"groupId":"settling-group","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
            """.utf8))
            tag = ChatTranscriptProjectionTag(snapshot: live, presentationGeneration: 40)
            store.submit(snapshot: live, tag: tag)
            let liveInstall = try await store.waitForInstall(of: tag)
            #expect(liveInstall.timeline.items.live.first?.id == "stream:install")
            #expect(liveInstall.timeline.items.compactMap { item -> ChatToolRunPresentation? in
                guard case .toolRun(let run) = item else { return nil }
                return run
            }.flatMap(\.tools).map(\.id) == ["settling-call"])
            #expect(store.resolveEntrance(
                id: "stream:install", installationTag: tag, isVisible: true
            ))

            var overlap = live
            overlap.eventSequence += 1
            overlap.transcript.append(try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"canonical","parentId":"parent","presentationId":"stream:install","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"stream:install:0","ordinal":0,"type":"text","text":"answer"},{"id":"stream:install:1","ordinal":1,"type":"toolCall","toolCallId":"settling-call","name":"read","arguments":{"path":"README.md"},"groupId":"settling-group","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
            """.utf8)))
            overlap.transcriptTotal = overlap.transcript.count
            tag = ChatTranscriptProjectionTag(snapshot: overlap, presentationGeneration: 40)
            store.submit(snapshot: overlap, tag: tag)
            let overlapInstall = try await store.waitForInstall(of: tag)
            #expect(overlapInstall.timeline.ids.filter { $0 == "stream:install" }.count == 1)
            #expect(overlapInstall.timeline.items.compactMap { item -> ChatToolRunPresentation? in
                guard case .toolRun(let run) = item else { return nil }
                return run
            }.flatMap(\.tools).map(\.id) == ["settling-call"])
            #expect(overlapInstall.hasUniqueDisplayedIDs)
            #expect(store.entranceState(for: "stream:install") == .admitted)

            var settled = overlap
            settled.eventSequence += 1
            settled.streaming = nil
            tag = ChatTranscriptProjectionTag(snapshot: settled, presentationGeneration: 40)
            store.submit(snapshot: settled, tag: tag)
            let settledInstall = try await store.waitForInstall(of: tag)
            #expect(settledInstall.timeline.items.canonical.contains { $0.id == "stream:install" })
            #expect(store.entranceState(for: "stream:install") == .admitted)

            settled.phase = .idle
            settled.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: settled, presentationGeneration: 40)
            store.submit(snapshot: settled, tag: tag)
            let idleInstall = try await store.waitForInstall(of: tag)
            #expect(idleInstall.timeline.items.canonical.contains { $0.id == "stream:install" })
            #expect(store.entranceState(for: "stream:install") == .admitted)
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
            store.consumeTranscriptEntrance(id: appended.id)
            #expect(store.entranceState(for: appended.id) == .none)

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
            #expect(store.entranceState(for: appended.id) == .none)
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

    @Test("finalized tool metadata preserves the mounted running chip lineage")
    func finalizedToolMetadataPreservesPhysicalLineage() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_224)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.phase = .idle
            snapshot.toolExecutions = []
            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 23)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            snapshot.phase = .running
            snapshot.toolExecutions = [storeRuntimeTool(
                id: "call",
                output: "working",
                progressSequence: 1
            )]
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 23)
            store.submit(snapshot: snapshot, tag: tag)
            let running = try await store.waitForInstall(of: tag)
            let runningRow = try #require(ChatPhysicalTranscriptRowPolicy.rows(
                installed: running,
                canonicalAliases: [:]
            ).first { $0.semanticID == "tool-run-call" })
            #expect(runningRow.id == "tool-run-call")
            #expect(store.resolveEntrance(
                id: runningRow.semanticID,
                installationTag: tag,
                isVisible: true
            ))
            #expect(store.entranceState(for: runningRow.semanticID) == .admitted)

            snapshot.toolExecutions = [storeRuntimeTool(
                id: "call",
                output: "done",
                progressSequence: 2,
                status: .completed,
                groupID: "producer-group"
            )]
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 23)
            store.submit(snapshot: snapshot, tag: tag)
            let completed = try await store.waitForInstall(of: tag)
            let completedRow = try #require(ChatPhysicalTranscriptRowPolicy.rows(
                installed: completed,
                canonicalAliases: [:]
            ).first { $0.semanticID == "tool-run-producer-group" })
            #expect(completedRow.id == runningRow.id)
            #expect(completedRow.semanticID == "tool-run-producer-group")
            #expect(ChatPhysicalTranscriptRowPolicy.admittedPhysicalIDs(
                installed: completed,
                canonicalAliases: [:]
            ).contains(runningRow.id))
            #expect(completed.hasUniqueDisplayedIDs)
            #expect(store.entranceState(for: runningRow.semanticID) == .none)
            #expect(store.entranceState(for: completedRow.semanticID) == .admitted)
            store.consumeTranscriptEntrance(id: completedRow.semanticID)
            #expect(store.entranceState(for: completedRow.semanticID) == .none)
        }
    }

    @Test("a newly fused tool boundary grants one canonical-host entrance")
    func newCanonicalLiveToolBoundaryUsesCanonicalEntrance() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_227)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.phase = .running
            snapshot.transcript = []
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 0
            snapshot.toolExecutions = []

            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 25)
            store.submit(snapshot: snapshot, tag: tag)
            _ = try await store.waitForInstall(of: tag)

            snapshot.transcript = [try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"assistant-one","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"part-one","type":"toolCall","toolCallId":"call-one","name":"read","arguments":{},"toolSegmentId":"segment:turn","groupId":"group-one","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
            """.utf8))]
            snapshot.transcriptTotal = 1
            snapshot.toolExecutions = [
                storeRuntimeTool(
                    id: "call-one", output: "done", progressSequence: 1,
                    status: .completed, toolSegmentID: "segment:turn",
                    groupID: "group-one"
                ),
                storeRuntimeTool(
                    id: "call-two", output: "running", progressSequence: 2,
                    toolSegmentID: "segment:turn", groupID: "group-two", order: 1
                ),
            ]
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 25)
            store.submit(snapshot: snapshot, tag: tag)
            let installed = try await store.waitForInstall(of: tag)
            let fusion = try #require(installed.toolBoundaryFusion)
            let rows = ChatPhysicalTranscriptRowPolicy.rows(
                installed: installed, canonicalAliases: [:]
            )
            #expect(rows.count == 1)
            #expect(store.pendingEntranceIDs == [fusion.canonicalRenderedID])
            #expect(!store.pendingEntranceIDs.contains(fusion.liveRenderedID))
            #expect(store.entranceState(for: fusion.canonicalRenderedID) == .pending)
        }
    }

    @Test("canonical and live segment members keep one physical chip through takeover")
    func canonicalLiveToolBoundaryKeepsPhysicalHost() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 1_226)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.phase = .running
            snapshot.transcript = [try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"assistant-one","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"part-one","type":"toolCall","toolCallId":"call-one","name":"read","arguments":{},"toolSegmentId":"segment:turn","groupId":"group-one","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
            """.utf8))]
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 1
            snapshot.toolExecutions = [storeRuntimeTool(
                id: "call-one", output: "done", progressSequence: 1,
                status: .completed, toolSegmentID: "segment:turn",
                groupID: "group-one"
            )]

            let store = ChatTranscriptPresentationStore()
            var tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 24)
            store.submit(snapshot: snapshot, tag: tag)
            let baseline = try await store.waitForInstall(of: tag)
            let baselineToolID = try #require(baseline.committedLedger.items.compactMap { item -> String? in
                guard case .toolRun(let run) = item else { return nil }
                return run.id
            }.last)

            snapshot.toolExecutions.append(storeRuntimeTool(
                id: "call-two", output: "running", progressSequence: 2,
                toolSegmentID: "segment:turn", groupID: "group-two", order: 1
            ))
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 24)
            store.submit(snapshot: snapshot, tag: tag)
            let running = try await store.waitForInstall(of: tag)
            let runningToolRows = ChatPhysicalTranscriptRowPolicy.rows(
                installed: running, canonicalAliases: [:]
            ).compactMap { row -> ChatToolRunPresentation? in
                guard case .transcript(.toolRun(let run), _) = row.content else { return nil }
                return run
            }
            #expect(running.committedLedger.items.count == baseline.committedLedger.items.count)
            #expect(running.liveRegion.items.count == 1)
            #expect(runningToolRows.count == 1)
            #expect(runningToolRows.first?.id == baselineToolID)
            #expect(runningToolRows.first?.tools.map(\.id) == ["call-one", "call-two"])
            #expect(runningToolRows.first?.isRunning == true)
            #expect(store.pendingEntranceIDs.isEmpty)

            snapshot.transcript.append(try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"assistant-two","parentId":"assistant-one","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"part-two","type":"toolCall","toolCallId":"call-two","name":"read","arguments":{},"toolSegmentId":"segment:turn","groupId":"group-two","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
            """.utf8)))
            snapshot.transcriptTotal = 2
            snapshot.toolExecutions = snapshot.toolExecutions.map {
                storeRuntimeTool(
                    id: $0.toolCallId, output: "done", progressSequence: 3,
                    status: .completed, toolSegmentID: "segment:turn",
                    groupID: $0.groupId, order: $0.order ?? 0
                )
            }
            snapshot.eventSequence += 1
            tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 24)
            store.submit(snapshot: snapshot, tag: tag)
            let settled = try await store.waitForInstall(of: tag)
            let settledToolRows = ChatPhysicalTranscriptRowPolicy.rows(
                installed: settled, canonicalAliases: [:]
            ).compactMap { row -> ChatToolRunPresentation? in
                guard case .transcript(.toolRun(let run), _) = row.content else { return nil }
                return run
            }
            #expect(settled.liveRegion.items.isEmpty)
            #expect(settledToolRows.count == 1)
            #expect(settledToolRows.first?.id == baselineToolID)
            #expect(settledToolRows.first?.tools.map(\.id) == ["call-one", "call-two"])
            #expect(settledToolRows.first?.isRunning == false)
            #expect(store.pendingEntranceIDs.isEmpty)
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
                        presentationId: "\(prefix)-\(index)",
                        content: [.init(
                            id: "\(prefix)-\(index)-text", ordinal: 0, thinkingRunOrdinal: nil,
                            type: .text, text: "row",
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
            snapshot.transcript = try decodeTranscriptFixture(
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
    try decodeTranscriptFixture(
        TranscriptItem.self,
        from: Data("""
        {"id":"\(id)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"Compacted summary","tokensBefore":1200}
        """.utf8)
    )
}

private func streamingMessage(update: Int) throws -> TranscriptItem {
    try decodeTranscriptFixture(
        TranscriptItem.self,
        from: Data("""
        {"id":"streaming","parentId":null,"presentationId":"stream:store","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"thinking","ordinal":0,"thinkingRunOrdinal":0,"type":"thinking","text":"Working"},{"id":"answer","ordinal":1,"type":"text","text":"update-\(update)"}]}
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
    status: ToolExecutionState.Status = .running,
    toolSegmentID: String? = nil,
    groupID: String? = nil,
    groupIndex: Int = 0,
    groupCount: Int = 1,
    order: Int = 0
) -> ToolExecutionState {
    ToolExecutionState(
        toolCallId: id,
        toolName: "read",
        order: order,
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
        progressSequence: progressSequence,
        toolSegmentId: toolSegmentID,
        groupId: groupID,
        groupIndex: groupID == nil ? nil : groupIndex,
        groupCount: groupID == nil ? nil : groupCount,
        groupFinalized: groupID == nil ? nil : true
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
