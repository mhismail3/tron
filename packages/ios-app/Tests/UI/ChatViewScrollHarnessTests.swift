import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@MainActor
@Suite("Hosted ChatView scroll harness", .serialized)
struct ChatViewScrollHarnessTests {
    @Test("long assistant Markdown keeps exact intrinsic height with bounded thinking")
    func longAssistantIntrinsicGeometry() throws {
        let body = (0..<120).map { index in
            index.isMultiple(of: 8)
                ? "## Section \(index)"
                : "Paragraph \(index) contains enough words to wrap naturally across the chat transcript width."
        }.joined(separator: "\n\n")
        let textOnly = try harnessRichAssistantMessage(
            id: "text-only",
            presentationID: "turn-text-only",
            thinkingLines: [],
            text: body
        )
        let withThinking = try harnessRichAssistantMessage(
            id: "with-thinking",
            presentationID: "turn-with-thinking",
            thinkingLines: (0..<36).map { "Private reasoning line \($0) with measurement content" },
            text: body
        )
        let proposal = CGSize(width: 358, height: CGFloat.greatestFiniteMagnitude)
        let textController = UIHostingController(
            rootView: TranscriptRow(item: textOnly, preparedText: .empty)
        )
        let thinkingController = UIHostingController(
            rootView: TranscriptRow(item: withThinking, preparedText: .empty)
        )
        let textHeight = textController.sizeThatFits(in: proposal).height
        let boundedProposalHeight = textController.sizeThatFits(
            in: CGSize(width: proposal.width, height: 400)
        ).height
        let thinkingHeight = thinkingController.sizeThatFits(in: proposal).height

        #expect(textHeight > 400)
        #expect(abs(boundedProposalHeight - textHeight) <= 1)
        #expect(thinkingHeight > textHeight)
        #expect(thinkingHeight - textHeight < 120)
    }

