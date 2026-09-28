import SwiftUI
import Testing
import TronMobileCore
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
                let pastEndBaseline = ready.observation.pastEndRepairCommandCount

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
                #expect(
                    harness.probeObservation.pastEndRepairCommandCount == pastEndBaseline,
                    "keyboard contraction and expansion must never fire the past-end net"
                )
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
                let pastEndBaseline = ready.observation.pastEndRepairCommandCount

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
                #expect(
                    harness.probeObservation.pastEndRepairCommandCount == pastEndBaseline,
                    "a short-transcript contraction must never fire the past-end net"
                )
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

    // A queued card is taller than its sent row. The swap must shrink over
    // several frames with the pinned tail held, never jump. Pixel sampling is
    // expensive, so geometry and the cross-fade are measured in separate runs
    // to keep geometry frames at display cadence.
    @Test("queued prompt shrinks into its canonical user row with the tail held")
    func queuedPromptCanonicalReplacementShrinks() async throws {
        try await queuedPromptCanonicalReplacement(samplesPixels: false)
    }

    private func queuedPromptCanonicalReplacement(samplesPixels: Bool) async throws {
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
                let region = queued.frame
                let pastEndBaseline = queuedSample.observation.pastEndRepairCommandCount
                var previousPixels = samplesPixels ? harness.renderedRowLuminance(in: region) : []
                harness.replaceAuthoritativeSnapshot(canonicalTemplate)
                var heights: [CGFloat] = []
                var tailDistances: [CGFloat] = []
                var pixelChangingFrames = 0
                var sawOtherHost = false
                for _ in 0..<40 {
                    try await harness.driveFrameBoundary()
                    guard let sample = harness.recorder.samples.last,
                          let row = sample.nativeRows.first(where: {
                              $0.physicalID == queued.physicalID && $0.isVisible && $0.frame.height > 1
                          }) else { continue }
                    if row.instance != queued.instance { sawOtherHost = true }
                    heights.append(row.frame.height)
                    tailDistances.append(try harness.nativeTranscriptDistanceFromTail())
                    guard samplesPixels else { continue }
                    // Sampled now, at this display boundary, not afterwards.
                    let pixels = harness.renderedRowLuminance(in: region)
                    let delta = zip(previousPixels, pixels).map { abs($1 - $0) }.reduce(0, +) / Double(max(1, pixels.count))
                    if delta > 0.5 { pixelChangingFrames += 1 }
                    previousPixels = pixels
                }
                #expect(!sawOtherHost)
                let finalHeight = try #require(heights.last)
                let totalChange = queued.frame.height - finalHeight
                // The fixture's queued card is taller than its canonical row.
                #expect(totalChange > 8)
                #expect(tailDistances.allSatisfy { $0 <= 2 }, "tail moved: \(tailDistances)")
                #expect(
                    harness.probeObservation.pastEndRepairCommandCount == pastEndBaseline,
                    "the queued-card cross-fade must never fire the past-end net"
                )
                if samplesPixels {
                    #expect(pixelChangingFrames >= 3)
                } else {
                    let steps = zip(heights, heights.dropFirst()).map { $0 - $1 }
                    #expect(steps.allSatisfy { $0 >= -0.5 }, "height must shrink monotonically: \(heights)")
                    #expect((steps.max() ?? 0) <= totalChange * 0.6, "height changed in one jump: \(heights)")
                    let intermediate = heights.filter { $0 < queued.frame.height - 1 && $0 > finalHeight + 1 }
                    #expect(intermediate.count >= 3, "too few intermediate heights: \(heights)")
                }
                print("Queued→canonical evidence: queuedHeight=\(queued.frame.height) finalHeight=\(finalHeight) heights=\(heights.map { Int($0.rounded()) }) maxTail=\(tailDistances.max() ?? 0) pixelChangingFrames=\(pixelChangingFrames)")
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
                let pastEndBaseline = harness.probeObservation.pastEndRepairCommandCount
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
                #expect(
                    harness.probeObservation.pastEndRepairCommandCount == pastEndBaseline,
                    "streaming growth must never fire the past-end net"
                )
            }
        }
    }

    // A positive-start tail with room for more rows admits one optional older
    // page inside the opaque opening. A Gateway that never answers it must
    // leave the opening on the usable tail within that page's bound, not fail
    // the conversation at the opening's outer deadline.
    @Test("an unanswered optional history page falls back to the usable tail")
    func unansweredOptionalHistoryPageOpensOnTail() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            let history = ProfileTranscript.history(seed: 7_401, items: 60)
            let snapshot = try ProfileTranscript.snapshot(seed: 7_401, items: history, priorItems: 40)
            try await withHarness(
                snapshot: snapshot, enablesComposerSubmission: true, usesRealOpening: true,
                unansweredRPCMethods: ["session.transcript"]
            ) { harness in
                let start = ContinuousClock.now
                _ = try await harness.recorder.waitUntil { $0.observation.isReady }
                #expect(ContinuousClock.now - start < ChatTranscriptPageRequest.optionalOpeningPageDeadline + .seconds(4))
                #expect(harness.rpcMethods.contains("session.transcript"))
                #expect(abs(try harness.nativeTranscriptSignedTailError()) <= 2)
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
                let pastEndBaseline = ready.observation.pastEndRepairCommandCount
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
                #expect(
                    settled.observation.pastEndRepairCommandCount == pastEndBaseline,
                    "the send choreography must never fire the past-end net"
                )
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
                let pastEndBaseline = ready.observation.pastEndRepairCommandCount
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
                #expect(
                    settled.observation.pastEndRepairCommandCount == pastEndBaseline,
                    "a resumed send across keyboard resize must never fire the past-end net"
                )
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

    // Stage 3 diagnostic fixture for the 2026-09-25 LazyVStack estimate
    // blow-up. That export resumed 177 canonical rows with a 17,371 pt content
    // estimate and an ~80,870 pt settled content, then jumped to 185,852 pt
    // about 3 ms after the send's changed physical spine installed, and
    // collapsed in multi-thousand-point steps under a pinned offset until the
    // reader saw a blank viewport.
    //
    // This fixture keeps the two structural ingredients that make such an
    // estimate possible: a realized tail of one-line rows, and unmeasured rows
    // near the end that render many screens tall. It then runs an ordinary send
    // across a keyboard-sized viewport transition, which is the one display
    // window that dismisses the keyboard, collapses the composer, applies the
    // tail-materialization `scrollTo(id:anchor:.bottom)`, and installs the
    // changed spine together.
    //
    // Measured here, SwiftUI re-derives the LazyVStack estimate from the rows it
    // has mounted when the container/inset changes, and not from the spine
    // install or the materialization target: this history reports ~9,000-12,900
    // pt while pinned at the full-height viewport, ~27,900 pt after the keyboard
    // contraction, and the identical send with no container change leaves the
    // estimate alone. The incident's 2.3x overshoot under a held offset did not
    // reproduce in the hosted harness, so this fixture protects the product
    // invariant instead: the pinned transcript still settles on its native tail.
    @Test("an ordinary send over a mixed-height lazy history settles on its native tail")
    func mixedHeightLazyHistorySendSettlesOnNativeTail() async throws {
        try await withTestWatchdog(timeout: .seconds(30)) {
            var snapshot = try SessionScenarioBuilder(seed: 1_266)
                .openingTail(targetEncodedBytes: 10_000)
            snapshot.acceptsQueuedPrompts = false
            snapshot.transcript = try (0..<172).map { index in
                try harnessRichAssistantMessage(
                    id: "tall-history-\(index)",
                    presentationID: "tall-history-turn-\(index)",
                    thinkingLines: [],
                    text: harnessTallTailHistoryRowText(index)
                )
            }
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = snapshot.transcript.count
            try await withHarness(snapshot: snapshot, enablesComposerSubmission: true) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeRows.contains {
                        $0.semanticID == "tall-history-turn-171" && $0.isVisible
                    }
                }
                let commandBaseline = ready.observation.tailMaterializationCommandCount
                let repairBaseline = ready.observation.pastEndRepairCommandCount
                // Keyboard-sized contraction, as while the reader is typing.
                harness.resize(height: 620)
                _ = try await harness.recorder.waitUntil {
                    $0.observation.geometry.containerHeight
                        < ready.observation.geometry.containerHeight - 100
                }
                try harness.setComposerDraftText(
                    Array(repeating: "A tall-tail resumed prompt paragraph.", count: 48)
                        .joined(separator: " ")
                )
                harness.submitPrompt()
                // The send dismisses the keyboard and collapses the composer in
                // the same display window that applies the materialization.
                harness.resize(height: 844)
                for _ in 0..<120 { try await harness.driveFrameBoundary() }

                // The opening and contracted estimates this fixture measures stay
                // in the hosted recorder's bounded geometry trace; these are the
                // invariants, not the number.
                #expect(
                    harness.probeObservation.tailMaterializationCommandCount
                        == commandBaseline + 1
                )
                #expect(!harness.probeObservation.geometry.isPastBottomEdge)
                #expect(try harness.nativeTranscriptDistanceFromTail() <= 2)
                #expect(
                    harness.probeObservation.pastEndRepairCommandCount == repairBaseline,
                    "a healthy tall-history send must never fire the past-end net"
                )
            }
        }
    }

    // CT-2 baseline measurement fixtures. These are the blank-transcript
    // investigation's hosted reproduction fixtures, ported as measurements
    // rather than pass/fail gates: each drives one shape, prints one
    // `CT2-METRICS` line and asserts only that the scenario ran. The blank
    // recovery, the mounted-row ledger and the gap sampler that branch added
    // alongside them are not ported — this plan deletes compensations rather
    // than adding them, and the question these fixtures answer is how wrong the
    // lazy estimate gets and how often a pinned viewport is left with no
    // realized row on screen.
    //
    // Both shapes start from the plan's context: an assistant message renders as
    // one physical row however long it is, and a `LazyVStack` derives its content
    // estimate from the height of the rows it has placed, so a tall row near the
    // tail is what makes the estimate swing when the container changes. One shape
    // applies a single keyboard contraction, send and dismissal to a history
    // whose tail holds many tall replies; the other repeats keyboard up/down
    // cycles with sends.
    //
    // The metric line is one space-separated `key=value` set so repeated runs
    // diff cleanly. Fields:
    // - `blankBoundaries=<blank>/<samples>` and `blankAfterSettle`: sampled
    //   display boundaries whose native viewport intersects no mounted transcript
    //   row, and the same excluding the first two boundaries of each phase, where
    //   the transition is still landing. The row set is read from the row hosts
    //   in the live hierarchy, so a row that unmounted cannot be counted.
    // - `longestBlankRun` and `blankPhases`: the longest consecutive blank run,
    //   and which phases (`p<index>:<blank count>`) held any blank at all.
    // - `maxEstimateRatio`: the estimate's swing, the largest published content
    //   estimate over the smallest (max/min), i.e. how far the lazy stack's own
    //   estimate moved during the journey. It is not a truth ratio: the harness
    //   has no independent measurement of the whole history's realized height —
    //   a lazy stack never realizes all of it, and the offsets of the rows it
    //   does place are themselves estimate-derived — so this is the estimate's
    //   own excursion, with `estimateOpen`/`Min`/`Max` carrying the raw points.
    // - `reDerivations`/`maxReDerivation`: content-estimate changes of at least
    //   1,000 pt between consecutive callbacks, and the largest of them, read
    //   from the probe's geometry trace (the only place a re-derivation inside one
    //   frame is visible).
    // - `tailDisplacements`: `chat.tail.first-displacement` diagnostics traced
    //   during the journey; `repairCommands` the commands by origin, with
    //   `pastEndRepairs` repeated on its own.
    // - `traceCoverage`: whether the two bounded buffers those counts are read
    //   from were full when the journey ended — the probe's geometry trace keeps
    //   its last 240 samples and the chat trace ring its last 256 records, each
    //   with its own eviction order. `saturated` means the buffer may have
    //   evicted records this journey counted, so `reDerivations` and
    //   `tailDisplacements` are lower bounds then; `complete` means neither
    //   buffer was full.
    // - `pastBottomBoundaries`, `tallRowHeight`, `tailErrorSettled`: sampled
    //   boundaries whose offset was past the legal content bottom, the tall
    //   row's measured frame height, and the native signed offset error against
    //   the legal bottom at the end of the journey.
    //
    // Each invocation runs one journey of each shape, so the line carries no run
    // number: the plan rule's repeated runs are repeated invocations, named by
    // the runner's own run directory.

    @Test("CT-2 baseline: many tall replies measure the blank boundaries and estimate swing", .enabled(if: UIValidationTier.isActive))
    func ct2ManyTallRepliesMetrics() async throws {
        try await withTestWatchdog(timeout: .seconds(60)) {
            // 140 rows, the last eight of them ~1,300 pt tall: the incident's
            // largest estimate excursion was the row count times one tall row's
            // measured height, a re-derivation that measured only the tall row.
            let rowCount = 140
            let tallRowIndices = Set((rowCount - 8)..<rowCount)
            let terminalSemanticID = "ct2-turn-\(rowCount - 1)"
            var snapshot = try SessionScenarioBuilder(seed: 1_268)
                .openingTail(targetEncodedBytes: 10_000)
            snapshot.acceptsQueuedPrompts = false
            snapshot.transcript = try (0..<rowCount).map { index in
                try harnessRichAssistantMessage(
                    id: "ct2-history-\(index)",
                    presentationID: "ct2-turn-\(index)",
                    thinkingLines: [],
                    text: tallRowIndices.contains(index)
                        ? harnessTallEstimateRowText(index)
                        : "Short history row \(index) stays one line."
                )
            }
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = snapshot.transcript.count
            try await withHarness(snapshot: snapshot, enablesComposerSubmission: true) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeRows.contains {
                        $0.semanticID == terminalSemanticID && $0.isVisible
                    }
                }
                // Phases, in order: settle the opened history the way a resumed
                // conversation has by the time the reader types, the
                // keyboard-sized contraction, the send's materialization, and the
                // dismissal that lands in one display window with it.
                let phaseLengths = [16, 12, 12, 32]
                let baselines = (materializations: ready.observation.tailMaterializationCommandCount,
                                 physicalRepairs: ready.observation.physicalTailRepairCommandCount,
                                 pastEndRepairs: ready.observation.pastEndRepairCommandCount,
                                 displacements: harness.tailDisplacementRecordCount)
                let traceFrame = (harness.probeObservation.geometryTrace.last?.frame ?? 0) + 1
                var samples: [CT2BoundarySample] = []
                let measurePhase: @MainActor (Int) async throws -> Void = { length in
                    for _ in 0..<length {
                        try await harness.driveFrameBoundary()
                        try samples.append(harness.ct2BoundarySample(tallSemanticID: terminalSemanticID))
                    }
                }
                try await measurePhase(phaseLengths[0])
                let openingSample = try #require(samples.last)
                harness.resize(height: 620)
                try await measurePhase(phaseLengths[1])
                try harness.setComposerDraftText("Keep this resumed conversation stable.")
                harness.submitPrompt()
                try await measurePhase(phaseLengths[2])
                harness.resize(height: 844)
                try await measurePhase(phaseLengths[3])

                let metrics = try ct2Metrics(
                    shape: "many-tall-replies", harness: harness, samples: samples,
                    phaseLengths: phaseLengths, baselines: baselines, traceFrame: traceFrame,
                    estimateOpen: openingSample.contentHeight,
                    tallRowHeight: openingSample.tallRowFrame?.height ?? 0
                )
                print(metrics.line)
                #expect(
                    samples.count == phaseLengths.reduce(0, +),
                    "the scenario ran every sampled display boundary"
                )
                #expect(
                    metrics.tallRowHeight > 1_000,
                    "the shape's tall row was realized and measured as the estimate-stressing row"
                )
                #expect(metrics.materializations > 0, "the send materialized its tail")
            }
        }
    }

    // The second shape drives the reader's actual journey instead of one send:
    // repeated keyboard up/down cycles, each submitting a prompt before the
    // keyboard dismisses. The first recorded baseline materialized one tail for
    // three submissions, because the journey never acknowledged its first send:
    // `ComposerDraftCoordinator` holds an admitted submission until an
    // authoritative snapshot publishes its canonical user row, and refuses the
    // next prompt meanwhile (`submission_in_progress`), so only the first send
    // reached the transcript (plan CT-10). The journey now installs that
    // canonical row after each cycle, the way a Gateway publishes it, so every
    // cycle's send is admitted. The single-send shape settles against the same
    // estimate; this one measures whether the pinned viewport is ever left with
    // no realized row on screen once each transition has landed.
    //
    // Measured on the branch that reproduced the 2026-09-26 blank, before any
    // recovery existed, over eight cycles of 20/20/60 boundaries: 240-280 of 600
    // sampled boundaries blank, every blank beginning at a phase boundary and
    // persisting for that whole phase. This journey is three cycles at
    // 20/20/60 after a 40-boundary settle; if it records no blank on a given
    // baseline, the estimate still swings and the displacement warnings are
    // still traced, and the plan's numbers come from the first shape.
    @Test("CT-2 baseline: repeated keyboard and send cycles measure the realized rows left on screen", .enabled(if: UIValidationTier.isActive))
    func repeatedKeyboardAndSendCyclesKeepRealizedRowsOnScreen() async throws {
        try await withTestWatchdog(timeout: .seconds(60)) {
            let rowCount = 140
            let tallRowIndex = rowCount - 2
            let terminalSemanticID = "tall-estimate-turn-\(rowCount - 1)"
            let tallSemanticID = "tall-estimate-turn-\(tallRowIndex)"
            let cycles = 3
            // A phase boundary is where the container changes, so the first two
            // boundaries of every phase are the transition still landing.
            let phaseLengths = [40] + Array(repeating: [20, 20, 60], count: cycles).flatMap { $0 }
            var snapshot = try SessionScenarioBuilder(seed: 1_268)
                .openingTail(targetEncodedBytes: 10_000)
            snapshot.acceptsQueuedPrompts = false
            snapshot.transcript = try (0..<rowCount).map { index in
                try harnessRichAssistantMessage(
                    id: "tall-estimate-history-\(index)",
                    presentationID: "tall-estimate-turn-\(index)",
                    thinkingLines: [],
                    text: index == tallRowIndex
                        ? harnessTallEstimateRowText(index)
                        : "Short history row \(index) stays one line."
                )
            }
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = snapshot.transcript.count
            let opened = snapshot
            try await withHarness(snapshot: opened, enablesComposerSubmission: true) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeRows.contains {
                        $0.semanticID == terminalSemanticID && $0.isVisible
                    }
                }
                let baselines = (materializations: ready.observation.tailMaterializationCommandCount,
                                 physicalRepairs: ready.observation.physicalTailRepairCommandCount,
                                 pastEndRepairs: ready.observation.pastEndRepairCommandCount,
                                 displacements: harness.tailDisplacementRecordCount)
                let traceFrame = (harness.probeObservation.geometryTrace.last?.frame ?? 0) + 1
                var samples: [CT2BoundarySample] = []
                let measurePhase: @MainActor (Int) async throws -> Void = { length in
                    for _ in 0..<length {
                        try await harness.driveFrameBoundary()
                        try samples.append(harness.ct2BoundarySample(tallSemanticID: tallSemanticID))
                    }
                }
                try await measurePhase(phaseLengths[0])
                let openingSample = try #require(samples.last)
                var acknowledged = opened
                for cycle in 0..<cycles {
                    harness.resize(height: 620)
                    try await measurePhase(phaseLengths[1])
                    try harness.setComposerDraftText("Keep this resumed conversation stable.")
                    harness.submitPrompt()
                    try await measurePhase(phaseLengths[2])
                    harness.resize(height: 844)
                    try await measurePhase(phaseLengths[3])
                    // The Gateway's canonical row for the prompt just sent, so
                    // the next cycle's submission is admitted.
                    acknowledged = try harnessAcknowledgedSnapshot(
                        acknowledged,
                        promptIndex: cycle,
                        text: "Keep this resumed conversation stable."
                    )
                    harness.replaceAuthoritativeSnapshot(acknowledged)
                }

                let metrics = try ct2Metrics(
                    shape: "keyboard-cycles-with-sends", harness: harness, samples: samples,
                    phaseLengths: phaseLengths, baselines: baselines, traceFrame: traceFrame,
                    estimateOpen: openingSample.contentHeight,
                    tallRowHeight: openingSample.tallRowFrame?.height ?? 0
                )
                print(metrics.line)
                #expect(
                    samples.count == phaseLengths.reduce(0, +),
                    "the scenario ran every sampled display boundary"
                )
                #expect(
                    metrics.materializations >= cycles,
                    "every cycle's admitted send materialized its tail"
                )
            }
        }
    }

    /// Assemble the CT-2 metric line for one journey. `baselines` are the
    /// observation's command counts and the trace's displacement count at the
    /// journey's start, and `traceFrame` the probe geometry trace's last frame
    /// then, so every counted command and estimate change belongs to the journey.
    private func ct2Metrics(
        shape: String,
        harness: ChatViewScrollHarness,
        samples: [CT2BoundarySample],
        phaseLengths: [Int],
        baselines: (materializations: Int, physicalRepairs: Int, pastEndRepairs: Int, displacements: Int),
        traceFrame: Int,
        estimateOpen: CGFloat,
        tallRowHeight: CGFloat
    ) throws -> CT2Metrics {
        let observation = harness.probeObservation
        let transitionTrace = observation.geometryTrace.filter { $0.frame >= traceFrame }
        let estimates = samples.map(\.contentHeight)
        let reDerivations = zip(transitionTrace, transitionTrace.dropFirst())
            .map { abs($1.contentHeight - $0.contentHeight) }
        let blankShape = ct2BlankShape(samples: samples, phaseLengths: phaseLengths)
        var metrics = CT2Metrics()
        metrics.shape = shape
        metrics.samples = samples.count
        metrics.blankBoundaries = blankShape.blank
        metrics.blankAfterSettle = blankShape.afterSettle
        metrics.longestBlankRun = blankShape.longestRun
        metrics.blankPhases = blankShape.phases
        metrics.estimateOpen = estimateOpen
        metrics.estimateMin = estimates.min() ?? 0
        metrics.estimateMax = estimates.max() ?? 0
        metrics.pastBottomBoundaries = samples.filter {
            $0.offsetY - max(0, $0.contentHeight + $0.bottomInset - $0.containerHeight) > 2
        }.count
        metrics.reDerivations = reDerivations.filter { $0 >= 1_000 }.count
        metrics.maxReDerivation = reDerivations.max() ?? 0
        metrics.tallRowHeight = tallRowHeight
        metrics.tailDisplacements = harness.tailDisplacementRecordCount - baselines.displacements
        metrics.materializations = observation.tailMaterializationCommandCount - baselines.materializations
        metrics.physicalRepairs = observation.physicalTailRepairCommandCount - baselines.physicalRepairs
        metrics.pastEndRepairs = observation.pastEndRepairCommandCount - baselines.pastEndRepairs
        metrics.tailErrorSettled = try harness.nativeTranscriptSignedTailError()
        metrics.traceCoverage = ct2TraceCoverage(harness: harness)
        return metrics
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
                let pastEndBaseline = ready.observation.pastEndRepairCommandCount
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
                // An ordinary prompt lifecycle row renders the same canonical
                // bubble, so it replaces atomically: one physical host, one
                // appearance, and no geometry step across the swap.
                #expect(ack.observation.physicalRowAppearanceCounts[outgoing.physicalID] == 1)
                #expect(ack.observation.physicalRowDisappearanceCounts[outgoing.physicalID, default: 0] == 0)
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
                print("Lifecycle→canonical atomic swap evidence: lifecycleHeight=\(lifecycleHeight), canonicalHeight=\(canonical.frame.height), maxRectStep=\(frameSteps.max() ?? 0), tailError=\(try harness.nativeTranscriptSignedTailError())")
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
                #expect(
                    settled.observation.pastEndRepairCommandCount == pastEndBaseline,
                    "an ordinary send over \(history) history must never fire the past-end net"
                )
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
                let covered = harness.renderedRevealGrid()
                try await DisplayFrameScheduler.displayLink.nextFrame()
                let coveredNextFrame = harness.renderedRevealGrid()
                #expect(harness.renderedPixelDistance(covered, coveredNextFrame) < 0.02)

                gate.release()
                var revealed: [Double] = []
                // The last sample is the settled render the reveal is measured
                // against, so only one distance is retained per sample.
                var settled = covered
                for _ in 0..<18 {
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                    settled = harness.renderedRevealGrid()
                    revealed.append(harness.renderedPixelDistance(covered, settled))
                }
                #expect(harness.probe.openingPhase?() == .ready)
                // How much of the settled render is on screen at each sample.
                // A per-pixel projection onto the settled frame measures
                // registration instead of progress: the entrance's own 8-point
                // rise moves the glyphs and drops that projection from 1 to
                // about 0, then restores it as they land, which is what made
                // this check flaky. The revealed content itself grows with the
                // fade, so that is what the reveal is monotonic in; the
                // tolerance covers the render's own sub-point settling noise.
                let progress = revealed.map { $0 / (revealed.last ?? 0) }
                #expect(revealed.count >= 3)
                #expect(zip(progress, progress.dropFirst()).allSatisfy { $1 + 0.06 >= $0 })
                #expect(harness.renderedPixelDistance(covered, settled) > 0.08)
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
                // Keep the mounted container and visible rect: a pinned
                // overshoot is the legal offset of a larger estimate still held
                // while the mounted rows report 100 pt less content. A synthetic
                // 400 pt container would instead displace the real tail marker by
                // the window's actual container height and let the marker-drift
                // repair — not this journey — write.
                let current = harness.probeObservation.geometry
                #expect(current.hasScrollableOverflow)
                let overshootOffset = max(
                    0, current.contentHeight + current.bottomInset - current.containerHeight
                )
                let overshoot = ChatTranscriptGeometry(
                    offsetY: overshootOffset,
                    contentHeight: current.contentHeight - 100,
                    containerHeight: current.containerHeight,
                    bottomInset: current.bottomInset,
                    visibleTopY: overshootOffset,
                    visibleBottomY: overshootOffset + current.containerHeight
                )
                let baseline = harness.probeObservation.scrollCommandCount
                let repairBaseline = harness.probeObservation.pastEndRepairCommandCount
                #expect(overshoot.isPastBottomEdge)
                #expect(overshoot.isPlausibleBottomRubberBand)
                #expect(!overshoot.isBeyondLegalContentBottom)
                harness.driveGeometry(previous: current, current: overshoot)
                try await harness.driveFrameBoundary()
                try await Task.sleep(for: .milliseconds(100))
                #expect(harness.probeObservation.scrollCommandCount == baseline)
                #expect(
                    harness.probeObservation.pastEndRepairCommandCount == repairBaseline,
                    "an in-tolerance pinned overshoot must never fire the past-end net"
                )
            }
        }
    }

    @Test("a sustained past-end pinned viewport returns to the tail through one disabled repair")
    func pastEndRepairReturnsToTail() async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            try await withHarness(seed: 1_195) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                let repairBaseline = harness.probeObservation.pastEndRepairCommandCount
                let commandBaseline = harness.probeObservation.scrollCommandCount
                // The harness cannot drag the real `UIScrollView` past its legal
                // bottom (`displaceNativeTranscriptFromTail` clamps to it), so
                // the collapse is injected as native geometry: the incident's
                // 2,128 pt offset past the legal content bottom, still pinned and
                // with no layout transaction in flight.
                let current = harness.probeObservation.geometry
                #expect(current.hasScrollableOverflow)
                let legalBottom = max(
                    0, current.contentHeight + current.bottomInset - current.containerHeight
                )
                let injectedOffset = legalBottom + 2_128
                let pastEnd = ChatTranscriptGeometry(
                    offsetY: injectedOffset,
                    contentHeight: current.contentHeight,
                    containerHeight: current.containerHeight,
                    bottomInset: current.bottomInset,
                    visibleTopY: injectedOffset,
                    visibleBottomY: injectedOffset + current.containerHeight
                )
                #expect(pastEnd.isBeyondLegalContentBottom)
                harness.driveGeometry(previous: current, current: pastEnd)

                // The condition must survive a presented frame before the one
                // correction is published and applied.
                for _ in 0..<30 where harness.probeObservation.pastEndRepairCommandCount == repairBaseline {
                    try await harness.driveFrameBoundary()
                }
                #expect(harness.probeObservation.pastEndRepairCommandCount == repairBaseline + 1)
                #expect(harness.probeObservation.scrollCommandCount == commandBaseline + 1)
                // The lease is released and native pinning owns the real tail.
                for _ in 0..<20 where try harness.nativeTranscriptDistanceFromTail() > 2 {
                    try await harness.driveFrameBoundary()
                    await Task.yield()
                }
                #expect(try harness.nativeTranscriptSignedTailError() <= 2)
                // One correction per installed layout epoch: a continuing
                // collapse that re-reports the same impossible viewport in that
                // epoch cannot issue a second command.
                for step in 1...6 {
                    let collapsed = ChatTranscriptGeometry(
                        offsetY: injectedOffset - Double(step),
                        contentHeight: pastEnd.contentHeight,
                        containerHeight: pastEnd.containerHeight,
                        bottomInset: pastEnd.bottomInset,
                        visibleTopY: injectedOffset - Double(step),
                        visibleBottomY: injectedOffset - Double(step) + pastEnd.containerHeight
                    )
                    harness.driveGeometry(previous: collapsed, current: collapsed)
                    try await harness.driveFrameBoundary()
                }
                #expect(harness.probeObservation.pastEndRepairCommandCount == repairBaseline + 1)
                #expect(harness.probeObservation.scrollCommandCount == commandBaseline + 1)
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
        unansweredRPCMethods: Set<String> = [],
        operation: @escaping @MainActor @Sendable (ChatViewScrollHarness) async throws -> Void
    ) async throws {
        let harness: ChatViewScrollHarness
        if enablesComposerSubmission {
            harness = try await ChatViewScrollHarness.composerSubmissionHarness(
                snapshot: snapshot,
                displayFrameScheduler: displayFrameScheduler,
                enablesPresentationCover: enablesPresentationCover,
                usesRealOpening: usesRealOpening,
                unansweredRPCMethods: unansweredRPCMethods
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

/// The operation identity the hosted composer send stub returns for every
/// submission (`composerSubmissionHarness`). An acknowledgement must carry it:
/// `ComposerDraftCoordinator` reconciles an admitted submission only against a
/// canonical user row whose `presentationId` is that operation ID.
let harnessHostedPromptOperationID = "hosted-prompt-operation"

/// The authoritative snapshot a Gateway publishes once it has accepted a
/// prompt: the canonical user row for that send. The CT-2 cycle shape installs
/// it after each send because an unacknowledged submission keeps
/// `ComposerDraftCoordinator` from admitting the next prompt
/// (`submission_in_progress`), which is why the first baseline materialized one
/// tail for three submissions.
private func harnessAcknowledgedSnapshot(
    _ snapshot: SessionSnapshot,
    promptIndex: Int,
    text: String
) throws -> SessionSnapshot {
    var acknowledged = snapshot
    acknowledged.transcript.append(try decodeTranscriptFixture(
        TranscriptItem.self,
        from: JSONSerialization.data(withJSONObject: [
            "id": "cycle-prompt-\(promptIndex)",
            "parentId": NSNull(),
            "presentationId": harnessHostedPromptOperationID,
            "timestamp": "2026-01-01T00:01:00Z",
            "kind": "message",
            "role": "user",
            "content": [[
                "id": "cycle-prompt-\(promptIndex)-text",
                "ordinal": 0,
                "type": "text",
                "text": text
            ]]
        ])
    ))
    acknowledged.transcriptTotal = acknowledged.transcript.count
    return acknowledged
}

/// Mixed-height lazy history for the tall-tailed send fixture: a realized tail
/// of one-line rows, with six rows near the end rendering many screens tall so
/// an estimate derived from the mounted rows can be wrong in both directions.
private func harnessTallTailHistoryRowText(_ index: Int) -> String {
    if (150...155).contains(index) {
        return Array(
            repeating: "Tall history row \(index) renders a body long enough to stand many screens above its neighbours.",
            count: 48
        ).joined(separator: "\n\n")
    }
    return "Short history row \(index) stays one line."
}

/// The ~1,300 pt assistant body the CT-2 shapes put beside the tail: 27 wrapped
/// paragraphs measure 1,286 pt on the owned simulator, which is the one row
/// whose measured height makes a `LazyVStack` re-derive its content estimate by
/// the whole row count when the container changes. Every other row is one line,
/// so the tall rows are the only structural difference from an ordinary history.
private func harnessTallEstimateRowText(_ index: Int) -> String {
    Array(
        repeating: "Tall history row \(index) renders a body long enough to stand one screen above its neighbours.",
        count: 27
    ).joined(separator: "\n\n")
}

/// One display boundary of a CT-2 shape, sampled directly from the native
/// transcript scroll view.
struct CT2BoundarySample {
    let contentHeight: CGFloat
    let offsetY: CGFloat
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    let visibleRowCount: Int
    let tallRowFrame: CGRect?
}

/// One `CT2-METRICS` line. The fields are the CT-2 baseline's shared
/// vocabulary across shapes, so a shape that cannot measure one reports zero
/// rather than dropping the key, and every line diffs against every other.
private struct CT2Metrics {
    var shape = ""
    var samples = 0
    var blankBoundaries = 0
    var blankAfterSettle = 0
    var longestBlankRun = 0
    var blankPhases = "none"
    var estimateOpen: CGFloat = 0
    var estimateMin: CGFloat = 0
    var estimateMax: CGFloat = 0
    var pastBottomBoundaries = 0
    var reDerivations = 0
    var maxReDerivation: CGFloat = 0
    var tallRowHeight: CGFloat = 0
    var tailDisplacements = 0
    var materializations = 0
    var physicalRepairs = 0
    var pastEndRepairs = 0
    var tailErrorSettled: CGFloat = 0
    var traceCoverage = "none"

    var maxEstimateRatio: CGFloat { estimateMin > 0 ? estimateMax / estimateMin : 0 }

    var line: String {
        "CT2-METRICS"
            + " shape=\(shape) samples=\(samples)"
            + " blankBoundaries=\(blankBoundaries)/\(samples)"
            + " blankAfterSettle=\(blankAfterSettle)"
            + " longestBlankRun=\(longestBlankRun)"
            + " blankPhases=\(blankPhases)"
            + " maxEstimateRatio=\(ct2Number(maxEstimateRatio))"
            + " estimateOpen=\(ct2Number(estimateOpen))"
            + " estimateMin=\(ct2Number(estimateMin))"
            + " estimateMax=\(ct2Number(estimateMax))"
            + " pastBottomBoundaries=\(pastBottomBoundaries)"
            + " reDerivations=\(reDerivations)"
            + " maxReDerivation=\(ct2Number(maxReDerivation))"
            + " tallRowHeight=\(ct2Number(tallRowHeight))"
            + " tailDisplacements=\(tailDisplacements)"
            + " repairCommands=materialize:\(materializations),physical:\(physicalRepairs),pastEnd:\(pastEndRepairs)"
            + " pastEndRepairs=\(pastEndRepairs)"
            + " tailErrorSettled=\(ct2Number(tailErrorSettled))"
            + " traceCoverage=\(traceCoverage)"
    }
}

private func ct2Number(_ value: CGFloat) -> String {
    String(format: "%.1f", Double(value))
}

/// Whether the two bounded buffers the journey's counts are read from were full
/// when it ended. `reDerivations` is derived from the probe's geometry trace,
/// which keeps its last 240 samples (`ChatHostedProbe.recordGeometryTrace`),
/// and `tailDisplacements` from the chat trace ring, which keeps its last
/// `ChatInteractionTrace.maximumRecords` (256) records with its own eviction
/// order. A saturated buffer may have evicted records this journey counted, so
/// the line labels those two counts as lower bounds instead of reporting them
/// as complete.
@MainActor
private func ct2TraceCoverage(harness: ChatViewScrollHarness) -> String {
    let geometryTraceBound = 240
    let geometrySaturated = harness.probeObservation.geometryTrace.count >= geometryTraceBound
    let chatSaturated = harness.traceRecords.count >= ChatInteractionTrace.maximumRecords
    return "geometry:\(geometrySaturated ? "saturated" : "complete")"
        + ",chat:\(chatSaturated ? "saturated" : "complete")"
}

/// The blank-boundary shape of one planned sample sequence: how many sampled
/// display boundaries showed no mounted transcript row, how many of those
/// survived the settling bound, the longest consecutive blank run, and which
/// phases (`p<index>:<blank count>`) held any blank at all. `phaseLengths`
/// describes the sampled sequence in order, so a phase's first boundaries are
/// the ones where its transition is still landing.
private func ct2BlankShape(
    samples: [CT2BoundarySample],
    phaseLengths: [Int],
    settlingBoundaries: Int = 2
) -> (blank: Int, afterSettle: Int, longestRun: Int, phases: String) {
    var blank = 0
    var afterSettle = 0
    var longestRun = 0
    var currentRun = 0
    var phases: [String] = []
    var index = 0
    for (phase, length) in phaseLengths.enumerated() {
        var phaseBlanks = 0
        for offset in 0..<length where index < samples.count {
            let isBlank = samples[index].visibleRowCount == 0
            index += 1
            guard isBlank else {
                currentRun = 0
                continue
            }
            blank += 1
            phaseBlanks += 1
            currentRun += 1
            longestRun = max(longestRun, currentRun)
            if offset >= settlingBoundaries { afterSettle += 1 }
        }
        if phaseBlanks > 0 { phases.append("p\(phase):\(phaseBlanks)") }
    }
    return (blank, afterSettle, longestRun, phases.isEmpty ? "none" : phases.joined(separator: ","))
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

func harnessRuntimeTool(
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

func harnessAssistantMessage(
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

func harnessRichAssistantMessage(
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

func harnessMessage(id: String) throws -> TranscriptItem {
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
        usesRealOpening: Bool = false,
        unansweredRPCMethods: Set<String> = []
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
            if usesRealOpening { await harness.startRPCResponder(unansweredMethods: unansweredRPCMethods) }
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
            _, _, _, _, _ in harnessHostedPromptOperationID
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

    /// A method in `unansweredMethods` is received and never answered, like a
    /// stalled Gateway request.
    private func startRPCResponder(unansweredMethods: Set<String>) async {
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
                    if unansweredMethods.contains(method) { continue }
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

    /// `chat.tail.first-displacement` diagnostics seen so far. The incident's
    /// trace ring held 99 of them and evicted the geometry records they shared
    /// the ring with, so the CT-2 fixtures count them explicitly.
    var tailDisplacementRecordCount: Int {
        traceRecords.count { "\($0.record.event)".contains("first-displacement") }
    }

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

    /// One display boundary of a CT-2 shape, sampled directly from the native
    /// transcript scroll view: the content estimate the lazy stack publishes,
    /// the native offset, container and bottom inset, and the mounted row hosts
    /// with their native visibility. Native rows come from the live hierarchy
    /// and exclude markers whose view has no window, so a row that unmounted
    /// cannot be counted as visible.
    func ct2BoundarySample(tallSemanticID: String) throws -> CT2BoundarySample {
        let scrollView = try nativeTranscriptScrollView()
        let rows = Self.nativeRows(in: hostingController.view)
        return CT2BoundarySample(
            contentHeight: scrollView.contentSize.height,
            offsetY: scrollView.contentOffset.y,
            containerHeight: scrollView.bounds.height,
            bottomInset: scrollView.adjustedContentInset.bottom,
            visibleRowCount: rows.filter(\.isVisible).count,
            tallRowFrame: rows.first { $0.semanticID == tallSemanticID }?.frame
        )
    }

    func nativeTranscriptDistanceFromTail() throws -> CGFloat {
        abs(try nativeTranscriptSignedTailError())
    }

    /// Round the transcript's native offset to a whole point. The parity gate
    /// compares rendered pixels, and the lazy stack's settled offset moves by a
    /// fraction of a point run to run, which at 1x rendering re-rasterizes every
    /// glyph and reads as a whole-frame difference unrelated to what the gate is
    /// about. Snapping first makes the rendered position a deterministic
    /// function of the layout instead of of the estimate; it changes no layout,
    /// row, or state the product owns.
    func snapNativeTranscriptOffsetToWholePoint() throws {
        let scrollView = try nativeTranscriptScrollView()
        let snapped = scrollView.contentOffset.y.rounded()
        guard abs(snapped - scrollView.contentOffset.y) > 0.01 else { return }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: snapped),
            animated: false
        )
        scrollView.layoutIfNeeded()
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

    /// Luminance samples of the transcript, one per point, where the opening
    /// reveal is measured. Full resolution is what makes the measurement
    /// meaningful: the entrance rises the transcript while it fades, and a
    /// coarser grid aliases that rise into the sample set — moving the settled
    /// content by the entrance's 8 points changes the distance measured from a
    /// 12-point grid by up to 20 percent, while the one-point integral stays
    /// within 0.1 percent of itself.
    func renderedRevealGrid() -> [Double] {
        let bounds = hostingController.view.bounds
        // Skip the edges and the centered opening pulse, whose animation is not
        // part of the reveal being measured.
        let pulse = CGRect(x: bounds.midX - 48, y: bounds.midY - 48, width: 96, height: 96)
        return renderedLuminance(in: bounds.insetBy(dx: 8, dy: 24), step: 1, excluding: pulse)
    }

    /// The parity gate's rendered frame: the mean luminance per row and per
    /// column band of the transcript region, plus the PNG a recording run
    /// retains as its per-frame artifact.
    ///
    /// This capture is the gate's frame clock. The gate samples one frame per
    /// driven display boundary, so a capture that costs more than a display
    /// period makes the app skip the frames in between: a full-window capture at
    /// 1x was measured at about 110 ms (about 45 ms rendering, 45 ms flattening
    /// the pixels to luminance, 20 ms building the profiles), so a 280 ms
    /// entrance landed on two or three samples and most of its frames were never
    /// compared. Rendering the transcript below the navigation bar at half scale,
    /// and accumulating both profiles in one pass over the image's bytes, costs
    /// about a third of that, so the entrance's own frames are sampled. The
    /// artifact encoding is part of the capture in every mode, so a recording run
    /// and a verifying run sample the same instants; only writing it differs.
    ///
    /// The screen update is forced. A sample that reads the last committed state
    /// without forcing one shows the same picture for tens of boundaries while an
    /// entrance runs: the app commits its layer tree only a few times per
    /// transition, so a stale sample cannot carry the animation at all (measured
    /// on the recorded send scenario, whose captured frames were identical for
    /// runs of 20 to 37 boundaries). Forcing the update makes the frame carry the
    /// animation state the display is showing at that instant, which is what the
    /// gate compares.
    ///
    /// The region is the transcript: below the navigation bar (whose glass
    /// material re-renders with pixel noise unrelated to it, as the reveal oracle
    /// already assumes) and above the composer (whose own material and spring
    /// dominated the run-to-run difference of a frame that included it, at up to
    /// 0.06 against 0.015 for the transcript alone).
    func renderedParityFrame(
        scale: CGFloat,
        rowBandPixels: Int,
        columnBandPixels: Int,
        includingPNG: Bool
    ) -> ParityFrame {
        let view = hostingController.view!
        let top = min(Self.parityTopInset, view.bounds.height)
        let bottom = min(top + Self.parityBottomInset, view.bounds.height)
        let region = CGRect(
            x: 0,
            y: top,
            width: view.bounds.width,
            height: max(0, view.bounds.height - bottom)
        )
        let image = renderedImage(in: region, scale: scale, afterScreenUpdates: true)
        let empty = ParityFrame(width: 0, height: 0, rows: [], columns: [], png: nil)
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return empty }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let rowBands = max(1, (height + rowBandPixels - 1) / rowBandPixels)
        let columnBands = max(1, (width + columnBandPixels - 1) / columnBandPixels)
        var rowSums = [Int](repeating: 0, count: rowBands)
        var columnSums = [Int](repeating: 0, count: columnBands)
        for y in 0..<height {
            let line = y * cgImage.bytesPerRow
            let rowBand = y / rowBandPixels
            for x in 0..<width {
                let offset = line + x * bytesPerPixel
                let value = Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
                rowSums[rowBand] += value
                columnSums[x / columnBandPixels] += value
            }
        }
        func bands(_ sums: [Int], total: Int, step: Int, divisor: Int) -> [UInt8] {
            sums.enumerated().map { index, sum in
                let length = min(step, total - index * step)
                return UInt8(sum / (3 * length * divisor))
            }
        }
        return ParityFrame(
            width: width,
            height: height,
            rows: bands(rowSums, total: height, step: rowBandPixels, divisor: width),
            columns: bands(columnSums, total: width, step: columnBandPixels, divisor: height),
            png: includingPNG ? image.pngData() : nil
        )
    }

    struct ParityFrame {
        let width: Int
        let height: Int
        let rows: [UInt8]
        let columns: [UInt8]
        let png: Data?
    }

    /// The parity gate's rendered region: the transcript, below the navigation
    /// bar (whose glass material re-renders with pixel noise) and above the
    /// composer (whose own material and spring are not the transcript, and whose
    /// animated height was measured as the largest source of run-to-run
    /// difference in a frame). Both insets are fixed so a frame's region has the
    /// same shape whatever the composer is doing.
    private static let parityTopInset: CGFloat = 100
    private static let parityBottomInset: CGFloat = 200

    /// A region of the hosted window rendered from the current hierarchy,
    /// including any in-flight presentation values an entrance or size change is
    /// showing. `drawHierarchy` renders at the view's coordinates, so the context
    /// is translated by the region's origin.
    private func renderedImage(in region: CGRect, scale: CGFloat, afterScreenUpdates: Bool) -> UIImage {
        let view = hostingController.view!
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(
            bounds: CGRect(origin: .zero, size: region.size),
            format: format
        ).image { context in
            context.cgContext.translateBy(x: -region.minX, y: -region.minY)
            view.drawHierarchy(in: region, afterScreenUpdates: afterScreenUpdates)
        }
    }

    /// The hosted window rendered from the current hierarchy, including any
    /// in-flight presentation values an entrance or size change is showing.
    private func renderedWindowImage(scale: CGFloat = 1, afterScreenUpdates: Bool = true) -> UIImage {
        renderedImage(
            in: hostingController.view.bounds,
            scale: scale,
            afterScreenUpdates: afterScreenUpdates
        )
    }

    /// Average-channel luminance sampled every `step` points of `region`,
    /// rendered at 1x from the current hierarchy.
    private func renderedLuminance(in region: CGRect, step: Int, excluding hole: CGRect = .null) -> [Double] {
        let image = renderedWindowImage()
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
