import Darwin
import Foundation
import QuartzCore
import Testing
import UIKit
@testable import TronMobile

/// The chat transcript's cost at scale: 150, 300 and 512 heavy mixed rows,
/// which is the price of realizing every row instead of the ~10-20 a lazy stack
/// mounts. The plan's CT-2 shapes measure correctness (blank boundaries,
/// estimate swing) on histories with one tall row beside the tail; this fixture
/// is the one both CT-13 columns were measured with and is `main`'s CT-10
/// baseline, so a candidate container compares against its lazy column.
///
/// What each shape records, per phase:
/// - opening: the product's own `firstReadyFrame` interval, the wall clock from
///   hosted view install to the ready sample, and resident memory before the
///   view was installed, before readiness and after readiness.
/// - `scroll`: a scripted history journey from the tail upward and back, one
///   display frame per 600 pt step, with display-link frame intervals and the
///   main-thread duration of each step (a step's layout runs synchronously in
///   `UIScrollView.layoutIfNeeded`).
/// - `stream`: streaming growth at the tail, one authoritative install per step.
/// - `send`: a composer send with the keyboard-sized contraction and the
///   dismissal that lands in the same display window, the shape the CT-2
///   fixtures use.
/// - `blank`: one keyboard up/down cycle sampled every frame through the native
///   row hosts, which is the CT-2 blank measurement at these row counts. This
///   phase walks the view hierarchy on every frame, so its timings are not
///   reported; it measures visibility only.
///
/// These are measurements, not gates: each shape prints `CT13-METRICS` and
/// `CT13-PHASE` lines and asserts only that the journey ran. They live in the
/// `ui-validation` tier: `UnitTests.xctestplan` lists them as skipped, but a
/// plan's `skippedTests` is not honored for Swift Testing tests on this path and
/// `-only-testing` overrides it in any case (measured: a unit-tier
/// `--only-testing TronMobileTests/ChatTranscriptScaleMeasurementTests` ran all
/// three shapes for 34.8 s), so the suite refuses to run unless xcodebuild is
/// running the `UIValidation` plan, which it records in the test process's own
/// environment. A scheme or test-plan environment variable cannot carry that
/// flag: measured on this lane, neither the shell environment nor the scheme's
/// test-action variables reach the test process.
///
/// Simulator timings are indicative only: the hosted harness keeps a
/// display-link recorder and a probe in the same process, and the machine is
/// shared. The absolute milliseconds are not device frame times; the eager and
/// lazy columns are comparable to each other because both run this same
/// fixture on the same lane.
///
/// The harness's own per-frame `PresentedFrameRecorder` hierarchy walk is
/// stopped for the cost phases (`scroll`, `stream`, `send`): that walk costs
/// more the more row markers are mounted, which would penalize the eager
/// container for the recorder's own work rather than for layout.
@MainActor
@Suite(
    "Chat transcript scale measurement",
    .serialized,
    .enabled(if: UIValidationTier.isActive)
)
struct ChatTranscriptScaleMeasurementTests {
    @Test("CT-13 scale: 150 heavy mixed rows")
    func ct13Scale150() async throws {
        try await withTestWatchdog(timeout: .seconds(300)) {
            try await runScaleShape(rowCount: 150)
        }
    }

    @Test("CT-13 scale: 300 heavy mixed rows")
    func ct13Scale300() async throws {
        try await withTestWatchdog(timeout: .seconds(600)) {
            try await runScaleShape(rowCount: 300)
        }
    }

    @Test("CT-13 scale: 512 heavy mixed rows")
    func ct13Scale512() async throws {
        try await withTestWatchdog(timeout: .seconds(900)) {
            try await runScaleShape(rowCount: 512)
        }
    }

    private func runScaleShape(rowCount: Int) async throws {
        let shape = "rows-\(rowCount)"
        let snapshot = try scaleMixedSnapshot(rowCount: rowCount)
        let signposts = ScaleTimestampedSignposts()
        let memoryBeforeInstall = scaleResidentMemoryBytes()
        let installStartedAt = ContinuousClock.now
        let harness = try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink,
            performanceSignposts: signposts
        )
        do {
            let opened = try await measureOpen(
                harness: harness, shape: shape, rowCount: rowCount,
                signposts: signposts, memoryBeforeInstall: memoryBeforeInstall,
                installStartedAt: installStartedAt
            )
            if !opened { await harness.close(); return }
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }

    private func measureOpen(
        harness: ChatViewScrollHarness,
        shape: String,
        rowCount: Int,
        signposts: ScaleTimestampedSignposts,
        memoryBeforeInstall: UInt64,
        installStartedAt: ContinuousClock.Instant
    ) async throws -> Bool {
        let memoryBeforeReady = scaleResidentMemoryBytes()
        let frames = ScaleFrameIntervalRecorder()
        frames.start()
        defer { frames.stop() }
        frames.beginPhase()
        let opened = await scaleWaitForReady(
            harness: harness,
            timeout: .seconds(scaleReadyBoundSeconds)
        )
        let openingIntervals = frames.endPhase()
        let readyAt = ContinuousClock.now
        let opening = scaleIntervalStats(openingIntervals)
        let installedRows = harness.probeObservation.installedProjectionRowCount
        guard opened else {
            let memoryAfterMiss = scaleResidentMemoryBytes()
            print(
                "CT13-METRICS shape=\(shape) opened=false"
                    + " items=\(rowCount) installedRows=\(installedRows)"
                    + " openInstallMs=\(scaleMilliseconds(installStartedAt.duration(to: readyAt)))"
                    + " openReadyFrameMs=\(signposts.duration(of: .firstReadyFrame).map(scaleMilliseconds) ?? -1)"
                    + " openAttemptMs=\(scaleMilliseconds(scaleAttemptDuration(signposts)))"
                    + " openFrameGapMaxMs=\(scalePoint(opening.maximum))"
                    + " memoryBeforeInstallMB=\(scaleMegabytes(memoryBeforeInstall))"
                    + " memoryBeforeReadyMB=\(scaleMegabytes(memoryBeforeReady))"
                    + " memoryAfterMissMB=\(scaleMegabytes(memoryAfterMiss))"
                    + " commands=\(scaleCommandCounts(harness))"
            )
            print(
                "CT13-NOTE shape=\(shape) the product never published a ready frame within"
                    + " \(scaleReadyBoundSeconds)s, so the scroll, stream, send and blank phases"
                    + " were not measured for this shape"
            )
            return false
        }
        let memoryAfterReady = scaleResidentMemoryBytes()
        let commandsAtReady = scaleCommandCounts(harness)
        let openInterval = signposts.duration(of: .firstReadyFrame)
        print(
            "CT13-METRICS shape=\(shape) opened=true"
                + " items=\(rowCount) installedRows=\(installedRows)"
                + " openInstallMs=\(scaleMilliseconds(installStartedAt.duration(to: readyAt)))"
                + " openReadyFrameMs=\(openInterval.map(scaleMilliseconds) ?? -1)"
                + " openEntries=\(signposts.entries(of: .firstReadyFrame))"
                + " openFrameGapMaxMs=\(scalePoint(opening.maximum))"
                + " openFrameGapsOver33=\(opening.over33)"
                + " mountedMarkers=\(harness.recorder.samples.last?.nativeRows.count ?? -1)"
                + " visibleRows=\(harness.recorder.samples.last?.nativeRows.filter(\.isVisible).count ?? -1)"
                + " contentHeight=\(scalePoint(harness.probeObservation.geometry.contentHeight))"
                + " containerHeight=\(scalePoint(harness.probeObservation.geometry.containerHeight))"
                + " memoryBeforeInstallMB=\(scaleMegabytes(memoryBeforeInstall))"
                + " memoryBeforeReadyMB=\(scaleMegabytes(memoryBeforeReady))"
                + " memoryAfterReadyMB=\(scaleMegabytes(memoryAfterReady))"
                + " commands=\(commandsAtReady)"
        )

        // The harness recorder walks the hierarchy every frame it records; that
        // walk scales with the mounted row markers, so it is stopped for the
        // cost phases and restarted for no further waits.
        harness.recorder.stop()

        let scroll = try await measureScrollPhase(harness: harness, frames: frames, shape: shape)
        let stream = try await measureStreamPhase(
            harness: harness, frames: frames, shape: shape, base: harness.snapshot
        )
        let send = try await measureSendPhase(harness: harness, frames: frames, shape: shape)
        _ = try await measureBlankPhase(harness: harness, shape: shape)

        let memoryEnd = scaleResidentMemoryBytes()
        print(
            "CT13-CLOSE shape=\(shape)"
                + " scrollOver16_7=\(scroll.over16_7) scrollOver33=\(scroll.over33)"
                + " streamOver16_7=\(stream.over16_7) streamOver33=\(stream.over33)"
                + " sendOver16_7=\(send.over16_7) sendOver33=\(send.over33)"
                + " memoryEndMB=\(scaleMegabytes(memoryEnd))"
                + " commands=\(scaleCommandCounts(harness))"
                + " tailError=\(scalePoint(try harness.nativeTranscriptSignedTailError()))"
        )
        return true
    }