    @Test("composer height changes are atomic and coalesced")
    func composerLayoutGenerationPolicy() {
        #expect(ChatComposerStructuralTransitionPolicy.admitsHeightChange(
            current: nil,
            measured: 44
        ))
        #expect(ChatComposerStructuralTransitionPolicy.admitsHeightChange(
            current: 44,
            measured: 88
        ))
        #expect(!ChatComposerStructuralTransitionPolicy.admitsHeightChange(
            current: 44,
            measured: 44.2
        ))
        #expect(!ChatComposerStructuralTransitionPolicy.admitsHeightChange(
            current: 44,
            measured: .infinity
        ))
    }

    @Test("pinned keyboard-sized viewport changes preserve the physical tail")
    func pinnedKeyboardViewportChangesPreserveTail() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_208) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady
                        && $0.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                }
                let baselineTailError = try harness.nativeTranscriptSignedTailError()
                let initialHeight = ready.observation.geometry.containerHeight

                harness.resize(height: 620)
                _ = try await harness.recorder.waitUntil {
                    $0.observation.geometry.containerHeight < initialHeight - 100
                }
                for _ in 0..<20 where try harness.nativeTranscriptDistanceFromTail() > 2 {
                    try await harness.driveFrameBoundary()
                    await Task.yield()
                }
                let shrunkenTailError = try harness.nativeTranscriptSignedTailError()
                #expect(shrunkenTailError <= max(2, baselineTailError + 2))

                harness.resize(height: 844)
                _ = try await harness.recorder.waitUntil {
                    abs($0.observation.geometry.containerHeight - initialHeight) <= 2
                }
                for _ in 0..<20 where try harness.nativeTranscriptDistanceFromTail() > 2 {
                    try await harness.driveFrameBoundary()
                    await Task.yield()
                }
                let expandedTailError = try harness.nativeTranscriptSignedTailError()
                // Returning from a keyboard-sized contraction must restore the
                // same legal native tail instead of retaining the old viewport
                // delta as a new past-bottom blank gap.
                #expect(abs(expandedTailError - baselineTailError) <= 16)
            }
        }
    }

    @Test("short transcript keeps its leading row through a viewport contraction")
    func shortTranscriptComposerChangesPreserveLeadingRow() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            let builder = SessionScenarioBuilder(seed: 1_209)
            var snapshot = try builder.openingTail(targetEncodedBytes: 10_000)
            snapshot.transcript = [try harnessMessage(id: "short-leading")]
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 1

            try await withHarness(snapshot: snapshot) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady
                        && $0.observation.visibleRowIDs.contains(harness.firstTranscriptID)
                }
                #expect(!ready.observation.geometry.isPastBottomEdge)
                let leadingFrame = try #require(
                    ready.observation.rowFrames[harness.firstTranscriptID]
                )
                let visibleBottom = ready.observation.geometry.containerHeight
                    - ready.observation.geometry.bottomInset
                let trailingGap = visibleBottom - leadingFrame.maxY
                #expect(trailingGap >= 0)
                #expect(trailingGap <= ChatTranscriptLayoutConstants.rowSpacing
                    + ChatTranscriptLayoutConstants.tailAffordanceHeight + 12)

                // The hosted window contraction is the keyboard-sized native
                // viewport boundary. Do not also summon the simulator keyboard,
                // which would apply the same contraction a second time.
                harness.resize(height: 620)
                let focused = try await harness.recorder.waitUntil {
                    $0.observation.geometry.containerHeight < ready.observation.geometry.containerHeight - 100
                        && $0.observation.visibleRowIDs.contains(harness.firstTranscriptID)
                }
                #expect(!focused.observation.geometry.isPastBottomEdge)
            }
        }
    }

    @Test("multiline composer growth does not reevaluate installed history")
    func multilineComposerGrowthKeepsHistoryStable() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 101) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                let evaluationBaseline = ready.observation.committedHistoryRowEvaluationCount
                let installBaseline = ready.observation.projectionInstallCount
                let remountBaseline = ready.observation.remountedWhileSemanticIDDisplayed
                let commandBaseline = ready.observation.automaticScrollCommandCount
                try harness.setComposerText(String(repeating: "stable transcript ", count: 18))
                try await harness.driveFrameBoundary()
                try await Task.sleep(for: .milliseconds(100))
                let grown = harness.probeObservation

                #expect(!grown.isDetached)
                #expect(grown.committedHistoryRowEvaluationCount == evaluationBaseline)
                #expect(grown.projectionInstallCount == installBaseline)
                #expect(grown.remountedWhileSemanticIDDisplayed == remountBaseline)
                #expect(grown.automaticScrollCommandCount == commandBaseline)
            }
        }
    }

    @Test("hosted aggregate counters and retained row frames are bounded")
    func hostedEvidenceBounds() {
        let probe = ChatHostedProbe()
        for index in 0..<300 {
            probe.updateRowFrame(
                id: "synthetic-row-\(index)",
                frame: CGRect(x: 0, y: index, width: 10, height: 10)
            )
        }
        #expect(probe.observation.rowFrames.count == 256)
        #expect(probe.observation.semanticFrameCallbackCount == 300)
    }

    @Test("hosted probe counts semantic remounts across projection installs")
    func hostedSemanticRemountCounter() {
        let probe = ChatHostedProbe()
        probe.recordProjectionInstall(
            rowCount: 1,
            sourceOrdinal: 1,
            nextRenderedIDBySemanticID: ["stream:turn": "stream:turn"]
        )
        probe.recordProjectionInstall(
            rowCount: 1,
            sourceOrdinal: 2,
            nextRenderedIDBySemanticID: ["stream:turn": "stream:turn"]
        )
        #expect(probe.observation.remountedWhileSemanticIDDisplayed == 0)

        probe.recordProjectionInstall(
            rowCount: 1,
            sourceOrdinal: 3,
            nextRenderedIDBySemanticID: ["stream:turn": "assistant-final"]
        )
        #expect(probe.observation.remountedWhileSemanticIDDisplayed == 1)
    }

    @Test("hosted row evidence promotes future callbacks and rejects stale generations")
    func hostedRowEvidenceGenerationFence() {
        let probe = ChatHostedProbe()
        let first = CGRect(x: 0, y: 10, width: 10, height: 10)
        let future = CGRect(x: 0, y: 20, width: 10, height: 10)
        let stale = CGRect(x: 0, y: 30, width: 10, height: 10)

        probe.updateRowFrame(id: "row", frame: first, generation: 1)
        #expect(probe.observation.rowFrames["row"] == nil)
        probe.recordProjectionInstall(
            rowCount: 1,
            sourceOrdinal: 1,
            nextRenderedIDBySemanticID: ["row": "row"]
        )
        #expect(probe.observation.rowFrames["row"] == first)

        probe.updateRowFrame(id: "row", frame: future, generation: 2)
        #expect(probe.observation.rowFrames["row"] == first)
        probe.recordProjectionInstall(
            rowCount: 1,
            sourceOrdinal: 2,
            nextRenderedIDBySemanticID: ["row": "row"]
        )
        #expect(probe.observation.rowFrames["row"] == future)

        probe.updateRowFrame(id: "row", frame: stale, generation: 1)
        #expect(probe.observation.rowFrames["row"] == future)
        probe.recordProjectionInstall(
            rowCount: 2,
            sourceOrdinal: 3,
            nextRenderedIDBySemanticID: ["row": "row", "new": "new"]
        )
        #expect(probe.observation.rowFrames.isEmpty)
    }

    @Test("harness renders the production scroll view and semantic row geometry")
    func harnessFidelity() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 101) { harness in
                let sample = try await harness.recorder.waitUntil { sample in
                    sample.observation.isReady
                        && sample.observation.geometry.isValid
                        && !sample.observation.visibleRowIDs.isEmpty
                        && !sample.observation.rowFrames.isEmpty
                        && sample.nativeGeometryMatches
                }

                #expect(sample.observation.geometry.isValid)
                #expect(sample.nativeGeometryMatches)
                #expect(sample.observation.rowFrames.keys.allSatisfy(harness.transcriptIDs.contains))
                #expect(Set(sample.observation.visibleRowIDs).isSubset(of: harness.transcriptIDs))
            }
        }
    }

    @Test("a real visible semantic frame computes a zero-excursion prepend correction")
    func semanticAnchorCorrection() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 106) { harness in
                let sample = try await harness.recorder.waitUntil { sample in
                    sample.observation.isReady
                        && sample.observation.rowFrames.keys.contains(where: {
                            sample.observation.visibleRowIDs.contains($0)
                        })
                }
                guard let rowID = sample.observation.visibleRowIDs.first(where: {
                    sample.observation.rowFrames[$0] != nil
                }), let capturedFrame = sample.observation.rowFrames[rowID] else {
                    Issue.record("expected a visible semantic frame")
                    return
                }
                let insertedPrefixHeight: CGFloat = 173
                let installedFrameMinY = capturedFrame.minY + insertedPrefixHeight
                let requestedOffset = ChatScrollCoordinator.prependCorrectionOffset(
                    currentOffsetY: sample.observation.geometry.offsetY,
                    capturedViewportOffsetY: capturedFrame.minY,
                    installedFrameMinY: installedFrameMinY
                )
                let restoredFrameMinY = installedFrameMinY
                    - (requestedOffset - sample.observation.geometry.offsetY)
                #expect(abs(restoredFrameMinY - capturedFrame.minY) <= 1)
            }
        }
    }

    @Test("an overflowing authoritative transcript opens at its latest tail")
    func opensAtTail() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 102) { harness in
                let sample = try await harness.recorder.waitUntil { sample in
                    sample.observation.isReady
                        && sample.observation.scrollSettledDistance != nil
                        && sample.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                }

                let scrollEvents = harness.scrollEvents
                #expect((sample.observation.scrollSettledDistance ?? .infinity)
                    <= ChatTranscriptGeometry.catchUpDistance)
                #expect(sample.observation.visibleRowIDs.contains(harness.lastTranscriptID))
                #expect(!sample.observation.visibleRowIDs.contains(harness.firstTranscriptID))
                // Native initial-bottom anchoring may prove the exact tail
                // without an explicit command. If a command was required, its
                // settlement still has to be successful and singular.
                if sample.observation.scrollCommandCount > 0 {
                    #expect(scrollEvents.first == .begin(.scrollCommandSettle))
                    #expect(scrollEvents.contains(.end(.scrollCommandSettle, .success, .none)))
                    #expect(!scrollEvents.contains(.end(.scrollCommandSettle, .failure, .none)))
                    #expect(!scrollEvents.contains(.end(.scrollCommandSettle, .cancelled, .none)))
                }
            }
        }
    }

    @Test("the first visible frame of a maximum-row transcript is the exact tail")
    func maximumRowOpeningNeverPresentsBlankViewport() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            let builder = SessionScenarioBuilder(seed: 1_204)
            var snapshot = try builder.openingTail(targetEncodedBytes: 10_000)
            snapshot.transcript = try (0..<ChatTranscriptPageRequest.maximumItemCount).map {
                try harnessMessage(id: "long-opening-\($0)")
            }
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = snapshot.transcript.count
            let expectedRowCount = snapshot.transcript.count

            try await withHarness(snapshot: snapshot) { harness in
                let firstReady = try await harness.recorder.waitUntil { $0.observation.isReady }
                #expect(firstReady.observation.installedProjectionRowCount == expectedRowCount)
                #expect(firstReady.observation.physicalRowAppearanceCounts.values.reduce(0, +) < expectedRowCount)
                #expect(firstReady.observation.visibleRowIDs.contains(harness.lastTranscriptID))
                #expect(firstReady.observation.visibleRowIDs.contains("transcript-bottom"))
                #expect(firstReady.observation.geometry.isPlausibleOpeningViewport)
                #expect(firstReady.observation.geometry.distanceFromBottom
                    <= ChatTranscriptGeometry.catchUpDistance)
                #expect(firstReady.nativeGeometryMatches)
                #expect(!firstReady.observation.visibleRowIDs.isEmpty)
                #expect(harness.recorder.samples.filter(\.observation.isReady).allSatisfy {
                    !$0.observation.visibleRowIDs.isEmpty
                })
            }
        }
    }

    @Test("readiness is recorded only after a display-link frame")
    func firstReadyFrame() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 104) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                #expect(harness.firstReadyEvents == [
                    .begin(.firstReadyFrame),
                    .end(.firstReadyFrame, .success, .none),
                ])
            }
        }
    }

    @Test("completed inline Markdown display settles on cold reopen")
    func inlineDisplayColdReopen() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            let snapshot = try harnessInlineMarkdownDisplaySnapshot()
            for _ in 0..<2 {
                try await withHarness(snapshot: snapshot) { harness in
                    let ready = try await harness.recorder.waitUntil {
                        $0.observation.readyFrameCompletionCount == 1
                            && $0.observation.isReady
                            && $0.observation.visibleRowIDs.contains("transcript-bottom")
                    }
                    #expect(ready.observation.geometry.isPlausibleOpeningViewport)
                    #expect(ready.observation.geometry.distanceFromBottom
                        <= ChatTranscriptGeometry.catchUpDistance)
                }
            }
        }
    }

    @Test("cancelled frame wait closes readiness exactly once")
    func cancelledReadyFrame() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            let scheduler = DisplayFrameScheduler { throw CancellationError() }
            try await withHarness(seed: 105, displayFrameScheduler: scheduler) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                #expect(harness.firstReadyEvents == [
                    .begin(.firstReadyFrame),
                    .end(.firstReadyFrame, .cancelled, .none),
                ])
            }
        }
    }

    @Test("displaced retained pinned view resumes without reopening conversation authority")
    func displacedRetainedResume() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_207) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                        && $0.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                }
                try harness.displaceNativeTranscriptFromTail(by: 180)
                #expect(try harness.nativeTranscriptDistanceFromTail() > 100)

                harness.drivePinnedPositionReapplication()
                let resumed = try await harness.recorder.waitUntil {
                    $0.frameIndex > ready.frameIndex
                        && $0.observation.isReady
                        && $0.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                        && $0.observation.geometry.distanceFromBottom <= 2
                }
                #expect(try harness.nativeTranscriptDistanceFromTail() <= 2)
                #expect(!harness.recorder.samples.contains {
                    $0.frameIndex > ready.frameIndex && !$0.observation.isReady
                })
                #expect(
                    resumed.observation.smoothAutomaticScrollCommandCount
                        == ready.observation.smoothAutomaticScrollCommandCount
                )
            }
        }
    }

    @Test("actual ChatView emits no growth offset writes while pinned or detached")
    func drivenCoordinatorExecutor() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 107) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }

                let baseline = harness.recorder.samples.last?.observation.automaticScrollCommandCount ?? 0
                let projectionWorkBaseline = harness.probeObservation.projectionWorkAdmissionCount
                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400
                )
                let firstGrowth = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_100, containerHeight: 400
                )
                let secondGrowth = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_180, containerHeight: 400
                )
                harness.driveGeometry(previous: bottom, current: firstGrowth)
                harness.driveGeometry(previous: firstGrowth, current: secondGrowth)
                try await harness.driveFrameBoundary()
                #expect(harness.probeObservation.automaticScrollCommandCount == baseline)

                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveSemanticResponse()
                #expect(harness.probeObservation.isDetached)
                #expect(harness.probeObservation.hasUnread)
                let commandsBeforeDetachedGrowth = harness.probeObservation.scrollCommandCount
                harness.driveGeometry(
                    previous: away,
                    current: ChatTranscriptGeometry(
                        offsetY: 300, contentHeight: 1_200, containerHeight: 400
                    )
                )
                harness.driveGeometry(
                    previous: away,
                    current: ChatTranscriptGeometry(
                        offsetY: 300, contentHeight: 1_200, containerHeight: 320, bottomInset: 80
                    ),
                    viewport: true
                )
                try await harness.driveFrameBoundary()
                #expect(
                    harness.probeObservation.scrollCommandCount
                        == commandsBeforeDetachedGrowth
                )
                #expect(
                    harness.probeObservation.projectionWorkAdmissionCount
                        == projectionWorkBaseline
                )

                let commandsBeforeCatchUp = harness.probeObservation.scrollCommandCount
                harness.driveCatchUp(reduceMotion: true)
                _ = try await harness.recorder.waitUntil {
                    $0.observation.scrollCommandCount == commandsBeforeCatchUp + 1
                }
                harness.drivePhase(from: .idle, to: .interacting, geometry: away)
                #expect(harness.probeObservation.isDetached)
                #expect(harness.probeObservation.hasUnread)
            }
        }
    }

    @Test("actual ChatView pinned and detached shrink emits zero scroll writes")
    func shrinkDoesNotFollow() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_193) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                let pinnedBefore = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_200, containerHeight: 400
                )
                let pinnedAfter = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_150, containerHeight: 400
                )
                let pinnedBaseline = harness.probeObservation.scrollCommandCount
                harness.driveGeometry(previous: pinnedBefore, current: pinnedAfter)
                try await harness.driveFrameBoundary()
                #expect(harness.probeObservation.scrollCommandCount == pinnedBaseline)

                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400
                )
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveNativeOwnership(false)
                #expect(harness.probeObservation.isDetached)

                let detachedBaseline = harness.probeObservation.scrollCommandCount
                harness.driveGeometry(
                    previous: away,
                    current: ChatTranscriptGeometry(
                        offsetY: 300, contentHeight: 950, containerHeight: 400
                    )
                )
                try await harness.driveFrameBoundary()
                #expect(harness.probeObservation.scrollCommandCount == detachedBaseline)
            }
        }
    }

    @Test("actual ChatView keeps pinned overshoot native without app writes")
    func pinnedOvershootNeedsNoAppWrite() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_194) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                let baseline = harness.probeObservation.automaticScrollCommandCount
                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400,
                    visibleTopY: 600, visibleBottomY: 1_000
                )
                let overshoot = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 900, containerHeight: 400,
                    visibleTopY: 600, visibleBottomY: 1_000
                )
                #expect(overshoot.isPastBottomEdge)
                harness.driveGeometry(previous: bottom, current: overshoot)
                try await harness.driveFrameBoundary()
                try await Task.sleep(for: .milliseconds(100))
                #expect(harness.probeObservation.automaticScrollCommandCount == baseline)
            }
        }
    }

    @Test("agent response and compaction settlement retain mounted physical rows")
    func unifiedResponseAndNotificationSettlement() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_190) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                        && ($0.observation.scrollSettledDistance ?? .infinity)
                            <= ChatTranscriptGeometry.catchUpDistance
                }
                let entranceBaseline = ready.observation.animatedEntranceCount
                let automaticScrollBaseline = ready.observation.automaticScrollCommandCount
                let smoothBaseline = ready.observation.smoothAutomaticScrollCommandCount
                let materializationBaseline = ready.observation.tailMaterializationCommandCount
                let installBaseline = ready.observation.projectionInstallCount

                var intermediate = harness.snapshot
                intermediate.phase = .running
                intermediate.streaming = try harnessAssistantMessage(
                    id: "streaming-agent",
                    presentationID: "turn-agent",
                    text: "An intermediate response"
                )
                intermediate.revision += 1
                intermediate.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(intermediate)

                let revealed = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > installBaseline
                        && $0.observation.animatedEntranceCount == entranceBaseline + 1
                        && $0.observation.rowFrames["turn-agent"] != nil
                }
                #expect(revealed.observation.automaticScrollCommandCount == automaticScrollBaseline)
                #expect(revealed.observation.smoothAutomaticScrollCommandCount == smoothBaseline)
                #expect(revealed.observation.tailMaterializationCommandCount == materializationBaseline + 1)
                #expect(revealed.observation.physicalRowAppearanceCounts["turn-agent"] == 1)
                #expect(try harness.nativeTranscriptDistanceFromTail() <= 2)
                #expect(!revealed.observation.visibleRowIDs.isEmpty)

                var final = intermediate
                final.phase = .idle
                final.streaming = nil
                final.transcript.append(try harnessAssistantMessage(
                    id: "canonical-agent",
                    presentationID: "turn-agent",
                    text: "The final response"
                ))
                final.transcriptTotal = (final.transcriptTotal ?? final.transcript.count - 1) + 1
                final.revision += 1
                final.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(final)

                let settled = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > revealed.observation.projectionInstallCount
                        && $0.observation.rowFrames["turn-agent"] != nil
                }
                #expect(settled.observation.animatedEntranceCount == entranceBaseline + 1)
                #expect(settled.observation.tailMaterializationCommandCount == materializationBaseline + 1)
                #expect(settled.observation.physicalRowAppearanceCounts["turn-agent"] == 1)
                #expect((settled.observation.physicalRowDisappearanceCounts["turn-agent"] ?? 0) == 0)
                #expect(try harness.nativeTranscriptDistanceFromTail() <= 2)
                #expect(!settled.observation.visibleRowIDs.isEmpty)

                let compactionOrdinal = try #require(final.transcriptTotal)
                let compactionRowID = "notification-compaction-slot-\(compactionOrdinal)"
                var compacting = final
                compacting.phase = .compacting
                compacting.revision += 1
                compacting.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(compacting)
                let progress = try await harness.recorder.waitUntil {
                    $0.observation.rowFrames[compactionRowID] != nil
                        && $0.observation.animatedEntranceCount == entranceBaseline + 2
                }
                #expect(progress.observation.physicalRowAppearanceCounts[compactionRowID] == 1)
                #expect(progress.observation.tailMaterializationCommandCount == materializationBaseline + 2)
                #expect(try harness.nativeTranscriptDistanceFromTail() <= 2)
                #expect(!progress.observation.visibleRowIDs.isEmpty)

                var compacted = compacting
                compacted.transcript.append(try harnessCompactionItem(id: "canonical-compaction"))
                compacted.transcriptTotal = compactionOrdinal + 1
                compacted.revision += 1
                compacted.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(compacted)
                let compactionSettled = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > progress.observation.projectionInstallCount
                        && $0.observation.rowFrames[compactionRowID] != nil
                }
                #expect(compactionSettled.observation.animatedEntranceCount == entranceBaseline + 2)
                #expect(compactionSettled.observation.tailMaterializationCommandCount == materializationBaseline + 2)
                #expect(compactionSettled.observation.physicalRowAppearanceCounts[compactionRowID] == 1)
                #expect((compactionSettled.observation.physicalRowDisappearanceCounts[compactionRowID] ?? 0) == 0)
                #expect(try harness.nativeTranscriptDistanceFromTail() <= 2)
                #expect(!compactionSettled.observation.visibleRowIDs.isEmpty)
            }
        }
    }

    @Test("ordinary discrete transcript insertion materializes and reveals exactly once")
    func ordinaryDiscreteInsertionEntrance() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_191) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                        && ($0.observation.scrollSettledDistance ?? .infinity)
                            <= ChatTranscriptGeometry.catchUpDistance
                }
                let entranceBaseline = ready.observation.animatedEntranceCount
                let automaticScrollBaseline = ready.observation.automaticScrollCommandCount
                let materializationBaseline = ready.observation.tailMaterializationCommandCount
                let installBaseline = ready.observation.projectionInstallCount

                var inserted = harness.snapshot
                inserted.transcript.append(try harnessMessage(id: "discrete-tail"))
                inserted.transcriptTotal = (inserted.transcriptTotal ?? inserted.transcript.count - 1) + 1
                inserted.revision += 1
                inserted.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(inserted)

                let revealed = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > installBaseline
                        && $0.observation.animatedEntranceCount == entranceBaseline + 1
                        && $0.observation.rowFrames["discrete-tail"] != nil
                }
                #expect(revealed.observation.automaticScrollCommandCount == automaticScrollBaseline)
                #expect(revealed.observation.tailMaterializationCommandCount == materializationBaseline + 1)
                #expect(revealed.observation.physicalRowAppearanceCounts["discrete-tail"] == 1)

                var revised = inserted
                revised.transcript[revised.transcript.count - 1] = try harnessAssistantMessage(
                    id: "discrete-tail",
                    presentationID: "discrete-tail",
                    text: "A revised final response"
                )
                revised.revision += 1
                revised.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(revised)
                let updated = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > revealed.observation.projectionInstallCount
                        && $0.observation.rowFrames["discrete-tail"] != nil
                }
                #expect(updated.observation.animatedEntranceCount == entranceBaseline + 1)
                #expect(updated.observation.tailMaterializationCommandCount == materializationBaseline + 1)
                #expect(updated.observation.physicalRowAppearanceCounts["discrete-tail"] == 1)
                #expect((updated.observation.physicalRowDisappearanceCounts["discrete-tail"] ?? 0) == 0)
            }
        }
    }

    @Test("running tool entrance uses displayed install when desired completion advances first")
    func displayedInstallOwnsRunningToolEntrance() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_192) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                        && $0.observation.projectionInstallCount >= 1
                }
                let entranceBaseline = ready.observation.animatedEntranceCount
                let smoothBaseline = ready.observation.smoothAutomaticScrollCommandCount
                let materializationBaseline = ready.observation.tailMaterializationCommandCount
                let installBaseline = ready.observation.projectionInstallCount

                var running = harness.snapshot
                running.phase = .running
                running.toolExecutions = [harnessRuntimeTool(
                    status: .running,
                    groupFinalized: false
                )]
                running.eventSequence += 1
                let runningOrdinal = running.eventSequence

                var completed = running
                completed.toolExecutions = [harnessRuntimeTool(
                    status: .completed,
                    groupId: "settled-group"
                )]
                completed.eventSequence += 1
                let completedOrdinal = completed.eventSequence

                harness.replaceOnNextProjectionInstall(
                    expectedSourceOrdinal: runningOrdinal,
                    with: completed
                )
                harness.replaceAuthoritativeSnapshot(running)

                let settled = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount >= installBaseline + 2
                        && $0.observation.installedProjectionSourceOrdinal == completedOrdinal
                        && $0.observation.lastAnimatedEntranceSourceOrdinal == runningOrdinal
                }
                #expect(settled.observation.animatedEntranceCount == entranceBaseline + 1)
                #expect(settled.observation.smoothAutomaticScrollCommandCount == smoothBaseline)
                #expect(
                    settled.observation.tailMaterializationCommandCount
                        == materializationBaseline + 1
                )
                #expect(settled.observation.rowFrames["tool-run-settled-group"] != nil)
                #expect(settled.observation.physicalRowAppearanceCounts["tool-run-active-race"] == 1)
                let lifecycleSamples = settled.observation.toolChipSamples.filter {
                    $0.callIDs.contains("active-race")
                }
                #expect(lifecycleSamples.count { $0.transitionToken == 1 } == 1)
                #expect(lifecycleSamples.last?.runID == "tool-run-settled-group")
            }
        }
    }

    @Test("real tool group topology inserts one chip under native viewport pinning")
    func toolGroupTopologySettlement() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_194) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                        && $0.observation.projectionInstallCount >= 1
                }
                let installBaseline = ready.observation.projectionInstallCount
                let smoothBaseline = ready.observation.smoothAutomaticScrollCommandCount
                let materializationBaseline = ready.observation.tailMaterializationCommandCount

                var first = harness.snapshot
                first.phase = .running
                first.toolExecutions = [
                    harnessRuntimeTool(id: "group-one", order: 0, status: .running, groupId: "group-one", groupIndex: 0, groupCount: 2),
                ]
                first.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(first)
                _ = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount >= installBaseline + 1
                        && $0.observation.rowFrames["tool-run-group-one"] != nil
                }

                var grouped = first
                grouped.toolExecutions = [
                    harnessRuntimeTool(id: "group-one", order: 0, status: .completed, groupId: "group-one", groupIndex: 0, groupCount: 2),
                    harnessRuntimeTool(id: "group-two", order: 1, status: .completed, groupId: "group-one", groupIndex: 1, groupCount: 2),
                ]
                grouped.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(grouped)
                let settled = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount >= installBaseline + 2
                        && $0.observation.rowFrames["tool-run-group-one"] != nil
                }

                #expect(settled.observation.rowFrames["tool-run-group-two"] == nil)
                #expect(settled.observation.smoothAutomaticScrollCommandCount == smoothBaseline)
                #expect(
                    settled.observation.tailMaterializationCommandCount
                        == materializationBaseline + 1
                )
                #expect(settled.observation.physicalRowAppearanceCounts["tool-run-group-one"] == 1)
                #expect(settled.observation.toolChipSamples.count {
                    $0.runID == "tool-run-group-one" && $0.transitionToken == 1
                } == 1)
                let samples = settled.observation.toolChipSamples.filter {
                    $0.runID == "tool-run-group-one"
                }
                #expect(samples.last?.count == 2)
                #expect(samples.allSatisfy { !$0.title.contains("Extension activity") })

                // A later assistant declaration is a distinct physical run.
                // It must not grow the most recent chip into an aggregate of
                // every tool still retained by runtime authority.
                var nextGroup = grouped
                nextGroup.toolExecutions.append(harnessRuntimeTool(
                    id: "group-next",
                    order: 2,
                    status: .running,
                    groupId: "group-next",
                    groupIndex: 0,
                    groupCount: 1
                ))
                nextGroup.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(nextGroup)
                let distinct = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount >= installBaseline + 3
                        && $0.observation.rowFrames["tool-run-group-one"] != nil
                        && $0.observation.rowFrames["tool-run-group-next"] != nil
                }
                #expect(distinct.observation.toolChipSamples.count {
                    $0.runID == "tool-run-group-one" && $0.transitionToken == 1
                } == 1)
                #expect(distinct.observation.toolChipSamples.count {
                    $0.runID == "tool-run-group-next" && $0.transitionToken == 1
                } == 1)
                let latest = distinct.observation.toolChipSamples.last {
                    $0.runID == "tool-run-group-next"
                }
                #expect(latest?.count == 1)
                #expect(latest?.title == "Read file")
            }
        }
    }

    @Test("detached discrete insertion freezes projection until manual tail return")
    func detachedDiscreteInsertion() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_191) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400
                )
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveNativeOwnership(false)
                #expect(harness.probeObservation.isDetached)

                let commandBaseline = harness.probeObservation.automaticScrollCommandCount
                let installBaseline = harness.probeObservation.projectionInstallCount
                var updated = harness.snapshot
                updated.transcript.append(try harnessMessage(id: "detached-tail"))
                updated.transcriptTotal = (updated.transcriptTotal ?? updated.transcript.count - 1) + 1
                updated.revision += 1
                updated.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(updated)
                try await harness.driveFrameBoundary()
                #expect(harness.probeObservation.projectionInstallCount == installBaseline)
                #expect(harness.probeObservation.automaticScrollCommandCount == commandBaseline)

                harness.drivePhase(from: .idle, to: .interacting, geometry: away)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: away, current: bottom)
                harness.drivePhase(from: .interacting, to: .idle, geometry: bottom)
                harness.driveNativeOwnership(false)
                let reconciled = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > installBaseline
                }
                #expect(!reconciled.observation.isDetached)
                #expect(reconciled.observation.automaticScrollCommandCount == commandBaseline)
            }
        }
    }

    @Test("catch-up keeps the frozen commit until its tail lease settles")
    func catchUpReconcilesNewestProjection() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_196) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400
                )
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveNativeOwnership(false)

                let installBaseline = harness.probeObservation.projectionInstallCount
                var newest = harness.snapshot
                for offset in 1...3 {
                    newest.eventSequence += 1
                    newest.revision += 1
                    newest.streaming = try harnessAssistantMessage(
                        id: "catch-up-stream-\(offset)",
                        presentationID: "catch-up-turn",
                        text: "update \(offset)"
                    )
                    harness.replaceAuthoritativeSnapshot(newest)
                }
                try await harness.driveFrameBoundary()
                #expect(harness.probeObservation.projectionInstallCount == installBaseline)

                let commandBaseline = harness.probeObservation.scrollCommandCount
                harness.driveCatchUp(reduceMotion: true)
                _ = try await harness.recorder.waitUntil {
                    $0.observation.scrollCommandCount > commandBaseline
                }
                #expect(harness.probeObservation.projectionInstallCount == installBaseline)
                harness.driveGeometry(previous: away, current: bottom, viewport: true)
                let reconciled = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount == installBaseline + 1
                }
                #expect(!reconciled.observation.isDetached)
                #expect(reconciled.observation.installedProjectionRowCount > 0)
            }
        }
    }

    @Test("retained detached authority replacement preserves its installed cut")
    func retainedDetachedAuthorityReplacement() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_197) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400
                )
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveNativeOwnership(false)
                #expect(harness.probeObservation.isDetached)

                let installBaseline = harness.probeObservation.projectionInstallCount
                var replacement = harness.snapshot
                replacement.runtimeGeneration += "-replacement"
                replacement.eventSequence = 1
                replacement.revision += 1
                replacement.transcript.append(try harnessMessage(id: "reopen-tail"))
                replacement.transcriptTotal = (replacement.transcriptTotal
                    ?? replacement.transcript.count - 1) + 1
                await harness.reopenWithAuthoritativeSnapshot(replacement)
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 2
                }
                #expect(harness.probeObservation.isDetached)
                #expect(harness.probeObservation.projectionInstallCount == installBaseline)

                harness.drivePhase(from: .idle, to: .interacting, geometry: away)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: away, current: bottom, viewport: true)
                harness.drivePhase(from: .interacting, to: .idle, geometry: bottom)
                harness.driveNativeOwnership(false)
                let reconciled = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount == installBaseline + 1
                }
                #expect(reconciled.observation.installedProjectionRowCount > 0)
                #expect(!reconciled.observation.isDetached)
            }
        }
    }

    @Test("streaming burst stays deferred and reconciles only its newest projection at the tail")
    func streamingBurstLatestProjection() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 118) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                        && $0.observation.projectionInstallCount >= 1
                        && $0.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                        && ($0.observation.scrollSettledDistance ?? .infinity)
                            <= ChatTranscriptGeometry.catchUpDistance
                }
                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400
                )
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveNativeOwnership(false)
                #expect(harness.probeObservation.isDetached)

                var newest = harness.snapshot
                let initialSequence = newest.eventSequence
                let initialProjectionOrdinal = try #require(
                    harness.probeObservation.installedProjectionSourceOrdinal
                )
                let initialProjectionInstalls = harness.probeObservation.projectionInstallCount
                let initialProjectionWorkAdmissions =
                    harness.probeObservation.projectionWorkAdmissionCount
                let committedEvaluationBaseline =
                    harness.probeObservation.committedHistoryRowEvaluationCount
                for offset in 1...30 {
                    newest.revision += 1
                    newest.eventSequence = initialSequence + offset
                    newest.streaming = newest.transcript.last
                    harness.replaceAuthoritativeSnapshot(newest)
                }

                try await harness.driveFrameBoundary()
                #expect(
                    harness.probeObservation.installedProjectionSourceOrdinal
                        == initialProjectionOrdinal
                )
                #expect(
                    harness.probeObservation.projectionInstallCount
                        == initialProjectionInstalls
                )
                #expect(
                    harness.probeObservation.projectionWorkAdmissionCount
                        == initialProjectionWorkAdmissions
                )
                #expect(
                    harness.probeObservation.committedHistoryRowEvaluationCount
                        == committedEvaluationBaseline
                )

                harness.drivePhase(from: .idle, to: .interacting, geometry: away)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: away, current: bottom)
                harness.drivePhase(from: .interacting, to: .idle, geometry: bottom)
                harness.driveNativeOwnership(false)
                let newestInstall = try await harness.recorder.waitUntil {
                    $0.observation.installedProjectionSourceOrdinal == initialProjectionOrdinal + 30
                }
                #expect(newestInstall.observation.installedProjectionRowCount > 0)
                #expect(!newestInstall.observation.isDetached)
                #expect(
                    newestInstall.observation.projectionInstallCount
                        == initialProjectionInstalls + 1
                )
                #expect(
                    newestInstall.observation.projectionWorkAdmissionCount
                        == initialProjectionWorkAdmissions + 1
                )
                #expect(
                    newestInstall.observation.committedHistoryRowEvaluationCount
                        <= committedEvaluationBaseline + 1
                )
            }
        }
    }

    @Test("manual tail return hides catch-up and pinned keyboard transition follows")
    func manualTailReturnAndKeyboardFollow() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 117) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                        && $0.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                        && ($0.observation.scrollSettledDistance ?? .infinity)
                            <= ChatTranscriptGeometry.catchUpDistance
                }
                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400
                )
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveNativeOwnership(false)
                harness.driveSemanticResponse()
                #expect(harness.probeObservation.isDetached)
                #expect(harness.probeObservation.hasUnread)

                // Production callback order observed on device: the final
                // direct return can be a mixed scroll/viewport callback while
                // interactive keyboard dismissal changes the inset.
                harness.drivePhase(from: .idle, to: .interacting, geometry: away)
                let intermediateViewport = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 350
                )
                harness.driveGeometry(previous: away, current: intermediateViewport, viewport: true)
                #expect(harness.probeObservation.isDetached)
                let mixedBottom = ChatTranscriptGeometry(
                    offsetY: 700, contentHeight: 1_000, containerHeight: 300
                )
                harness.drivePhase(from: .interacting, to: .idle, geometry: mixedBottom)
                #expect(!harness.probeObservation.isDetached)
                #expect(!harness.probeObservation.hasUnread)

                let automaticBeforeKeyboard = harness.probeObservation.automaticScrollCommandCount
                let keyboard = ChatTranscriptGeometry(
                    offsetY: 700,
                    contentHeight: 1_000,
                    containerHeight: 250,
                    bottomInset: 100
                )
                harness.driveGeometry(previous: mixedBottom, current: keyboard, viewport: true)
                try await harness.driveFrameBoundary()
                #expect(
                    harness.probeObservation.automaticScrollCommandCount
                        == automaticBeforeKeyboard
                )
                #expect(!harness.probeObservation.isDetached)
            }
        }
    }

    @Test("hosted exact page barrier rejects repeat and stale prepend completion")
    func hostedPrependBarrier() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 108) { harness in
                _ = try await harness.recorder.waitUntil { sample in
                    sample.observation.readyFrameCompletionCount == 1
                        && sample.observation.visibleRowIDs.contains(where: {
                            sample.observation.rowFrames[$0] != nil
                        })
                }
                guard harness.drivePrepend() else {
                    Issue.record("expected measured hosted prepend admission")
                    return
                }
                #expect(!harness.drivePrepend())
                _ = try await harness.recorder.waitUntil { $0.observation.prependLoadWaiting }
                let callbacksBeforeRelease = harness.probeObservation.semanticFrameCallbackCount
                let automaticBeforeRelease = harness.probeObservation.automaticScrollCommandCount
                harness.releasePrependPage()
                let waiting = try await harness.recorder.waitUntil {
                    $0.observation.prependSemanticFrameWaiting
                        || $0.observation.prependCompletionResult != nil
                }
                if waiting.observation.prependCompletionResult == nil {
                    harness.driveGeometry(
                        previous: waiting.observation.geometry,
                        current: waiting.observation.geometry
                    )
                }
                let completed = try await harness.recorder.waitUntil {
                    $0.observation.prependCompletionResult == .success
                }
                #expect(completed.observation.semanticFrameCallbackCount > callbacksBeforeRelease)
                #expect(completed.observation.maximumSemanticExcursion <= 2)
                #expect(completed.observation.automaticScrollCommandCount == automaticBeforeRelease)

                #expect(harness.drivePrepend())
                _ = try await harness.recorder.waitUntil { $0.observation.prependLoadWaiting }
                harness.drivePresentationInvalidation()
                _ = try await harness.recorder.waitUntil {
                    $0.observation.prependCompletionResult == .discarded
                }
                harness.releasePrependPage()
            }
        }
    }

    @Test("geometry observations are coalesced to one sample per presented frame")
    func oneSamplePerPresentedFrame() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 103) { harness in
                let initial = try await harness.recorder.waitUntil { $0.observation.geometry.isValid }
                harness.resize(height: 760)
                let resized = try await harness.recorder.waitUntil {
                    abs($0.observation.geometry.containerHeight - initial.observation.geometry.containerHeight) > 1
                }
                harness.resize(height: 844)
                _ = try await harness.recorder.waitUntil {
                    $0.frameIndex > resized.frameIndex
                        && abs($0.observation.geometry.containerHeight - initial.observation.geometry.containerHeight) <= 1
                }

                let samples = harness.recorder.samples
                #expect(samples.count >= 3)
                #expect(Set(samples.map(\.frameIndex)).count == samples.count)
                for (previous, current) in zip(samples, samples.dropFirst()) {
                    #expect(
                        current.observation.automaticScrollCommandCount
                            - previous.observation.automaticScrollCommandCount <= 1
                    )
                }
            }
        }
    }

    private func withHarness(
        seed: Int,
        displayFrameScheduler: DisplayFrameScheduler = .displayLink,
        operation: @escaping @MainActor @Sendable (ChatViewScrollHarness) async throws -> Void
    ) async throws {
        try await withHarness(
            snapshot: SessionScenarioBuilder(seed: seed).openingTail(targetEncodedBytes: 10_000),
            displayFrameScheduler: displayFrameScheduler,
            operation: operation
        )
    }

    private func withHarness(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler = .displayLink,
        operation: @escaping @MainActor @Sendable (ChatViewScrollHarness) async throws -> Void
    ) async throws {
        let harness = try ChatViewScrollHarness(
            snapshot: snapshot,
            displayFrameScheduler: displayFrameScheduler
        )
        do {
            try await operation(harness)
        } catch {
            harness.cleanup()
            throw error
        }
        harness.cleanup()
    }
}

