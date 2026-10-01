import SwiftUI
import Testing
@testable import TronMobileCore
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
                let baselineClearance = try #require(harness.newestRowClearance())
                let initialHeight = ready.observation.geometry.containerHeight

                harness.resize(height: 620)
                _ = try await harness.recorder.waitUntil {
                    $0.observation.geometry.containerHeight < initialHeight - 100
                }
                for _ in 0..<20 where !harness.isPinnedToBottom() {
                    try await harness.driveFrameBoundary()
                    await Task.yield()
                }
                let shrunkenClearance = try #require(harness.newestRowClearance())
                // A contraction may not leave the newest row lower than the
                // baseline tail allows; the clearance is the visual gap to the
                // composer, so a smaller one means the row moved down.
                #expect(shrunkenClearance >= min(-2, baselineClearance - 2))

                harness.resize(height: 844)
                _ = try await harness.recorder.waitUntil {
                    abs($0.observation.geometry.containerHeight - initialHeight) <= 2
                }
                for _ in 0..<20 where !harness.isPinnedToBottom() {
                    try await harness.driveFrameBoundary()
                    await Task.yield()
                }
                let expandedClearance = try #require(harness.newestRowClearance())
                // Returning from a keyboard-sized contraction must restore the
                // same legal native tail instead of retaining the old viewport
                // delta as a new past-bottom blank gap.
                #expect(abs(expandedClearance - baselineClearance) <= 16)
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
                    $0.semanticID == harness.firstTranscriptID && $0.isOnScreen
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
                    $0.semanticID == harness.firstTranscriptID && $0.isOnScreen
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
                        $0.observation.isReady && !$0.nativeRows.filter(\.isOnScreen).isEmpty
                    }
                    let visibleBefore = ready.nativeRows.filter(\.isOnScreen)
                    let baselineIDs = visibleBefore.map { ($0.physicalID, $0.instance) }
                    let baselineClearance = try #require(harness.newestRowClearance())
                    var recovered = initial
                    recovered.revision += 1
                    recovered.eventSequence += 1
                    recovered.phase = .idle
                    harness.replaceAuthoritativeSnapshot(recovered)
                    let resumed = try await harness.recorder.waitUntil {
                        $0.observation.projectionInstallCount > ready.observation.projectionInstallCount
                    }
                    for (physicalID, instance) in baselineIDs {
                        let rows = resumed.nativeRows.filter { $0.isOnScreen && $0.physicalID == physicalID }
                        #expect(rows.count == 1)
                        #expect(rows.first?.instance == instance)
                    }
                    #expect(abs(try #require(harness.newestRowClearance()) - baselineClearance) <= 16)
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
                    #expect(tail.isOnScreen)
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
                let pinnedGap = try #require(harness.newestRowClearance())
                #expect(abs(pinnedGap - 4) <= 0.5, "the 0122f8416 mounted gap measured 4 pt")
                #expect(harness.isPinnedToBottom())

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
                        $0.physicalID == "queued-message-queued-prompt-operation" && $0.isOnScreen
                    }
                }
                let queued = try #require(queuedSample.nativeRows.first {
                    $0.physicalID == "queued-message-queued-prompt-operation" && $0.isOnScreen
                })
                let region = harness.renderRegion(ofRow: queued)
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
                              $0.physicalID == queued.physicalID && $0.isOnScreen && $0.windowFrame.height > 1
                          }) else { continue }
                    if row.instance != queued.instance { sawOtherHost = true }
                    heights.append(row.windowFrame.height)
                    tailDistances.append(abs(harness.pinnedError() ?? .infinity))
                    guard samplesPixels else { continue }
                    // Sampled now, at this display boundary, not afterwards.
                    let pixels = harness.renderedRowLuminance(in: region)
                    let delta = zip(previousPixels, pixels).map { abs($1 - $0) }.reduce(0, +) / Double(max(1, pixels.count))
                    if delta > 0.5 { pixelChangingFrames += 1 }
                    previousPixels = pixels
                }
                #expect(!sawOtherHost)
                let finalHeight = try #require(heights.last)
                let totalChange = queued.windowFrame.height - finalHeight
                // The fixture's queued card is taller than its canonical row.
                #expect(totalChange > 8)
                // The card's own height animation displaces the newest row's
                // rendered bottom edge transiently (CT-20 measured 21.4 pt), so
                // the transient is measured, not asserted away; what must hold
                // is that the replacement returns to the pinned bottom.
                #expect(
                    harness.isPinnedToBottom(),
                    "the replacement returned to the pinned bottom: \(harness.pinnedDescription())"
                )
                if samplesPixels {
                    #expect(pixelChangingFrames >= 3)
                } else {
                    let steps = zip(heights, heights.dropFirst()).map { $0 - $1 }
                    #expect(steps.allSatisfy { $0 >= -0.5 }, "height must shrink monotonically: \(heights)")
                    #expect((steps.max() ?? 0) <= totalChange * 0.6, "height changed in one jump: \(heights)")
                    let intermediate = heights.filter { $0 < queued.windowFrame.height - 1 && $0 > finalHeight + 1 }
                    #expect(intermediate.count >= 3, "too few intermediate heights: \(heights)")
                }
                print("Queued→canonical evidence: queuedHeight=\(queued.windowFrame.height) finalHeight=\(finalHeight) heights=\(heights.map { Int($0.rounded()) }) maxTail=\(tailDistances.max() ?? 0) pixelChangingFrames=\(pixelChangingFrames)")
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
                    #expect(tail.isOnScreen)
                    #expect(clearance >= -2)
                    #expect(clearance <= 32)
                }
                #expect(harness.probeObservation.geometry.hasScrollableOverflow)
                #expect(crossedInsetBand)
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
                let pinnedGap = try #require(harness.newestRowClearance())
                #expect(abs(pinnedGap - 4) <= 0.5, "the 0122f8416 mounted gap measured 4 pt")
                #expect(harness.isPinnedToBottom())
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
                    $0.semanticID == harness.lastTranscriptID && $0.isOnScreen
                })
                let composerHeight = ready.observation.composerHeight
                let outgoingPrefix = "outgoing-submission:\(snapshot.sessionId):"

                try harness.setComposerDraftText(
                    "Keep the resumed transcript physically stable."
                )
                harness.submitPrompt()
                let stabilized = try await harness.recorder.waitUntil { sample in
                    sample.nativeRows.contains {
                        $0.physicalID.hasPrefix(outgoingPrefix) && $0.isOnScreen
                            && $0.isAtTailSpacing()
                    }
                }
                #expect(try harness.isAttachmentButtonEnabled())
                let outgoing = try #require(stabilized.nativeRows.first {
                    $0.physicalID.hasPrefix(outgoingPrefix) && $0.isOnScreen
                })
                let outgoingID = outgoing.physicalID
                // Observe subsequent presented geometry: origin anchoring
                // needs no app-issued target for this insertion.
                let settled = try await harness.recorder.waitUntil { sample in
                    sample.frameIndex > stabilized.frameIndex
                        && sample.nativeRows.contains {
                            $0.physicalID == outgoingID && $0.instance == outgoing.instance
                                && $0.isOnScreen && $0.isAtTailSpacing()
                        }
                }
                // The send's continuity is judged over the whole span from the
                // ready frame; a truncated recorder window would inspect only
                // its tail and pass.
                #expect(
                    harness.recorder.windowIsComplete(since: ready.frameIndex),
                    "the recorder retained every sample of the send"
                )
                let physicalPixel = 1 / max(1, harness.screenScale)
                let sendSamples = harness.recorder.samples.filter {
                    $0.frameIndex >= ready.frameIndex && $0.frameIndex <= settled.frameIndex
                }
                // Lazy contentSize/contentOffset can rebase together without
                // moving visible content. Measure the mounted prior row instead.
                let sendOffsets = sendSamples.compactMap { sample in
                    sample.nativeRows.first {
                        $0.physicalID == previousTail.physicalID && $0.isOnScreen
                    }?.windowFrame.maxY
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
                    sample.nativeRows.first { $0.physicalID == outgoingID && $0.isOnScreen }?.windowFrame.maxY
                }
                let deltas = zip(offsets, offsets.dropFirst()).map { $1 - $0 }
                    .filter { abs($0) > physicalPixel }
                let reversedDirection = deltas.contains(where: { $0 > 0 })
                    && deltas.contains(where: { $0 < 0 })
                #expect(!reversedDirection)
                #expect(samples.allSatisfy { sample in
                    sample.nativeRows.contains {
                        $0.physicalID == outgoingID && $0.instance == outgoing.instance && $0.isOnScreen
                            && $0.isAtTailSpacing()
                    }
                })
                #expect(settled.nativeRows.contains {
                    $0.physicalID == outgoingID && $0.instance == outgoing.instance && $0.isOnScreen
                        && $0.isAtTailSpacing()
                })
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
                _ = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeRows.contains {
                        $0.semanticID == "resumed-turn-95" && $0.isOnScreen
                    }
                }
                try harness.setComposerDraftText(String(repeating: "multiline resumed prompt ", count: 28))
                harness.submitPrompt()
                // Exercise both sides of the keyboard-sized viewport change
                // while the lazy history and outgoing row are settling.
                harness.resize(height: 620)
                harness.resize(height: 844)
                let sent = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains {
                        $0.physicalID.hasPrefix("outgoing-submission:") && $0.isOnScreen
                    }
                }
                let outgoing = try #require(sent.nativeRows.first {
                    $0.physicalID.hasPrefix("outgoing-submission:") && $0.isOnScreen
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
                    $0.nativeRows.contains { $0.semanticID == "resumed-canonical-prompt" && $0.isOnScreen }
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
                    $0.nativeRows.contains { $0.semanticID == "resumed-first-successor" && $0.isOnScreen }
                }
                for _ in 0..<80 { try await harness.driveFrameBoundary() }
                let settled = try #require(harness.recorder.samples.last)
                #expect(
                    harness.recorder.windowIsComplete(since: sent.frameIndex),
                    "the recorder retained every sample of the resumed send"
                )
                #expect(successor.nativeRows.contains {
                    $0.physicalID == outgoing.physicalID && $0.instance == outgoing.instance && $0.isOnScreen
                })
                let transitionSamples = harness.recorder.samples.filter {
                    $0.frameIndex >= sent.frameIndex && $0.frameIndex <= settled.frameIndex
                }
                #expect(!transitionSamples.isEmpty)
                #expect(transitionSamples.allSatisfy { sample in
                    sample.nativeRows.contains {
                        $0.physicalID == outgoing.physicalID && $0.instance == outgoing.instance && $0.isOnScreen
                    }
                })
                #expect(!harness.traceRecords.contains { $0.record.event == "chat.layout.abandoned" })
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
    // window that dismisses the keyboard, collapses the composer, and installs
    // the changed spine together under native origin anchoring.
    //
    // Measured here, SwiftUI re-derives the LazyVStack estimate from the rows it
    // has mounted when the container/inset changes, rather than from a row
    // target command: this history reports ~9,000-12,900
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
                        $0.semanticID == "tall-history-turn-171" && $0.isOnScreen
                    }
                }
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
                // The send dismisses the keyboard and collapses the composer;
                // the exact origin keeps the new physical prompt at the tail.
                harness.resize(height: 844)
                _ = try await harness.recorder.waitUntil { sample in
                    sample.nativeRows.contains {
                        $0.physicalID.hasPrefix("outgoing-submission:") && $0.isOnScreen
                            && $0.isAtTailSpacing()
                    }
                }
                #expect(!harness.probeObservation.geometry.isPastBottomEdge)
                #expect(harness.isPinnedToBottom())
            }
        }
    }

    @Test("a keyboard inset reserved at the transcript's far edge fails the composer gate")
    func keyboardInsetAtWrongEdgeFailsTheComposerGate() async throws {
        try await withTestWatchdog(timeout: .seconds(30)) {
            try await withHarness(seed: 1_272) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeSettledAtOrigin
                }
                let samples = try await harness.driveKeyboardInsetAtWrongEdge(.show())
                // The keyboard's own transition ran: the composer moved with its
                // inset, so what the gate rejects below is the inset's edge and
                // not a missing transition.
                let composerTops = samples.compactMap(\.composerTop)
                let composerTravel = (composerTops.min().flatMap { minimum in
                    composerTops.max().map { $0 - minimum }
                }) ?? 0
                #expect(
                    composerTravel > 200,
                    "the keyboard's own inset moved the composer \(ct2Number(composerTravel)) pt"
                )
                let settled = try #require(samples.last)
                let clearance = try #require(settled.clearance)
                #expect(
                    abs(clearance - TranscriptWindowOracle.tailSpacing) > 6,
                    "the wrong-edge inset's newest row settled \(ct2Number(clearance)) pt from the composer"
                )
                #expect(
                    !TranscriptWindowOracle.isPinned(
                        in: harness.visibleRootView, tolerance: TranscriptWindowOracle.profilingTolerance
                    ),
                    "the wrong-edge inset left the transcript pinned: \(harness.pinnedDescription())"
                )
            }
        }
    }

    // The origin-anchored transcript's one piece of chrome (CT-23 stage 2): the
    // automatic scroll edge effect at the pinned end.
    //
    // iOS 26 sizes that effect's band from the scroll view's own geometry, and
    // under the flip it makes the band the whole scroll view viewport instead of
    // the bar-sized one: measured 844 pt against 170.8 pt (106 pt with the hard
    // style) for every style, scroll position, content size and inset, with the
    // band's position (the visual top) unchanged. Drawn at that size it is a
    // whole-viewport wash — 0.105 of the parity gate's difference against 0.018
    // with it suppressed, and visible on the simulator's own screen — while the
    // chat's own top blur is unchanged by the flip and still owns the chrome.
    // So the origin-anchored path suppresses the pinned end's effect and today's
    // path must keep the effect it has always drawn: this is the test that fails
    // if the suppression is dropped or applied to the other path.
    @Test("only the origin-anchored transcript suppresses the pinned end's scroll edge effect")
    func originAnchoredTranscriptSuppressesPinnedEndScrollEdgeEffect() async throws {
        try await withTestWatchdog(timeout: .seconds(40)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_284)
                .openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, orientation: .newestAtOrigin) { harness in
                let scrollView = try harness.nativeTranscriptScrollViewForTesting()
                #expect(
                    scrollView.topEdgeEffect.isHidden,
                    "the origin-anchored transcript suppresses the pinned end's automatic effect"
                )
                #expect(
                    !scrollView.bottomEdgeEffect.isHidden,
                    "the origin-anchored transcript leaves the other edge's effect alone"
                )
            }
        }
    }

    // The window oracle's orientation read, as a failure mode: a container that
    // flips the scroll view *and* an ancestor renders upright, so the read has to
    // multiply the signs along the layer chain instead of stopping at the first
    // negative `m22`. Reading it as flipped would send `scrollReader`'s newest end
    // and every pinned check the wrong way on exactly that container.
    // MARK: CT-23 stage 4: accessibility, the status-bar tap and the context menu

    /// Why a context-menu preview is not the source lifted in place, or `nil`
    /// when it is.
    ///
    /// The preview is the source's own view, so its geometry is the source's own
    /// geometry: the transcript's flip and each row's counter-flip are ancestor
    /// render transforms, and a preview built from the source's own transform is
    /// upright by construction. A preview that carried the transcript's flip —
    /// the failure mode the origin-anchored transcript creates — would lift the
    /// bubble mirrored, and one built in the flipped container's coordinates
    /// would lift away from the finger.
    enum ContextMenuPreviewPlacement {
        static let tolerance: CGFloat = 0.5

        static func failure(
            sourceWindowFrame: CGRect,
            targetTransform: CGAffineTransform,
            containerCenterInWindow: CGPoint,
            previewSize: CGSize,
            containerRendersFlipped: Bool,
            previewViewRendersFlipped: Bool
        ) -> String? {
            guard targetTransform == .identity else {
                return "the preview target carries a transform \(targetTransform)"
            }
            guard !containerRendersFlipped else {
                return "the preview's container renders flipped"
            }
            guard !previewViewRendersFlipped else {
                return "the preview's view renders flipped"
            }
            let expected = CGPoint(x: sourceWindowFrame.midX, y: sourceWindowFrame.midY)
            guard abs(containerCenterInWindow.x - expected.x) <= tolerance,
                  abs(containerCenterInWindow.y - expected.y) <= tolerance else {
                return "the preview is centered at \(containerCenterInWindow), not over the source at \(expected)"
            }
            guard abs(previewSize.width - sourceWindowFrame.width) <= tolerance,
                  abs(previewSize.height - sourceWindowFrame.height) <= tolerance else {
                return "the preview is \(previewSize), not the source's \(sourceWindowFrame.size)"
            }
            return nil
        }
    }

    /// Why VoiceOver would not read the transcript's elements in the order the
    /// reader sees them, or `nil` when it would.
    ///
    /// VoiceOver reads a container's elements in the accessibility tree's own
    /// order, which follows the view order, and a sort priority sorts highest
    /// first within that container; equal priorities keep the tree order, which
    /// is what the product does without a priority at all. `priority` is what
    /// the orientation owner gives each content spine position.
    func voiceOverOrderFailure(
        orientation: ChatTranscriptOrientation,
        count: Int,
        priority: (Int) -> Double
    ) -> String? {
        let spinePositions = Array(0..<count)
        let ranked = spinePositions.sorted { lhs, rhs in
            let left = priority(lhs)
            let right = priority(rhs)
            if left != right { return left > right }
            return lhs < rhs
        }
        let expected = spinePositions
            .map { orientation.visualPosition(ofSpinePosition: $0, count: count) }
            .sorted()
        let actual = ranked.map { orientation.visualPosition(ofSpinePosition: $0, count: count) }
        guard actual != expected else { return nil }
        return "the accessibility order would be \(actual), not the visual order \(expected)"
    }

    @Test("the accessibility reading order puts the oldest row first on the origin-anchored transcript")
    func accessibilityReadingOrderFollowsTheVisualOrder() {
        let count = 24
        let orientation = ChatTranscriptOrientation.newestAtOrigin
        let failure = voiceOverOrderFailure(orientation: orientation, count: count) {
            orientation.voiceOverSortPriority(forSpinePosition: $0)
        }
        #expect(failure == nil, "\(orientation): \(failure ?? "")")
        // The failure mode the priority exists for: the same origin-anchored
        // transcript with no priority applied reads bottom-up, which is what the
        // tree order gives.
        let unprioritized = voiceOverOrderFailure(orientation: .newestAtOrigin, count: count) { _ in 0 }
        #expect(unprioritized != nil, "\(unprioritized ?? "")")
        // A reversed priority is not a fix for the surviving layout.
        let reversed = voiceOverOrderFailure(orientation: orientation, count: count) {
            Double(count - 1 - $0)
        }
        #expect(reversed != nil, "\(reversed ?? "")")
    }

    @Test("the context-menu preview gate fails a mirrored, displaced or resized preview")
    func contextMenuPreviewPlacementGateRejectsAMirroredPreview() {
        let source = CGRect(x: 40, y: 700, width: 231, height: 36)
        func failure(
            transform: CGAffineTransform = .identity,
            center: CGPoint = .zero,
            size: CGSize? = nil,
            containerFlipped: Bool = false,
            previewFlipped: Bool = false
        ) -> String? {
            ContextMenuPreviewPlacement.failure(
                sourceWindowFrame: source,
                targetTransform: transform,
                containerCenterInWindow: center == .zero ? CGPoint(x: source.midX, y: source.midY) : center,
                previewSize: size ?? source.size,
                containerRendersFlipped: containerFlipped,
                previewViewRendersFlipped: previewFlipped
            )
        }
        #expect(failure() == nil)
        #expect(failure(transform: CGAffineTransform(scaleX: 1, y: -1)) != nil, "the transcript's flip")
        #expect(failure(center: CGPoint(x: source.midX, y: source.midY - 1)) != nil, "one point away")
        #expect(failure(size: CGSize(width: source.width, height: source.height + 1)) != nil, "one point taller")
        #expect(failure(containerFlipped: true) != nil, "a flipped container")
        #expect(failure(previewFlipped: true) != nil, "a flipped preview view")
    }

    @Test("the prompt menu's preview is upright and in place on the origin-anchored transcript")
    func promptContextMenuPreviewIsUprightAndInPlace() async throws {
        let snapshots = [(ChatTranscriptOrientation.newestAtOrigin, try transcriptMenuSnapshot())]
        try await withTestWatchdog(timeout: .seconds(60)) {
            for (orientation, snapshot) in snapshots {
                try await withHarness(snapshot: snapshot, orientation: orientation) { harness in
                    let ready = try await harness.recorder.waitUntil {
                        $0.observation.isReady && $0.observation.visibleRowIDs.contains("transcript-bottom")
                    }
                    #expect(
                        ready.observation.visibleRowIDs.contains("menu-prompt"),
                        "\(orientation): the prompt row's menu surface must be mounted"
                    )
                    try await harness.driveFrameBoundary()
                    let scrollView = try harness.nativeTranscriptScrollViewForTesting()
                    #expect(
                        TranscriptWindowOracle.isFlipped(scrollView),
                        "\(orientation): the transcript must use its origin-anchored layout"
                    )
                    let surfaces = harness.promptContextMenuSurfaces()
                    #expect(!surfaces.isEmpty, "\(orientation): the production menu surface must be mounted")
                    for surface in surfaces {
                        let windowFrame = surface.view.convert(surface.view.bounds, to: nil)
                        let configuration = surface.owner.contextMenuInteraction(
                            surface.interaction,
                            configurationForMenuAtLocation: surface.view.convert(
                                CGPoint(x: windowFrame.midX, y: windowFrame.midY), from: nil
                            )
                        )
                        #expect(configuration != nil, "\(orientation): the menu must open over the prompt")
                        guard let configuration else { continue }
                        let identifier: any NSCopying = configuration.identifier ?? ("preview-gate" as NSString)
                        guard let preview = surface.owner.contextMenuInteraction(
                            surface.interaction, configuration: configuration,
                            highlightPreviewForItemWithIdentifier: identifier
                        ) else {
                            Issue.record("\(orientation): the production preview must exist")
                            continue
                        }
                        guard let container = preview.target.container as? UIView else {
                            Issue.record("\(orientation): the preview must name a container view")
                            continue
                        }
                        let failure = ContextMenuPreviewPlacement.failure(
                            sourceWindowFrame: windowFrame,
                            targetTransform: preview.target.transform,
                            containerCenterInWindow: container.convert(preview.target.center, to: nil),
                            previewSize: preview.view.bounds.size,
                            containerRendersFlipped: TranscriptWindowOracle.isFlipped(container),
                            previewViewRendersFlipped: TranscriptWindowOracle.isFlipped(preview.view)
                        )
                        #expect(failure == nil, "\(orientation): \(failure ?? "")")
                    }
                }
            }
        }
    }

    @Test("the display card's context menu resolves at the card on the origin-anchored transcript")
    func displayCardContextMenuResolvesAtTheCard() async throws {
        let snapshots = [(ChatTranscriptOrientation.newestAtOrigin, try transcriptMenuSnapshot())]
        try await withTestWatchdog(timeout: .seconds(60)) {
            for (orientation, snapshot) in snapshots {
                try await withHarness(snapshot: snapshot, orientation: orientation) { harness in
                    _ = try await harness.recorder.waitUntil {
                        $0.observation.isReady && $0.observation.visibleRowIDs.contains("transcript-bottom")
                    }
                    try await harness.driveFrameBoundary()
                    let sources = harness.promptContextMenuSurfaces().filter {
                        $0.owner.actions.contains { $0.id == .toolDetails }
                    }
                    #expect(sources.count == 1, "\(orientation): one mounted display source")
                    for source in sources {
                        let configuration = try #require(source.owner.contextMenuInteraction(source.interaction,
                            configurationForMenuAtLocation: CGPoint(x: source.view.bounds.midX, y: source.view.bounds.midY)))
                        let preview = try #require(source.owner.contextMenuInteraction(source.interaction,
                            configuration: configuration, highlightPreviewForItemWithIdentifier: "card" as NSString))
                        let container = try #require(preview.target.container as? UIView)
                        let failure = ContextMenuPreviewPlacement.failure(
                            sourceWindowFrame: source.view.convert(source.view.bounds, to: nil),
                            targetTransform: preview.target.transform,
                            containerCenterInWindow: container.convert(preview.target.center, to: nil),
                            previewSize: preview.view.bounds.size,
                            containerRendersFlipped: TranscriptWindowOracle.isFlipped(container),
                            previewViewRendersFlipped: TranscriptWindowOracle.isFlipped(preview.view)
                        )
                        #expect(failure == nil, "\(orientation): \(failure ?? "")")
                    }
                }
            }
        }
    }

    private func transcriptMenuSnapshot() throws -> SessionSnapshot {
        var snapshot = try harnessInlineMarkdownDisplaySnapshot()
        snapshot.transcript.append(try harnessUserMessage(id: "menu-prompt", text: "A prompt with a context menu."))
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = snapshot.transcript.count
        return snapshot
    }

    @Test("the origin flip is read through the complete layer chain")
    func originFlipIsReadThroughTheCompleteLayerChain() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let scrollView = UIScrollView(frame: root.bounds)
        root.addSubview(scrollView)
        #expect(!TranscriptWindowOracle.isFlipped(scrollView))
        // The flip CT-23 puts on the transcript's own scroll view.
        scrollView.layer.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1))
        #expect(TranscriptWindowOracle.isFlipped(scrollView))
        // The same flip on an ancestor instead.
        scrollView.layer.setAffineTransform(.identity)
        root.layer.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1))
        #expect(TranscriptWindowOracle.isFlipped(scrollView))
        // A flip on both layers renders the content upright: two flips are not a
        // flip.
        scrollView.layer.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1))
        #expect(!TranscriptWindowOracle.isFlipped(scrollView))
    }

    // The bottom-coverage gate's own failure modes, in isolation: it must not
    // pass a run that leaves the origin-pinned edge uncovered or a fixture that
    // stopped reproducing the blank.
    @Test("the bottom-coverage gate fails an uncovered bottom and a fixture that stopped reproducing")
    func transcriptBottomGateExpectations() {
        func coverage(
            blank: Bool, uncoveredBand: Bool, visibleRowFraction: CGFloat
        ) -> TranscriptBottomCoverage {
            TranscriptBottomCoverage(
                blank: blank, uncoveredBand: uncoveredBand,
                visibleRowFraction: visibleRowFraction, newestRowClearance: blank ? nil : 12
            )
        }
        func summary(_ samples: [TranscriptBottomCoverage]) -> TranscriptCoverageSummary {
            TranscriptCoverageSummary(samples: samples, phaseLengths: [samples.count])
        }
        let covered = coverage(blank: false, uncoveredBand: false, visibleRowFraction: 0.9)
        let blank = coverage(blank: true, uncoveredBand: true, visibleRowFraction: 0)
        // A partial blank: rows are on screen, the pinned bottom is not.
        let partial = coverage(blank: false, uncoveredBand: true, visibleRowFraction: 0.3)
        // A short transcript that leaves most of the viewport empty.
        let sparse = coverage(blank: false, uncoveredBand: false, visibleRowFraction: 0.2)

        // The origin-anchored transcript must keep each boundary covered and
        // at least half the visible transcript in rows.
        #expect(transcriptBottomGateOutcome(summary([covered, covered])) == .asExpected)
        #expect(
            transcriptBottomGateOutcome(summary([blank]))
                == .bottomUncovered(
                    blankBoundaries: 1, uncoveredBandBoundaries: 1, minimumVisibleRowFraction: 0
                )
        )
        #expect(
            transcriptBottomGateOutcome(summary([partial]))
                == .bottomUncovered(
                    blankBoundaries: 0, uncoveredBandBoundaries: 1, minimumVisibleRowFraction: 0.3
                )
        )
        #expect(
            transcriptBottomGateOutcome(summary([sparse]))
                == .bottomUncovered(
                    blankBoundaries: 0, uncoveredBandBoundaries: 0, minimumVisibleRowFraction: 0.2
                )
        )
    }

    // The window oracle's negative control. A flipped transcript whose rows are
    // not counter-flipped renders mirrored: the newest row is at the visual top
    // and the oldest loaded rows cover the composer edge. The scroll-space tail
    // measurement this oracle replaced reports that layout as perfectly aligned,
    // because the offset is still at the legal end of the estimated content —
    // which is exactly why a flipped transcript cannot be judged by it.
    @Test("a flipped transcript without counter-flipped rows fails the window oracle")
    func flippedTranscriptWithoutCounterFlippedRowsFailsTheOracle() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            try await withHarness(seed: 1_270) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeSettledAtOrigin
                }
                #expect(harness.isPinnedToBottom())
                #expect(ready.nativePinnedAtOrigin)
                #expect(
                    TranscriptWindowOracle.isPinned(
                        in: harness.visibleRootView, tolerance: TranscriptWindowOracle.profilingTolerance
                    )
                )
                try harness.flipNativeTranscriptWithoutCounterFlippingRows()
                try await harness.driveFrameBoundary()

                #expect(!harness.isPinnedToBottom())
                let pinnedError = try #require(harness.pinnedError())
                #expect(pinnedError > 40, "the newest row left the pinned bottom by \(pinnedError) pt")
                #expect(harness.recorder.samples.last?.nativePinnedAtOrigin == false)
                // The profiling scenarios' own decision, which ends a measured
                // window while the transcript may still be settling.
                #expect(
                    !TranscriptWindowOracle.isPinned(
                        in: harness.visibleRootView, tolerance: TranscriptWindowOracle.profilingTolerance
                    )
                )
            }
        }
    }

    enum SendHistory: CaseIterable, Sendable { case short, shortToOverflow, long }
    @Test("short and long history preserve the mounted prompt through acknowledgement and successor", arguments: SendHistory.allCases)
    func resumedSendAcknowledgementSuccessor(history: SendHistory) async throws {
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
                        $0.semanticID == "mixed-turn-\(historyCount - 1)" && $0.isOnScreen
                    }
                }
                let isShort = history != .long
                #expect(ready.observation.geometry.hasScrollableOverflow == !isShort)
                let text = history == .shortToOverflow
                    ? String(repeating: "A large outgoing prompt must cross the viewport without a forced offset. ", count: 40)
                    : "Keep this resumed conversation stable."
                try harness.setComposerDraftText(text)
                harness.submitPrompt()
                let sent = try await harness.recorder.waitUntil { sample in
                    sample.nativeRows.contains {
                        $0.physicalID.hasPrefix("outgoing-submission:") && $0.isOnScreen
                            && $0.isAtTailSpacing()
                    }
                }
                let outgoing = try #require(sent.nativeRows.first {
                    $0.physicalID.hasPrefix("outgoing-submission:") && $0.isOnScreen
                })
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
                    $0.nativeRows.contains { $0.semanticID == "canonical-prompt" && $0.isOnScreen }
                }
                let canonical = try #require(ack.nativeRows.first { $0.semanticID == "canonical-prompt" })
                #expect(canonical.physicalID == outgoing.physicalID)
                #expect(canonical.instance == outgoing.instance)
                #expect(abs(canonical.windowFrame.maxY - outgoing.windowFrame.maxY) <= 2)
                // An ordinary prompt lifecycle row renders the same canonical
                // bubble, so it replaces atomically: one physical host, one
                // appearance, and no geometry step across the swap.
                #expect(ack.observation.physicalRowAppearanceCounts[outgoing.physicalID] == 1)
                #expect(ack.observation.physicalRowDisappearanceCounts[outgoing.physicalID, default: 0] == 0)
                let lifecycleHeight = outgoing.windowFrame.height
                let lifecycleOrigin = outgoing.windowFrame.minY
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
                #expect(transitionRows.allSatisfy { abs($0.windowFrame.height - lifecycleHeight) <= 1 })
                #expect(transitionRows.allSatisfy { abs($0.windowFrame.minY - lifecycleOrigin) <= 1 })
                let frameSteps = zip(transitionRows, transitionRows.dropFirst()).map { old, new in
                    max(abs(new.windowFrame.minY - old.windowFrame.minY), abs(new.windowFrame.height - old.windowFrame.height))
                }
                #expect(frameSteps.allSatisfy { $0 <= 1 })
                print("Lifecycle→canonical atomic swap evidence: lifecycleHeight=\(lifecycleHeight), canonicalHeight=\(canonical.windowFrame.height), maxRectStep=\(frameSteps.max() ?? 0), tailClearance=\(harness.newestRowClearance().map(ct2Number) ?? "none")")
                #expect(harness.isPinnedToBottom())

                var response = acknowledged
                response.transcript.append(try harnessAssistantMessage(
                    id: "first-successor", presentationID: "first-successor", text: "The first response is now visible."
                ))
                response.transcriptTotal = response.transcript.count
                harness.replaceAuthoritativeSnapshot(response)
                _ = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains { $0.semanticID == "first-successor" && $0.isOnScreen }
                }
                // Observe actual display boundaries beyond the old one-second
                // fallback. No production delay or synthetic offset is injected.
                for _ in 0..<80 { try await harness.driveFrameBoundary() }
                let settled = try #require(harness.recorder.samples.last)
                let prompt = try #require(settled.nativeRows.first { $0.semanticID == "canonical-prompt" })
                #expect(prompt.isOnScreen)
                #expect(prompt.instance == outgoing.instance)
                #expect(settled.nativeRows.filter { $0.physicalID == outgoing.physicalID }.count == 1)
                let frames = harness.recorder.samples.filter { $0.frameIndex >= ack.frameIndex }
                #expect(frames.allSatisfy { sample in
                    sample.nativeRows.contains {
                        $0.physicalID == outgoing.physicalID && $0.instance == outgoing.instance && $0.isOnScreen
                    }
                })
                #expect(harness.isPinnedToBottom())
                let successor = try #require(settled.nativeRows.first { $0.semanticID == "first-successor" })
                #expect(try #require(successor.composerClearance) >= -2)
            }
        }
    }

    @Test("a real managed sheet freezes covered chat and uncovers to the latest native frame")
    func managedSheetFreezesCoveredChat() async throws {
        try await withTestWatchdog(timeout: .seconds(15)) {
            let snapshot = try SessionScenarioBuilder(seed: 1_229).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, enablesPresentationCover: true) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady && $0.nativeSettledAtOrigin }
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
                        && $0.nativeRows.contains { $0.semanticID == "covered-latest-3" && $0.isOnScreen }
                        && $0.nativePinnedAtOrigin
                }
                #expect(returned.observation.projectionInstallCount == frozen.projectionInstallCount + 1)
                #expect(harness.isPinnedToBottom())
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
                _ = try await harness.recorder.waitUntil { $0.observation.isReady && $0.nativeSettledAtOrigin }
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
                    $0.observation.isReady && $0.nativeSettledAtOrigin
                        && harness.probe.composerCatalogBuildCount >= buildsBefore + 1
                        && harness.probe.composerCatalogCommandNames == latest
                }
                #expect(harness.probe.composerCatalogBuildCount == buildsBefore + 1)
                #expect(harness.isPinnedToBottom())
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
                _ = try await harness.recorder.waitUntil { $0.observation.isReady && $0.nativeSettledAtOrigin }
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
                        $0.observation.isReady && $0.nativeSettledAtOrigin
                            && harness.probe.composerCatalogCommandNames == ["current"]
                    }
                    #expect(harness.selectedComposerResource == nil)
                    let draftAfter = try harness.composerTextAndSelection()
                    #expect(draftAfter.text == draftBefore.text)
                    #expect(draftAfter.selection == draftBefore.selection)
                    #expect(draftAfter.identity == draftBefore.identity)
                    #expect(harness.isPinnedToBottom())
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
                _ = try await harness.recorder.waitUntil { $0.observation.isReady && $0.nativeSettledAtOrigin }
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
                _ = try await harness.recorder.waitUntil { $0.observation.isReady && $0.nativeSettledAtOrigin }
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
                        && $0.nativePinnedAtOrigin
                }
                #expect(try harness.isAttachmentButtonEnabled())
                #expect(try harness.isNativeTranscriptInteractionEnabled())
                #expect(harness.isPinnedToBottom())
            }
        }
    }

    // F4: the opening reveal's direction. Flipping the transcript inverts any
    // offset applied outside a row's counter-flip, so the reveal's rise would
    // become a drop while every earlier check still passed (the reveal oracle is
    // deliberately insensitive to direction, and the parity gate cannot resolve a
    // sub-60 ms phase). The gate is the committed position of the newest row's
    // bottom edge, in window coordinates: layout-true, and the amplitude —
    // measured as the reveal's 8 pt step, 786.7 → 778.7 pt in every run. The
    // rendered pixels were measured for the same gate and rejected (CT-25 stage
    // B4): content realization moves the entering region's luminance centre 74 pt
    // over the same frames, so the 8 pt rise is invisible inside it, and the
    // send's 20 pt rise is never committed between display boundaries at all.
    @Test("the opening reveal moves the transcript upward")
    func hostedOpeningRevealRisesUpward() async throws {
        try await withTestWatchdog(timeout: .seconds(25)) { @MainActor in
            let gate = OpeningFrameGate()
            defer { gate.release() }
            let snapshot = try SessionScenarioBuilder(seed: 1_276)
                .openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, displayFrameScheduler: gate.scheduler,
                                  enablesPresentationCover: true, usesRealOpening: true) { harness in
                gate.condition = { harness.probe.openingPhase?() == .presenting }
                try await gate.waitUntilHeld()
                var edges: [CGFloat] = []
                gate.release()
                for _ in 0..<12 {
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                    if let edge = harness.transcriptBottom().newestRowBottomEdge {
                        edges.append(edge)
                    }
                }
                #expect(harness.probe.openingPhase?() == .ready)
                if let failure = OpeningRevealDirection.failure(edges: edges) {
                    Issue.record(Comment(rawValue: failure))
                }
                print("CT25-MOTION-OPENING edges=\(edges.map { String(format: "%.1f", Double($0)) })")
            }
        }
    }

    // The gate's own failure mode, in isolation: the reveal inverted. The
    // sequence the gate accepts (CT-25 stage B4's three runs) must pass, and the
    // same frames with the reveal inverted — the edge stepping *down* by the
    // lift, and never monotone upward — must fail. Three hosted runs of the
    // inverted product offset (both `.offset(y: 8)` modifiers negated, reverted
    // afterwards) failed at the watchdog instead: the inverted offsets leave the
    // opening unsettled, so the harness never samples and the assertions never
    // ran. This pins what those runs would have reported.
    @Test("the opening reveal's direction gate rejects a drop")
    func openingRevealDirectionGateRejectsADrop() {
        let risen: [CGFloat] = [
            786.7, 786.7, 786.7, 785.0, 781.6, 780.3, 779.1, 778.7, 778.7, 778.7, 778.7, 778.7,
        ]
        #expect(OpeningRevealDirection.failure(edges: risen) == nil)
        let dropped = Array(risen.reversed())
        #expect(
            OpeningRevealDirection.failure(edges: dropped) != nil,
            "the inverted reveal must fail the direction gate"
        )
        // The lift is the amplitude, so a reveal that does not move at all is not
        // a reveal either; and an empty sequence is not a measurement.
        #expect(OpeningRevealDirection.failure(edges: [778.7, 778.7, 778.7]) != nil)
        #expect(OpeningRevealDirection.failure(edges: []) != nil)
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
                #expect(ready.nativeRows.contains { $0.isOnScreen })
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
                try await harness.detachReaderByRealScroll()
                #expect(harness.probeObservation.isDetached)
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
        try await withTestWatchdog(timeout: .seconds(20)) { @MainActor in
            let gate = OpeningFrameGate()
            defer { gate.release() }
            let snapshot = try SessionScenarioBuilder(seed: 1_232).openingTail(targetEncodedBytes: 10_000)
            try await withHarness(snapshot: snapshot, displayFrameScheduler: gate.scheduler,
                                  enablesComposerSubmission: true, enablesPresentationCover: true,
                                  usesRealOpening: true) { harness in
                gate.condition = {
                    [.presented, .ready].contains(harness.probe.openingPhase?() ?? .opening)
                }
                try await gate.waitUntilHeld()
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
                gate.release()
                try await harness.waitForOpeningAttemptCompletion(1)
                #expect(harness.probe.readyPublicationCount == 0)
                harness.uploads.release()
                await upload.value
                #expect(harness.currentAttachments.map(\.gatewayUploadID) == ["fixture-upload-1"])
                harness.setCovered(false)
                try await harness.waitForCoverTransition(presented: false)
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeSettledAtOrigin
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
                #expect(harness.isPinnedToBottom())
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
                try await harness.detachReaderByRealScroll()
                #expect(harness.probeObservation.isDetached)
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
                let pinnedGap = try #require(harness.newestRowClearance())
                #expect(abs(pinnedGap - 4) <= 0.5, "the 0122f8416 mounted gap measured 4 pt")
                #expect(firstReady.nativePinnedAtOrigin)
                #expect(harness.isPinnedToBottom())
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
                    $0.nativeRows.contains { $0.semanticID == tailSemanticID && $0.isOnScreen }
                }
                let readyTail = try #require(readyWithNativeTail.nativeRows.first {
                    $0.semanticID == tailSemanticID && $0.isOnScreen
                })
                #expect(readyWithNativeTail.observation.installedProjectionRowCount == 72)
                #expect(readyTail.windowFrame.height > 0)
                #expect(readyWithNativeTail.observation.rowFrames[tailSemanticID]?.height ?? 0 > 0)
                try harness.scrollReader(byVisualPoints: 180)
                #expect(try #require(harness.pinnedError()) > 100)

                harness.drivePinnedPositionReapplication()
                let resumed = try await harness.recorder.waitUntil {
                    $0.frameIndex > ready.frameIndex
                        && $0.observation.isReady
                        && $0.observation.visibleRowIDs.contains(tailSemanticID)
                        && $0.nativeRows.contains { $0.semanticID == tailSemanticID && $0.isOnScreen }
                        && $0.observation.geometry.distanceFromBottom <= 2
                        && harness.isPinnedToBottom()
                }
                let resumedTail = try #require(resumed.nativeRows.first {
                    $0.semanticID == tailSemanticID && $0.isOnScreen
                })
                #expect(harness.isPinnedToBottom())
                #expect(resumedTail.windowFrame.height > 0)
                #expect(resumed.observation.rowFrames[tailSemanticID]?.height ?? 0 > 0)
                #expect(
                    harness.recorder.windowIsComplete(since: ready.frameIndex),
                    "the recorder retained every sample of the re-application"
                )
                #expect(!harness.recorder.samples.contains {
                    $0.frameIndex > ready.frameIndex && !$0.observation.isReady
                })
                #expect(
                    resumed.observation.smoothAutomaticScrollCommandCount
                        == ready.observation.smoothAutomaticScrollCommandCount
                )
                for _ in 0..<3 { try await harness.driveFrameBoundary() }
                let settled = harness.probeObservation
                #expect(settled.visibleRowIDs.contains(tailSemanticID))
                #expect(harness.recorder.samples.last?.nativePinnedAtOrigin == true)
                #expect(harness.isPinnedToBottom())
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

                // The native bottom is part of the wait: the coordinator's
                // semantic row set is retained across an install, while the row
                // hosts can be between layouts for a frame, and the assertion
                // below is about the native transcript.
                let revealed = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > installBaseline
                        && $0.observation.animatedEntranceCount == entranceBaseline + 1
                        && $0.observation.rowFrames["turn-agent"] != nil
                        && !$0.observation.visibleRowIDs.isEmpty
                        && $0.nativePinnedAtOrigin
                }
                #expect(revealed.observation.automaticScrollCommandCount == automaticScrollBaseline)
                #expect(revealed.observation.smoothAutomaticScrollCommandCount == smoothBaseline)
                #expect(revealed.observation.physicalRowAppearanceCounts["turn-agent"] == 1)
                #expect(revealed.nativePinnedAtOrigin, "the reveal's display frame: \(harness.pinnedDescription())")
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
                        && $0.nativePinnedAtOrigin
                }
                #expect(settled.observation.animatedEntranceCount == entranceBaseline + 1)
                #expect(settled.observation.physicalRowAppearanceCounts["turn-agent"] == 1)
                #expect((settled.observation.physicalRowDisappearanceCounts["turn-agent"] ?? 0) == 0)
                #expect(settled.nativePinnedAtOrigin, "the settled display frame: \(harness.pinnedDescription())")
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
                        && $0.nativePinnedAtOrigin
                }
                #expect(progress.observation.animatedEntranceCount >= entranceBaseline + 1)
                #expect(progress.nativePinnedAtOrigin, "the compacting display frame: \(harness.pinnedDescription())")
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
                        && !$0.observation.visibleRowIDs.isEmpty
                        && $0.nativePinnedAtOrigin
                }
                #expect(compactionSettled.observation.animatedEntranceCount
                    >= progress.observation.animatedEntranceCount)
                #expect(compactionSettled.nativePinnedAtOrigin, "the compacted display frame: \(harness.pinnedDescription())")
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
                        && $0.nativeRows.filter { $0.isOnScreen && $0.windowFrame.height > 20 }.count == 2
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
                        $0.semanticID == "first-reply" && $0.isOnScreen && $0.windowFrame.height > 20
                    } && $0.nativeRows.filter { $0.isOnScreen && $0.windowFrame.height > 20 }.count == 3
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
                            $0.semanticID == "tool-run-settled-group" && $0.isOnScreen
                        }
                }
                #expect(settled.observation.animatedEntranceCount == entranceBaseline + 1)
                #expect(settled.observation.smoothAutomaticScrollCommandCount == smoothBaseline)
                #expect(settled.observation.rowFrames["tool-run-settled-group"] != nil)
                #expect(settled.observation.physicalRowAppearanceCounts["tool-run-active-race"] == 1)
                let lifecycleSamples = settled.observation.toolChipSamples.filter {
                    $0.callIDs.contains("active-race")
                }
                #expect(lifecycleSamples.contains { $0.transitionToken == 1 })
                #expect(lifecycleSamples.last?.runID == "tool-run-settled-group")
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
                try await harness.detachReaderByRealScroll()
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

                try await harness.returnReaderToPinnedTailByCatchUp()
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
                try await harness.detachReaderByRealScroll()
                #expect(harness.probeObservation.isDetached)

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
                try await harness.returnReaderToPinnedTail()
                let reconciled = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount == installBaseline + 1
                }
                #expect(!reconciled.observation.isDetached)
                #expect(reconciled.observation.installedProjectionRowCount > 0)
            }
        }
    }

    // CT-23 P1-1: the catch-up's staged step is reflected back into the native
    // scroll coordinate before scrolling, so it remains near the newest row
    // instead of jumping thousands of points into loaded history.
    @Test("a staged catch-up lands at the newest end with origin anchoring")
    func stagedCatchUpLandsAtTheNewestEndWithOriginAnchoring() async throws {
        try await withTestWatchdog(timeout: .seconds(60)) {
            var snapshot = try SessionScenarioBuilder(seed: 1_231)
                .openingTail(targetEncodedBytes: 10_000)
            snapshot.acceptsQueuedPrompts = false
            snapshot.transcript = try (0..<60).map { index in
                try harnessRichAssistantMessage(
                    id: "catch-up-anchor-\(index)",
                    presentationID: "catch-up-anchor-turn-\(index)",
                    thinkingLines: [],
                    text: Array(
                        repeating: "Catch-up row \(index) keeps its own height while the reader is away.",
                        count: 1 + index % 4
                    ).joined(separator: "\n\n")
                )
            }
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = snapshot.transcript.count
            let newestRowID = "catch-up-anchor-turn-59"
            try await withHarness(snapshot: snapshot) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.isReady
                        && $0.observation.visibleRowIDs.contains(newestRowID)
                }
                try await harness.detachReaderMidHistory()
                #expect(
                    harness.probeObservation.isDetached,
                    "the real scroll detached the reader: \(harness.pinnedDescription())"
                )
                let commandBaseline = harness.probeObservation.scrollCommandCount
                harness.driveCatchUp(reduceMotion: false)
                var boundaries = 0
                var observedBoundaries = 0
                var boundariesWithoutTheNewestRow: [Int] = []
                var stagedOffset: CGFloat?
                while boundaries < 60 {
                    try await harness.driveFrameBoundary()
                    boundaries += 1
                    // The staged command is delivered on its own update pass;
                    // boundaries before it are the reader's own position, not
                    // the catch-up's.
                    guard harness.probeObservation.scrollCommandCount > commandBaseline else {
                        continue
                    }
                    observedBoundaries += 1
                    if stagedOffset == nil {
                        stagedOffset = try harness.nativeTranscriptScrollViewForTesting()
                            .contentOffset.y
                    }
                    if !harness.probeObservation.visibleRowIDs.contains(newestRowID) {
                        boundariesWithoutTheNewestRow.append(boundaries)
                    }
                    if !harness.probeObservation.isDetached, harness.isPinnedToBottom() { break }
                }
                let settled = try await harness.newestRowSettledAtComposer(boundaries: 120)
                let clearance = try #require(
                    settled.clearance,
                    "the catch-up settled with no newest row: \(harness.pinnedDescription())"
                )
                #expect(observedBoundaries > 0, "the catch-up issued no scroll command")
                // The staged step's own landing: the staged point the coordinator
                // computes is a point near the newest end, and on the
                // origin-anchored path it only *is* one once the owner has mapped
                // it back to the scroll view's own offset. Unmapped, the same
                // point is thousands of points into the oldest history, which the
                // smooth second step then animates back.
                let newestEnd = try harness.nativeNewestEndOffset()
                let staged = try #require(stagedOffset, "the staged step measured no offset")
                let viewport = try harness.nativeTranscriptScrollViewForTesting().bounds.height
                #expect(
                    abs(staged - newestEnd) <= viewport,
                    "the staged step landed \(ct2Number(abs(staged - newestEnd))) pt from the newest end"
                )
                #expect(
                    boundariesWithoutTheNewestRow.isEmpty,
                    "the catch-up left the reader's newest row off screen at \(boundariesWithoutTheNewestRow.count) of \(observedBoundaries) boundaries: \(boundariesWithoutTheNewestRow)"
                )
                #expect(
                    !harness.probeObservation.isDetached,
                    "the catch-up returned to a pinned viewport: \(harness.pinnedDescription())"
                )
                // The newest row settles with the shared 12 pt marker-owned
                // gap, independent of row identity or opening state.
                #expect(
                    harness.isPinnedToBottom(),
                    "the caught-up transcript settled \(ct2Number(clearance)) pt from the composer: \(harness.pinnedDescription())"
                )
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
                try await harness.detachReaderByRealScroll()
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

                try await harness.returnReaderToPinnedTail()
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
                try await harness.detachReaderByRealScroll()
                try #require(
                    harness.probeObservation.isDetached,
                    "the real scroll must detach before streaming updates"
                )

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

                try await harness.returnReaderToPinnedTailByCatchUp()
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

    @Test("a detached reader holds its top row through streaming, a keyboard cycle and a page load")
    func detachedReaderHoldsItsTopRowThroughStreamingKeyboardAndPage() async throws {
        try await withTestWatchdog(timeout: .seconds(60)) {
            // A 60-row mixed-height history with 40 earlier messages loaded
            // before it, so the reader's oldest end is real history rather than
            // the top of a short transcript, and a page load has somewhere to go.
            var snapshot = try SessionScenarioBuilder(seed: 1_273)
                .openingTail(targetEncodedBytes: 10_000)
            snapshot.acceptsQueuedPrompts = false
            snapshot.transcript = try (0..<60).map { index in
                try harnessRichAssistantMessage(
                    id: "detach-anchor-\(index)",
                    presentationID: "detach-anchor-turn-\(index)",
                    thinkingLines: [],
                    text: Array(
                        repeating: "Detached reader row \(index) keeps its own height while the reader is away.",
                        count: 1 + index % 4
                    ).joined(separator: "\n\n")
                )
            }
            snapshot.transcriptStart = 40
            snapshot.transcriptTotal = 100
            try await withHarness(snapshot: snapshot) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.observation.projectionInstallCount >= 1
                }
                // Mid-history, not at the oldest end: the status-bar detach sits
                // at the content's far edge, where streaming, the keyboard and a
                // page load could not move the anchor even if the invariant were
                // broken. 1.5 viewports up is a reader who is actually reading.
                try await harness.detachReaderMidHistory()
                #expect(
                    harness.probeObservation.isDetached,
                    "the real scroll detached the reader: \(harness.pinnedDescription())"
                )
                // A detached reader owns the viewport: nothing the app does while
                // they are away may write a scroll command at all. This is the
                // invariant the two synthetic zero-write fixtures asserted,
                // measured here on the real view, and it is the count of every
                // command rather than of the ones the application marked
                // automatic — that flag is the same for both, so it could not
                // have failed.
                let commandBaseline = harness.probeObservation.scrollCommandCount
                let anchor = try #require(
                    harness.readerAnchor(), "the detached reader had no on-screen row"
                )
                // The anchor is the topmost row intersecting the transcript's
                // visible region, so it is on screen by construction and — the
                // reader having stopped part-way — may start above that region.
                #expect(
                    anchor.windowMinY < harness.visibleRootView.bounds.height,
                    "the anchor row is in the window"
                )
                var movements: [String] = []

                // 1. Streaming while the reader is away: the installed
                // projection stays frozen, so nothing on screen may move.
                var streamed = harness.snapshot
                for step in 1...6 {
                    streamed.revision += 1
                    streamed.eventSequence += 1
                    streamed.streaming = try harnessAssistantMessage(
                        id: "detach-stream-\(step)",
                        presentationID: "detach-stream-turn",
                        text: "Streaming update \(step) while the reader is away."
                    )
                    harness.replaceAuthoritativeSnapshot(streamed)
                }
                for _ in 0..<12 { try await harness.driveFrameBoundary() }
                let afterStreaming = try #require(try await harness.settleReaderAnchor(to: anchor))
                movements.append("streaming:\(ct2Number(afterStreaming.windowMinY - anchor.windowMinY))")
                #expect(
                    afterStreaming.physicalID == anchor.physicalID,
                    "streaming remounted the reader's anchor row"
                )
                #expect(
                    abs(afterStreaming.windowMinY - anchor.windowMinY) <= 0.5,
                    "streaming moved the detached reader by \(ct2Number(afterStreaming.windowMinY - anchor.windowMinY)) pt"
                )
                #expect(
                    harness.probeObservation.scrollCommandCount == commandBaseline,
                    "streaming wrote a scroll command while the reader was away"
                )

                // 2. The keyboard's inset cycle: the composer's own edge moves,
                // which neither the reader's rows nor its position may follow.
                // A margin-only viewport must not clip away the reader's row
                // midway through a keyboard transition, even if its offset holds.
                let holdsReader: @MainActor () throws -> Void = {
                    let current = try #require(harness.readerAnchor())
                    #expect(current.physicalID == anchor.physicalID)
                    #expect(current.instance == anchor.instance)
                    #expect(abs(current.windowMinY - anchor.windowMinY) < 0.5)
                    #expect(harness.probeObservation.scrollCommandCount == commandBaseline)
                }
                try await harness.driveKeyboardInset(.show(), onBoundary: holdsReader)
                let afterShow = try #require(try await harness.settleReaderAnchor(to: anchor))
                movements.append("keyboard-up:\(ct2Number(afterShow.windowMinY - anchor.windowMinY))")
                #expect(
                    afterShow.physicalID == anchor.physicalID
                        && abs(afterShow.windowMinY - anchor.windowMinY) <= 0.5,
                    "the keyboard moved the detached reader by \(ct2Number(afterShow.windowMinY - anchor.windowMinY)) pt"
                )
                try await harness.driveKeyboardInset(.hide(), onBoundary: holdsReader)
                let afterHide = try #require(try await harness.settleReaderAnchor(to: anchor))
                movements.append("keyboard-down:\(ct2Number(afterHide.windowMinY - anchor.windowMinY))")
                #expect(
                    afterHide.physicalID == anchor.physicalID
                        && abs(afterHide.windowMinY - anchor.windowMinY) <= 0.5,
                    "the dismissal moved the detached reader by \(ct2Number(afterHide.windowMinY - anchor.windowMinY)) pt"
                )
                #expect(
                    harness.probeObservation.scrollCommandCount == commandBaseline,
                    "the keyboard cycle wrote a scroll command while the reader was away"
                )

                // 3. A page load above the reader: older rows arrive at the far
                // end, so the row being read must not move.
                guard harness.drivePrepend() else {
                    Issue.record("the earlier-messages row admitted no page load")
                    return
                }
                _ = try await harness.recorder.waitUntil { $0.observation.prependLoadWaiting }
                harness.releasePrependPage()
                for _ in 0..<20 { try await harness.driveFrameBoundary() }
                let afterPage = try #require(try await harness.settleReaderAnchor(to: anchor))
                movements.append("page-load:\(ct2Number(afterPage.windowMinY - anchor.windowMinY))")
                #expect(
                    afterPage.physicalID == anchor.physicalID,
                    "the page load remounted the reader's anchor row"
                )
                #expect(
                    abs(afterPage.windowMinY - anchor.windowMinY) <= 0.5,
                    "the page load moved the detached reader by \(ct2Number(afterPage.windowMinY - anchor.windowMinY)) pt"
                )
                #expect(
                    harness.probeObservation.scrollCommandCount == commandBaseline,
                    "the page load wrote a scroll command while the reader was away"
                )
                #expect(harness.probeObservation.isDetached, "the reader stayed away")
                print("CT25-DETACH-METRICS anchor=\(anchor.physicalID) startY=\(ct2Number(anchor.windowMinY)) movements=\(movements.joined(separator: ","))")
            }
        }
    }

    // The two synthetic fixtures this work replaced (`drivenCoordinatorExecutor`,
    // `shrinkDoesNotFollow`) also asserted three things no CT-25 journey covers.
    // The written failure modes they stand for: a pinned transcript that needs an
    // application position write to follow its own content growth or shrink; a
    // detached viewport whose restructure is admitted as projection work while the
    // reader is away; and a reader who takes the viewport back while a catch-up is
    // in flight and must stay away with their unread state. They are measured here
    // on the real view, through the window oracle, instead of on injected geometry.
    @Test("pinned content growth and shrink keep the tail with no position write")
    func pinnedGrowthAndShrinkWriteNoPosition() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) {
            try await withHarness(seed: 1_277) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeSettledAtOrigin
                }
                // A content change may publish the new terminal row's own exact
                // realization lease. Every other command is the application
                // correcting a position the pinned layout should keep by itself, so
                // the count of commands that are not leases must not move.
                let commandBaseline = ready.observation.scrollCommandCount
                let installBaseline = ready.observation.projectionInstallCount
                let semanticID = "pinned-growth-turn"

                var grown = harness.snapshot
                grown.transcript.append(try harnessAssistantMessage(
                    id: "pinned-growth-row",
                    presentationID: semanticID,
                    // One wrapped paragraph: `harnessAssistantMessage` interpolates
                    // its text into a JSON string, so it carries no newlines.
                    text: Array(
                        repeating: "The pinned reply grows while the reader stays at the tail.",
                        count: 8
                    ).joined(separator: " ")
                ))
                grown.transcriptTotal = (grown.transcriptTotal ?? grown.transcript.count - 1) + 1
                grown.revision += 1
                grown.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(grown)
                let grew = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > installBaseline
                        && $0.observation.rowFrames[semanticID] != nil
                        && $0.nativePinnedAtOrigin
                }
                #expect(
                    grew.nativePinnedAtOrigin,
                    "the grown tail: \(harness.pinnedDescription())"
                )
                #expect(
                    grew.observation.scrollCommandCount == commandBaseline,
                    "pinned growth published a position write: \(harness.pinnedDescription())"
                )
                // Content shrinks: the reply leaves again, so the pinned transcript
                // has to come back to where it was. Rows may get their own lease
                // here too; nothing may write a position.
                var shrunk = grown
                shrunk.transcript.removeLast()
                shrunk.transcriptTotal = (shrunk.transcriptTotal ?? shrunk.transcript.count) - 1
                shrunk.revision += 1
                shrunk.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(shrunk)
                let shrank = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > grew.observation.projectionInstallCount
                        && $0.nativePinnedAtOrigin
                }
                #expect(
                    shrank.nativePinnedAtOrigin,
                    "the shrunk tail: \(harness.pinnedDescription())"
                )
                #expect(
                    shrank.observation.scrollCommandCount == commandBaseline,
                    "pinned shrink published a position write: \(harness.pinnedDescription())"
                )
                // The settled live state, not only the sample the wait returned on.
                // The marker-owned 12 pt gap remains stable after the shrink's
                // own layout gets its frames first.
                for _ in 0..<24 { try await harness.driveFrameBoundary() }
                let settledBottom = harness.transcriptBottom()
                #expect(
                    settledBottom.isPinned,
                    "the settled tail holds the pinned band (clearance \(settledBottom.clearance.map(ct2Number) ?? "none")): \(harness.pinnedDescription())"
                )
            }
        }
    }

    @Test("a detached restructure admits no projection work and a re-interaction stays away with unread")
    func detachedRestructureAdmitsNoProjectionWork() async throws {
        try await withTestWatchdog(timeout: .seconds(30)) {
            try await withHarness(seed: 1_278) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.isReady && $0.nativeSettledAtOrigin
                }
                try await harness.detachReaderMidHistory()
                #expect(
                    harness.probeObservation.isDetached,
                    "the real scroll detached the reader: \(harness.pinnedDescription())"
                )
                let installs = harness.probeObservation.projectionInstallCount
                let work = harness.probeObservation.projectionWorkAdmissionCount
                let commands = harness.probeObservation.scrollCommandCount
                let anchor = try #require(
                    harness.readerAnchor(), "the detached reader had no on-screen row"
                )

                // The restructure a detached reader can still see: the keyboard's
                // own inset cycle changes the container the estimate is derived
                // from. The projection stays frozen while the reader is away, so
                // nothing may be admitted and nothing may be written — and the
                // reader's own rows may not move.
                try await harness.driveKeyboardInset(.show())
                try await harness.driveKeyboardInset(.hide())
                try await harness.driveFrameBoundary()
                let held = try #require(try await harness.settleReaderAnchor(to: anchor))
                #expect(
                    held.physicalID == anchor.physicalID
                        && abs(held.windowMinY - anchor.windowMinY) <= 0.5,
                    "the detached restructure moved the reader by \(ct2Number(held.windowMinY - anchor.windowMinY)) pt"
                )
                #expect(
                    harness.probeObservation.projectionWorkAdmissionCount == work,
                    "the detached restructure admitted projection work: \(harness.pinnedDescription())"
                )
                #expect(harness.probeObservation.projectionInstallCount == installs)
                #expect(
                    harness.probeObservation.scrollCommandCount == commands,
                    "the detached restructure wrote a scroll command: \(harness.pinnedDescription())"
                )
                #expect(harness.probeObservation.isDetached)

                // A response arrives while the reader is away, the catch-up is
                // admitted, and the reader takes the viewport back before it
                // settles: they are still away, with the unread still theirs.
                harness.driveSemanticResponse()
                #expect(harness.probeObservation.hasUnread)
                harness.driveCatchUp(reduceMotion: true)
                harness.drivePhase(from: .idle, to: .interacting, geometry: nil)
                #expect(
                    harness.probeObservation.isDetached,
                    "the catch-up's re-interaction returned the reader to the tail: \(harness.pinnedDescription())"
                )
                #expect(harness.probeObservation.hasUnread)
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
                try await harness.detachReaderByRealScroll()
                harness.driveSemanticResponse()
                #expect(harness.probeObservation.isDetached)
                #expect(harness.probeObservation.hasUnread)

                // The reader's own finger remains the only thing a hosted test
                // cannot produce: `onScrollPhaseChange` is the pan gesture's
                // callback, so this part stays the production callback order
                // observed on device — a mixed scroll/viewport callback whose
                // final frame lands while interactive keyboard dismissal changes
                // the inset. Everything above it is now the real scroll view.
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
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
        orientation: ChatTranscriptOrientation = .newestAtOrigin,
        displayFrameScheduler: DisplayFrameScheduler = .displayLink,
        operation: @escaping @MainActor @Sendable (ChatViewScrollHarness) async throws -> Void
    ) async throws {
        try await withHarness(
            snapshot: SessionScenarioBuilder(seed: seed).openingTail(targetEncodedBytes: 10_000),
            orientation: orientation,
            displayFrameScheduler: displayFrameScheduler,
            operation: operation
        )
    }

    private func withHarness(
        snapshot: SessionSnapshot,
        orientation: ChatTranscriptOrientation = .newestAtOrigin,
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
                unansweredRPCMethods: unansweredRPCMethods,
                orientation: orientation
            )
        } else {
            harness = try ChatViewScrollHarness(
                snapshot: snapshot,
                displayFrameScheduler: displayFrameScheduler,
                enablesPresentationCover: enablesPresentationCover,
                installsSubscribedSnapshot: installsSubscribedSnapshot || enablesPresentationCover,
                orientation: orientation
            )
        }
        do {
            #expect(harness.orientation == .newestAtOrigin)
            #expect(
                TranscriptWindowOracle.isFlipped(try harness.nativeTranscriptScrollViewForTesting()),
                "the hosted harness must exercise the origin-anchored layout"
            )
            try await operation(harness)
        } catch {
            if let sample = harness.recorder.samples.last {
                print("Hosted failure frame \(sample.frameIndex): releases=\(sample.observation.targetReleaseCount) rows=\(sample.nativeRows.suffix(8))")
                print("Origin readiness: newest=\(String(describing: sample.nativeBottom.newestRowSemanticID)) visible=\(sample.observation.visibleRowIDs) distance=\(sample.observation.geometry.distanceFromBottom) originPinned=\(sample.nativePinnedAtOrigin)")
                print("Geometry comparison (diagnostic only): native=\(String(describing: sample.nativeContentHeight)) model=\(sample.observation.geometry)")
                print("Composer catalog: builds=\(harness.probe.composerCatalogBuildCount) installed=\(harness.probe.composerCatalogCommandNames) canonical=\(harness.canonicalCommandNames) activity=\(harness.chatSurfaceActivity)")
            }
            await harness.close()
            throw error
        }
        await harness.close()
    }
}

