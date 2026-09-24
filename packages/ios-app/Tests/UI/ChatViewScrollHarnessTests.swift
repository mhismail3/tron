import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@MainActor
@Suite("Hosted ChatView scroll harness", .serialized)
struct ChatViewScrollHarnessTests {
    @Test("pasted images use the photo batch chips without replacing the editor or its draft")
    func pastedImagesUsePhotoAttachmentFlow() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_260).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, enablesComposerSubmission: true, enablesPresentationCover: true) { harness in
                let ready = try await harness.recorder.waitUntil { $0.observation.isReady }
                try harness.setComposerText("Describe these images")
                let before = try harness.composerTextAndSelection()
                let images = [UIColor.red, .blue].map { color in
                    UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                        color.setFill()
                        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                    }
                }
                let clipboard = UIPasteboard.general
                let originalClipboard = clipboard.items
                defer { clipboard.items = originalClipboard }
                clipboard.images = images
                harness.uploads.hold = true
                try harness.pasteFromClipboard()
                _ = try await harness.recorder.waitUntil {
                    harness.currentAttachments.count == 2 && harness.uploads.calls == 1
                        && $0.observation.composerHeight > ready.observation.composerHeight + 50
                }
                #expect(harness.currentAttachments.allSatisfy { $0.preparedThumbnail != nil && $0.mimeType.hasPrefix("image/") })
                #expect(harness.currentAttachments.allSatisfy { $0.gatewayUploadID == nil })
                let after = try harness.composerTextAndSelection()
                #expect(after.text == before.text && after.selection == before.selection && after.identity == before.identity)
                for _ in 0..<24 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                harness.captureScreenshot(named: "pasted-photo-batch-chips.png")
                harness.setCovered(true)
                try await harness.waitForCoverTransition(presented: true)
                harness.uploads.hold = false
                harness.uploads.release()
                while harness.currentAttachments.contains(where: { $0.gatewayUploadID == nil }) {
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                }
                #expect(harness.currentAttachments.map(\.gatewayUploadID) == ["fixture-upload-1", "fixture-upload-2"])
                harness.setCovered(false)
                try await harness.waitForCoverTransition(presented: false)
                try harness.pasteImages([NSItemProvider(object: images[0])])
                while harness.currentAttachments.count != 3 || harness.uploads.calls != 3 {
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                }
                try harness.pasteImages([NSItemProvider(object: " in detail" as NSString)])
                while try harness.composerTextAndSelection().text != "Describe these images in detail" {
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                }
                #expect(harness.currentAttachments.count == 3)
            }
        }
    }

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
                let leading = try #require(ready.nativeRows.first {
                    $0.semanticID == harness.firstTranscriptID && $0.isVisible
                })
                let trailingGap = try #require(leading.composerClearance)
                #expect(trailingGap >= -2)
                #expect(trailingGap <= 32)

                // The hosted window contraction is the keyboard-sized native
                // viewport boundary. Do not also summon the simulator keyboard,
                // which would apply the same contraction a second time.
                harness.resize(height: 620)
                let focused = try await harness.recorder.waitUntil {
                    $0.observation.geometry.containerHeight < ready.observation.geometry.containerHeight - 100
                        && $0.observation.visibleRowIDs.contains(harness.firstTranscriptID)
                }
                #expect(!focused.observation.geometry.isPastBottomEdge)
                let contracted = try #require(focused.nativeRows.first {
                    $0.semanticID == harness.firstTranscriptID && $0.isVisible
                })
                #expect(contracted.instance == leading.instance)
                #expect(try #require(contracted.composerClearance) >= -2)
                #expect(try #require(contracted.composerClearance) <= 32)
            }
        }
    }

    @Test("brief recovery preserves rendered Chat identity and native geometry")
    func briefRecoveryPreservesRenderedChat() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            for (seed, encodedBytes) in [(1_240, 10_000), (1_241, 120_000)] {
                let initial = try SessionScenarioBuilder(seed: seed).openingTail(targetEncodedBytes: encodedBytes)
                try await withHarness(snapshot: initial) { harness in
                    let ready = try await harness.recorder.waitUntil {
                        $0.observation.isReady && !$0.nativeRows.filter(\.isVisible).isEmpty
                    }
                    let visibleBefore = ready.nativeRows.filter(\.isVisible)
                    let baselineIDs = visibleBefore.map { ($0.physicalID, $0.instance) }
                    let baselineTailError = try harness.nativeTranscriptSignedTailError()
                    var recovered = initial
                    recovered.revision += 1
                    recovered.eventSequence += 1
                    recovered.phase = .idle
                    harness.replaceAuthoritativeSnapshot(recovered)
                    let resumed = try await harness.recorder.waitUntil {
                        $0.observation.projectionInstallCount > ready.observation.projectionInstallCount
                    }
                    for (physicalID, instance) in baselineIDs {
                        let rows = resumed.nativeRows.filter { $0.isVisible && $0.physicalID == physicalID }
                        #expect(rows.count == 1)
                        #expect(rows.first?.instance == instance)
                    }
                    #expect(abs(try harness.nativeTranscriptSignedTailError() - baselineTailError) <= 16)
                    #expect(!resumed.nativeRows.isEmpty)
                }
            }
        }
    }

    @Test("short transcript appends remain above the real composer through overflow")
    func shortTranscriptAppendsClearComposer() async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            var snapshot = try SessionScenarioBuilder(seed: 1_213).openingTail(targetEncodedBytes: 10_000)
            snapshot.transcript = [try harnessMessage(id: "short-history")]
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 1
            snapshot.toolExecutions = []
            let initial = snapshot
            try await withHarness(snapshot: initial) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeRows.contains { $0.semanticID == "short-history" }
                }
                #expect(!ready.observation.geometry.hasScrollableOverflow)
                let opening = try #require(ready.nativeRows.first { $0.semanticID == "short-history" })
                #expect(try #require(opening.composerClearance) >= 0)
                var next = initial
                for index in 1...10 {
                    let id = "short-append-\(index)"
                    next.transcript.append(try harnessAssistantMessage(
                        id: id, presentationID: id,
                        text: Array(repeating: "A growing short conversation must stay above the input.", count: 3).joined(separator: " ")
                    ))
                    next.transcriptTotal = next.transcript.count
                    next.eventSequence += 1
                    next.revision += 1
                    let installed = harness.probeObservation.projectionInstallCount
                    harness.replaceAuthoritativeSnapshot(next)
                    _ = try await harness.recorder.waitUntil {
                        $0.observation.projectionInstallCount > installed
                            && $0.nativeRows.contains { $0.semanticID == id }
                    }
                    for _ in 0..<30 { try await harness.driveFrameBoundary() }
                    let sample = try #require(harness.recorder.samples.last)
                    let tail = try #require(sample.nativeRows.first { $0.semanticID == id })
                    let clearance = try #require(tail.composerClearance)
                    #expect(tail.isVisible)
                    #expect(clearance >= -2)
                    #expect(clearance <= 32)
                }
                #expect(harness.probeObservation.geometry.hasScrollableOverflow)
            }
        }
    }

    @Test("idle and streaming openings use the production ChatView settlement path")
    func idleAndStreamingOpeningsSettle() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            try await withHarness(seed: 1_215) { harness in
                let ready = try await harness.recorder.waitUntil { $0.observation.isReady }
                #expect(ready.observation.visibleRowIDs.contains(harness.lastTranscriptID))
            }

            var streaming = try SessionScenarioBuilder(seed: 1_216).openingTail(targetEncodedBytes: 10_000)
            streaming.phase = .running
            streaming.streaming = streaming.transcript.last
            try await withHarness(snapshot: streaming) { harness in
                let ready = try await harness.recorder.waitUntil { $0.observation.isReady }
                #expect(ready.observation.visibleRowIDs.contains(harness.lastTranscriptID))
            }
        }
    }

    @Test("opening readiness follows the installed terminal physical row")
    func openingReadinessFollowsInstalledTerminalRow() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            try await withHarness(seed: 1_217) { harness in
                let ready = try await harness.recorder.waitUntil { $0.observation.isReady }
                let terminalID = harness.lastTranscriptID
                #expect(ready.observation.projectionInstallCount > 0)
                #expect(ready.observation.physicalRowAppearanceCounts[terminalID, default: 0] > 0)
                #expect(ready.observation.visibleRowIDs.contains(terminalID))
                #expect(abs(try harness.nativeTranscriptSignedTailError()) <= 2)

                // The production ChatView/ChatTranscriptScrollView path must
                // expose the terminal row before readiness, not merely expose
                // the eager marker from the empty pre-projection tree.
                let samples = harness.recorder.samples
                let firstReady = try #require(samples.firstIndex { $0.observation.isReady })
                #expect(samples[..<firstReady].contains {
                    $0.observation.physicalRowAppearanceCounts[terminalID, default: 0] > 0
                })
            }
        }
    }

    @Test("mounted terminal reopens after a same-ID epoch replacement")
    func mountedTerminalReopensAfterSameIDEpochReplacement() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            try await withHarness(seed: 1_218) { harness in
                let initial = try await harness.recorder.waitUntil {
                    $0.observation.isReady
                        && $0.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                }
                let baselineReadyCount = initial.observation.readyFrameCompletionCount
                var replacement = harness.snapshot
                replacement.revision += 1
                replacement.eventSequence += 1
                replacement.transcript[0] = try harnessMessage(id: replacement.transcript[0].id)
                harness.replaceAuthoritativeSnapshot(replacement)
                await harness.probe.reopenPresentation()

                let reopened = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount > baselineReadyCount
                        && $0.observation.isReady
                        && $0.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                }
                #expect(reopened.observation.geometry.isPlausibleOpeningViewport)
                #expect(reopened.observation.visibleRowIDs.contains(harness.lastTranscriptID))
            }
        }
    }

    @Test("queued prompt cross-fades into its canonical user row without changing its host or geometry")
    func queuedPromptCanonicalReplacementCrossFades() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            var initial = try SessionScenarioBuilder(seed: 1_263).openingTail(targetEncodedBytes: 10_000)
            initial.phase = .running
            initial.streaming = initial.transcript.last
            initial.queueRevision += 1
            initial.queuedItems = [
                .init(id: "queued-prompt-operation", behavior: .steer, text: "A queued prompt", attachmentCount: 0)
            ]
            var canonicalTemplate = initial
            canonicalTemplate.revision += 1
            canonicalTemplate.eventSequence += 1
            canonicalTemplate.queueRevision += 1
            canonicalTemplate.queuedItems = []
            canonicalTemplate.transcript.append(try decodeTranscriptFixture(
                TranscriptItem.self,
                from: JSONSerialization.data(withJSONObject: [
                    "id": "queued-message-queued-prompt-operation", "parentId": NSNull(),
                    "presentationId": "queued-prompt-operation", "timestamp": "2026-01-01T00:01:00Z",
                    "kind": "message", "role": "user",
                    "content": [["id": "queued-prompt-text", "ordinal": 0, "type": "text", "text": "A queued prompt"]]
                ])
            ))
            canonicalTemplate.transcriptTotal = (canonicalTemplate.transcriptTotal ?? canonicalTemplate.transcript.count - 1) + 1
            try await withHarness(snapshot: initial) { harness in
                let queuedSample = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeRows.contains {
                        $0.physicalID == "queued-message-queued-prompt-operation" && $0.isVisible
                    }
                }
                let queued = try #require(queuedSample.nativeRows.first {
                    $0.physicalID == "queued-message-queued-prompt-operation" && $0.isVisible
                })
                let beforePixels = harness.renderedRowLuminance(in: queued.frame)
                harness.replaceAuthoritativeSnapshot(canonicalTemplate)
                let installed = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains { $0.semanticID == "queued-message-queued-prompt-operation" && $0.isVisible }
                }
                let target = try #require(installed.nativeRows.first {
                    $0.semanticID == "queued-message-queued-prompt-operation" && $0.isVisible
                })
                #expect(target.physicalID == queued.physicalID)
                #expect(target.instance == queued.instance)
                let afterInstall = harness.recorder.samples.last?.frameIndex ?? installed.frameIndex
                for _ in 0..<30 { try await harness.driveFrameBoundary() }
                let frames = harness.recorder.samples.filter { $0.frameIndex >= queuedSample.frameIndex && $0.frameIndex <= afterInstall + 30 }
                let rows = frames.compactMap { sample in
                    sample.nativeRows.first {
                        $0.physicalID == queued.physicalID && $0.instance == queued.instance
                            && $0.isVisible && $0.frame.height > 1
                    }
                }
                let pixelFrames = frames.compactMap { sample -> (PresentedFrameRecorder.NativeRow, [Double])? in
                    guard let row = sample.nativeRows.first(where: {
                        $0.physicalID == queued.physicalID && $0.instance == queued.instance
                            && $0.isVisible && $0.frame.height > 1
                    }) else { return nil }
                    return (row, harness.renderedRowLuminance(in: row.frame))
                }
                #expect(rows.count >= 8)
                let rectSteps = zip(rows, rows.dropFirst()).map {
                    max(abs($1.frame.minY - $0.frame.minY), abs($1.frame.height - $0.frame.height))
                }
                let unavoidableHeightChange = abs(rows.last!.frame.height - queued.frame.height)
                #expect(rectSteps.filter { $0 > 1 }.count <= (unavoidableHeightChange > 1 ? 1 : 0))
                #expect(rectSteps.allSatisfy { $0 <= max(1, unavoidableHeightChange) })
                let geometryChangeIndex = rectSteps.firstIndex(where: { $0 > 1 })
                if let geometryChangeIndex {
                    #expect(rows.dropFirst(geometryChangeIndex + 1).allSatisfy {
                        abs($0.frame.minY - rows.last!.frame.minY) <= 1
                            && abs($0.frame.height - rows.last!.frame.height) <= 1
                    })
                }
                #expect(pixelFrames.count >= 4)
                let endpoint = harness.renderedRowLuminance(in: pixelFrames.last?.0.frame ?? queued.frame)
                let change = zip(beforePixels, endpoint).map { abs($1 - $0) }.reduce(0, +)
                let changedFrameCount = pixelFrames.dropFirst().filter { row, pixels in
                    zip(beforePixels, pixels).map { abs($1 - $0) }.reduce(0, +) > 0.02 * max(1, change)
                }.count
                #expect(changedFrameCount >= 3)
                print("Queued→canonical frame evidence: queuedHeight=\(queued.frame.height), canonicalHeight=\(rows.last!.frame.height), maxRectStep=\(rectSteps.max() ?? 0), changedFrames=\(changedFrameCount), tailDistance=\(try harness.nativeTranscriptDistanceFromTail())")
            }
        }
    }

    @Test("short streaming response remains above composer as it outgrows the viewport")
    func shortStreamingResponseClearsComposer() async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            var snapshot = try SessionScenarioBuilder(seed: 1_214).openingTail(targetEncodedBytes: 10_000)
            snapshot.transcript = [try harnessMessage(id: "short-history")]
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 1
            snapshot.toolExecutions = []
            let initial = snapshot
            try await withHarness(snapshot: initial) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady }
                var next = initial
                next.phase = .running
                var crossedInsetBand = false
                for count in [1, 3, 6, 7, 8, 9, 10, 11, 12, 14, 20] {
                    next.streaming = try harnessAssistantMessage(
                        id: "growing-response", presentationID: "growing-response",
                        text: Array(repeating: "Streaming content must remain above the composer while a short session grows.", count: count).joined(separator: " ")
                    )
                    next.revision += 1
                    next.eventSequence += 1
                    let installed = harness.probeObservation.projectionInstallCount
                    harness.replaceAuthoritativeSnapshot(next)
                    _ = try await harness.recorder.waitUntil { $0.observation.projectionInstallCount > installed }
                    for _ in 0..<30 { try await harness.driveFrameBoundary() }
                    let sample = try #require(harness.recorder.samples.last)
                    let geometry = sample.observation.geometry
                    crossedInsetBand = crossedInsetBand || (geometry.hasScrollableOverflow
                        && geometry.contentHeight < geometry.containerHeight)
                    let tail = try #require(sample.nativeRows.first { $0.semanticID == "growing-response" })
                    let clearance = try #require(tail.composerClearance)
                    #expect(tail.isVisible)
                    #expect(clearance >= -2)
                    #expect(clearance <= 32)
                }
                #expect(harness.probeObservation.geometry.hasScrollableOverflow)
                #expect(crossedInsetBand)
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

    @Test("ordinary send keeps one stable tail through target release")
    func ordinarySendKeepsStableTail() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            var snapshot = try SessionScenarioBuilder(seed: 1_211)
                .openingTail(targetEncodedBytes: 10_000)
            snapshot.acceptsQueuedPrompts = false
            try await withHarness(snapshot: snapshot, enablesComposerSubmission: true) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady
                        && $0.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                        && abs(($0.observation.rowFrames["transcript-bottom"]?.height ?? 0)
                            - ChatTranscriptLayoutConstants.tailAffordanceHeight) <= 0.5
                }
                let previousTail = try #require(ready.nativeRows.first {
                    $0.semanticID == harness.lastTranscriptID && $0.isVisible
                })
                let commandBaseline = ready.observation.tailMaterializationCommandCount
                let releaseBaseline = ready.observation.targetReleaseCount
                let repairBaseline = ready.observation.physicalTailRepairCommandCount
                let composerHeight = ready.observation.composerHeight
                let outgoingPrefix = "outgoing-submission:\(snapshot.sessionId):"

                try harness.setComposerDraftText(
                    "Keep the resumed transcript physically stable."
                )
                harness.submitPrompt()
                let stabilized = try await harness.recorder.waitUntil { sample in
                    let observation = sample.observation
                    return observation.tailMaterializationCommandCount == commandBaseline + 1
                        && observation.targetReleaseCount == releaseBaseline
                        && sample.nativeRows.contains {
                            $0.physicalID.hasPrefix(outgoingPrefix) && $0.isVisible
                                && abs($0.tailGap - ChatTranscriptLayoutConstants.tailAffordanceHeight) <= 2
                        }
                }
                #expect(try harness.isAttachmentButtonEnabled())
                let outgoing = try #require(stabilized.nativeRows.first {
                    $0.physicalID.hasPrefix(outgoingPrefix) && $0.isVisible
                })
                let outgoingID = outgoing.physicalID
                _ = try await harness.recorder.waitUntil {
                    $0.observation.targetReleaseCount == releaseBaseline + 1
                        && $0.nativeRows.contains {
                            $0.physicalID == outgoingID && $0.isVisible
                                && abs($0.tailGap - ChatTranscriptLayoutConstants.tailAffordanceHeight) <= 2
                        }
                }

                // Consuming the release command precedes its native layout.
                // Observe that layout too, rather than ending on whichever
                // side of the display callback recorded the release counter.
                try await harness.driveFrameBoundary()
                try await harness.driveFrameBoundary()
                let settled = try #require(harness.recorder.samples.last)
                let physicalPixel = 1 / max(1, harness.screenScale)
                let sendSamples = harness.recorder.samples.filter {
                    $0.frameIndex >= ready.frameIndex && $0.frameIndex <= settled.frameIndex
                }
                // Lazy contentSize/contentOffset can rebase together without
                // moving visible content. Measure the mounted prior row instead.
                let sendOffsets = sendSamples.compactMap { sample in
                    sample.nativeRows.first {
                        $0.physicalID == previousTail.physicalID && $0.isVisible
                    }?.frame.maxY
                }
                let sendDeltas = zip(sendOffsets, sendOffsets.dropFirst())
                    .map { $1 - $0 }
                    .filter { abs($0) > physicalPixel }
                let sendReversedDirection = sendDeltas.contains(where: { $0 > 0 })
                    && sendDeltas.contains(where: { $0 < 0 })
                #expect(!sendReversedDirection,
                    "Mounted prior-tail positions: \(sendOffsets); admitted deltas: \(sendDeltas)")
                let samples = sendSamples.filter { $0.frameIndex >= stabilized.frameIndex }
                let offsets = samples.compactMap { sample in
                    sample.nativeRows.first { $0.physicalID == outgoingID && $0.isVisible }?.frame.maxY
                }
                let deltas = zip(offsets, offsets.dropFirst()).map { $1 - $0 }
                    .filter { abs($0) > physicalPixel }
                let reversedDirection = deltas.contains(where: { $0 > 0 })
                    && deltas.contains(where: { $0 < 0 })
                #expect(!reversedDirection)
                #expect(samples.allSatisfy { sample in
                    sample.nativeRows.contains {
                        $0.physicalID == outgoingID && $0.instance == outgoing.instance && $0.isVisible
                            && abs($0.tailGap - ChatTranscriptLayoutConstants.tailAffordanceHeight) <= 2
                    }
                })
                #expect(settled.observation.targetReleaseCount == releaseBaseline + 1)
                #expect(settled.observation.tailMaterializationCommandCount == commandBaseline + 1)
                #expect(settled.observation.physicalTailRepairCommandCount == repairBaseline)
                #expect(abs(settled.observation.composerHeight - composerHeight) <= 1)
                #expect(settled.observation.physicalRowAppearanceCounts[outgoingID] == 1)
                #expect(settled.observation.physicalRowDisappearanceCounts[outgoingID, default: 0] == 0)
            }
        }
    }

    @Test("resumed multiline send settles from native row geometry during keyboard resize")
    func resumedMultilineSendSettlesDuringKeyboardResize() async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            var snapshot = try SessionScenarioBuilder(seed: 1_213)
                .openingTail(targetEncodedBytes: 10_000)
            snapshot.acceptsQueuedPrompts = false
            snapshot.transcript = try (0..<96).map { index in
                try harnessRichAssistantMessage(
                    id: "resumed-\(index)", presentationID: "resumed-turn-\(index)",
                    thinkingLines: index.isMultiple(of: 4) ? ["Bounded resumed history."] : [],
                    text: Array(repeating: "Variable-height resumed history must remain mounted while a prompt is sent.", count: 1 + index % 5).joined(separator: "\n\n")
                )
            }
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = snapshot.transcript.count
            let initial = snapshot
            try await withHarness(snapshot: initial, enablesComposerSubmission: true) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeRows.contains {
                        $0.semanticID == "resumed-turn-95" && $0.isVisible
                    }
                }
                let releaseBaseline = ready.observation.targetReleaseCount
                try harness.setComposerDraftText(String(repeating: "multiline resumed prompt ", count: 28))
                harness.submitPrompt()
                // Exercise both sides of the keyboard-sized viewport change
                // while the lazy history and outgoing row are settling.
                harness.resize(height: 620)
                harness.resize(height: 844)
                let sent = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains {
                        $0.physicalID.hasPrefix("outgoing-submission:") && $0.isVisible
                    }
                }
                let outgoing = try #require(sent.nativeRows.first {
                    $0.physicalID.hasPrefix("outgoing-submission:") && $0.isVisible
                })

                var acknowledged = initial
                let promptText = String(repeating: "multiline resumed prompt ", count: 28)
                acknowledged.transcript.append(try decodeTranscriptFixture(
                    TranscriptItem.self,
                    from: JSONSerialization.data(withJSONObject: [
                        "id": "resumed-canonical-prompt", "parentId": NSNull(),
                        "presentationId": "hosted-prompt-operation",
                        "timestamp": "2026-01-01T00:01:00Z", "kind": "message", "role": "user",
                        "content": [["id": "resumed-canonical-text", "ordinal": 0, "type": "text", "text": promptText]]
                    ])
                ))
                acknowledged.transcriptTotal = acknowledged.transcript.count
                harness.replaceAuthoritativeSnapshot(acknowledged)
                let ack = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains { $0.semanticID == "resumed-canonical-prompt" && $0.isVisible }
                }
                let canonical = try #require(ack.nativeRows.first {
                    $0.semanticID == "resumed-canonical-prompt"
                })
                #expect(canonical.physicalID == outgoing.physicalID)
                #expect(canonical.instance == outgoing.instance)

                var response = acknowledged
                response.transcript.append(try harnessAssistantMessage(
                    id: "resumed-first-successor", presentationID: "resumed-first-successor",
                    text: "The resumed successor is visible."
                ))
                response.transcriptTotal = response.transcript.count
                harness.replaceAuthoritativeSnapshot(response)
                let successor = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains { $0.semanticID == "resumed-first-successor" && $0.isVisible }
                }
                for _ in 0..<80 { try await harness.driveFrameBoundary() }
                let settled = try #require(harness.recorder.samples.last)
                #expect(settled.observation.targetReleaseCount >= releaseBaseline + 1)
                #expect(successor.nativeRows.contains {
                    $0.physicalID == outgoing.physicalID && $0.instance == outgoing.instance && $0.isVisible
                })
                let transitionSamples = harness.recorder.samples.filter {
                    $0.frameIndex >= sent.frameIndex && $0.frameIndex <= settled.frameIndex
                }
                #expect(!transitionSamples.isEmpty)
                #expect(transitionSamples.allSatisfy { sample in
                    sample.nativeRows.contains {
                        $0.physicalID == outgoing.physicalID && $0.instance == outgoing.instance && $0.isVisible
                    }
                })
                #expect(!harness.traceRecords.contains { $0.record.event == "chat.layout.abandoned" })
                #expect(!harness.traceRecords.contains {
                    $0.record.event == "chat.lease.release-requested"
                        && $0.record.message.contains("reason=bounded-fallback")
                })
            }
        }
    }

    enum SendHistory: CaseIterable, Sendable { case short, shortToOverflow, long }

    @Test("short and long history preserve the mounted prompt through acknowledgement and successor", arguments: SendHistory.allCases, [false, true])
    func resumedSendAcknowledgementSuccessor(history: SendHistory, acknowledgeDuringLease: Bool) async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            let historyCount = history == .long ? 160 : 1
            var snapshot = try SessionScenarioBuilder(seed: 1_212)
                .openingTail(targetEncodedBytes: 10_000)
            snapshot.acceptsQueuedPrompts = false
            snapshot.transcript = try (0..<historyCount).map { index in
                try harnessRichAssistantMessage(
                    id: "mixed-\(index)", presentationID: "mixed-turn-\(index)",
                    thinkingLines: index.isMultiple(of: 5) ? ["Bounded thinking fixture."] : [],
                    text: Array(repeating: "Paragraph \(index) with mixed-height history that wraps across the native transcript.",
                                count: 1 + index % 7).joined(separator: "\n\n")
                )
            }
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = snapshot.transcript.count
            let initial = snapshot
            try await withHarness(snapshot: initial, enablesComposerSubmission: true) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeRows.contains {
                        $0.semanticID == "mixed-turn-\(historyCount - 1)" && $0.isVisible
                    }
                }
                let isShort = history != .long
                #expect(ready.observation.geometry.hasScrollableOverflow == !isShort)
                let commandBaseline = ready.observation.tailMaterializationCommandCount
                let releaseBaseline = ready.observation.targetReleaseCount
                let maximumSendCommands = history == .shortToOverflow ? 2 : 1
                let text = history == .shortToOverflow
                    ? String(repeating: "A large outgoing prompt must cross the viewport without a forced offset. ", count: 40)
                    : "Keep this resumed conversation stable."
                try harness.setComposerDraftText(text)
                harness.submitPrompt()
                let sent = try await harness.recorder.waitUntil {
                    (acknowledgeDuringLease
                        ? $0.observation.targetReleaseCount == releaseBaseline
                        : $0.observation.targetReleaseCount > releaseBaseline)
                        && (1...maximumSendCommands).contains($0.observation.tailMaterializationCommandCount - commandBaseline)
                        && $0.nativeRows.contains {
                            $0.physicalID.hasPrefix("outgoing-submission:") && $0.isVisible
                                && (!acknowledgeDuringLease
                                    || abs($0.tailGap - ChatTranscriptLayoutConstants.tailAffordanceHeight) <= 2)
                        }
                }
                let outgoing = try #require(sent.nativeRows.first {
                    $0.physicalID.hasPrefix("outgoing-submission:") && $0.isVisible
                })
                // Fail with the measured native gap rather than waiting for
                // an exact subpixel geometry value that may never republish.
                if !acknowledgeDuringLease {
                    #expect(abs(outgoing.tailGap - ChatTranscriptLayoutConstants.tailAffordanceHeight) <= 2)
                }
                #expect(harness.probeObservation.geometry.hasScrollableOverflow == (history != .short))
                var acknowledged = initial
                acknowledged.transcript.append(try decodeTranscriptFixture(
                    TranscriptItem.self,
                    from: JSONSerialization.data(withJSONObject: [
                        "id": "canonical-prompt", "parentId": NSNull(),
                        "presentationId": "hosted-prompt-operation",
                        "timestamp": "2026-01-01T00:01:00Z", "kind": "message", "role": "user",
                        "content": [["id": "canonical-text", "ordinal": 0, "type": "text", "text": text]]
                    ])
                ))
                acknowledged.transcriptTotal = acknowledged.transcript.count
                harness.replaceAuthoritativeSnapshot(acknowledged)
                let ack = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains { $0.semanticID == "canonical-prompt" && $0.isVisible }
                }
                let canonical = try #require(ack.nativeRows.first { $0.semanticID == "canonical-prompt" })
                #expect(canonical.physicalID == outgoing.physicalID)
                #expect(canonical.instance == outgoing.instance)
                #expect(abs(canonical.frame.maxY - outgoing.frame.maxY) <= 2)
                let lifecycleHeight = outgoing.frame.height
                let lifecycleOrigin = outgoing.frame.minY
                let transitionEnd = ack.frameIndex + 16
                for _ in 0..<16 { try await harness.driveFrameBoundary() }
                let transitionSamples = harness.recorder.samples.filter {
                    $0.frameIndex >= sent.frameIndex && $0.frameIndex <= transitionEnd
                }
                let transitionRows = transitionSamples.compactMap { sample in
                    sample.nativeRows.first {
                        $0.physicalID == outgoing.physicalID && $0.instance == outgoing.instance
                    }
                }
                #expect(transitionRows.count >= 8)
                #expect(transitionRows.allSatisfy { abs($0.frame.height - lifecycleHeight) <= 1 })
                #expect(transitionRows.allSatisfy { abs($0.frame.minY - lifecycleOrigin) <= 1 })
                let frameSteps = zip(transitionRows, transitionRows.dropFirst()).map { old, new in
                    max(abs(new.frame.minY - old.frame.minY), abs(new.frame.height - old.frame.height))
                }
                #expect(frameSteps.allSatisfy { $0 <= 1 })
                print("Lifecycle→canonical frame evidence: lifecycleHeight=\(lifecycleHeight), canonicalHeight=\(canonical.frame.height), maxRectStep=\(frameSteps.max() ?? 0), tailError=\(try harness.nativeTranscriptSignedTailError())")
                #expect(try harness.nativeTranscriptDistanceFromTail() <= 2)

                var response = acknowledged
                response.transcript.append(try harnessAssistantMessage(
                    id: "first-successor", presentationID: "first-successor", text: "The first response is now visible."
                ))
                response.transcriptTotal = response.transcript.count
                harness.replaceAuthoritativeSnapshot(response)
                _ = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains { $0.semanticID == "first-successor" && $0.isVisible }
                }
                // Observe actual display boundaries beyond the old one-second
                // fallback. No production delay or synthetic offset is injected.
                for _ in 0..<80 { try await harness.driveFrameBoundary() }
                let settled = try #require(harness.recorder.samples.last)
                let prompt = try #require(settled.nativeRows.first { $0.semanticID == "canonical-prompt" })
                #expect(prompt.isVisible)
                #expect(prompt.instance == outgoing.instance)
                #expect(settled.nativeRows.filter { $0.physicalID == outgoing.physicalID }.count == 1)
                // The successor may already be realized before admission; it
                // is entitled to at most one materialization, acknowledgement none.
                #expect(ack.observation.tailMaterializationCommandCount == sent.observation.tailMaterializationCommandCount)
                #expect(settled.observation.tailMaterializationCommandCount <= commandBaseline + maximumSendCommands + 1)
                let frames = harness.recorder.samples.filter { $0.frameIndex >= ack.frameIndex }
                #expect(frames.allSatisfy { sample in
                    sample.nativeRows.contains {
                        $0.physicalID == outgoing.physicalID && $0.instance == outgoing.instance && $0.isVisible
                    }
                })
                #expect(abs(try harness.nativeTranscriptSignedTailError()) <= 2)
                let successor = try #require(settled.nativeRows.first { $0.semanticID == "first-successor" })
                #expect(try #require(successor.composerClearance) >= -2)
                #expect(!harness.traceRecords.contains { $0.record.event == "chat.lease.bounded-fallback" })
            }
        }
    }

    @Test("a real managed sheet freezes covered chat and uncovers to the latest native frame")
    func managedSheetFreezesCoveredChat() async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_229).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, enablesPresentationCover: true) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady && $0.nativeGeometryMatches }
                let authorityOpensBeforeCover = harness.traceRecords.filter {
                    $0.record.event == "chat.opening.authority-opened"
                }.count
                harness.setCovered(true)
                try await harness.waitForCoverTransition(presented: true)
                #expect(harness.chatSurfaceActivity == .presentingDescendant)
                let baseline = harness.probeObservation
                for index in 1...3 {
                    var current = snapshot
                    current.phase = .running
                    current.revision += index
                    current.eventSequence += index
                    current.streaming = try harnessMessage(id: "covered-latest-\(index)")
                    harness.replaceAuthoritativeSnapshot(current)
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                }
                // The recorder intentionally omits unchanged frames. Wait for
                // actual display boundaries, not nonexistent changed samples.
                for _ in 0..<3 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                let frozen = harness.probeObservation
                #expect(frozen.projectionInstallCount == baseline.projectionInstallCount)
                #expect(frozen.projectionWorkAdmissionCount == baseline.projectionWorkAdmissionCount)
                #expect(frozen.semanticFrameCallbackCount == baseline.semanticFrameCallbackCount)
                harness.setCovered(false)
                try await harness.waitForCoverTransition(presented: false)
                let returned = try await harness.recorder.waitUntil {
                    $0.observation.isReady
                        && $0.observation.projectionInstallCount > frozen.projectionInstallCount
                        && $0.observation.targetReleaseCount > frozen.targetReleaseCount
                        && $0.nativeRows.contains { $0.semanticID == "covered-latest-3" && $0.isVisible }
                        && $0.nativeGeometryMatches
                }
                #expect(returned.observation.projectionInstallCount == frozen.projectionInstallCount + 1)
                #expect(abs(try harness.nativeTranscriptSignedTailError()) <= 2)
                #expect(harness.traceRecords.filter {
                    $0.record.event == "chat.opening.authority-opened"
                }.count == authorityOpensBeforeCover)
            }
        }
    }

    @Test("covered or inactive chat defers composer catalog work and resumes with the latest canonical commands", arguments: [true, false], [true, false])
    func coveredChatDefersComposerCatalog(managedSheet: Bool, changesCommands: Bool) async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_245).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(
                snapshot: snapshot, enablesComposerSubmission: true, enablesPresentationCover: true
            ) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady && $0.nativeGeometryMatches }
                try await harness.loadCanonicalCommands(["initial"])
                _ = try await harness.recorder.waitUntil { _ in
                    harness.probe.composerCatalogCommandNames == ["initial"]
                }
                if managedSheet {
                    harness.setCovered(true)
                    try await harness.waitForCoverTransition(presented: true)
                } else {
                    harness.setScenePhase(.inactive)
                    for _ in 0..<3 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                }
                #expect(harness.chatSurfaceActivity == (managedSheet ? .presentingDescendant : .active))
                let buildsBefore = harness.probe.composerCatalogBuildCount
                #expect(buildsBefore > 0)
                if changesCommands {
                    for index in 1...3 {
                        try await harness.loadCanonicalCommands(["latest-\(index)"])
                        try await DisplayFrameScheduler.displayLink.nextFrame()
                    }
                }
                let latest = changesCommands ? ["latest-3"] : ["initial"]
                for _ in 0..<3 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                // Canonical intake continues, but this hidden composer's derived
                // catalog and its worker stay frozen until the managed uncover.
                #expect(harness.canonicalCommandNames == latest)
                #expect(harness.probe.composerCatalogBuildCount == buildsBefore)
                #expect(harness.probe.composerCatalogCommandNames == ["initial"])
                if managedSheet {
                    harness.setCovered(false)
                    try await harness.waitForCoverTransition(presented: false)
                } else {
                    harness.setScenePhase(.active)
                }
                _ = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeGeometryMatches
                        && harness.probe.composerCatalogBuildCount >= buildsBefore + 1
                        && harness.probe.composerCatalogCommandNames == latest
                }
                #expect(harness.probe.composerCatalogBuildCount == buildsBefore + 1)
                #expect(abs(try harness.nativeTranscriptSignedTailError()) <= 2)
            }
        }
    }

    @Test("a composer catalog completion retired by a managed sheet cannot publish")
    func retiredComposerCatalogDoesNotPublish() async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_246).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(
                snapshot: snapshot, enablesComposerSubmission: true, enablesPresentationCover: true
            ) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady && $0.nativeGeometryMatches }
                try await harness.loadCanonicalCommands(["initial"], skills: ["skill:retain"])
                _ = try await harness.recorder.waitUntil { _ in
                    harness.probe.composerCatalogCommandNames == ["initial"]
                }
                try harness.selectCanonicalSkill(named: "skill:retain")
                let selectedBefore = try #require(harness.selectedComposerResource)
                try harness.setComposerText("retain this draft")
                let draftBefore = try harness.composerTextAndSelection()
                let gate = TestReadGate()
                let finished = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let completion = Task { @MainActor in
                    var iterator = finished.stream.makeAsyncIterator()
                    return await iterator.next()
                }
                var held = false
                harness.probe.composerCatalogWillInstall = { catalog in
                    guard catalog.commands.map(\.invocationName) == ["retired"] else { return }
                    held = true
                    await gate.wait()
                }
                harness.probe.composerCatalogDidFinish = { commands in
                    if commands.map(\.name) == ["retired"] { finished.continuation.yield(()) }
                }
                defer {
                    harness.probe.composerCatalogWillInstall = nil
                    harness.probe.composerCatalogDidFinish = nil
                    finished.continuation.finish()
                    completion.cancel()
                }
                do {
                    try await harness.loadCanonicalCommands(["retired"])
                    try await gate.waitForEntry()
                    let installedBeforeCover = harness.probe.composerCatalogCommandNames
                    harness.setCovered(true)
                    try await harness.waitForCoverTransition(presented: true)
                    try await harness.loadCanonicalCommands(["current"])
                    await gate.release()
                    #expect(await completion.value != nil)
                    #expect(harness.chatSurfaceActivity == .presentingDescendant)
                    #expect(harness.probe.composerCatalogCommandNames == installedBeforeCover)
                    #expect(harness.selectedComposerResource == selectedBefore)
                    #expect(harness.canonicalCommandNames == ["current"])
                    harness.setCovered(false)
                    try await harness.waitForCoverTransition(presented: false)
                    _ = try await harness.recorder.waitUntil {
                        $0.observation.isReady && $0.nativeGeometryMatches
                            && harness.probe.composerCatalogCommandNames == ["current"]
                    }
                    #expect(harness.selectedComposerResource == nil)
                    let draftAfter = try harness.composerTextAndSelection()
                    #expect(draftAfter.text == draftBefore.text)
                    #expect(draftAfter.selection == draftBefore.selection)
                    #expect(draftAfter.identity == draftBefore.identity)
                    #expect(abs(try harness.nativeTranscriptSignedTailError()) <= 2)
                } catch {
                    await gate.release()
                    if held { _ = await completion.value }
                    throw error
                }
            }
        }
    }

    @Test("picker consumers reject old entries before replacement derivation installs")
    func pickerRejectsRetiredCatalog() async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_249).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, enablesComposerSubmission: true, enablesPresentationCover: true) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady && $0.nativeGeometryMatches }
                try await harness.loadCanonicalCommands(["original"])
                try harness.setComposerText("/")
                _ = try await harness.recorder.waitUntil { _ in
                    harness.probe.composerPickerEntries?().map(\.invocationName) == ["original"]
                }
                let old = try #require(harness.probe.composerPickerEntries?().first)
                let draft = try harness.composerTextAndSelection()
                let gate = TestReadGate()
                let finished = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let completion = Task { @MainActor in
                    var iterator = finished.stream.makeAsyncIterator()
                    return await iterator.next()
                }
                var held = false
                harness.probe.composerCatalogWillInstall = { catalog in
                    if catalog.commands.map(\.invocationName) == ["replacement"] { held = true }
                    await gate.wait()
                }
                harness.probe.composerCatalogDidFinish = { commands in
                    if commands.map(\.name) == ["replacement"] { finished.continuation.yield(()) }
                }
                defer {
                    harness.probe.composerCatalogWillInstall = nil
                    harness.probe.composerCatalogDidFinish = nil
                    finished.continuation.finish()
                    completion.cancel()
                }
                do {
                    try await harness.loadCanonicalCommands(["replacement"], beforeResponse: {
                        #expect(harness.probe.composerPickerEntries?().isEmpty == true)
                        harness.probe.composerResourceSelection?(old)
                        try #require(harness.selectedComposerResource == nil)
                        let currentDraft = try harness.composerTextAndSelection()
                        #expect(currentDraft.text == draft.text)
                    })
                    try await gate.waitForEntry()
                    #expect(harness.probe.composerPickerEntries?().isEmpty == true)
                    harness.probe.composerResourceSelection?(old)
                    try #require(harness.selectedComposerResource == nil)
                    #expect(try harness.composerTextAndSelection().text == draft.text)
                    await gate.release()
                    #expect(await completion.value != nil)
                    _ = try await harness.recorder.waitUntil { _ in
                        harness.probe.composerPickerEntries?().map(\.invocationName) == ["replacement"]
                    }
                    let current = try #require(harness.probe.composerPickerEntries?().first)
                    harness.probe.composerResourceSelection?(current)
                    #expect(harness.selectedComposerResource == current.commandInfo)
                    #expect(try harness.composerTextAndSelection().identity == draft.identity)
                } catch {
                    await gate.release()
                    if held { _ = await completion.value }
                    throw error
                }
            }
        }
    }

    @Test("mention and slash pickers preserve source selection across catalog refresh", arguments: [true, false])
    func resourcePickerSourceSelection(mention: Bool) async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_249).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, enablesComposerSubmission: true, enablesPresentationCover: true) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady && $0.nativeGeometryMatches }
                try await harness.loadCanonicalCommands(["review"], skills: ["skill:review"], prompts: ["review"])
                try harness.setComposerText(mention ? "@rev" : "/rev")
                let expected = mention ? ["skill:skill:review"] : ["extension:review", "prompt:review"]
                _ = try await harness.recorder.waitUntil { _ in
                    harness.probe.composerPickerEntries?().map(\.id) == expected
                }
                // Re-derive while the same trigger remains active. A refresh must
                // not drop prompts or reinterpret @ as a slash command search.
                try await harness.loadCanonicalCommands(["review", "other"], skills: ["skill:review"], prompts: ["review"])
                _ = try await harness.recorder.waitUntil { _ in
                    harness.probe.composerPickerEntries?().map(\.id) == expected
                }
                let selected = try #require(harness.probe.composerPickerEntries?().last)
                let original = try harness.composerTextAndSelection()
                harness.probe.composerResourceSelection?(selected)
                #expect(harness.selectedComposerResource == selected.commandInfo)
                #expect(harness.selectedComposerResource?.source == (mention ? .skill : .prompt))
                _ = try await harness.recorder.waitUntil { _ in
                    (try? harness.composerTextAndSelection().text.isEmpty) == true
                }
                let updated = try harness.composerTextAndSelection()
                #expect(updated.text.isEmpty)
                #expect(updated.identity == original.identity)
            }
        }
    }

    @Test("hosted retirement releases composer control captures")
    func retiredProbeReleasesComposerControls() {
        let probe = ChatHostedProbe()
        var owner: NSObject? = NSObject()
        weak var retained = owner
        probe.composerResourceSelection = { [owner] _ in _ = owner?.description }
        owner = nil
        #expect(retained != nil)
        probe.retirePresentation()
        #expect(retained == nil)
        #expect(probe.composerResourceSelection == nil)
    }

    @Test("production opening releases native controls on its ready frame")
    func openingReadyFrameReleasesNativeControls() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_231).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(
                snapshot: snapshot,
                enablesComposerSubmission: true,
                enablesPresentationCover: true
            ) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.isReady
                        && $0.observation.readyFrameCompletionCount >= 1
                        && $0.nativeGeometryMatches
                }
                #expect(try harness.isAttachmentButtonEnabled())
                #expect(try harness.isNativeTranscriptInteractionEnabled())
                #expect(abs(try harness.nativeTranscriptSignedTailError()) <= 2)
            }
        }
    }

    @Test("hosted opening render stays opaque before one monotonic transcript reveal")
    func hostedOpeningRevealIsMonotonic() async throws {
        try await withTestWatchdog(timeout: .seconds(25)) { @MainActor in
            let gate = OpeningFrameGate()
            defer { gate.release() }
            let snapshot = try SessionScenarioBuilder(seed: 1_250).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, displayFrameScheduler: gate.scheduler,
                                  enablesPresentationCover: true, usesRealOpening: true) { harness in
                gate.condition = { harness.probe.openingPhase?() == .presenting }
                try await gate.waitUntilHeld()
                let covered = harness.renderedPixelGrid()
                try await DisplayFrameScheduler.displayLink.nextFrame()
                let coveredNextFrame = harness.renderedPixelGrid()
                #expect(harness.renderedPixelDistance(covered, coveredNextFrame) < 0.02)

                gate.release()
                var renderedFrames: [[Double]] = []
                for _ in 0..<18 {
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                    renderedFrames.append(harness.renderedPixelGrid())
                }
                #expect(harness.probe.openingPhase?() == .ready)
                let finalFrame = renderedFrames.last ?? harness.renderedPixelGrid()
                let distances = renderedFrames.map {
                    harness.renderedPixelProgress($0, from: covered, to: finalFrame)
                }
                #expect(distances.count >= 3)
                #expect(zip(distances, distances.dropFirst()).allSatisfy { $1 + 0.035 >= $0 })
                #expect((distances.last ?? 0) > 0.9)
                #expect(harness.renderedPixelDistance(covered, finalFrame) > 0.08)
            }
        }
    }

    // Regression: while the opening cover was up, transcript rows positioned
    // under the navigation bar showed through it for a frame, because the
    // cover was sized to the scroll view's safe frame.
    @Test("the opening cover hides the transcript under the navigation bar")
    func openingCoverHidesNavigationBand() async throws {
        try await withTestWatchdog(timeout: .seconds(25)) { @MainActor in
            let snapshot = try SessionScenarioBuilder(seed: 1_252).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, enablesPresentationCover: true, usesRealOpening: true) { harness in
                var bands: [[Double]] = []
                var sawRevealing = false
                for _ in 0..<240 {
                    guard let phase = harness.probe.openingPhase?() else {
                        try await DisplayFrameScheduler.displayLink.nextFrame()
                        continue
                    }
                    if phase == .presented || phase == .ready { break }
                    // `.revealing` is when positioned rows first exist beneath the
                    // cover, so the check is vacuous unless it was sampled.
                    sawRevealing = sawRevealing || phase == .revealing
                    bands.append(harness.renderedNavigationBandGrid())
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                }
                #expect(sawRevealing)
                let reference = try #require(bands.first)
                // Glyph pixels differ sharply from the backdrop; material
                // noise in the bar does not. Count only glyph-sized changes.
                let changed = bands.map { band in
                    zip(reference, band).filter { abs($0 - $1) > 48 }.count
                }
                #expect(changed.max() == 0, "transcript showed under the navigation bar while covered: \(changed)")
            }
        }
    }

    @Test("final opening frame cannot publish behind a managed cover")
    func coveredFinalOpeningFrame() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) { @MainActor in
            let gate = OpeningFrameGate()
            defer { gate.release() }
            let snapshot = try SessionScenarioBuilder(seed: 1_251).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, displayFrameScheduler: gate.scheduler,
                                  enablesComposerSubmission: true, enablesPresentationCover: true, usesRealOpening: true) { harness in
                gate.condition = { [.presented, .ready].contains(harness.probe.openingPhase?() ?? .opening) }
                try await gate.waitUntilHeld()
                #expect(harness.probe.readyPublicationCount == 0)
                let target = harness.currentTarget
                harness.setCovered(true)
                try await harness.waitForCoverTransition(presented: true)
                gate.release()
                try await harness.waitForOpeningAttemptCompletion(1)
                #expect(harness.probe.readyPublicationCount == 0)
                #expect(harness.probe.extensionPublicationAllowed?() == false)
                #expect(harness.currentTarget == target)
                #expect(!harness.rpcMethods.contains("session.close"))
                harness.setCovered(false)
                try await harness.waitForCoverTransition(presented: false)
                _ = try await harness.recorder.waitUntil { _ in harness.probe.readyPublicationCount == 1 }
                #expect(harness.currentTarget == target)
                #expect(harness.rpcMethods.filter { $0 == "session.open" }.count == 1)
            }
        }
    }

    enum OpeningDeadlineOwner: CaseIterable { case current, replacedRuntime, coveredAfterFailure }

    @Test("real opening deadline failures publish only for their current live owner", arguments: OpeningDeadlineOwner.allCases)
    func openingDeadlineRevalidatesOwner(owner: OpeningDeadlineOwner) async throws {
        try await withTestWatchdog(timeout: .seconds(15)) { @MainActor in
            let frames = OpeningFrameGate()
            let returned = OpeningSettlementReturnGate()
            defer { frames.release(); returned.release() }
            let snapshot = try SessionScenarioBuilder(seed: 1_254).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, displayFrameScheduler: frames.scheduler,
                                  enablesComposerSubmission: true, enablesPresentationCover: true, usesRealOpening: true) { harness in
                frames.condition = { harness.probe.openingPhase?() == .revealing }
                harness.probe.openingSettlementReturned = { await returned.hold($0) }
                try await frames.waitUntilHeld()
                let target = try #require(harness.currentTarget)
                var next = snapshot
                if owner == .replacedRuntime {
                    next.runtimeGeneration += "-replacement"
                    next.revision += 1
                    next.eventSequence += 1
                    harness.replaceAuthoritativeSnapshot(next)
                    #expect(harness.currentTarget == target)
                }
                // The production two-second post-reveal deadline runs while
                // its real display-frame dependency is held, producing failure.
                try await returned.waitUntilHeld()
                guard case .failed(let reasons) = returned.result else {
                    Issue.record("Expected the actual post-reveal deadline failure")
                    return
                }
                #expect(reasons.contains(.frameStability))
                if owner == .coveredAfterFailure {
                    harness.setCovered(true)
                    try await harness.waitForCoverTransition(presented: true)
                }
                harness.probe.openingSettlementReturned = nil
                returned.release() // Ignores cancellation: failure was already produced.
                frames.release()
                try await harness.waitForOpeningAttemptCompletion(1)
                let failures = harness.traceRecords.filter { $0.record.event == "chat.opening.failed" }
                if owner == .current {
                    #expect(failures.count == 1)
                    #expect(ChatOpeningAttemptPolicy.isFailed(harness.probe.openingPhase?() ?? .opening))
                    #expect(harness.currentTarget == nil)
                    #expect(harness.probe.readyPublicationCount == 0)
                    #expect(harness.rpcMethods.filter { $0 == "session.close" }.count == 1)
                    return
                }
                #expect(failures.isEmpty)
                #expect(!ChatOpeningAttemptPolicy.isFailed(harness.probe.openingPhase?() ?? .opening))
                #expect(harness.currentTarget == target)
                #expect(!harness.rpcMethods.contains("session.close"))
                if owner == .coveredAfterFailure {
                    #expect(harness.probe.readyPublicationCount == 0)
                    #expect(harness.probe.extensionPublicationAllowed?() == false)
                    harness.setCovered(false)
                    try await harness.waitForCoverTransition(presented: false)
                }
                _ = try await harness.recorder.waitUntil { _ in harness.probe.readyPublicationCount == 1 }
                #expect(harness.probe.installedRuntime?() == next.runtimeGeneration)
                #expect(harness.currentTarget == target)
                #expect(harness.rpcMethods.filter { $0 == "session.open" }.count == 1)
                #expect(!harness.rpcMethods.contains("session.close"))
            }
        }
    }

    @Test("same-target runtime replacement invalidates every unfinished opening cut", arguments: [false, true])
    func runtimeReplacementDuringOpening(finalFrame: Bool) async throws {
        try await withTestWatchdog(timeout: .seconds(20)) { @MainActor in
            let gate = OpeningFrameGate()
            defer { gate.release() }
            let snapshot = try SessionScenarioBuilder(seed: 1_252).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, displayFrameScheduler: gate.scheduler,
                                  enablesComposerSubmission: true, enablesPresentationCover: true, usesRealOpening: true) { harness in
                gate.condition = {
                    let phase = harness.probe.openingPhase?() ?? .opening
                    return finalFrame ? [.presented, .ready].contains(phase) : phase == .revealing
                }
                try await gate.waitUntilHeld()
                let target = harness.currentTarget
                var next = snapshot
                next.runtimeGeneration += "-new-runtime"
                next.revision += 1
                next.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(next) // does NOT replace target generation
                #expect(harness.currentTarget == target)
                gate.release()
                let ready = try await harness.recorder.waitUntil { _ in harness.probe.readyPublicationCount > 0 }
                #expect(harness.probe.installedRuntime?() == next.runtimeGeneration)
                #expect(harness.currentTarget == target)
                #expect(harness.rpcMethods.filter { $0 == "session.open" }.count == 1)
                #expect(ready.nativeRows.contains { $0.isVisible })
            }
        }
    }

    @Test("cancelled detached replacement keeps authority independent of its old display cut", arguments: [false, true], [false, true])
    func cancelledDetachedReplacement(background: Bool, revoke: Bool) async throws {
        try await withTestWatchdog(timeout: .seconds(20)) { @MainActor in
            let gate = OpeningFrameGate()
            defer { gate.release() }
            let snapshot = try SessionScenarioBuilder(seed: 1_253).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, displayFrameScheduler: gate.scheduler,
                                  enablesComposerSubmission: true, enablesPresentationCover: true, usesRealOpening: true) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady }
                try harness.setComposerText("keep detached draft")
                let draft = try harness.composerTextAndSelection()
                let bottom = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_000, containerHeight: 400)
                let away = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_000, containerHeight: 400)
                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveNativeOwnership(false)
                let baseline = harness.probeObservation.projectionInstallCount
                gate.condition = { harness.probe.extensionPublicationAllowed?() == false && harness.probe.openingPhase?() == .ready }
                var next = snapshot
                next.runtimeGeneration += "-replacement"
                harness.installReplacementAuthority(next)
                try await gate.waitUntilHeld()
                let target = harness.currentTarget
                if background { harness.setScenePhase(.background) }
                else {
                    harness.setCovered(true)
                    try await harness.waitForCoverTransition(presented: true)
                }
                if revoke { harness.revokeTarget() }
                gate.release()
                try await harness.waitForOpeningAttemptCompletion(2)
                #expect(harness.probe.readyPublicationCount == 1)
                #expect(harness.probeObservation.projectionInstallCount == baseline)
                #expect(harness.probe.installedRuntime?() == snapshot.runtimeGeneration)
                let after = try harness.composerTextAndSelection()
                #expect(after.text == draft.text && after.selection == draft.selection && after.identity == draft.identity)
                let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
                if revoke {
                    #expect(!harness.admitsUploads)
                    await harness.probe.importCameraImage?(image)
                    harness.probe.submitPrompt()
                    #expect(harness.uploads.calls == 0)
                    #expect(harness.currentSubmission == nil)
                    return
                }
                #expect(harness.currentTarget == target)
                #expect(!harness.rpcMethods.contains("session.close"))
                if background { harness.setScenePhase(.active) }
                else {
                    harness.setCovered(false)
                    try await harness.waitForCoverTransition(presented: false)
                }
                _ = try await harness.recorder.waitUntil { _ in harness.probe.readyPublicationCount == 2 }
                #expect(harness.probeObservation.isDetached)
                #expect(harness.probeObservation.projectionInstallCount == baseline)
                #expect(harness.admitsUploads)
                await harness.probe.importCameraImage?(image)
                #expect(harness.uploads.calls == 1)
                #expect(harness.currentAttachments.map(\.gatewayUploadID) == ["fixture-upload-1"])
                harness.probe.submitPrompt()
                _ = try await harness.recorder.waitUntil { _ in harness.currentSubmission != nil }
                #expect(harness.currentSubmission?.target == target)
            }
        }
    }

    @Test("production unfinished opening retains its exact subscription across cover and settles an accepted upload once")
    func unfinishedCoveredOpeningResumesAuthority() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_232).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, enablesComposerSubmission: true,
                                  enablesPresentationCover: true, usesRealOpening: true) { harness in
                let installed = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > 0 && !$0.observation.isReady
                }
                let target = try #require(harness.currentTarget)
                #expect(harness.currentAuthorityIsMounted)
                #expect(harness.rpcMethods.filter { $0 == "session.open" }.count == 1)
                harness.uploads.hold = true
                let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
                let upload = Task { await harness.probe.importCameraImage?(image) }
                _ = try await harness.recorder.waitUntil { _ in harness.uploads.calls == 1 }
                harness.setCovered(true)
                try await harness.waitForCoverTransition(presented: true)
                #expect(harness.currentTarget == target)
                #expect(harness.currentAuthorityIsMounted)
                #expect(harness.rpcMethods.filter { $0 == "session.close" }.isEmpty)
                harness.uploads.release()
                await upload.value
                #expect(harness.currentAttachments.map(\.gatewayUploadID) == ["fixture-upload-1"])
                harness.setCovered(false)
                try await harness.waitForCoverTransition(presented: false)
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeGeometryMatches
                        && $0.observation.readyFrameCompletionCount >= 2
                }
                #expect(ready.observation.projectionInstallCount == installed.observation.projectionInstallCount)
                #expect(harness.currentTarget == target)
                #expect(harness.rpcMethods.filter { $0 == "session.open" }.count == 1)
                #expect(harness.uploads.calls == 1)
                harness.uploads.hold = false
                await harness.probe.importCameraImage?(image)
                #expect(harness.uploads.calls == 2)
                #expect(harness.currentAttachments.map(\.gatewayUploadID) == ["fixture-upload-1", "fixture-upload-2"])
                #expect(harness.traceRecords.contains {
                    $0.record.event == "chat.composer.availability"
                        && $0.record.message.contains("openingTask=1")
                })
                #expect(harness.traceRecords.contains {
                    $0.record.event == "chat.composer.availability"
                        && $0.record.message.contains("viewportActive=0 publicationActive=0")
                })
                #expect(harness.traceRecords.contains { $0.record.event == "chat.opening.visible-reveal-began" })
                #expect(harness.traceRecords.contains { $0.record.event == "chat.opening.ready-frame-awaited" })
                #expect(try harness.isAttachmentButtonEnabled())
                #expect(try harness.isNativeTranscriptInteractionEnabled())
                #expect(abs(try harness.nativeTranscriptSignedTailError()) <= 2)
                harness.removeChatRoute()
                _ = try await harness.recorder.waitUntil { _ in harness.rpcMethods.contains("session.close") }
                #expect(harness.rpcMethods.filter { $0 == "session.close" }.count == 1)
                #expect(!harness.currentAuthorityIsMounted)
            }
        }
    }

    @Test("cancelled native appearance transition preserves the committed chat subscription and draft identity")
    func cancelledAppearanceTransitionPreservesAuthority() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_235).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, enablesComposerSubmission: true,
                                  enablesPresentationCover: true, usesRealOpening: true) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady }
                try harness.setComposerText("cancelled back draft")
                let draft = try harness.composerTextAndSelection()
                let target = try #require(harness.currentTarget)
                await harness.cancelNativeAppearanceTransition()
                #expect(harness.currentTarget == target)
                #expect(harness.currentAuthorityIsMounted)
                #expect(harness.rpcMethods.filter { $0 == "session.close" }.isEmpty)
                let after = try harness.composerTextAndSelection()
                #expect(after.text == draft.text)
                #expect(after.selection == draft.selection)
                #expect(after.identity == draft.identity)
            }
        }
    }

    @Test("attachment picker action rejects disconnected and revoked current targets", arguments: [true, false])
    func attachmentActionRejectsRetiredAuthority(disconnect: Bool) async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_233).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, enablesComposerSubmission: true, enablesPresentationCover: true, usesRealOpening: true) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady }
                if disconnect { await harness.disconnectTransport() } else { harness.revokeTarget() }
                #expect(!harness.admitsUploads)
                let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
                await harness.probe.importCameraImage?(image)
                #expect(harness.uploads.calls == 0)
                #expect(harness.currentAttachments.isEmpty)
                try await DisplayFrameScheduler.displayLink.nextFrame()
                #expect(try !harness.isAttachmentButtonEnabled())
            }
        }
    }

    @Test("detached display retention admits send on the replacement current authority without a viewport event", arguments: [false, true])
    func detachedReplacementAdmitsCurrentTarget(replaceWhileCovered: Bool) async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_234).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, enablesComposerSubmission: true, enablesPresentationCover: true, usesRealOpening: true) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady && $0.observation.readyFrameCompletionCount == 1 }
                let oldTarget = try #require(harness.currentTarget)
                let bottom = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_000, containerHeight: 400)
                let away = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_000, containerHeight: 400)
                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveNativeOwnership(false)
                let baseline = harness.probeObservation.projectionInstallCount
                var replacement = snapshot
                replacement.runtimeGeneration += "-replacement"
                replacement.revision += 1
                replacement.eventSequence = 1
                if replaceWhileCovered {
                    harness.setCovered(true)
                    try await harness.waitForCoverTransition(presented: true)
                }
                harness.installReplacementAuthority(replacement)
                if replaceWhileCovered {
                    harness.setCovered(false)
                    try await harness.waitForCoverTransition(presented: false)
                }
                _ = try await harness.recorder.waitUntil { $0.observation.readyFrameCompletionCount == 2 }
                #expect(harness.currentTarget != oldTarget)
                #expect(harness.currentAuthorityIsMounted)
                #expect(harness.probeObservation.isDetached)
                #expect(harness.probeObservation.projectionInstallCount == baseline)
                #expect(try harness.isAttachmentButtonEnabled())
                try harness.setComposerDraftText("detached replacement send")
                try await DisplayFrameScheduler.displayLink.nextFrame()
                harness.probe.submitPrompt()
                _ = try await harness.recorder.waitUntil { _ in harness.currentSubmission != nil }
                #expect(harness.currentSubmission?.outgoingText == "detached replacement send")
                #expect(harness.probeObservation.isDetached)
                #expect(harness.probeObservation.projectionInstallCount == baseline)
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
            snapshot.transcript = try (0..<275).map { index in
                let lineCount = [1, 3, 12, 2, 6][index % 5]
                let text = Array(repeating: "mixed opening row \(index)", count: lineCount)
                    .joined(separator: "\\n")
                return try harnessAssistantMessage(
                    id: "long-opening-\(index)",
                    presentationID: "long-opening-\(index)",
                    text: text
                )
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
                #expect(abs(try harness.nativeTranscriptSignedTailError()) <= 2)
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
                    $0.observation.readyFrameCompletionCount >= 1
                }
                // Multiple cancelled attempts can finish before one presented
                // sample. Check every recorded attempt, not a transient count
                // that the frame observer is allowed to skip.
                let events = harness.firstReadyEvents
                #expect(events.count >= 2)
                for index in stride(from: 0, to: events.count - 1, by: 2) {
                    #expect(Array(events[index...index + 1]) == [
                        .begin(.firstReadyFrame),
                        .end(.firstReadyFrame, .cancelled, .none),
                    ])
                }
                if !events.count.isMultiple(of: 2) {
                    #expect(events.last == .begin(.firstReadyFrame))
                }
            }
        }
    }

    @Test("dynamic-height retained pinned view rebases native rows after displacement")
    func displacedRetainedResume() async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            var snapshot = try SessionScenarioBuilder(seed: 1_207)
                .openingTail(targetEncodedBytes: 10_000)
            snapshot.transcript = try (0..<72).map { index in
                try harnessRichAssistantMessage(
                    id: "retained-\(index)", presentationID: "retained-turn-\(index)",
                    thinkingLines: index.isMultiple(of: 5) ? ["Retained native geometry evidence."] : [],
                    text: Array(
                        repeating: "Variable-height retained history must remain mounted after a native displacement.",
                        count: 1 + index % 4
                    ).joined(separator: "\n\n")
                )
            }
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = snapshot.transcript.count
            let tailSemanticID = "retained-turn-71"
            try await withHarness(snapshot: snapshot) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                let readyWithNativeTail = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains { $0.semanticID == tailSemanticID && $0.isVisible }
                }
                let readyTail = try #require(readyWithNativeTail.nativeRows.first {
                    $0.semanticID == tailSemanticID && $0.isVisible
                })
                #expect(readyWithNativeTail.observation.installedProjectionRowCount == 72)
                #expect(readyTail.frame.height > 0)
                #expect(readyWithNativeTail.observation.rowFrames[tailSemanticID]?.height ?? 0 > 0)
                try harness.displaceNativeTranscriptFromTail(by: 180)
                #expect(try harness.nativeTranscriptDistanceFromTail() > 100)

                harness.drivePinnedPositionReapplication()
                let resumed = try await harness.recorder.waitUntil {
                    $0.frameIndex > ready.frameIndex
                        && $0.observation.isReady
                        && $0.observation.visibleRowIDs.contains(tailSemanticID)
                        && $0.nativeRows.contains { $0.semanticID == tailSemanticID && $0.isVisible }
                        && $0.observation.geometry.distanceFromBottom <= 2
                        && ((try? harness.nativeTranscriptDistanceFromTail()) ?? .infinity) <= 2
                }
                let resumedTail = try #require(resumed.nativeRows.first {
                    $0.semanticID == tailSemanticID && $0.isVisible
                })
                #expect(try harness.nativeTranscriptDistanceFromTail() <= 2)
                #expect(resumedTail.frame.height > 0)
                #expect(resumed.observation.rowFrames[tailSemanticID]?.height ?? 0 > 0)
                #expect(!harness.recorder.samples.contains {
                    $0.frameIndex > ready.frameIndex && !$0.observation.isReady
                })
                #expect(
                    resumed.observation.smoothAutomaticScrollCommandCount
                        == ready.observation.smoothAutomaticScrollCommandCount
                )
                let repairBaseline = resumed.observation.physicalTailRepairCommandCount
                for _ in 0..<3 { try await harness.driveFrameBoundary() }
                let settled = harness.probeObservation
                #expect(settled.physicalTailRepairCommandCount == repairBaseline)
                #expect(settled.visibleRowIDs.contains(tailSemanticID))
                #expect(harness.recorder.samples.last?.nativeGeometryMatches == true)
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
    // Installation can precede this generation's native visibility callbacks.
    // Assert the rendered row only after a nonempty viewport observation, not
    // the deliberately cleared evidence in the intermediate install frame.
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
                        && !$0.observation.visibleRowIDs.isEmpty
                }
                #expect(revealed.observation.automaticScrollCommandCount == automaticScrollBaseline)
                #expect(revealed.observation.smoothAutomaticScrollCommandCount == smoothBaseline)
                #expect(revealed.observation.tailMaterializationCommandCount == materializationBaseline + 2)
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
                        && !$0.observation.visibleRowIDs.isEmpty
                }
                #expect(settled.observation.animatedEntranceCount == entranceBaseline + 1)
                #expect(settled.observation.tailMaterializationCommandCount == materializationBaseline + 2)
                #expect(settled.observation.physicalRowAppearanceCounts["turn-agent"] == 1)
                #expect((settled.observation.physicalRowDisappearanceCounts["turn-agent"] ?? 0) == 0)
                #expect(try harness.nativeTranscriptDistanceFromTail() <= 2)
                #expect(!settled.observation.visibleRowIDs.isEmpty)

                let compactionOrdinal = try #require(final.transcriptTotal)
                var compacting = final
                compacting.phase = .compacting
                compacting.revision += 1
                compacting.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(compacting)
                let progress = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > settled.observation.projectionInstallCount
                        && $0.observation.installedProjectionSourceOrdinal
                            == compacting.eventSequence
                        && ($0.observation.scrollSettledDistance ?? .infinity)
                            <= ChatTranscriptGeometry.catchUpDistance
                        && !$0.observation.visibleRowIDs.isEmpty
                }
                #expect(progress.observation.animatedEntranceCount >= entranceBaseline + 1)
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
                        && $0.observation.installedProjectionSourceOrdinal
                            == compacted.eventSequence
                        && ($0.observation.scrollSettledDistance ?? .infinity)
                            <= ChatTranscriptGeometry.catchUpDistance
                }
                #expect(compactionSettled.observation.animatedEntranceCount
                    >= progress.observation.animatedEntranceCount)
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
                #expect(revealed.observation.tailMaterializationCommandCount == materializationBaseline + 2)
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
                #expect(updated.observation.tailMaterializationCommandCount == materializationBaseline + 2)
                #expect(updated.observation.physicalRowAppearanceCounts["discrete-tail"] == 1)
                #expect((updated.observation.physicalRowDisappearanceCounts["discrete-tail"] ?? 0) == 0)
            }
        }
    }

    @Test("recent subagent expiry animates the adjacent composer width")
    func recentSubagentExpiryAnimatesComposerWidth() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_194).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady }
                let fullWidth = try harness.composerWidth()
                let now = Date.now
                let expiry = now.addingTimeInterval(1.5)
                var recent = harness.snapshot
                recent.processActivities = [SessionProcessActivity(
                    processId: "recent-worker", kind: .subagent, executionMode: .asynchronous,
                    source: .delegatedAgent,
                    lifecycle: SessionProcessLifecycle(
                        state: .completed, sequence: 1,
                        observedAt: GatewayTimestamp.preciseString(from: now),
                        terminalAt: GatewayTimestamp.preciseString(from: expiry.addingTimeInterval(-300)),
                        recentUntil: GatewayTimestamp.preciseString(from: expiry)
                    ), visibility: .recent, title: "Finished worker"
                )]
                recent.processOverview = SessionProcessOverview(
                    revision: 1, asOf: GatewayTimestamp.preciseString(from: now),
                    activeCount: 0, recentCount: 1, problemCount: 0, visibility: .recent,
                    nearestExpiry: GatewayTimestamp.preciseString(from: expiry)
                )
                recent.revision += 1
                recent.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(recent)
                var insertion: [CGFloat] = []
                var removal: [CGFloat] = []
                let end = expiry.addingTimeInterval(0.8)
                while Date.now < end {
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                    let width = try harness.composerWidth()
                    if Date.now < expiry { insertion.append(width) }
                    else { removal.append(width) }
                }
                let narrow = try #require(insertion.min())
                #expect(fullWidth - narrow > 30)
                #expect(insertion.contains { $0 > narrow + 2 && $0 < fullWidth - 2 })
                #expect(removal.contains { $0 > narrow + 2 && $0 < fullWidth - 2 })
                #expect(abs(try harness.composerWidth() - fullWidth) < 1)
            }
        }
    }

    @Test("an empty session renders command and notification pills before its first reply")
    func emptySessionMaterializesExtensionPills() async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            var empty = try SessionScenarioBuilder(seed: 1_193).openingTail(targetEncodedBytes: 10_000)
            empty.transcript = []
            empty.transcriptStart = 0
            empty.transcriptTotal = 0
            empty.toolExecutions = []
            let initial = empty
            try await withHarness(snapshot: initial) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady }
                var running = initial
                running.phase = .running
                // Slash commands have no optimistic user row. The first
                // installed content can consist entirely of compact pills.
                running.transcript = try decodeTranscriptFixture([TranscriptItem].self, from: Data("""
                [
                {"id":"command","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"customEntry","customType":"tron.chat-invocation.v1","semantic":{"version":1,"direction":"ambientStatus","contextEffect":"none","delivery":"stored","visibility":"visible","kind":"command","origin":{"kind":"extension","ownerId":"extension:goal","title":"Pi Goal","confidence":"adapter"},"invocationId":"invocation","operationId":"operation","sequence":1,"lifecycle":"completed","resourceInvocation":{"source":"extension","name":"goal","arguments":"Reply ok"}}},
                {"id":"notice","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"customEntry","customType":"tron.extension-notification.v1","data":{"writer":"gateway","version":1,"receiptId":"notification:goal","sessionId":"session","message":"Goal created.","tone":"info","origin":{"kind":"extension","ownerId":"extension:goal","title":"Pi Goal","confidence":"receipt"},"sequence":1,"createdAt":"2026-01-01T00:00:00.000Z"},"semantic":{"version":1,"direction":"ambientStatus","contextEffect":"none","delivery":"stored","visibility":"visible","kind":"status","origin":{"kind":"extension","ownerId":"extension:goal","title":"Pi Goal","confidence":"receipt"},"sequence":1}}
                ]
                """.utf8))
                running.transcriptTotal = running.transcript.count
                running.revision += 1
                running.eventSequence += 1
                let installBaseline = harness.probeObservation.projectionInstallCount
                harness.replaceAuthoritativeSnapshot(running)
                let rendered = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > installBaseline
                        && $0.nativeRows.filter { $0.isVisible && $0.frame.height > 20 }.count == 2
                }
                #expect(rendered.observation.geometry.contentHeight > 64)
                let pillIdentities = Dictionary(uniqueKeysWithValues: rendered.nativeRows.map {
                    ($0.semanticID, $0.instance)
                })

                var completed = running
                completed.phase = .idle
                completed.transcript.append(try harnessAssistantMessage(
                    id: "first-reply", presentationID: "first-reply", text: "ok"
                ))
                completed.transcriptTotal = completed.transcript.count
                completed.revision += 1
                completed.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(completed)
                let reply = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains {
                        $0.semanticID == "first-reply" && $0.isVisible && $0.frame.height > 20
                    } && $0.nativeRows.filter { $0.isVisible && $0.frame.height > 20 }.count == 3
                }
                // The first reply must not require remounting the chat or its
                // existing pills to become visible.
                for (id, instance) in pillIdentities {
                    #expect(reply.nativeRows.first { $0.semanticID == id }?.instance == instance)
                }
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
                        // An installed projection precedes its native/semantic
                        // geometry publication; it is not a rendered-frame fence.
                        && $0.observation.rowFrames["tool-run-settled-group"] != nil
                        && $0.nativeRows.contains {
                            $0.semanticID == "tool-run-settled-group" && $0.isVisible
                        }
                }
                #expect(settled.observation.animatedEntranceCount == entranceBaseline + 1)
                #expect(settled.observation.smoothAutomaticScrollCommandCount == smoothBaseline)
                #expect(
                    settled.observation.tailMaterializationCommandCount
                        == materializationBaseline + 2
                )
                #expect(settled.observation.rowFrames["tool-run-settled-group"] != nil)
                #expect(settled.observation.physicalRowAppearanceCounts["tool-run-active-race"] == 1)
                let lifecycleSamples = settled.observation.toolChipSamples.filter {
                    $0.callIDs.contains("active-race")
                }
                #expect(lifecycleSamples.contains { $0.transitionToken == 1 })
                #expect(lifecycleSamples.last?.runID == "tool-run-settled-group")
                let handoffs = harness.traceRecords.filter {
                    $0.record.event == "chat.lease.semantic-handoff"
                }
                #expect(handoffs.contains {
                    $0.record.message.contains("physicalRow=")
                        && $0.record.message.contains("semanticRow=")
                        && $0.record.message.contains("rowEvidence=")
                })
                #expect(!harness.traceRecords.contains {
                    $0.record.event == "chat.lease.bounded-fallback"
                        || ($0.record.event == "chat.lease.release-requested"
                            && $0.record.message.contains("reason=bounded-fallback"))
                })
            }
        }
    }

    @Test("real tool group topology inserts one chip under native viewport pinning")
    // Chip topology commits and native visibility observations are separate
    // frame boundaries; neither a cached row rect nor installation proves both.
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
                        && !$0.observation.visibleRowIDs.isEmpty
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
                        && !$0.observation.visibleRowIDs.isEmpty
                }

                #expect(settled.observation.rowFrames["tool-run-group-two"] == nil)
                #expect(settled.observation.smoothAutomaticScrollCommandCount == smoothBaseline)
                #expect(
                    settled.observation.tailMaterializationCommandCount
                        == materializationBaseline + 2
                )
                #expect(settled.observation.physicalRowAppearanceCounts["tool-run-group-one"] == 1)
                #expect(settled.observation.toolChipSamples.contains {
                    $0.runID == "tool-run-group-one" && $0.transitionToken == 1
                })
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
                        && $0.observation.installedProjectionRowCount >= 4
                        && ($0.observation.scrollSettledDistance ?? .infinity)
                            <= ChatTranscriptGeometry.catchUpDistance
                        && !$0.observation.visibleRowIDs.isEmpty
                }
                #expect(distinct.observation.toolChipSamples.contains {
                    $0.runID == "tool-run-group-one" && $0.transitionToken == 1
                })
                #expect(!distinct.observation.visibleRowIDs.isEmpty)
                let latest = distinct.observation.toolChipSamples.last {
                    $0.runID == "tool-run-group-next"
                }
                if let latest {
                    #expect(latest.transitionToken == 1)
                    #expect(latest.count == 1)
                    #expect(latest.title == "Read file")
                }
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
                        <= committedEvaluationBaseline + 2
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
        enablesComposerSubmission: Bool = false,
        enablesPresentationCover: Bool = false,
        installsSubscribedSnapshot: Bool = true,
        usesRealOpening: Bool = false,
        operation: @escaping @MainActor @Sendable (ChatViewScrollHarness) async throws -> Void
    ) async throws {
        let harness: ChatViewScrollHarness
        if enablesComposerSubmission {
            harness = try await ChatViewScrollHarness.composerSubmissionHarness(
                snapshot: snapshot,
                displayFrameScheduler: displayFrameScheduler,
                enablesPresentationCover: enablesPresentationCover,
                usesRealOpening: usesRealOpening
            )
        } else {
            harness = try ChatViewScrollHarness(
                snapshot: snapshot,
                displayFrameScheduler: displayFrameScheduler,
                enablesPresentationCover: enablesPresentationCover,
                installsSubscribedSnapshot: installsSubscribedSnapshot || enablesPresentationCover
            )
        }
        do {
            try await operation(harness)
        } catch {
            if let sample = harness.recorder.samples.last {
                print("Hosted failure frame \(sample.frameIndex): commands=\(sample.observation.tailMaterializationCommandCount) releases=\(sample.observation.targetReleaseCount) rows=\(sample.nativeRows.suffix(8))")
                print("Composer catalog: builds=\(harness.probe.composerCatalogBuildCount) installed=\(harness.probe.composerCatalogCommandNames) canonical=\(harness.canonicalCommandNames) activity=\(harness.chatSurfaceActivity)")
            }
            await harness.close()
            throw error
        }
        await harness.close()
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

@MainActor @Observable
private final class HarnessCoverState {
    var presented = false
    var scenePhase: ScenePhase = .active
    var rootToken: PresentationSurfaceToken?
    let coordinator = PresentationActivityCoordinator()
}

private struct HarnessManagedSurface: View {
    let content: AnyView
    @Bindable var cover: HarnessCoverState

    var body: some View {
        TronPresentationSurface(id: "harness-chat", onMount: { cover.rootToken = $0 }) {
            content.tronManagedSheet(isPresented: $cover.presented, identity: "harness-cover") {
                Text("Covered chat").presentationDetents([.medium])
            }
        }
        .environment(\.tronPresentationActivityCoordinator, cover.coordinator)
        // UIHostingController is not a SwiftUI Scene; declare this fixture's
        // scene input independently of its real native sheet ownership.
        .environment(\.scenePhase, cover.scenePhase)
    }
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

    private struct Dependencies {
        let suiteName: String
        let defaults: UserDefaults
        let cacheRoot: URL
        let client: GatewayClient
        let model: AppModel
        let socket: ScriptedGatewaySocket?
        let profile: GatewayProfile?
        fileprivate let uploads: HostedUploadReceipt
    }

    private let model: AppModel
    private let client: GatewayClient
    private let socket: ScriptedGatewaySocket?
    fileprivate let uploads: HostedUploadReceipt
    private var rpcTask: Task<Void, Never>?
    private(set) var rpcMethods: [String] = []
    private let suiteName: String
    private let cacheRoot: URL
    private let defaults: UserDefaults
    private let window: UIWindow
    private let hostingController: UIHostingController<AnyView>
    private let cover = HarnessCoverState()

    convenience init(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler,
        performanceSignposts: (any PerformanceSignposting)? = nil,
        enablesPresentationCover: Bool = false,
        installsSubscribedSnapshot: Bool = true
    ) throws {
        let dependencies = try Self.makeDependencies(enablesComposerSubmission: false)
        try self.init(
            snapshot: snapshot,
            displayFrameScheduler: displayFrameScheduler,
            performanceSignposts: performanceSignposts,
            dependencies: dependencies,
            installsSubscribedSnapshot: installsSubscribedSnapshot,
            enablesPresentationCover: enablesPresentationCover
        )
    }

    static func composerSubmissionHarness(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler,
        performanceSignposts: (any PerformanceSignposting)? = nil,
        enablesPresentationCover: Bool = false,
        usesRealOpening: Bool = false
    ) async throws -> ChatViewScrollHarness {
        let dependencies = try makeDependencies(enablesComposerSubmission: true)
        guard let socket = dependencies.socket, let profile = dependencies.profile else {
            throw HarnessError.invalidAuthorityBoundary
        }
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"hosted-machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","skill-prompt.v1"]}"#.utf8))
        do {
            try await dependencies.model.connectHostedGateway(
                profile: profile,
                token: "hosted-token"
            )
            let harness = try ChatViewScrollHarness(
                snapshot: snapshot,
                displayFrameScheduler: displayFrameScheduler,
                performanceSignposts: performanceSignposts,
                dependencies: dependencies,
                installsSubscribedSnapshot: true,
                enablesPresentationCover: enablesPresentationCover,
                usesRealOpening: usesRealOpening
            )
            if usesRealOpening { await harness.startRPCResponder() }
            return harness
        } catch {
            await dependencies.model.teardown()
            await dependencies.client.close()
            dependencies.defaults.removePersistentDomain(forName: dependencies.suiteName)
            try? FileManager.default.removeItem(at: dependencies.cacheRoot)
            throw error
        }
    }

    private static func makeDependencies(
        enablesComposerSubmission: Bool
    ) throws -> Dependencies {
        let suiteName = "ChatViewScrollHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(
            path: suiteName,
            directoryHint: .isDirectory
        )
        let socket = enablesComposerSubmission ? ScriptedGatewaySocket() : nil
        let profile = enablesComposerSubmission ? GatewayProfile(
            id: "hosted-chat",
            label: "Hosted Chat",
            host: "gateway.test",
            port: 9_847,
            machineId: "hosted-machine",
            deviceId: "hosted-device"
        ) : nil
        if let profile {
            defaults.set(
                try JSONEncoder.gateway.encode([profile]),
                forKey: "gatewayProfiles.v1"
            )
            defaults.set(profile.id, forKey: "selectedGateway.v1")
        }
        let client = if let socket {
            GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        } else {
            GatewayClient()
        }
        let hostedSend: ComposerSendOperation = {
            _, _, _, _, _ in "hosted-prompt-operation"
        }
        let composerSend: ComposerSendOperation? = enablesComposerSubmission
            ? hostedSend
            : nil
        let uploads = HostedUploadReceipt()
        let model = AppModel(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: cacheRoot),
            composerUpload: { _, _, data in try await uploads.upload(data) },
            composerSend: composerSend,
            composerDraftStore: ComposerDraftStore(root: cacheRoot.appending(path: "drafts"))
        )
        return Dependencies(
            suiteName: suiteName,
            defaults: defaults,
            cacheRoot: cacheRoot,
            client: client,
            model: model,
            socket: socket,
            profile: profile,
            uploads: uploads
        )
    }

    private init(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler,
        performanceSignposts: (any PerformanceSignposting)?,
        dependencies: Dependencies,
        installsSubscribedSnapshot: Bool,
        enablesPresentationCover: Bool = false,
        usesRealOpening: Bool = false
    ) throws {
        self.snapshot = snapshot
        transcriptIDs = Set(snapshot.transcript.map(\.id)).union(["transcript-bottom"])
        firstTranscriptID = snapshot.transcript.first?.id ?? "transcript-bottom"
        lastTranscriptID = snapshot.transcript.last?.id ?? "transcript-bottom"
        let signposts = RecordingPerformanceSignposts()
        self.signposts = signposts
        suiteName = dependencies.suiteName
        defaults = dependencies.defaults
        cacheRoot = dependencies.cacheRoot
        client = dependencies.client
        model = dependencies.model
        socket = dependencies.socket
        uploads = dependencies.uploads
        guard model.authoritativeSnapshot(for: snapshot.sessionId) == nil else {
            throw HarnessError.invalidAuthorityBoundary
        }
        // Hosted presentation generations are authoritative and need not match
        // ChatOpenPresentationState's local opening epoch.
        model.invalidateHostedPendingPresentation()
        if usesRealOpening {
            // No hosted authority: ChatView must call AppModel/session.open.
        } else if installsSubscribedSnapshot {
            model.installHostedSubscribedSnapshot(snapshot, token: "hosted-session-token")
        } else {
            model.installHostedAuthoritativeSnapshot(snapshot)
        }
        guard usesRealOpening || model.authoritativeSnapshot(for: snapshot.sessionId) == snapshot else {
            throw HarnessError.invalidAuthorityBoundary
        }

        let probe = ChatHostedProbe()
        if !usesRealOpening {
            probe.fixtureOpenPresentation = { [model] in
                guard let target = model.presentationTarget(for: snapshot.sessionId),
                      model.hasMountedSessionAuthority(target) else { throw CancellationError() }
                return target.generation
            }
        }
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
        hostingController = UIHostingController(rootView: enablesPresentationCover
            ? AnyView(HarnessManagedSurface(content: root, cover: cover))
            : AnyView(root.environment(\.scenePhase, .active)))
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
        recorder = PresentedFrameRecorder(
            probe: probe,
            nativeGeometryMatches: { geometry in
                Self.containsNativeTranscriptScrollView(in: hostedView, matching: geometry)
            },
            nativeRows: { Self.nativeRows(in: hostedView) }
        )
        recorder.start()
    }

    private func startRPCResponder() async {
        guard let socket else { return }
        rpcTask = Task { @MainActor [weak self] in
            var index = 1 // connection hello is the sole non-RPC frame
            do {
                while !Task.isCancelled {
                    try await socket.waitUntilSent(count: index + 1)
                    let request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[index])
                    index += 1
                    guard let self,
                          let method = request.objectValue?["method"]?.stringValue,
                          let id = request.objectValue?["id"]?.stringValue else { continue }
                    rpcMethods.append(method)
                    let result: JSONValue
                    switch method {
                    case "session.open":
                        result = .object([
                            "session": try JSONValue.encode(snapshot),
                            "syncToken": .string("fixture-sync-\(index)"),
                            "subscriptionToken": .string("fixture-subscription-\(index)"),
                            "completionRevision": .number(0),
                        ])
                    case "session.sync": result = .object(["synchronized": .bool(true)])
                    case "session.close": result = .object(["closed": .bool(true)])
                    case "session.commands": result = .object(["commands": .array([])])
                    case "session.attention.read":
                        result = .object(["completionRevision": .number(0), "attentionRevision": .number(0), "isUnread": .bool(false)])
                    default:
                        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                            "type": .string("response"), "id": .string(id), "ok": .bool(false),
                            "error": .object(["code": .string("fixture_unsupported"), "message": .string(method), "retryable": .bool(false)])
                        ])))
                        continue
                    }
                    await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                        "type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result
                    ])))
                }
            } catch is CancellationError {} catch { Issue.record("Fake Gateway responder: \(error)") }
        }
    }

    func waitForOpeningAttemptCompletion(_ count: Int) async throws {
        while probe.observation.readyFrameCompletionCount < count {
            try await DisplayFrameScheduler.displayLink.nextFrame()
        }
    }

    var currentTarget: SessionPresentationIdentity? { model.mountedPresentationTarget }
    var currentAuthorityIsMounted: Bool { currentTarget.map(model.hasMountedSessionAuthority) ?? false }
    var currentSubmission: ComposerSubmissionSnapshot? {
        currentTarget.flatMap { model.composerDrafts.outgoingSubmission(for: $0) }
    }
    var currentAttachments: [PendingAttachment] {
        currentTarget.map { model.composerDrafts.pendingAttachments(for: $0) } ?? []
    }
    func revokeTarget() { if let currentTarget { model.revokePresentationIntake(currentTarget) } }
    var admitsUploads: Bool { currentTarget.map(model.admitsLiveSessionUploads) ?? false }
    func disconnectTransport() async { await model.enteredBackground().value }
    func cancelNativeAppearanceTransition() async {
        hostingController.beginAppearanceTransition(false, animated: true)
        try? await DisplayFrameScheduler.displayLink.nextFrame()
        hostingController.beginAppearanceTransition(true, animated: true)
        hostingController.endAppearanceTransition()
        try? await DisplayFrameScheduler.displayLink.nextFrame()
    }

    func composerWidth() throws -> CGFloat {
        guard let textView = Self.textViews(in: hostingController.view).first else {
            throw HarnessError.missingComposer
        }
        return textView.bounds.width
    }

    func removeChatRoute() { hostingController.rootView = AnyView(EmptyView()) }

    func setCovered(_ value: Bool) { cover.presented = value }
    func setScenePhase(_ phase: ScenePhase) { cover.scenePhase = phase }

    var chatSurfaceActivity: PresentationSurfaceActivity { cover.coordinator.activity(for: cover.rootToken) }
    var coverTransitionSettled: Bool {
        guard let presented = hostingController.presentedViewController else { return false }
        return !presented.isBeingPresented && presented.transitionCoordinator == nil
    }
    var uncoverTransitionSettled: Bool { hostingController.presentedViewController == nil }
    func waitForCoverTransition(presented: Bool) async throws {
        for _ in 0..<180 {
            if presented ? coverTransitionSettled : uncoverTransitionSettled { return }
            try await DisplayFrameScheduler.displayLink.nextFrame()
        }
        throw HarnessError.coverTransitionDidNotSettle
    }

    var probeObservation: ChatHostedObservation { probe.observation }
    var traceRecords: [GatewayProfileLogRecord] { model.chatInteractionTrace.diagnosticRecords(limit: 256) }
    var screenScale: CGFloat { window.screen.scale }

    var canonicalCommandNames: [String] { model.commands.map(\.name) }

    func loadCanonicalCommands(
        _ names: [String], skills: [String] = [], prompts: [String] = [],
        beforeResponse: (@MainActor () async throws -> Void)? = nil
    ) async throws {
        let socket = try #require(socket)
        let priorFrames = await socket.sentFrames().count
        let loading = Task { await model.loadCommands(sessionID: snapshot.sessionId) }
        do {
            try await socket.waitUntilSent(count: priorFrames + 1)
            let request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[priorFrames])
            #expect(request.objectValue?["method"]?.stringValue == "session.commands")
            let id = try #require(request.objectValue?["id"]?.stringValue)
            try await beforeResponse?()
            let commands = names.map {
                CommandInfo(name: $0, description: nil, argumentHint: nil, source: .extension, sourcePath: nil)
            } + skills.map {
                CommandInfo(name: $0, description: nil, argumentHint: nil, source: .skill, sourcePath: nil)
            } + prompts.map {
                CommandInfo(name: $0, description: nil, argumentHint: nil, source: .prompt, sourcePath: nil)
            }
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(id), "ok": .bool(true),
                "result": .object(["commands": try JSONValue.encode(commands)]),
            ])))
            await loading.value
            #expect(model.commandCatalogTarget == model.mountedPresentationTarget)
        } catch {
            loading.cancel()
            await loading.value
            throw error
        }
    }

    func replaceAuthoritativeSnapshot(_ snapshot: SessionSnapshot) {
        model.replaceHostedAuthoritativeSnapshot(snapshot)
    }

    func installReplacementAuthority(_ snapshot: SessionSnapshot) {
        model.installHostedSubscribedSnapshot(snapshot, token: "replacement-token")
    }

    func reopenWithAuthoritativeSnapshot(_ snapshot: SessionSnapshot) async {
        model.installHostedSubscribedSnapshot(snapshot, token: "replacement-token")
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

    func submitPrompt() { probe.submitPrompt() }

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

    func isNativeTranscriptInteractionEnabled() throws -> Bool {
        let scrollView = try nativeTranscriptScrollView()
        return scrollView.isScrollEnabled && scrollView.isUserInteractionEnabled
            && scrollView.panGestureRecognizer.isEnabled
    }

    private func nativeTranscriptScrollView() throws -> UIScrollView {
        guard let value = Self.nativeTranscriptScrollView(in: hostingController.view) else {
            throw HarnessError.missingTranscript
        }
        return value
    }

    /// Luminance samples from the top of the chat, where the transcript
    /// scrolls under the navigation bar outside the scroll view's safe frame.
    /// The glass bar buttons are excluded: their material re-renders with
    /// small pixel noise unrelated to what is beneath them.
    func renderedNavigationBandGrid() -> [Double] {
        let width = hostingController.view.bounds.width
        return renderedLuminance(in: CGRect(x: 72, y: 0, width: width - 144, height: 160), step: 3)
    }

    func renderedRowLuminance(in frame: CGRect) -> [Double] {
        renderedLuminance(in: frame.intersection(hostingController.view.bounds), step: 3)
    }

    func renderedPixelGrid() -> [Double] {
        let bounds = hostingController.view.bounds
        // Skip the edges and the centered opening pulse, whose animation is not
        // part of the reveal being measured.
        let pulse = CGRect(x: bounds.midX - 48, y: bounds.midY - 48, width: 96, height: 96)
        return renderedLuminance(in: bounds.insetBy(dx: 8, dy: 24), step: 12, excluding: pulse)
    }

    /// Average-channel luminance sampled every `step` points of `region`,
    /// rendered at 1x from the current hierarchy.
    private func renderedLuminance(in region: CGRect, step: Int, excluding hole: CGRect = .null) -> [Double] {
        let view = hostingController.view!
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return [] }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        var samples: [Double] = []
        for y in stride(from: Int(region.minY), to: Int(region.maxY), by: step) {
            for x in stride(from: Int(region.minX), to: Int(region.maxX), by: step) {
                if hole.contains(CGPoint(x: x, y: y)) { continue }
                let offset = y * cgImage.bytesPerRow + x * bytesPerPixel
                samples.append((Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2])) / 3)
            }
        }
        return samples
    }

    func renderedPixelDistance(_ first: [Double], _ second: [Double]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return .infinity }
        let squared = zip(first, second).reduce(0.0) { partial, pair in
            let delta = (pair.0 - pair.1) / 255
            return partial + delta * delta
        }
        return (squared / Double(first.count)).squareRoot()
    }

    func renderedPixelProgress(_ frame: [Double], from start: [Double], to end: [Double]) -> Double {
        guard frame.count == start.count, start.count == end.count, !frame.isEmpty else { return 0 }
        var projected = 0.0
        var distance = 0.0
        for index in frame.indices {
            let axis = end[index] - start[index]
            projected += (frame[index] - start[index]) * axis
            distance += axis * axis
        }
        guard distance > 0 else { return 0 }
        return min(1, max(0, projected / distance))
    }

    func resize(height: CGFloat) {
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
    }

    struct FloatingLayout {
        let marker: FloatingDisplayHostedMarker
        let frame: CGRect
        let composer: CGRect
        let toolbarBottom: CGFloat
    }

    func floatingLayout() -> FloatingLayout? {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(hostingController.view)
        guard let marker = views.compactMap({ $0 as? FloatingDisplayHostedMarker }).first,
              let composer = views.compactMap({ $0 as? ChatHostedNativeRowMarker })
                .first(where: { $0.physicalID == ChatHostedNativeRowProbe.composerID }),
              let toolbar = views.compactMap({ $0 as? UINavigationBar }).first else { return nil }
        return FloatingLayout(marker: marker, frame: marker.convert(marker.bounds, to: window),
                              composer: composer.convert(composer.bounds, to: window),
                              toolbarBottom: toolbar.convert(toolbar.bounds, to: window).maxY)
    }

    func setComposerAccessories(_ enabled: Bool) throws {
        guard let target = model.mountedPresentationTarget,
              let scope = model.composerDrafts.scope(for: target) else { throw HarnessError.missingComposer }
        if enabled {
            model.composerDrafts.selectResource(CommandInfo(name: "skill:layout", description: "Layout fixture",
                argumentHint: nil, source: .skill, sourcePath: "/fixture/skills/layout"), for: scope)
            model.composerDrafts.installHostedAttachment(PendingAttachment(id: "layout-photo", name: "Photo",
                mimeType: "image/jpeg", size: 1, previewData: nil), target: target)
        } else {
            model.composerDrafts.removeSelectedResource(for: scope)
            model.composerDrafts.removeAttachment("layout-photo", target: target)
        }
    }

    func focusComposer(_ focused: Bool) throws {
        guard let textView = Self.textViews(in: hostingController.view).first else { throw HarnessError.missingComposer }
        if focused { textView.becomeFirstResponder() } else { textView.resignFirstResponder() }
    }

    func pasteFromClipboard() throws {
        guard let textView = Self.textViews(in: hostingController.view).first else { throw HarnessError.missingComposer }
        #expect(textView.canPerformAction(#selector(UITextView.paste(_:)), withSender: nil))
        textView.paste(nil)
    }

    func pasteImages(_ providers: [NSItemProvider]) throws {
        guard let textView = Self.textViews(in: hostingController.view).first else { throw HarnessError.missingComposer }
        #expect(textView.canPaste(providers))
        textView.paste(itemProviders: providers)
    }

    func captureScreenshot(named name: String) {
        let view = hostingController.view!
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        if let data = image.pngData() { Attachment.record(data, named: name) }
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

    func selectCanonicalSkill(named name: String) throws {
        let target = try #require(model.mountedPresentationTarget)
        let scope = try #require(model.composerDrafts.scope(for: target))
        let command = try #require(model.commands.first { $0.source == .skill && $0.name == name })
        model.composerDrafts.selectResource(command, for: scope)
    }

    var selectedComposerResource: CommandInfo? {
        guard let target = model.mountedPresentationTarget,
              let scope = model.composerDrafts.scope(for: target) else { return nil }
        return model.composerDrafts.selectedResource(for: scope)
    }

    func composerTextAndSelection() throws -> (text: String, selection: NSRange, identity: ObjectIdentifier) {
        guard let textView = Self.textViews(in: hostingController.view).first else {
            throw HarnessError.missingComposer
        }
        return (textView.text, textView.selectedRange, ObjectIdentifier(textView))
    }

    func setComposerDraftText(_ text: String) throws {
        guard model.setHostedComposerText(text, sessionID: snapshot.sessionId) else {
            throw HarnessError.missingComposer
        }
    }

    func isAttachmentButtonEnabled() throws -> Bool {
        guard let button = Self.buttons(in: hostingController.view).first(where: {
            $0.accessibilityLabel == "Add attachment"
        }) else {
            throw HarnessError.missingComposer
        }
        return button.isEnabled
    }

    func cleanup() {
        retireHostedView()
        retireStorage()
    }

    func close() async {
        uploads.release()
        if hostingController.presentedViewController != nil {
            await withCheckedContinuation { continuation in
                hostingController.dismiss(animated: false) { continuation.resume() }
            }
        }
        retireHostedView()
        await model.teardown()
        rpcTask?.cancel()
        await rpcTask?.value
        await client.close()
        retireStorage()
    }

    private func retireHostedView() {
        probe.retirePresentation()
        recorder.stop()
        window.isHidden = true
        window.rootViewController = nil
    }

    private func retireStorage() {
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

    private static func markers(in view: UIView) -> [ChatHostedNativeRowMarker] {
        (view as? ChatHostedNativeRowMarker).map { [$0] } ?? view.subviews.flatMap { markers(in: $0) }
    }

    private static func nativeTranscriptScrollView(in root: UIView) -> UIScrollView? {
        // This fixed-window harness has one full-size transcript viewport.
        // Its identity cannot depend on overflowing content or a lazy child
        // being mounted at the instant an entrance/compaction is sampled.
        scrollViews(in: root).filter { !($0 is UITextView) }.max {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        }
    }

    private static func nativeRows(in root: UIView) -> [PresentedFrameRecorder.NativeRow] {
        guard let scroll = nativeTranscriptScrollView(in: root) else { return [] }
        let composer = markers(in: root).first { $0.physicalID == ChatHostedNativeRowProbe.composerID }
        let composerTop = composer.map { $0.convert($0.bounds, to: scroll).minY - scroll.bounds.minY }
        let viewport = CGRect(x: 0, y: scroll.adjustedContentInset.top, width: scroll.bounds.width,
                              height: scroll.bounds.height - scroll.adjustedContentInset.top
                                - scroll.adjustedContentInset.bottom)
        return markers(in: scroll).filter { $0.window != nil && !$0.isHidden }.map { marker in
            let frame = marker.convert(marker.bounds, to: scroll)
                .offsetBy(dx: -scroll.bounds.minX, dy: -scroll.bounds.minY)
            return .init(physicalID: marker.physicalID, semanticID: marker.semanticID,
                         instance: marker.hostIdentity, frame: frame,
                         isVisible: frame.height > 0 && frame.intersects(viewport),
                         tailGap: viewport.maxY - frame.maxY,
                         composerClearance: composerTop.map { $0 - frame.maxY })
        }
    }

    private static func textViews(in view: UIView) -> [UITextView] {
        let current = (view as? UITextView).map { [$0] } ?? []
        return current + view.subviews.flatMap(textViews)
    }

    private static func buttons(in view: UIView) -> [UIButton] {
        let current = (view as? UIButton).map { [$0] } ?? []
        return current + view.subviews.flatMap(buttons)
    }
}

@MainActor
final class PresentedFrameRecorder: NSObject {
    struct NativeRow: Sendable, Equatable {
        let physicalID: String
        let semanticID: String
        let instance: UUID
        let frame: CGRect
        let isVisible: Bool
        let tailGap: CGFloat
        let composerClearance: CGFloat?
    }

    struct Sample: Sendable {
        let frameIndex: Int
        let observation: ChatHostedObservation
        let nativeGeometryMatches: Bool
        let nativeRows: [NativeRow]
    }

    private struct Waiter {
        let id: Int
        let predicate: @MainActor (Sample) -> Bool
        let continuation: CheckedContinuation<Sample, Error>
    }

    private let probe: ChatHostedProbe
    private let nativeGeometryMatches: @MainActor (ChatTranscriptGeometry) -> Bool
    private let nativeRows: @MainActor () -> [NativeRow]
    private var lastNativeRows: [NativeRow] = []
    private var displayLink: CADisplayLink?
    private var frameIndex = 0
    private var lastRevision = -1
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    private(set) var samples: [Sample] = []

    init(
        probe: ChatHostedProbe,
        nativeGeometryMatches: @escaping @MainActor (ChatTranscriptGeometry) -> Bool,
        nativeRows: @escaping @MainActor () -> [NativeRow]
    ) {
        self.probe = probe
        self.nativeGeometryMatches = nativeGeometryMatches
        self.nativeRows = nativeRows
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
        let rows = nativeRows()
        guard observation.revision != lastRevision || rows != lastNativeRows else { return }
        lastRevision = observation.revision
        lastNativeRows = rows
        let sample = Sample(
            frameIndex: frameIndex,
            observation: observation,
            nativeGeometryMatches: nativeGeometryMatches(observation.geometry),
            nativeRows: rows
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
    case coverTransitionDidNotSettle
}

@MainActor
private final class HostedUploadReceipt {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<String, Error>?
    var hold = false

    func upload(_ data: Data) async throws -> String {
        #expect(!data.isEmpty)
        calls += 1
        if hold {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return "fixture-upload-\(calls)"
    }

    func release() {
        continuation?.resume(returning: "fixture-upload-\(calls)")
        continuation = nil
    }
}

@MainActor
private final class OpeningSettlementReturnGate {
    private(set) var result: ChatScrollCoordinator.OpeningTailSettlementResult?
    private var continuation: CheckedContinuation<Void, Never>?

    func hold(_ result: ChatScrollCoordinator.OpeningTailSettlementResult) async {
        self.result = result
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilHeld() async throws {
        while continuation == nil { try await DisplayFrameScheduler.displayLink.nextFrame() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class OpeningFrameGate {
    var condition: (() -> Bool)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var consumed = false
    var scheduler: DisplayFrameScheduler {
        DisplayFrameScheduler { [self] in
            if !consumed, condition?() == true {
                consumed = true
                // Intentionally ignore cancellation: prove the production
                // continuation rejects a late frame from its retired owner.
                await withCheckedContinuation { continuation = $0 }
            } else {
                try await DisplayFrameScheduler.displayLink.nextFrame()
            }
        }
    }
    func waitUntilHeld() async throws {
        while continuation == nil { try await DisplayFrameScheduler.displayLink.nextFrame() }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