private func harnessInlineMarkdownDisplaySnapshot() throws -> SessionSnapshot {
    var snapshot = try SessionScenarioBuilder(seed: 1_210).openingTail(targetEncodedBytes: 10_000)
    snapshot.transcript = try decodeTranscriptFixture(
        [TranscriptItem].self,
        from: Data(#"""
        [
          {"id":"display-request","parentId":null,"presentationId":"display-request","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"display-call-content","ordinal":0,"type":"toolCall","toolCallId":"display-call","name":"display","arguments":{"presentation":{"surface":"inline"}}}
          ]},
          {"id":"display-result","parentId":"display-request","presentationId":"display-result","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"display-result-text","ordinal":0,"type":"text","text":"Displayed Inline Markdown."}],"toolCallId":"display-call","toolName":"display","isError":false,
           "display":{"schema":"tron.display.v1","displayId":"inline-markdown","revision":1,"title":"Inline Markdown","altText":"An inline Markdown fixture.","kind":"markdown","presentation":{"requestedSurface":"inline","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline"],"fallbackText":"Inline Markdown fixture.","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc3b","name":"inline.md","mimeType":"text/markdown","size":335,"kind":"markdown"}}},
          {"id":"display-answer","parentId":"display-result","presentationId":"display-answer","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"display-answer-text","ordinal":0,"type":"text","text":"Displayed Inline Markdown inline."}]}
        ]
        """#.utf8)
    )
    snapshot.transcriptStart = 0
    snapshot.transcriptTotal = snapshot.transcript.count
    snapshot.toolExecutions = []
    return snapshot
}

private func harnessRuntimeTool(
    id: String = "active-race",
    order: Int = 0,
    status: ToolExecutionState.Status,
    groupId: String? = nil,
    groupIndex: Int = 0,
    groupCount: Int = 1,
    groupFinalized: Bool = true
) -> ToolExecutionState {
    ToolExecutionState(
        toolCallId: id,
        toolName: "read",
        order: order,
        status: status,
        arguments: .object(["path": .string("README.md")]),
        partialResult: nil,
        result: status == .completed ? .object(["ok": .bool(true)]) : nil,
        output: status == .completed ? "done" : nil,
        isError: false,
        startedAt: "2026-01-01T00:00:00Z",
        updatedAt: status == .completed ? "2026-01-01T00:00:01Z" : "2026-01-01T00:00:00Z",
        completedAt: status == .completed ? "2026-01-01T00:00:01Z" : nil,
        durationMs: status == .completed ? 1_000 : nil,
        progressSequence: status == .completed ? 2 : 1,
        groupId: groupFinalized ? (groupId ?? id) : nil,
        groupIndex: groupFinalized ? groupIndex : nil,
        groupCount: groupFinalized ? groupCount : nil,
        groupFinalized: groupFinalized ? true : nil
    )
}

private func harnessAssistantMessage(
    id: String,
    presentationID: String,
    text: String
) throws -> TranscriptItem {
    try decodeTranscriptFixture(
        TranscriptItem.self,
        from: Data("""
        {"id":"\(id)","parentId":null,"presentationId":"\(presentationID)","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"\(id):text","ordinal":0,"type":"text","text":"\(text)"}]}
        """.utf8)
    )
}

private func harnessRichAssistantMessage(
    id: String,
    presentationID: String,
    thinkingLines: [String],
    text: String
) throws -> TranscriptItem {
    var content: [[String: Any]] = []
    if !thinkingLines.isEmpty {
        content.append([
            "id": "\(id):thinking",
            "ordinal": 0,
            "thinkingRunOrdinal": 0,
            "type": "thinking",
            "text": thinkingLines.joined(separator: "\n")
        ])
    }
    content.append([
        "id": "\(id):text",
        "ordinal": thinkingLines.isEmpty ? 0 : 1,
        "type": "text",
        "text": text
    ])
    let data = try JSONSerialization.data(withJSONObject: [
        "id": id,
        "parentId": NSNull(),
        "presentationId": presentationID,
        "timestamp": "2026-01-01T00:00:00Z",
        "kind": "message",
        "role": "assistant",
        "content": content
    ])
    return try decodeTranscriptFixture(TranscriptItem.self, from: data)
}

private func harnessCompactionItem(id: String) throws -> TranscriptItem {
    try decodeTranscriptFixture(
        TranscriptItem.self,
        from: Data("""
        {"id":"\(id)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"Compacted context","tokensBefore":100}
        """.utf8)
    )
}

private func harnessMessage(id: String) throws -> TranscriptItem {
    try decodeTranscriptFixture(
        TranscriptItem.self,
        from: Data("""
        {"id":"\(id)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"\(id):text","type":"text","text":"A new response"}]}
        """.utf8)
    )
}

@MainActor
final class ChatViewScrollHarness {
    let snapshot: SessionSnapshot
    let transcriptIDs: Set<String>
    let firstTranscriptID: String
    let lastTranscriptID: String
    let recorder: PresentedFrameRecorder
    let signposts: RecordingPerformanceSignposts
    let probe: ChatHostedProbe

    private let model: AppModel
    private let suiteName: String
    private let cacheRoot: URL
    private let defaults: UserDefaults
    private let window: UIWindow
    private let hostingController: UIHostingController<AnyView>

    convenience init(seed: Int, displayFrameScheduler: DisplayFrameScheduler) throws {
        try self.init(
            snapshot: SessionScenarioBuilder(seed: seed).openingTail(targetEncodedBytes: 10_000),
            displayFrameScheduler: displayFrameScheduler
        )
    }

    init(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler,
        performanceSignposts: (any PerformanceSignposting)? = nil
    ) throws {
        self.snapshot = snapshot
        transcriptIDs = Set(snapshot.transcript.map(\.id)).union(["transcript-bottom"])
        firstTranscriptID = try Self.require(snapshot.transcript.first?.id)
        lastTranscriptID = try Self.require(snapshot.transcript.last?.id)
        let signposts = RecordingPerformanceSignposts()
        self.signposts = signposts

        suiteName = "ChatViewScrollHarnessTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        cacheRoot = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        let model = AppModel(
            client: GatewayClient(),
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: cacheRoot)
        )
        self.model = model
        guard model.authoritativeSnapshot(for: snapshot.sessionId) == nil else {
            throw HarnessError.invalidAuthorityBoundary
        }
        // Hosted presentation generations are authoritative and need not match
        // ChatOpenPresentationState's local opening epoch.
        model.invalidateHostedPendingPresentation()
        model.installHostedAuthoritativeSnapshot(snapshot)
        guard model.authoritativeSnapshot(for: snapshot.sessionId) == snapshot else {
            throw HarnessError.invalidAuthorityBoundary
        }

        let probe = ChatHostedProbe()
        self.probe = probe
        let sessionID = snapshot.sessionId
        let root = AnyView(
            NavigationStack {
                ChatView(
                    sessionID: sessionID,
                    hostedProbe: probe,
                    displayFrameScheduler: displayFrameScheduler,
                    performanceSignposts: performanceSignposts ?? signposts
                )
            }
            .environment(model)
        )
        hostingController = UIHostingController(rootView: root)
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw HarnessError.missingWindowScene
        }
        window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        let hostedView = hostingController.view!
        recorder = PresentedFrameRecorder(probe: probe) { geometry in
            Self.containsNativeTranscriptScrollView(in: hostedView, matching: geometry)
        }
        recorder.start()
    }

    var probeObservation: ChatHostedObservation { probe.observation }

    func replaceAuthoritativeSnapshot(_ snapshot: SessionSnapshot) {
        model.replaceHostedAuthoritativeSnapshot(snapshot)
    }

    func reopenWithAuthoritativeSnapshot(_ snapshot: SessionSnapshot) async {
        model.installHostedAuthoritativeSnapshot(snapshot)
        await probe.reopenPresentation()
    }

    func replaceOnNextProjectionInstall(
        expectedSourceOrdinal: Int,
        with snapshot: SessionSnapshot
    ) {
        probe.onNextProjectionInstall { [model] sourceOrdinal in
            #expect(sourceOrdinal == expectedSourceOrdinal)
            guard sourceOrdinal == expectedSourceOrdinal else { return }
            model.replaceHostedAuthoritativeSnapshot(snapshot)
        }
    }

    func driveGeometry(
        previous: ChatTranscriptGeometry,
        current: ChatTranscriptGeometry,
        viewport: Bool = false
    ) {
        probe.driveGeometry(previous: previous, current: current, viewport: viewport)
    }

    func drivePhase(from: ScrollPhase, to: ScrollPhase, geometry: ChatTranscriptGeometry?) {
        probe.drivePhase(from: from, to: to, geometry: geometry)
    }

    func driveNativeOwnership(_ owned: Bool) {
        probe.driveNativeOwnership(owned)
    }

    func driveSemanticResponse() {
        probe.driveSemanticResponse()
    }

    func driveCatchUp(reduceMotion: Bool) {
        probe.driveCatchUp(reduceMotion: reduceMotion)
    }

    func drivePrepend() -> Bool { probe.drivePrepend() }

    func drivePinnedPositionReapplication() {
        probe.drivePinnedPositionReapplication()
    }

    func releasePrependPage() { probe.releasePrependPage() }

    func drivePresentationInvalidation() { probe.drivePresentationInvalidation() }

    func driveFrameBoundary() async throws {
        try await probe.driveFrameBoundary()
    }

    var firstReadyEvents: [RecordingPerformanceSignposts.Event] {
        signposts.events().filter { $0.operation == .firstReadyFrame }
    }

    var scrollEvents: [RecordingPerformanceSignposts.Event] {
        signposts.events().filter { $0.operation == .scrollCommandSettle }
    }

    private static func containsNativeTranscriptScrollView(
        in view: UIView,
        matching geometry: ChatTranscriptGeometry
    ) -> Bool {
        Self.scrollViews(in: view).contains { scrollView in
            !(scrollView is UITextView)
                && scrollView.contentSize.height > scrollView.bounds.height
                && abs(scrollView.contentSize.height - geometry.contentHeight) <= 2
                && abs(scrollView.bounds.origin.y - geometry.offsetY) <= 2
        }
    }

    func displaceNativeTranscriptFromTail(by distance: CGFloat) throws {
        let scrollView = try nativeTranscriptScrollView()
        let maximum = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: max(0, maximum - distance)),
            animated: false
        )
        scrollView.layoutIfNeeded()
    }

    func nativeTranscriptSignedTailError() throws -> CGFloat {
        let scrollView = try nativeTranscriptScrollView()
        let maximum = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        return scrollView.contentOffset.y - maximum
    }

    func nativeTranscriptDistanceFromTail() throws -> CGFloat {
        abs(try nativeTranscriptSignedTailError())
    }

    private func nativeTranscriptScrollView() throws -> UIScrollView {
        guard let value = Self.scrollViews(in: hostingController.view)
            .filter({ !($0 is UITextView) && $0.contentSize.height > $0.bounds.height })
            .max(by: { $0.contentSize.height < $1.contentSize.height }) else {
            throw HarnessError.missingTranscript
        }
        return value
    }

    func resize(height: CGFloat) {
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
    }

    func setComposerText(_ text: String) throws {
        guard let textView = Self.textViews(in: hostingController.view).first else {
            throw HarnessError.missingComposer
        }
        textView.text = text
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        textView.delegate?.textViewDidChange?(textView)
        textView.delegate?.textViewDidChangeSelection?(textView)
        hostingController.view.setNeedsLayout()
    }

    func cleanup() {
        probe.cancelPresentation()
        recorder.stop()
        window.isHidden = true
        window.rootViewController = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw HarnessError.missingTranscript }
        return value
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews)
    }

    private static func textViews(in view: UIView) -> [UITextView] {
        let current = (view as? UITextView).map { [$0] } ?? []
        return current + view.subviews.flatMap(textViews)
    }
}

@MainActor
final class PresentedFrameRecorder: NSObject {
    struct Sample: Sendable {
        let frameIndex: Int
        let observation: ChatHostedObservation
        let nativeGeometryMatches: Bool
    }

    private struct Waiter {
        let id: Int
        let predicate: @MainActor (Sample) -> Bool
        let continuation: CheckedContinuation<Sample, Error>
    }

    private let probe: ChatHostedProbe
    private let nativeGeometryMatches: @MainActor (ChatTranscriptGeometry) -> Bool
    private var displayLink: CADisplayLink?
    private var frameIndex = 0
    private var lastRevision = -1
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    private(set) var samples: [Sample] = []

    init(
        probe: ChatHostedProbe,
        nativeGeometryMatches: @escaping @MainActor (ChatTranscriptGeometry) -> Bool
    ) {
        self.probe = probe
        self.nativeGeometryMatches = nativeGeometryMatches
    }

    func start() {
        guard displayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(displayFrame))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
    }

    func waitUntil(_ predicate: @escaping @MainActor (Sample) -> Bool) async throws -> Sample {
        if let sample = samples.last(where: predicate) { return sample }
        let id = nextWaiterID
        nextWaiterID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, predicate: predicate, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id: id) }
        }
    }

    @objc private func displayFrame() {
        frameIndex += 1
        let observation = probe.observation
        guard observation.revision != lastRevision else { return }
        lastRevision = observation.revision
        let sample = Sample(
            frameIndex: frameIndex,
            observation: observation,
            nativeGeometryMatches: nativeGeometryMatches(observation.geometry)
        )
        samples.append(sample)
        if samples.count > 256 { samples.removeFirst(samples.count - 256) }

        var ready: [Waiter] = []
        var pending: [Waiter] = []
        for waiter in waiters {
            if waiter.predicate(sample) {
                ready.append(waiter)
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
        for waiter in ready { waiter.continuation.resume(returning: sample) }
    }

    private func cancelWaiter(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

enum HarnessError: Error {
    case invalidAuthorityBoundary
    case missingTranscript
    case missingWindowScene
    case missingComposer
}