    // MARK: phases

    private struct PhaseOutcome {
        var samples = 0
        var over16_7 = 0
        var over33 = 0
    }

    /// One display frame per 600 pt step: up through the history and back to the
    /// tail. Each step writes the native content offset and lays out
    /// synchronously, which is the per-frame main-thread work this measures.
    private func measureScrollPhase(
        harness: ChatViewScrollHarness,
        frames: ScaleFrameIntervalRecorder,
        shape: String
    ) async throws -> PhaseOutcome {
        let steps = 60
        let stepPoints: CGFloat = 600
        frames.beginPhase()
        var stepDurations: [Double] = []
        var distances: [CGFloat] = (0..<steps).map { stepPoints * CGFloat($0) }
        distances += distances.reversed()
        for distance in distances {
            let startedAt = ContinuousClock.now
            try harness.displaceNativeTranscriptFromTail(by: distance)
            stepDurations.append(
                scaleMilliseconds(startedAt.duration(to: .now))
            )
            try await harness.driveFrameBoundary()
        }
        let intervals = frames.endPhase()
        return try report(
            harness: harness, shape: shape, phase: "scroll",
            intervals: intervals, stepDurations: stepDurations
        )
    }

    /// Streaming growth at the pinned tail: each step installs one longer
    /// assistant body and settles three display frames.
    private func measureStreamPhase(
        harness: ChatViewScrollHarness,
        frames: ScaleFrameIntervalRecorder,
        shape: String,
        base: SessionSnapshot
    ) async throws -> PhaseOutcome {
        var next = base
        next.phase = .running
        frames.beginPhase()
        var stepDurations: [Double] = []
        let growthSteps = 30
        for step in 1...growthSteps {
            next.streaming = try scaleAssistantMessage(
                id: "scale-streaming",
                presentationID: "scale-streaming",
                text: scaleStreamingBody(step: step, of: growthSteps)
            )
            next.revision += 1
            next.eventSequence += 1
            let startedAt = ContinuousClock.now
            harness.replaceAuthoritativeSnapshot(next)
            stepDurations.append(scaleMilliseconds(startedAt.duration(to: .now)))
            for _ in 0..<3 { try await harness.driveFrameBoundary() }
        }
        let intervals = frames.endPhase()
        return try report(
            harness: harness, shape: shape, phase: "stream",
            intervals: intervals, stepDurations: stepDurations
        )
    }