/// The opening reveal's direction gate, as a pure decision so its failure mode is
/// pinnable: the committed position of the newest row's bottom edge, in window
/// coordinates, must never move down across the reveal and must step up by the
/// reveal's own physical lift. A flip of the transcript inverts any offset applied
/// outside a row's counter-flip, which turns the whole sequence into a drop.
///
/// The hosted journey calls this on the frames it samples; the negative control
/// calls it on the measured sequence and its reversal, which is what an inverted
/// reveal reports.
enum OpeningRevealDirection {
    /// The reveal's physical lift, in points, and how far the measured step may
    /// differ from it: 786.7 → 778.7 pt in every CT-25 run.
    static let lift: CGFloat = 8
    static let liftTolerance: CGFloat = 3
    /// The downward drift one boundary may carry without counting as a move down:
    /// the lazy stack's own sub-point settle.
    static let driftTolerance: CGFloat = 0.5

    /// Why `edges` is not an upward reveal, or `nil` when it is. `edges` is the
    /// newest row's bottom edge at each sampled display boundary, in window
    /// coordinates.
    static func failure(edges: [CGFloat]) -> String? {
        guard let first = edges.first, let settled = edges.last else {
            return "the reveal sampled no newest-row edge"
        }
        guard abs((first - settled) - lift) <= liftTolerance else {
            return "the reveal stepped the newest row's edge from \(first) to \(settled)"
        }
        guard zip(edges, edges.dropFirst()).allSatisfy({ $1 <= $0 + driftTolerance }) else {
            return "the newest row's edge moved down: \(edges)"
        }
        return nil
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

/// The bottom-coverage evidence of one sampled display boundary, in window
/// coordinates. `blank` is the CT-2 blank oracle: no mounted transcript row
/// intersects the visible transcript at all. `uncoveredBand` is the pinned
/// bottom band left without a mounted row, which is what catches the partial
/// blanks ("stops short", rows far above the composer) a whole-screen test
/// misses. `visibleRowFraction` is how much of the visible transcript the
/// mounted rows cover.
struct TranscriptBottomCoverage: Sendable, Equatable {
    let blank: Bool
    let uncoveredBand: Bool
    let visibleRowFraction: CGFloat
    let newestRowClearance: CGFloat?
}

struct CT2BoundarySample {
    let contentHeight: CGFloat
    let offsetY: CGFloat
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    let visibleRowCount: Int
    let tallRowFrame: CGRect?
    let coverage: TranscriptBottomCoverage
}

struct KeyboardInsetTransition: Sendable {
    let height: CGFloat
    let duration: Double
    let curve: UIView.AnimationCurve
    /// The driven display boundaries the inset's steps are spread over. The
    /// keyboard interpolates for `duration`; this lane's boundary is about
    /// one display frame, so the count stands for that duration here.
    let boundaries: Int

    /// A full-height keyboard on this window at the iOS keyboard's usual
    /// 250 ms curve, the transition a real keyboard delivers.
    static func show(
        height: CGFloat = 336,
        duration: Double = 0.25,
        curve: UIView.AnimationCurve = .easeInOut,
        boundaries: Int = 12
    ) -> KeyboardInsetTransition {
        KeyboardInsetTransition(
            height: height, duration: duration, curve: curve, boundaries: boundaries
        )
    }

    /// The same transition back to no keyboard.
    static func hide(
        duration: Double = 0.25,
        curve: UIView.AnimationCurve = .easeInOut,
        boundaries: Int = 12
    ) -> KeyboardInsetTransition {
        KeyboardInsetTransition(height: 0, duration: duration, curve: curve, boundaries: boundaries)
    }
}

/// One display boundary of the safe-area keyboard journey: the gap the reader
/// sees between the newest row's bottom edge and the composer's top edge, the
/// composer's own top edge and height, all in window coordinates. The gap is the
/// quantity P0-1's scenario records; the composer's absolute position is what
/// shows the keyboard's inset actually moved it.
struct KeyboardBoundarySample {
    let clearance: CGFloat?
    let composerTop: CGFloat?
    let composerHeight: CGFloat
    let coverage: TranscriptBottomCoverage
    let distanceFromNewest: CGFloat
    let tailState: String?
}

/// One journey's bottom-coverage gate evidence, folded from its samples.
struct TranscriptCoverageSummary: Sendable, Equatable {
    let samples: Int
    let blankBoundaries: Int
    let blankAfterSettle: Int
    let uncoveredBandBoundaries: Int
    let longestBlankRun: Int
    let blankPhases: String
    let minimumVisibleRowFraction: CGFloat

    init(samples: [TranscriptBottomCoverage], phaseLengths: [Int]) {
        let shape = blankShape(
            blankBoundaries: samples.map(\.blank), phaseLengths: phaseLengths
        )
        self.samples = samples.count
        blankBoundaries = shape.blank
        blankAfterSettle = shape.afterSettle
        uncoveredBandBoundaries = samples.count { $0.uncoveredBand }
        longestBlankRun = shape.longestRun
        blankPhases = shape.phases
        minimumVisibleRowFraction = samples.map(\.visibleRowFraction).min() ?? 0
    }
}

/// The origin-anchored transcript keeps the pinned newest-row band covered.
enum TranscriptBottomGateExpectation {
    case coveringBottomIsRequired
    static let current = coveringBottomIsRequired

    /// The floor the CT-23 path gates `minimumVisibleRowFraction` against: half
    /// the visible transcript. Every CT-2 and CT-24 shape's newest row is
    /// taller than the viewport (1,143-1,906 pt measured), so a pinned
    /// transcript covers it.
    static let coveredFractionFloor: CGFloat = 0.5
}

/// The verdict of one journey's bottom-coverage gate.
enum TranscriptBottomGateOutcome: Equatable {
    case asExpected
    case bottomUncovered(blankBoundaries: Int, uncoveredBandBoundaries: Int, minimumVisibleRowFraction: CGFloat)
}

/// The bottom-coverage gate fails when the pinned band or visible transcript is uncovered.
func transcriptBottomGateOutcome(
    _ summary: TranscriptCoverageSummary
) -> TranscriptBottomGateOutcome {
    let uncovered = summary.blankBoundaries > 0
        || summary.uncoveredBandBoundaries > 0
        || summary.minimumVisibleRowFraction < TranscriptBottomGateExpectation.coveredFractionFloor
    return uncovered
        ? .bottomUncovered(
            blankBoundaries: summary.blankBoundaries,
            uncoveredBandBoundaries: summary.uncoveredBandBoundaries,
            minimumVisibleRowFraction: summary.minimumVisibleRowFraction
        )
        : .asExpected
}

private func ct2Number(_ value: CGFloat) -> String {
    String(format: "%.1f", Double(value))
}

/// The blank-boundary shape of one planned sample sequence: how many sampled
/// display boundaries were blank, how many of those survived the settling
/// bound, the longest consecutive blank run, and which phases
/// (`p<index>:<blank count>`) held any blank at all. `phaseLengths` describes
/// the sampled sequence in order, so a phase's first boundaries are the ones
/// where its transition is still landing.
private func blankShape(
    blankBoundaries: [Bool],
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
        for offset in 0..<length where index < blankBoundaries.count {
            let isBlank = blankBoundaries[index]
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

func harnessUserMessage(id: String, text: String) throws -> TranscriptItem {
    try decodeTranscriptFixture(
        TranscriptItem.self,
        from: Data("""
        {"id":"\(id)","parentId":null,"presentationId":"\(id)","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"\(id):text","ordinal":0,"type":"text","text":"\(text)"}]}
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
    /// The mounted callbacks a hosted test activates through the control that
    /// owns them (a SwiftUI button cannot be tapped from the harness).
    let toolActionProbe = HostedToolActionProbe()

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
    /// The sole transcript orientation exercised by hosted chat journeys.
    let orientation: ChatTranscriptOrientation

    convenience init(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler,
        performanceSignposts: (any PerformanceSignposting)? = nil,
        enablesPresentationCover: Bool = false,
        installsSubscribedSnapshot: Bool = true,
        scrollCallbackMode: ChatHostedScrollCallbackMode = .synthetic,
        mediaFetch: ChatMediaFetch? = nil,
        orientation: ChatTranscriptOrientation = .newestAtOrigin
    ) throws {
        let dependencies = try Self.makeDependencies(
            enablesComposerSubmission: false,
            mediaFetch: mediaFetch
        )
        try self.init(
            snapshot: snapshot,
            displayFrameScheduler: displayFrameScheduler,
            performanceSignposts: performanceSignposts,
            dependencies: dependencies,
            installsSubscribedSnapshot: installsSubscribedSnapshot,
            enablesPresentationCover: enablesPresentationCover,
            scrollCallbackMode: scrollCallbackMode,
            orientation: orientation
        )
    }

    static func composerSubmissionHarness(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler,
        performanceSignposts: (any PerformanceSignposting)? = nil,
        enablesPresentationCover: Bool = false,
        usesRealOpening: Bool = false,
        unansweredRPCMethods: Set<String> = [],
        mediaFetch: ChatMediaFetch? = nil,
        orientation: ChatTranscriptOrientation = .newestAtOrigin
    ) async throws -> ChatViewScrollHarness {
        let dependencies = try makeDependencies(
            enablesComposerSubmission: true,
            mediaFetch: mediaFetch
        )
        guard let socket = dependencies.socket, let profile = dependencies.profile else {
            throw HarnessError.invalidAuthorityBoundary
        }
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":6,"minProtocolVersion":6,"machineId":"hosted-machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","skill-prompt.v1"]}"#.utf8))
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
                usesRealOpening: usesRealOpening,
                orientation: orientation
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
        enablesComposerSubmission: Bool,
        mediaFetch: ChatMediaFetch? = nil
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
            composerDraftStore: ComposerDraftStore(root: cacheRoot.appending(path: "drafts")),
            chatMediaFetch: mediaFetch
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
        usesRealOpening: Bool = false,
        scrollCallbackMode: ChatHostedScrollCallbackMode = .synthetic,
        orientation: ChatTranscriptOrientation = .newestAtOrigin
    ) throws {
        self.snapshot = snapshot
        self.orientation = orientation
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

        let probe = ChatHostedProbe(scrollCallbackMode: scrollCallbackMode)
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
                    performanceSignposts: performanceSignposts ?? signposts,
                    transcriptOrientation: orientation
                )
            }
            .environment(model)
            .environment(\.hostedToolActionProbe, toolActionProbe)
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
            orientation: orientation,
            windowState: { TranscriptWindowOracle.state(in: hostedView) }
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

    /// The mounted chat's media owner, so a hosted test can read what it
    /// retained for an exact artifact identity.
    var chatMedia: ChatMediaLoader { model.chatMedia }

    /// The exact media identity the mounted chat resolves for one artifact.
    func chatMediaIdentity(blobID: String) -> ChatMediaIdentity? {
        model.chatMediaIdentity(blobID: blobID, sessionID: snapshot.sessionId)
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

    /// Whether the hosted chat has a sheet presented. A transcript row's detail
    /// sheet is presented above the rows, so it must outlive the row that asked
    /// for it.
    var presentsManagedSheet: Bool { hostingController.presentedViewController != nil }
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
            // Presentation registration can race catalog loading; respond to
            // this request's method rather than whichever RPC arrived first.
            var index = priorFrames
            var request: JSONValue
            repeat {
                try await socket.waitUntilSent(count: index + 1)
                request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[index])
                index += 1
            } while request.objectValue?["method"]?.stringValue != "session.commands"
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

    /// The transcript's bottom, measured in window coordinates: the composer's
    /// top edge, the pinned bottom band, the newest mounted row's bottom edge
    /// and the fraction of the visible transcript the rows cover.
    func transcriptBottom() -> TranscriptWindowOracle.Bottom {
        TranscriptWindowOracle.bottom(in: hostingController.view)
    }

    /// The view the window oracle walks: the hosted chat's own view.
    var visibleRootView: UIView { hostingController.view }

    /// Whether the newest mounted row's bottom edge sits in the pinned bottom
    /// band. The one spelling of "the transcript is pinned to its visual
    /// bottom", and the replacement for every scroll-space tail error: window
    /// coordinates make it independent of the scroll view's orientation, so it
    /// reads the same after CT-23 flips the transcript.
    func isPinnedToBottom() -> Bool { transcriptBottom().isPinned }

    /// The visual gap between the newest mounted row's bottom edge and the
    /// composer's top edge. The eager marker owns its 12 pt band; the measured
    /// row-to-composer clearance is fixture-specific and pinned by opening tests.
    /// `nil` when no composer or no mounted row is there to measure.
    func newestRowClearance() -> CGFloat? { transcriptBottom().clearance }

    /// The visual distance between the newest mounted row's bottom edge and the
    /// pinned band, signed: `0` while pinned, negative when the transcript rests
    /// above the composer, positive when the row runs under it.
    func pinnedError() -> CGFloat? { transcriptBottom().pinnedError }

    /// The transcript's pinned state in window coordinates, for a failure
    /// message.
    func pinnedDescription() -> String {
        let bottom = transcriptBottom()
        func point(_ value: CGFloat?) -> String {
            value.map { String(format: "%.1f", Double($0)) } ?? "none"
        }
        return "clearance=\(point(bottom.clearance))"
            + " composerTop=\(point(bottom.composerTop))"
            + " newestEdge=\(point(bottom.newestRowBottomEdge))"
            + " bandCovered=\(bottom.isBandCovered)"
            + " visibleFraction=\(String(format: "%.2f", Double(bottom.visibleRowFraction)))"
    }

    /// Place the real reader `points` visual points from the newest end: `0` is
    /// the pinned bottom, larger values move toward older history, and the value
    /// is clamped to the transcript's legal scroll range. The distance is a
    /// visual distance and the newest end is the visual end the rows call
    /// newest, so the same call means the same thing on a flipped transcript
    /// (CT-23) as on today's pinned `LazyVStack`.
    func scrollReader(byVisualPoints points: CGFloat) throws {
        let scrollView = try nativeTranscriptScrollView()
        let inset = scrollView.adjustedContentInset
        let maximumOffset = max(
            -inset.top,
            scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
        )
        // Today the rows run oldest-first, so the newest end is the scroll
        // view's legal maximum offset; a flipped scroll view puts it at the
        // content origin.
        let newestEnd = TranscriptWindowOracle.isFlipped(scrollView) ? -inset.top : maximumOffset
        let proposed = newestEnd - (TranscriptWindowOracle.isFlipped(scrollView) ? -points : points)
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: min(maximumOffset, max(-inset.top, proposed))),
            animated: false
        )
        scrollView.layoutIfNeeded()
    }

    /// The scroll view's own offset at the transcript's newest end: today the
    /// legal maximum, and on a flipped transcript the content origin (see
    /// `scrollReader(byVisualPoints:)`, which places the reader from it).
    func nativeNewestEndOffset() throws -> CGFloat {
        let scrollView = try nativeTranscriptScrollView()
        let inset = scrollView.adjustedContentInset
        let maximumOffset = max(
            -inset.top,
            scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
        )
        return TranscriptWindowOracle.isFlipped(scrollView) ? -inset.top : maximumOffset
    }

    /// Move the real transcript scroll view to its oldest loaded content, then
    /// deliver the native drag phases that make that viewport movement direct
    /// user intent. Programmatic content-offset changes alone are not a reader
    /// taking over. The geometry and visible row frames remain those produced by
    /// the mounted scroll view.
    func detachReaderByRealScroll(boundaries: Int = 60) async throws {
        try scrollReader(byVisualPoints: 10_000_000)
        try await driveFrameBoundary()
        drivePhase(from: .idle, to: .interacting, geometry: nil)
        drivePhase(from: .interacting, to: .idle, geometry: nil)
        for _ in 0..<boundaries {
            if probeObservation.isDetached, readerAnchor() != nil { return }
            try await driveFrameBoundary()
        }
    }

    /// Detach the reader part-way up the loaded history, the way a reader who
    /// scrolls up and stops does: move the real transcript scroll view `viewports`
    /// viewports above the pinned tail and report the pan's own phase callbacks,
    /// which is the coordinator path that reads a viewport in motion as direct
    /// ownership. `detachReaderByRealScroll` exercises the status-bar path, which
    /// lands at the oldest loaded row (its heuristic needs a visual top inside 2
    /// pt of the window's) and leaves the reader at the content's far edge, where
    /// nothing above it can move it. A mid-history reader is the position the
    /// streaming, keyboard and page-load phases have to hold.
    func detachReaderMidHistory(
        byViewports viewports: CGFloat = 1.5,
        boundaries: Int = 60
    ) async throws {
        let scrollView = try nativeTranscriptScrollView()
        try scrollReader(byVisualPoints: viewports * scrollView.bounds.height)
        // One boundary so the coordinator's own geometry is the real mid-history
        // viewport before the phase callbacks arrive: a pinned position left in
        // its evidence would read the retreat as a bottom rubber band.
        try await driveFrameBoundary()
        drivePhase(from: .idle, to: .interacting, geometry: nil)
        drivePhase(from: .interacting, to: .idle, geometry: nil)
        for _ in 0..<boundaries {
            if probeObservation.isDetached, readerAnchor() != nil { return }
            try await driveFrameBoundary()
        }
    }

    /// Return the reader to the pinned tail through the real scroll view.
    func returnReaderToPinnedTail(boundaries: Int = 40) async throws {
        try scrollReader(byVisualPoints: 0)
        for _ in 0..<boundaries {
            if !probeObservation.isDetached && isPinnedToBottom() { return }
            try await driveFrameBoundary()
        }
    }

    /// Return the reader to the pinned tail through the real scroll view, by
    /// pressing the product's own catch-up affordance. A hosted test cannot
    /// synthesize the pan gesture whose phase transitions re-pin a detached
    /// reader (`onScrollPhaseChange` is the gesture's own callback), so the
    /// finger-driven return stays the device checklist's check and this is the
    /// real in-product equivalent: a scroll command to the tail, its exact lease
    /// settling, and the pinned mode restored.
    func returnReaderToPinnedTailByCatchUp(boundaries: Int = 60) async throws {
        let baseline = probeObservation.scrollCommandCount
        driveCatchUp(reduceMotion: true)
        for _ in 0..<boundaries {
            if !probeObservation.isDetached { return }
            if probeObservation.scrollCommandCount > baseline, isPinnedToBottom() { return }
            try await driveFrameBoundary()
        }
    }

    /// The row the reader is reading: the topmost mounted row that intersects the
    /// transcript's visible region, in window coordinates. A detached reader's
    /// anchor is this row's window position, so the same measurement holds
    /// whichever way the transcript's scroll view is oriented.
    struct ReaderAnchor: Equatable {
        let physicalID: String
        let instance: UUID
        let windowMinY: CGFloat
    }

    func readerAnchor() -> ReaderAnchor? {
        TranscriptWindowOracle.rows(in: hostingController.view)
            .filter(\.isOnScreen)
            .min { $0.windowFrame.minY < $1.windowFrame.minY }
            .map { ReaderAnchor(
                physicalID: $0.physicalID, instance: $0.instance, windowMinY: $0.windowFrame.minY
            ) }
    }

    /// Advance driven boundaries until the reader's anchor row sits where it did,
    /// or the bound is reached; returns the anchor either way. A journey that
    /// gates the anchor uses this to give the layout transaction's clock its own
    /// frames, then asserts the position itself.
    @discardableResult
    func settleReaderAnchor(
        to anchor: ReaderAnchor,
        boundaries: Int = 40
    ) async throws -> ReaderAnchor? {
        for _ in 0..<boundaries {
            if let current = readerAnchor(),
               current.physicalID == anchor.physicalID,
               abs(current.windowMinY - anchor.windowMinY) <= 0.5 {
                return current
            }
            try await driveFrameBoundary()
        }
        return readerAnchor()
    }

    /// The render region of one oracle row. The oracle reports window
    /// coordinates; the luminance samplers read the hosting view's own space.
    func renderRegion(ofRow row: TranscriptWindowOracle.Row) -> CGRect {
        hostingController.view.convert(row.windowFrame, from: nil)
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

    /// The real transcript scroll view, for a test that drives or inspects the
    /// native container directly.
    func nativeTranscriptScrollViewForTesting() throws -> UIScrollView {
        try nativeTranscriptScrollView()
    }

    /// Test-only: flip the real transcript scroll view the way CT-23's design
    /// flips it, but leave the rows un-counter-flipped, so the transcript
    /// renders mirrored and the newest row leaves the visual bottom. The window
    /// oracle's negative control: the scroll-space tail measurement this oracle
    /// replaced still reads the pinned bottom here, because the offset is still
    /// at the legal end of the estimated content.
    func flipNativeTranscriptWithoutCounterFlippingRows() throws {
        let scrollView = try nativeTranscriptScrollView()
        scrollView.layer.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1))
        scrollView.layoutIfNeeded()
    }

    /// The prompt rows' production context-menu surfaces: the native views that
    /// carry the interaction, with the owner that builds their preview. The
    /// prompt and display-card menus share this source-owned UIKit interaction.
    func promptContextMenuSurfaces() -> [(view: UIView, interaction: UIContextMenuInteraction, owner: ChatMessageContextMenuOwner)] {
        Self.contextMenuViews(in: hostingController.view).compactMap { view in
            guard let interaction = view.interactions.compactMap({ $0 as? UIContextMenuInteraction }).first,
                  let owner = interaction.delegate as? ChatMessageContextMenuOwner else { return nil }
            return (view, interaction, owner)
        }
    }

    /// The row the reader sees at the top of the transcript, or `nil` when no
    /// mounted row is on screen.
    func visuallyTopmostOnScreenRow() -> TranscriptWindowOracle.Row? {
        TranscriptWindowOracle.rows(in: visibleRootView)
            .filter(\.isOnScreen)
            .min { $0.windowFrame.minY < $1.windowFrame.minY }
    }

    private static func contextMenuViews(in view: UIView) -> [UIView] {
        let found = view.interactions.contains { $0 is UIContextMenuInteraction } ? [view] : []
        return found + view.subviews.flatMap(contextMenuViews)
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


    /// One origin-layout geometry sample for the scale and lazy-history regressions.
    func ct2BoundarySample(tallSemanticID: String) throws -> CT2BoundarySample {
        let scrollView = try nativeTranscriptScrollView()
        let rows = TranscriptWindowOracle.rows(in: hostingController.view)
        let bottom = transcriptBottom()
        return CT2BoundarySample(
            contentHeight: scrollView.contentSize.height,
            offsetY: scrollView.contentOffset.y,
            containerHeight: scrollView.bounds.height,
            bottomInset: scrollView.adjustedContentInset.bottom,
            visibleRowCount: rows.count { $0.isOnScreen },
            tallRowFrame: rows.first { $0.semanticID == tallSemanticID }?.windowFrame,
            coverage: TranscriptBottomCoverage(
                blank: rows.count { $0.isOnScreen } == 0,
                uncoveredBand: !bottom.isBandCovered,
                visibleRowFraction: bottom.visibleRowFraction,
                newestRowClearance: newestRowClearance()
            )
        )
    }

    fileprivate func keyboardBoundarySample() throws -> KeyboardBoundarySample {
        let bottom = transcriptBottom()
        let rows = TranscriptWindowOracle.rows(in: hostingController.view)
        let composer = TranscriptWindowOracle.composerFrame(in: hostingController.view)
        return KeyboardBoundarySample(
            clearance: bottom.clearance,
            composerTop: composer?.minY ?? bottom.composerTop,
            composerHeight: composer?.height ?? 0,
            coverage: TranscriptBottomCoverage(
                blank: !rows.contains { $0.isOnScreen },
                uncoveredBand: !bottom.isBandCovered,
                visibleRowFraction: bottom.visibleRowFraction,
                newestRowClearance: bottom.clearance
            ),
            distanceFromNewest: probeObservation.geometry.distanceFromBottom,
            tailState: traceRecords.first { $0.record.message.contains("tail=") }?.record.message
        )
    }

    /// Advance driven boundaries until the newest row is back inside the pinned
    /// band, up to `boundaries`, and report the boundary's own sample. A
    /// keyboard or send transition is owned by the layout transaction's clock,
    /// which may re-anchor the tail a few frames after the transition's own
    /// frames, so a journey that gates the settled position waits for it here
    /// instead of guessing a frame count. This is not a retry: it is the same
    /// wait every other pinned journey makes, and a transcript that never
    /// returns fails the caller's own assertion.
    func newestRowSettledAtComposer(boundaries: Int = 40) async throws -> KeyboardBoundarySample {
        for _ in 0..<boundaries {
            if isPinnedToBottom() { break }
            try await driveFrameBoundary()
        }
        return try keyboardBoundarySample()
    }

    /// The safe-area keyboard journey's `CT25-KEYBOARD-METRICS` line, folded
    /// from its per-boundary samples.
    func resize(height: CGFloat) {
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
    }

    /// The keyboard transition's own beginning: one end-frame notification, as
    /// UIKit posts one when a keyboard starts moving.
    func beginKeyboardInset(_ transition: KeyboardInsetTransition) {
        postKeyboardFrame(transition)
    }

    /// One step of a keyboard inset transition: the bottom safe area at `step` of
    /// `transition.boundaries`, on the curve's own values. A caller that captures
    /// between steps gets the keyboard's intermediate frames.
    func applyKeyboardInset(_ transition: KeyboardInsetTransition, step: Int) {
        let progress = Double(step) / Double(max(1, transition.boundaries))
        applyKeyboardInset(
            transition.height * Self.keyboardProgress(progress, curve: transition.curve)
        )
    }

    /// Drive the keyboard's inset transition: the notification UIKit posts, then
    /// the bottom safe area through the curve's own values, one driven display
    /// boundary per step. A journey samples the keyboard's intermediate frames
    /// deterministically; the returned samples are the gap between the composer's
    /// top edge and the newest row's bottom edge at each of those boundaries, in
    /// window coordinates.
    @discardableResult
    func driveKeyboardInset(
        _ transition: KeyboardInsetTransition,
        onBoundary: (@MainActor () throws -> Void)? = nil
    ) async throws -> [KeyboardBoundarySample] {
        beginKeyboardInset(transition)
        var samples: [KeyboardBoundarySample] = []
        for step in 1...max(1, transition.boundaries) {
            applyKeyboardInset(transition, step: step)
            try await driveFrameBoundary()
            samples.append(try keyboardBoundarySample())
            try onBoundary?()
        }
        return samples
    }

    /// The safe-area scenario's negative control: the keyboard's own transition
    /// with its height reserved at the transcript's *far* edge. CT-23's flipped
    /// transcript has to apply the keyboard as a swapped content margin — the
    /// height has to land at the visual bottom, where the composer's edge is — so
    /// a wrong-edge application leaves the pinned row one keyboard height away
    /// from the composer while the rows keep their orientation and order. The
    /// inset itself is the real one, stepped through the curve's own values, so
    /// the composer moves with it exactly as it does in the journey.
    @discardableResult
    func driveKeyboardInsetAtWrongEdge(
        _ transition: KeyboardInsetTransition
    ) async throws -> [KeyboardBoundarySample] {
        beginKeyboardInset(transition)
        var samples: [KeyboardBoundarySample] = []
        for step in 1...max(1, transition.boundaries) {
            let progress = Double(step) / Double(max(1, transition.boundaries))
            applyKeyboardInset(transition, step: step)
            try await driveFrameBoundary()
            try reserveKeyboardHeightAtTranscriptFarEdge(
                transition.height * Self.keyboardProgress(progress, curve: transition.curve)
            )
            samples.append(try keyboardBoundarySample())
        }
        return samples
    }

    /// Test-only: reserve `height` at the transcript's far edge instead of the
    /// composer's, the way a wrongly swapped keyboard margin does. The real scroll
    /// view cannot be *dragged* past its legal bottom, so the reservation is
    /// written as the offset beyond that bottom: the geometry the wrong edge
    /// produces for the reader, with the rows keeping their own height and order
    /// and the composer — outside the scroll view — keeping its own edge.
    func reserveKeyboardHeightAtTranscriptFarEdge(_ height: CGFloat) throws {
        let scrollView = try nativeTranscriptScrollView()
        let maximumOffset = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: maximumOffset + height), animated: false
        )
    }

    /// The bottom safe area a keyboard owns, applied without a notification:
    /// for a journey that needs the inset at a stated height while it drives the
    /// chat itself.
    func applyKeyboardInset(_ height: CGFloat) {
        hostingController.additionalSafeAreaInsets = UIEdgeInsets(
            top: 0, left: 0, bottom: height, right: 0
        )
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
    }

    /// The keyboard's own end-frame notification, in the form UIKit delivers it:
    /// `ChatKeyboardObserver` reads the same three user-info keys, so the layout
    /// transaction takes the keyboard it takes on a device.
    private func postKeyboardFrame(_ transition: KeyboardInsetTransition) {
        let endFrame = window.convert(
            CGRect(
                x: 0, y: window.bounds.maxY - transition.height,
                width: window.bounds.width, height: transition.height
            ),
            to: nil
        )
        NotificationCenter.default.post(
            name: transition.height > 0
                ? UIResponder.keyboardWillChangeFrameNotification
                : UIResponder.keyboardWillHideNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: transition.duration),
                UIResponder.keyboardAnimationCurveUserInfoKey: NSNumber(value: transition.curve.rawValue),
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: endFrame),
            ]
        )
    }

    /// Focus the production editor: UIKit posts the notification and owns the
    /// hosting controller's keyboard safe-area animation over real time.
    func setRealKeyboardVisible(_ visible: Bool) throws {
        let editor = try #require(Self.textViews(in: hostingController.view).first)
        if visible { editor.becomeFirstResponder() } else { editor.resignFirstResponder() }
    }

    func topViewportEvidence() throws -> (uncoveredTop: CGFloat, description: String) {
        let scroll = try nativeTranscriptScrollView()
        func navigationBar(in view: UIView) -> UINavigationBar? {
            (view as? UINavigationBar) ?? view.subviews.lazy.compactMap { navigationBar(in: $0) }.first
        }
        let navigation = try #require(navigationBar(in: hostingController.view))
        let nav = navigation.convert(navigation.bounds, to: window).maxY
        let frame = scroll.layer.convert(scroll.bounds, to: window.layer).standardized
        var clip = frame
        var parent = scroll.superview
        var chain: [String] = []
        while let view = parent {
            let rect = view.layer.convert(view.bounds, to: window.layer).standardized
            if view.clipsToBounds { clip = clip.intersection(rect) }
            chain.append("\(type(of: view)):\(rect):clip=\(view.clipsToBounds)")
            parent = view.superview
        }
        let rows = TranscriptWindowOracle.rows(in: hostingController.view)
        let first = rows.filter { $0.windowFrame.maxY > max(nav, clip.minY) }.min { $0.windowFrame.minY < $1.windowFrame.minY }
        return (max(0, max(clip.minY, first?.windowFrame.minY ?? .infinity) - nav), "nav=\(nav) frame=\(frame) clip=\(clip) insets=\(scroll.contentInset) adjusted=\(scroll.adjustedContentInset) safe=\(scroll.safeAreaInsets) first=\(String(describing: first?.windowFrame)) chain=\(chain)")
    }

    enum MotionAccessory { case photo, file, skill, command }

    func setMotionAccessory(_ accessory: MotionAccessory?) throws {
        let target = try #require(model.mountedPresentationTarget)
        let scope = try #require(model.composerDrafts.scope(for: target))
        model.composerDrafts.removeSelectedResource(for: scope)
        model.composerDrafts.removeAttachment("motion-attachment", target: target)
        switch accessory {
        case .photo, .file:
            let photo = accessory == .photo
            model.composerDrafts.installHostedAttachment(PendingAttachment(
                id: "motion-attachment", name: photo ? "Photo" : "Notes.txt",
                mimeType: photo ? "image/jpeg" : "text/plain", size: 1, previewData: nil
            ), target: target)
        case .skill:
            try selectCanonicalSkill(named: "skill:review")
        case .command:
            let command = try #require(model.commands.first { $0.name == "inspect" })
            model.composerDrafts.selectResource(command, for: scope)
        case nil: break
        }
    }

    func obstructionRecorder(trackedID: String? = nil) throws -> AnimatedObstructionRecorder {
        let root = hostingController.view!
        let newest = try #require(TranscriptWindowOracle.rows(in: root).max { $0.windowFrame.maxY < $1.windowFrame.maxY })
        return AnimatedObstructionRecorder(root: root, newestID: trackedID ?? newest.physicalID, probe: probe)
    }

    /// UIKit's keyboard curve evaluated at `progress`. The public
    /// `UIView.AnimationCurve` cases map one-to-one onto `CAMediaTimingFunction`'s
    /// named curves, so the intermediate positions are the curve's own rather
    /// than a substituted approximation of it.
    static func keyboardProgress(_ progress: Double, curve: UIView.AnimationCurve) -> CGFloat {
        let name: CAMediaTimingFunctionName = switch curve {
        case .linear: .linear
        case .easeIn: .easeIn
        case .easeOut: .easeOut
        default: .easeInEaseOut
        }
        let function = CAMediaTimingFunction(name: name)
        var first = [Float](repeating: 0, count: 2)
        var second = [Float](repeating: 0, count: 2)
        function.getControlPoint(at: 1, values: &first)
        function.getControlPoint(at: 2, values: &second)
        let target = CGFloat(progress)
        // The curve's x axis is progress and its y axis is the fraction applied.
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<24 {
            let middle = (lower + upper) / 2
            if cubic(first[0], first[1], second[0], second[1], middle).x < target {
                lower = middle
            } else {
                upper = middle
            }
        }
        let resolved = (lower + upper) / 2
        let sample = cubic(first[0], first[1], second[0], second[1], resolved)
        guard sample.x != 0 else { return 0 }
        return min(1, max(0, sample.y))
    }

    /// A cubic Bézier's point at parameter `t`, for the four control values
    /// `CAMediaTimingFunction` reports.
    private static func cubic(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ t: CGFloat
    ) -> (x: CGFloat, y: CGFloat) {
        let inverse = 1 - t
        func axis(_ first: Float, _ second: Float) -> CGFloat {
            3 * inverse * inverse * t * CGFloat(first)
                + 3 * inverse * t * t * CGFloat(second)
                + t * t * t
        }
        return (axis(x1, x2), axis(y1, y2))
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

    private static func nativeTranscriptScrollView(in root: UIView) -> UIScrollView? {
        TranscriptWindowOracle.transcriptScrollView(in: root)
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

/// The transcript's bottom, measured in window coordinates: the one oracle for
/// "is the newest row where the pinned tail puts it?".
///
/// Window coordinates carry what the reader sees, so every quantity here means
/// the same thing whichever way the transcript's scroll view is oriented. That
/// is what CT-23 needs: after the scroll view is flipped and the rows are
/// counter-flipped, a scroll-space tail error measures the distance to the
/// oldest estimated end and calls a blank viewport aligned, while the newest
/// row's window frame is exactly what it was.
///
/// The rects come from the layer chain (`CALayer.convert`), not
/// `UIView.convert`: SwiftUI applies its own transforms (`scaleEffect`,
/// `offset`) on layers, which `UIView.convert` does not walk, so the flip CT-23
/// puts on the scroll view is visible here and invisible there.
enum TranscriptWindowOracle {
    /// The tail spacing a pinned transcript keeps between its newest row and the
    /// composer.
    static let tailSpacing = ChatTranscriptLayoutConstants.tailAffordanceHeight
    /// The band above the composer a pinned transcript keeps covered: the tail
    /// spacing plus 24 pt of the newest row.
    static let bottomBandHeight = tailSpacing + 24
    /// The tolerance the profiling scenarios allow a measured window's pinned
    /// bottom: the window ends while the transcript may still be settling.
    static let profilingTolerance: CGFloat = 24

    /// How far the newest row's rendered bottom edge may sit outside the pinned
    /// band and still count as pinned. The edge is read from the render tree, so
    /// it carries a row's own animated transforms: the queued card's 80 → 44 pt
    /// shrink measured 4.1-13.5 pt excursions below the band, while a detached
    /// reader or a blank is tens or hundreds of points away.
    static let pinnedTolerance: CGFloat = 6

    /// One mounted transcript row, in window coordinates.
    struct Row: Sendable, Equatable {
        let physicalID: String
        let semanticID: String
        let instance: UUID
        /// The row marker's frame in window coordinates.
        let windowFrame: CGRect
        /// Whether the row intersects the transcript's visible region: the
        /// scroll view's on-screen rect, less the composer it insets under.
        let isOnScreen: Bool
        /// Whether the row intersects the pinned bottom band.
        let isInBottomBand: Bool
        /// The visual gap between the row's bottom edge and the composer's top
        /// edge, `nil` without a mounted composer. The pinned tail row sits at
        /// `tailSpacing`; a negative value runs under the composer.
        let composerClearance: CGFloat?

        /// Whether the row's bottom edge sits at the tail spacing above the
        /// composer: the position of a pinned transcript's newest row.
        func isAtTailSpacing(tolerance: CGFloat = 2) -> Bool {
            guard let composerClearance else { return false }
            return abs(composerClearance - TranscriptWindowOracle.tailSpacing) <= tolerance
        }
    }

    /// The transcript's bottom in window coordinates.
    struct Bottom: Sendable, Equatable {
        /// The composer marker's top edge.
        let composerTop: CGFloat?
        /// The pinned bottom band: `bottomBandHeight` points ending at the
        /// composer's top edge.
        let band: CGRect?
        /// The bottom edge and identity of the bottom-most mounted row, which
        /// is the newest row when the origin-anchored viewport is pinned.
        let newestRowBottomEdge: CGFloat?
        let newestRowSemanticID: String?
        /// The fraction of the visible transcript rect that mounted rows cover.
        let visibleRowFraction: CGFloat
        /// Whether any mounted row intersects the bottom band.
        let isBandCovered: Bool
        /// The visual distance of the bottom-most row's bottom edge from the
        /// pinned band, signed: `0` anywhere inside the band, negative when the
        /// row rests above it (a detached reader, or a blank) and positive when
        /// it runs under it below the composer.
        let pinnedError: CGFloat?

        /// The visual gap between the bottom-most row's bottom edge and the
        /// composer's top edge.
        var clearance: CGFloat? {
            guard let composerTop, let newestRowBottomEdge else { return nil }
            return composerTop - newestRowBottomEdge
        }

        /// The marker-owned band is the sole pinned placement; short and tall
        /// terminal rows produce different measured gaps within that band.
        var isPinned: Bool {
            guard let clearance else { return false }
            return clearance >= -pinnedTolerance && clearance <= tailSpacing + pinnedTolerance
        }
    }

    /// Every mounted transcript row and the transcript's bottom, from one walk
    /// of the live hierarchy.
    struct State: Sendable, Equatable {
        let rows: [Row]
        let bottom: Bottom
        /// The transcript scroll view's own content height. Both layouts report
        /// it identically, so a readiness fence can still require the native
        /// view and the coordinator to agree about it.
        let contentHeight: CGFloat?
    }

    static func rows(in root: UIView) -> [Row] { state(in: root).rows }

    static func bottom(in root: UIView) -> Bottom { state(in: root).bottom }

    /// The composer marker's frame in window coordinates: the one structural
    /// inset owner's own frame, which is where the keyboard's safe area lands.
    static func composerFrame(in root: UIView) -> CGRect? {
        guard let window = root.window else { return nil }
        return markers(in: root)
            .first { $0.physicalID == ChatHostedNativeRowProbe.composerID }
            .map { $0.layer.convert($0.bounds, to: window.layer).standardized }
    }

    /// Whether the newest row's bottom edge sits within `tolerance` points of
    /// the pinned band: the decision the profiling scenarios make about a
    /// measured window, which ends while the transcript may still be settling,
    /// so it is wider than `Bottom.isPinned`.
    static func isPinned(in root: UIView, tolerance: CGFloat) -> Bool {
        guard let pinnedError = bottom(in: root).pinnedError else { return false }
        return abs(pinnedError) <= tolerance
    }

    static func state(in root: UIView) -> State {
        guard let window = root.window, let scroll = transcriptScrollView(in: root) else {
            return State(rows: [], bottom: emptyBottom, contentHeight: nil)
        }
        let windowLayer = window.layer
        let composerTop = markers(in: root)
            .first { $0.physicalID == ChatHostedNativeRowProbe.composerID }
            .map { $0.layer.convert($0.bounds, to: windowLayer).standardized.minY }
        var visible = scroll.layer.convert(scroll.bounds, to: windowLayer).standardized
            .intersection(window.bounds)
        // The composer is subtracted from the window rect rather than read from
        // `adjustedContentInset`, which a flipped scroll view would apply at the
        // other edge.
        if let composerTop, composerTop > visible.minY {
            visible = visible.intersection(CGRect(
                x: visible.minX, y: visible.minY,
                width: visible.width, height: composerTop - visible.minY
            ))
        }
        let band = composerTop.map { top in
            CGRect(
                x: visible.minX, y: top - bottomBandHeight,
                width: visible.width, height: bottomBandHeight
            )
        }
        let hasVisibleArea = !visible.isNull && visible.height > 0
        var rows: [Row] = []
        var coveredHeight: CGFloat = 0
        for marker in markers(in: scroll) where marker.window == window && !marker.isHidden {
            let frame = marker.layer.convert(marker.bounds, to: windowLayer).standardized
            guard frame.height > 0 else { continue }
            let isOnScreen = hasVisibleArea && frame.intersects(visible)
            if isOnScreen { coveredHeight += frame.intersection(visible).height }
            rows.append(Row(
                physicalID: marker.physicalID,
                semanticID: marker.semanticID,
                instance: marker.hostIdentity,
                windowFrame: frame,
                isOnScreen: isOnScreen,
                isInBottomBand: band.map { frame.intersects($0) } ?? false,
                composerClearance: composerTop.map { $0 - frame.maxY }
            ))
        }
        let newestRow = rows.max { $0.windowFrame.maxY < $1.windowFrame.maxY }
        let newestRowBottomEdge = newestRow?.windowFrame.maxY
        let clearance = composerTop.flatMap { top in
            newestRowBottomEdge.map { top - $0 }
        }
        let pinnedError = clearance.map(Self.pinnedError(forClearance:))
        let bottom = Bottom(
            composerTop: composerTop,
            band: band,
            newestRowBottomEdge: newestRowBottomEdge,
            newestRowSemanticID: newestRow?.semanticID,
            visibleRowFraction: hasVisibleArea
                ? min(1, max(0, coveredHeight / visible.height)) : 0,
            isBandCovered: rows.contains { $0.isInBottomBand },
            pinnedError: pinnedError
        )
        return State(rows: rows, bottom: bottom, contentHeight: scroll.contentSize.height)
    }

    /// Whether this view renders flipped (CT-23's transcript layout), read from
    /// the render tree: a vertical scale of -1 on the view's own layer or on one
    /// of its ancestors up to the window. The signs multiply along the chain,
    /// because a flip on the scroll view and another on an ancestor renders the
    /// content upright — reading the first negative `m22` alone would call a
    /// doubly flipped container flipped and send every orientation-dependent
    /// branch (`scrollReader`'s newest end, the pinned checks, a context-menu
    /// preview's uprightness) the wrong way.
    static func isFlipped(_ view: UIView) -> Bool {
        var layer: CALayer? = view.layer
        var flipped = false
        while let current = layer {
            if current.transform.m22 < 0 { flipped.toggle() }
            layer = current.superlayer
        }
        return flipped
    }

    /// This fixed-window harness has one full-size transcript viewport. Its
    /// identity cannot depend on overflowing content or a lazy child being
    /// mounted at the instant an entrance or compaction is sampled.
    static func transcriptScrollView(in root: UIView) -> UIScrollView? {
        scrollViews(in: root).filter { !($0 is UITextView) }.max {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        }
    }

    /// The signed distance of a newest-row clearance from the pinned band: `0`
    /// inside it, negative above it, positive below it.
    private static func pinnedError(forClearance clearance: CGFloat) -> CGFloat {
        if clearance > tailSpacing + pinnedTolerance {
            return (tailSpacing + pinnedTolerance) - clearance
        }
        if clearance < -pinnedTolerance { return -pinnedTolerance - clearance }
        return 0
    }

    private static let emptyBottom = Bottom(
        composerTop: nil, band: nil, newestRowBottomEdge: nil,
        newestRowSemanticID: nil,
        visibleRowFraction: 0, isBandCovered: false, pinnedError: nil
    )

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews)
    }

    private static func markers(in view: UIView) -> [ChatHostedNativeRowMarker] {
        (view as? ChatHostedNativeRowMarker).map { [$0] } ?? view.subviews.flatMap { markers(in: $0) }
    }
}

/// Dedicated motion oracle: no revision deduplication, forced layout or driven
/// frames. Presentation layers retain all ancestor transforms, including the
/// transcript flip and UIKit's animated scroll offset.
@MainActor
final class AnimatedObstructionRecorder: NSObject {
    struct Sample: Encodable {
        let time: Double
        let phase: String
        let composerTop: CGFloat?
        let newestBottom: CGFloat?
        let declaredObstruction: CGFloat
        let renderedObstruction: CGFloat?
        let distanceFromNewest: CGFloat
        let trackedTop: CGFloat?
        let trackedInstance: UUID?
        var gap: CGFloat? {
            guard let composerTop, let newestBottom else { return nil }
            return composerTop - newestBottom
        }
    }
    private let root: UIView
    private let newestID: String
    private let probe: ChatHostedProbe
    private var link: CADisplayLink?
    var phase = "settled"
    private(set) var samples: [Sample] = []

    init(root: UIView, newestID: String, probe: ChatHostedProbe) {
        self.root = root
        self.newestID = newestID
        self.probe = probe
    }
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func sample(_ link: CADisplayLink) {
        guard let window = root.window else { return }
        let markers = markers(in: root)
        func frame(_ id: String) -> CGRect? {
            guard let marker = markers.first(where: { $0.physicalID == id }),
                  let layer = marker.layer.presentation(),
                  let windowLayer = window.layer.presentation() else { return nil }
            return layer.convert(layer.bounds, to: windowLayer).standardized
        }
        samples.append(Sample(time: link.timestamp, phase: phase,
                              composerTop: frame(ChatHostedNativeRowProbe.composerID)?.minY,
                              newestBottom: frame(newestID)?.maxY,
                              declaredObstruction: probe.observation.geometry.bottomInset,
                              renderedObstruction: obstruction(in: root)?.layer.presentation()?.bounds.height,
                              distanceFromNewest: probe.observation.geometry.distanceFromBottom,
                              trackedTop: frame(newestID)?.minY,
                              trackedInstance: markers.first { $0.physicalID == newestID }?.hostIdentity))
    }
    private func obstruction(in view: UIView) -> ChatHostedObstructionMarker? {
        (view as? ChatHostedObstructionMarker) ?? view.subviews.lazy.compactMap { self.obstruction(in: $0) }.first
    }
    private func markers(in view: UIView) -> [ChatHostedNativeRowMarker] {
        (view as? ChatHostedNativeRowMarker).map { [$0] } ?? view.subviews.flatMap { markers(in: $0) }
    }
}

@MainActor
final class PresentedFrameRecorder: NSObject {
    /// How many samples the recorder retains. It drops the oldest beyond this,
    /// so a journey that reads native frames across a window it no longer holds
    /// checks only part of the transition: `windowIsComplete(since:)` is how
    /// such a journey fails instead of passing quietly.
    static let retainedSampleLimit = 256

    struct Sample: Sendable {
        let frameIndex: Int
        let observation: ChatHostedObservation
        /// The transcript's bottom in window coordinates at this display frame.
        let nativeBottom: TranscriptWindowOracle.Bottom
        let nativeRows: [TranscriptWindowOracle.Row]
        /// The transcript scroll view's own content height at this display frame.
        let nativeContentHeight: CGFloat?

        /// Whether the newest row is visible at the origin-anchored pinned edge.
        var nativePinnedAtOrigin: Bool {
            guard let newestRowID = nativeBottom.newestRowSemanticID else { return false }
            return nativeBottom.isPinned
                && observation.geometry.distanceFromBottom <= ChatTranscriptGeometry.catchUpDistance
                && observation.visibleRowIDs.contains(newestRowID)
                && nativeRows.contains { $0.semanticID == newestRowID && $0.isOnScreen }
        }

        /// Opening is settled at the pinned edge, without comparing estimates of
        /// the lazily materialized far history end.
        var nativeSettledAtOrigin: Bool { nativePinnedAtOrigin }
    }

    private struct Waiter {
        let id: Int
        let predicate: @MainActor (Sample) -> Bool
        let continuation: CheckedContinuation<Sample, Error>
    }

    private let probe: ChatHostedProbe
    private let orientation: ChatTranscriptOrientation
    private let windowState: @MainActor () -> TranscriptWindowOracle.State
    private var lastWindowState: TranscriptWindowOracle.State?
    private var displayLink: CADisplayLink?
    private var frameIndex = 0
    private var lastRevision = -1
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    private(set) var samples: [Sample] = []
    /// Samples the recorder's bounded window has dropped.
    private(set) var droppedSampleCount = 0

    init(
        probe: ChatHostedProbe,
        orientation: ChatTranscriptOrientation,
        windowState: @escaping @MainActor () -> TranscriptWindowOracle.State
    ) {
        self.probe = probe
        self.orientation = orientation
        self.windowState = windowState
    }

    /// Whether the retained sample window still holds every sample from
    /// `frameIndex` on. A journey that reads native frames over a range the
    /// recorder has evicted must fail this rather than inspect a partial window.
    func windowIsComplete(since frameIndex: Int) -> Bool {
        guard let oldest = samples.first?.frameIndex else { return false }
        return oldest <= frameIndex
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
        let state = windowState()
        guard observation.revision != lastRevision || state != lastWindowState else { return }
        lastRevision = observation.revision
        lastWindowState = state
        let sample = Sample(
            frameIndex: frameIndex,
            observation: observation,
            nativeBottom: state.bottom,
            nativeRows: state.rows,
            nativeContentHeight: state.contentHeight.map {
                $0 - observation.geometry.bottomInset
            }
        )
        samples.append(sample)
        if samples.count > Self.retainedSampleLimit {
            droppedSampleCount += samples.count - Self.retainedSampleLimit
            samples.removeFirst(samples.count - Self.retainedSampleLimit)
        }

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