    /// The CT-2 send shape at these row counts: keyboard-sized contraction, a
    /// prompt submission, and the dismissal that lands in the same display
    /// window as the tail materialization.
    private func measureSendPhase(
        harness: ChatViewScrollHarness,
        frames: ScaleFrameIntervalRecorder,
        shape: String
    ) async throws -> PhaseOutcome {
        // Return to the pinned tail the way a reader does before typing.
        try harness.displaceNativeTranscriptFromTail(by: 0)
        for _ in 0..<10 { try await harness.driveFrameBoundary() }
        frames.beginPhase()
        var stepDurations: [Double] = []
        func step(_ body: () throws -> Void) async throws {
            let startedAt = ContinuousClock.now
            try body()
            stepDurations.append(scaleMilliseconds(startedAt.duration(to: .now)))
            try await harness.driveFrameBoundary()
        }
        try await step { harness.resize(height: 620) }
        for _ in 0..<9 { try await step {} }
        try await step { try harness.setComposerDraftText("Keep this scale shape stable.") }
        for _ in 0..<4 { try await step {} }
        try await step { harness.submitPrompt() }
        for _ in 0..<19 { try await step {} }
        try await step { harness.resize(height: 844) }
        for _ in 0..<29 { try await step {} }
        let intervals = frames.endPhase()
        return try report(
            harness: harness, shape: shape, phase: "send",
            intervals: intervals, stepDurations: stepDurations
        )
    }

    /// One keyboard up/down/up cycle sampled every frame through the live row
    /// hosts: the CT-2 blank-boundary measurement at this row count. Sampling
    /// walks the hierarchy each frame, so this phase reports visibility only.
    private func measureBlankPhase(
        harness: ChatViewScrollHarness,
        shape: String
    ) async throws -> Int {
        let segmentLength = 20
        // A phase's first two boundaries are its transition still landing, the
        // same settling bound the CT-2 fixtures use.
        let settlingBoundaries = 2
        var blank = 0
        var blankAfterSettle = 0
        var samples = 0
        var visibleMinimum = Int.max
        var phaseBlanks: [String] = []
        for (segment, height) in [CGFloat(620), 844, 620].enumerated() {
            harness.resize(height: height)
            var segmentBlank = 0
            for frame in 0..<segmentLength {
                try await harness.driveFrameBoundary()
                let sample = try harness.ct2BoundarySample(tallSemanticID: "")
                samples += 1
                visibleMinimum = min(visibleMinimum, sample.visibleRowCount)
                guard sample.visibleRowCount == 0 else { continue }
                blank += 1
                segmentBlank += 1
                if frame >= settlingBoundaries { blankAfterSettle += 1 }
            }
            phaseBlanks.append("p\(segment):\(segmentBlank)")
        }
        print(
            "CT13-BLANK shape=\(shape) samples=\(samples) blankBoundaries=\(blank)/\(samples)"
                + " blankAfterSettle=\(blankAfterSettle)"
                + " blankPhases=\(phaseBlanks.joined(separator: ","))"
                + " visibleRowsMinimum=\(visibleMinimum)"
        )
        return blank
    }

    private func report(
        harness: ChatViewScrollHarness,
        shape: String,
        phase: String,
        intervals: [Double],
        stepDurations: [Double]
    ) throws -> PhaseOutcome {
        let sample = try harness.ct2BoundarySample(tallSemanticID: "")
        let sortedIntervals = intervals.sorted()
        let sortedSteps = stepDurations.sorted()
        var outcome = PhaseOutcome()
        outcome.samples = intervals.count
        outcome.over16_7 = intervals.count { $0 > 16.7 }
        outcome.over33 = intervals.count { $0 > 33 }
        print(
            "CT13-PHASE shape=\(shape) phase=\(phase)"
                + " frames=\(intervals.count) steps=\(stepDurations.count)"
                + " intervalMedianMs=\(scalePoint(scaleMedian(sortedIntervals)))"
                + " intervalP95Ms=\(scalePoint(scalePercentile(sortedIntervals, 0.95)))"
                + " intervalMaxMs=\(scalePoint(sortedIntervals.last ?? 0))"
                + " over16_7=\(outcome.over16_7) over33=\(outcome.over33)"
                + " stepMedianMs=\(scalePoint(scaleMedian(sortedSteps)))"
                + " stepP95Ms=\(scalePoint(scalePercentile(sortedSteps, 0.95)))"
                + " stepMaxMs=\(scalePoint(sortedSteps.last ?? 0))"
                + " visibleRows=\(sample.visibleRowCount)"
                + " contentHeight=\(scalePoint(sample.contentHeight))"
                + " offsetY=\(scalePoint(sample.offsetY))"
                + " residentMB=\(scaleMegabytes(scaleResidentMemoryBytes()))"
        )
        return outcome
    }
}

// MARK: - fixture content

/// A 150/300/512-item transcript of heavy mixed rows: a user prompt with a
/// paragraph body and a file chip, a rich assistant body (heading, prose, a
/// fenced code block and a table), a completed tool run, and a shorter
/// assistant body with a table. Four items per cycle, so every shape has the
/// same content mixture at a different length.
private func scaleMixedSnapshot(rowCount: Int) throws -> SessionSnapshot {
    var snapshot = try SessionScenarioBuilder(seed: 1_268)
        .openingTail(targetEncodedBytes: 10_000)
    snapshot.acceptsQueuedPrompts = false
    var transcript: [TranscriptItem] = []
    var executions: [ToolExecutionState] = []
    transcript.reserveCapacity(rowCount)
    for index in 0..<rowCount {
        switch index % 4 {
        case 0:
            transcript.append(try scaleUserMessage(index: index))
        case 1:
            transcript.append(try scaleAssistantMessage(
                id: "scale-markdown-\(index)",
                presentationID: "scale-turn-\(index)",
                text: scaleMarkdownBody(index: index)
            ))
        case 2:
            transcript.append(try scaleToolCallMessage(index: index))
            executions.append(scaleCompletedToolExecution(index: index))
        default:
            transcript.append(try scaleAssistantMessage(
                id: "scale-summary-\(index)",
                presentationID: "scale-turn-\(index)",
                text: scaleSummaryBody(index: index)
            ))
        }
    }
    snapshot.transcript = transcript
    snapshot.transcriptStart = 0
    snapshot.transcriptTotal = transcript.count
    snapshot.toolExecutions = executions
    return snapshot
}

private func scaleUserMessage(index: Int) throws -> TranscriptItem {
    var content: [[String: Any]] = [
        [
            "id": "scale-prompt-\(index):text",
            "ordinal": 0,
            "type": "text",
            "text": "Prompt \(index) asks for the same shape again. "
                + "It keeps a paragraph of prose so the bubble wraps over several lines, "
                + "then states the constraint that must survive the change: the transcript "
                + "must look and behave exactly as it does today."
        ]
    ]
    if index.isMultiple(of: 8) {
        content.append([
            "id": "scale-prompt-\(index):attachment",
            "ordinal": 1,
            "type": "image",
            "attachment": [
                "name": "notes-\(index).pdf",
                "mimeType": "application/pdf",
                "size": 240_000
            ]
        ])
    }
    let data = try JSONSerialization.data(withJSONObject: [
        "id": "scale-prompt-\(index)",
        "parentId": NSNull(),
        "presentationId": "scale-prompt-\(index)",
        "timestamp": "2026-01-01T00:00:00Z",
        "kind": "message",
        "role": "user",
        "content": content
    ])
    return try decodeTranscriptFixture(TranscriptItem.self, from: data)
}

private func scaleAssistantMessage(
    id: String,
    presentationID: String,
    text: String
) throws -> TranscriptItem {
    let data = try JSONSerialization.data(withJSONObject: [
        "id": id,
        "parentId": NSNull(),
        "presentationId": presentationID,
        "timestamp": "2026-01-01T00:00:00Z",
        "kind": "message",
        "role": "assistant",
        "content": [["id": "\(id):text", "ordinal": 0, "type": "text", "text": text]]
    ])
    return try decodeTranscriptFixture(TranscriptItem.self, from: data)
}

private func scaleToolCallMessage(index: Int) throws -> TranscriptItem {
    let data = try JSONSerialization.data(withJSONObject: [
        "id": "scale-tool-\(index)",
        "parentId": NSNull(),
        "presentationId": "scale-tool-\(index)",
        "timestamp": "2026-01-01T00:00:00Z",
        "kind": "message",
        "role": "assistant",
        "content": [[
            "id": "scale-tool-\(index):call",
            "ordinal": 0,
            "type": "toolCall",
            "toolCallId": "scale-call-\(index)",
            "name": ["read", "bash", "find"][index % 3],
            "arguments": ["path": "packages/ios-app/Sources/UI/Chat/ChatTranscriptScrollView.swift"],
            "toolSegmentId": "scale-segment-\(index)",
            "groupId": "scale-call-\(index)",
            "groupIndex": 0,
            "groupCount": 1,
            "groupFinalized": true
        ]]
    ])
    return try decodeTranscriptFixture(TranscriptItem.self, from: data)
}

private func scaleCompletedToolExecution(index: Int) -> ToolExecutionState {
    ToolExecutionState(
        toolCallId: "scale-call-\(index)",
        toolName: ["read", "bash", "find"][index % 3],
        order: index,
        status: .completed,
        arguments: .object(["path": .string("README.md")]),
        partialResult: nil,
        result: .object(["ok": .bool(true)]),
        output: "read \(index) lines from README.md",
        isError: false,
        startedAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:01Z",
        completedAt: "2026-01-01T00:00:01Z",
        durationMs: 1_000,
        progressSequence: 2,
        groupId: "scale-call-\(index)",
        groupIndex: 0,
        groupCount: 1,
        groupFinalized: true
    )
}

/// A rich assistant body: heading, two prose paragraphs, a fenced Swift block
/// and a small table. Every row is one physical row however long it is.
private func scaleMarkdownBody(index: Int) -> String {
    """
    ## Turn \(index) change summary

    The transcript installs physical rows from the bounded source window and \
    keeps one host per row. Row \(index) carries enough prose to wrap several \
    lines so that a realized row has real height beside its neighbours.

    The second paragraph states the invariant this measurement protects: the \
    chat must look and behave exactly as it does today, so any container change \
    must be measured before it is trusted.

    ```swift
    let row\(index) = ChatPhysicalTranscriptRowPolicy.rows(
        installed: installed,
        canonicalAliases: canonicalAliases
    )
    print(row\(index).count)
    ```

    | metric | row \(index) |
    | --- | --- |
    | interval median | 16.7 ms |
    | over 33 ms | count |
    | resident memory | megabytes |
    """
}

private func scaleSummaryBody(index: Int) -> String {
    """
    Turn \(index) also ends with a short table:

    | field | value |
    | --- | --- |
    | rows | \(index) |
    | estimate | none |

    Nothing else changed in this turn; the table exists so the row is not a \
    single line of text.
    """
}

private func scaleStreamingBody(step: Int, of steps: Int) -> String {
    let paragraphs = (1...step).map { paragraph in
        "Streaming paragraph \(paragraph) of \(steps) keeps the tail growing while "
            + "the reader watches, with enough prose that each growth step changes the "
            + "row's measured height instead of only its text."
    }
    return paragraphs.joined(separator: "\n\n")
}

// MARK: - measurement support

/// The observation's command counters, so the eager and lazy columns can be
/// compared on what the coordinator had to do.
@MainActor
private func scaleCommandCounts(_ harness: ChatViewScrollHarness) -> String {
    let observation = harness.probeObservation
    return "materialize:\(observation.tailMaterializationCommandCount)"
        + ",physical:\(observation.physicalTailRepairCommandCount)"
        + ",pastEnd:\(observation.pastEndRepairCommandCount)"
        + ",automatic:\(observation.automaticScrollCommandCount)"
        + ",smooth:\(observation.smoothAutomaticScrollCommandCount)"
}

/// A shape whose opening never publishes a ready frame is abandoned after this
/// bound: the product's own opening deadline is 30 s, so a bound well past it
/// still reports the failure without holding the runner's no-output deadline.
private let scaleReadyBoundSeconds = 60

/// Races the ready sample against the bound. The harness's own wait is
/// cancellation-aware, so the losing branch exits instead of stranding the
/// process.
@MainActor
private func scaleWaitForReady(
    harness: ChatViewScrollHarness,
    timeout: Duration
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            (try? await harness.recorder.waitUntil { $0.observation.isReady }) != nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

/// The product's opening attempt interval, whether or not it succeeded: the
/// failed case ends at the product's own opening deadline.
private func scaleAttemptDuration(_ signposts: ScaleTimestampedSignposts) -> Duration {
    signposts.lastSpan(of: .firstReadyFrame) ?? .zero
}

/// Frame-interval summary used by the opening diagnostic.
private func scaleIntervalStats(_ intervals: [Double]) -> (maximum: Double, over33: Int) {
    (
        maximum: intervals.max() ?? 0,
        over33: intervals.filter { $0 > 33 }.count
    )
}

/// The product's own interval measurements, timestamped with
/// `ContinuousClock` so a fixture can report how long the opening took without
/// depending on the signpost system's on-device trace.
private final class ScaleTimestampedSignposts: PerformanceSignposting, @unchecked Sendable {
    private struct Entry: Sendable {
        let operation: PerformanceOperation
        let start: ContinuousClock.Instant
        var end: ContinuousClock.Instant?
        var result: PerformanceResult?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func begin(_ operation: PerformanceOperation) -> PerformanceInterval {
        let start = ContinuousClock.now
        lock.withLock { entries.append(Entry(operation: operation, start: start)) }
        return PerformanceInterval(operation: operation, measuredStart: start)
    }

    func end(
        _ interval: PerformanceInterval,
        result: PerformanceResult,
        metrics: PerformanceMetrics
    ) {
        let end = ContinuousClock.now
        lock.withLock {
            guard let index = entries.lastIndex(where: {
                $0.operation == interval.operation && $0.end == nil
            }) else { return }
            entries[index].end = end
            entries[index].result = result
        }
    }

    /// The duration of the last finished interval that did not fail.
    func duration(of operation: PerformanceOperation) -> Duration? {
        lock.withLock {
            var latest: Duration?
            for entry in entries where entry.operation == operation && entry.result == .success {
                guard let end = entry.end else { continue }
                latest = end - entry.start
            }
            return latest
        }
    }

    func entries(of operation: PerformanceOperation) -> Int {
        lock.withLock { entries.filter { $0.operation == operation }.count }
    }

    /// The wall-clock span of the last interval of `operation`, finished or not,
    /// so a failed opening reports the product's own deadline and not zero.
    func lastSpan(of operation: PerformanceOperation) -> Duration? {
        lock.withLock {
            var latest: Duration?
            for entry in entries where entry.operation == operation {
                latest = (entry.end ?? ContinuousClock.now) - entry.start
            }
            return latest
        }
    }
}

/// Display-link frame intervals on the main run loop. A frame whose work
/// overruns the display period delays the next callback, so the interval is the
/// main thread's blocking time per frame as the renderer sees it.
@MainActor
private final class ScaleFrameIntervalRecorder: NSObject {
    private var displayLink: CADisplayLink?
    private var marks: [CFTimeInterval] = []
    private var phaseStart = 0

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        marks.append(CACurrentMediaTime())
    }

    func beginPhase() {
        phaseStart = marks.count
    }

    /// Milliseconds between consecutive frame callbacks since `beginPhase`.
    func endPhase() -> [Double] {
        let slice = Array(marks[phaseStart...])
        phaseStart = marks.count
        guard slice.count > 1 else { return [] }
        var intervals: [Double] = []
        intervals.reserveCapacity(slice.count - 1)
        for index in 1..<slice.count {
            intervals.append((slice[index] - slice[index - 1]) * 1_000)
        }
        return intervals
    }
}

private func scaleMedian(_ sorted: [Double]) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
        ? (sorted[middle - 1] + sorted[middle]) / 2
        : sorted[middle]
}

private func scalePercentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[max(0, min(sorted.count - 1, index))]
}

/// `ContinuousClock.Duration` as milliseconds.
private func scaleMilliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func scaleResidentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

private func scaleMegabytes(_ bytes: UInt64) -> Double {
    (Double(bytes) / 1_048_576 * 10).rounded() / 10
}

private func scalePoint(_ value: CGFloat) -> Double {
    (Double(value) * 10).rounded() / 10
}
