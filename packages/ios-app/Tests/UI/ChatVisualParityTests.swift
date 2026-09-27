import Foundation
import Testing
import UIKit

@testable import TronMobile

// MARK: - The gate's fingerprint

/// How one rendered frame is reduced to something comparable. The gate's job is
/// to reject a candidate transcript container that looks or moves differently
/// from the recorded chat, so the fingerprint keeps the axis where a transcript
/// changes when it moves: mean luminance per 2-point row band across the full
/// window width. Two points is the resolution limit that matters here, because
/// the smallest layout difference the gate must reject is the 2-point row
/// spacing control, and the reveal oracle already showed that a coarser grid
/// aliases sub-point motion into its samples. The second profile is the mean
/// luminance per 8-point column band across the full height, which carries
/// horizontal ink changes (a row's alignment, glyph weight or Markdown
/// rendering) at a fraction of a full grid's size. The unquantized rendered
/// frames are retained as per-frame PNG artifacts for a human to inspect.
enum ChatVisualParitySpec {
    static let rowStep = 2
    static let columnStep = 8

    /// Per-frame tolerance: the normalized RMS luminance difference of a
    /// candidate frame against its recorded reference frame over both profiles,
    /// after the bounded vertical alignment above. It is stated here, recorded
    /// in the committed manifest, and set from the noise the three-run
    /// determinism check measured plus a margin — never widened past it.
    /// `docs/development.md` owns the recorded numbers.
    static let tolerance = 0.010

    /// How far a candidate frame may be re-aligned vertically, in 2-point row
    /// bands, before its diff counts. A pinned transcript settles within a
    /// couple of points run to run, which the harness's own tail checks also
    /// allow, so an unaligned comparison would measure that sub-point settle as
    /// if it were a layout change.
    static let alignmentBands = 2

    /// How many frames away a candidate frame may be matched to a recorded frame.
    /// A recorded animation frame lands up to one display boundary away from the
    /// same rendered state in the next run, because the reference container
    /// (a `LazyVStack`) decides when its animated row moves on its own clock, and
    /// a boundary-aligned comparison would otherwise read that one-frame timing
    /// difference as a different picture. Three boundaries is about 50 ms: wide
    /// enough for the recorded reference's own jitter, narrow enough that a
    /// different motion trajectory still has to match a recorded frame — the
    /// entrance-rise control moves the outgoing row 6 points over a 20-point
    /// rise, more than one matched frame's worth of travel at either end.
    static let matchWindow = 3
}

/// One sampled frame's fingerprint, with the window size it was rendered at so
/// a container that resizes the window is reported rather than compared against
/// a differently shaped frame.
struct ChatVisualParityFingerprint: Equatable {
    let width: Int
    let height: Int
    let rows: [UInt8]
    let columns: [UInt8]

    /// Re-label a fingerprint the manifest already stores as two bands.
    init(width: Int, height: Int, rows: [UInt8], columns: [UInt8]) {
        self.width = width
        self.height = height
        self.rows = rows
        self.columns = columns
    }

    init(width: Int, height: Int, luminance: [UInt8]) {
        self.width = width
        self.height = height
        let bands = ChatVisualParityFingerprint.bands(
            luminance: luminance,
            width: width,
            height: height,
            rowStep: ChatVisualParitySpec.rowStep,
            columnStep: ChatVisualParitySpec.columnStep
        )
        rows = bands.rows
        columns = bands.columns
    }

    private static func bands(
        luminance: [UInt8],
        width: Int,
        height: Int,
        rowStep: Int,
        columnStep: Int
    ) -> (rows: [UInt8], columns: [UInt8]) {
        guard width > 0, height > 0, luminance.count >= width * height else { return ([], []) }
        let rowBands = (height + rowStep - 1) / rowStep
        let columnBands = (width + columnStep - 1) / columnStep
        var rowSums = [Int](repeating: 0, count: rowBands)
        var columnSums = [Int](repeating: 0, count: columnBands)
        for y in 0..<height {
            let base = y * width
            let rowBand = y / rowStep
            for x in 0..<width {
                let value = Int(luminance[base + x])
                rowSums[rowBand] += value
                columnSums[x / columnStep] += value
            }
        }
        func bandLength(_ index: Int, total: Int, step: Int) -> Int {
            let start = index * step
            return min(step, total - start)
        }
        let rows = rowSums.enumerated().map { index, sum -> UInt8 in
            UInt8(sum / (bandLength(index, total: height, step: rowStep) * width))
        }
        let columns = columnSums.enumerated().map { index, sum -> UInt8 in
            UInt8(sum / (bandLength(index, total: width, step: columnStep) * height))
        }
        return (rows, columns)
    }

    /// The frame's diff against its reference after the best alignment: the
    /// normalized RMS luminance difference of the row profile (which is what a
    /// vertical move changes) minimized over shifts of at most `alignmentBands`
    /// bands, plus the unshifted column profile.
    static func magnitude(
        _ candidate: ChatVisualParityFingerprint,
        _ reference: ChatVisualParityFingerprint,
        alignmentBands: Int
    ) -> (magnitude: Double, shift: Int) {
        guard candidate.rows.count == reference.rows.count,
              candidate.columns.count == reference.columns.count,
              !candidate.rows.isEmpty, !candidate.columns.isEmpty else { return (.infinity, 0) }
        var best = (magnitude: Double.infinity, shift: 0)
        for shift in -alignmentBands...alignmentBands {
            let start = max(0, -shift)
            let end = min(reference.rows.count, reference.rows.count - shift)
            guard end > start else { continue }
            var squared = 0.0
            var count = 0
            for index in start..<end {
                let delta = (Double(candidate.rows[index + shift]) - Double(reference.rows[index])) / 255
                squared += delta * delta
                count += 1
            }
            for (candidateValue, referenceValue) in zip(candidate.columns, reference.columns) {
                let delta = (Double(candidateValue) - Double(referenceValue)) / 255
                squared += delta * delta
                count += 1
            }
            let magnitude = (squared / Double(count)).squareRoot()
            if magnitude < best.magnitude { best = (magnitude, shift) }
        }
        return best
    }
}

/// One captured parity frame: where it sits in its scenario, the phase the
/// driver was in, and the fingerprint the gate compares.
struct ChatVisualParityFrame {
    let index: Int
    let phase: String
    let fingerprint: ChatVisualParityFingerprint
}

// MARK: - Committed manifest and run report

/// Byte arrays persist as base64 so the committed manifest stays small enough
/// to review and diff as text.
struct ChatVisualParityBytes: Codable, Equatable {
    let values: [UInt8]

    init(_ values: [UInt8]) { self.values = values }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let data = Data(base64Encoded: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected base64 fingerprint bytes"
            )
        }
        values = [UInt8](data)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Data(values).base64EncodedString())
    }
}

/// The committed reference: one fingerprint per sampled display boundary of each
/// scenario, recorded from the unchanged chat. The per-frame artifacts the
/// recording also writes are PNGs at `packages/ios-app/build/parity-reference/`,
/// which is git-ignored; this file is what a candidate run on any machine can be
/// compared against.
struct ChatVisualParityManifest: Codable, Equatable {
    struct FingerprintSpec: Codable, Equatable {
        let rowStep: Int
        let columnStep: Int
        /// The comparison's vertical alignment window, in row bands.
        let alignmentBands: Int
        /// The comparison's frame-match window, in recorded frames.
        let matchWindow: Int
    }

    struct Frame: Codable, Equatable {
        let index: Int
        let phase: String
        let width: Int
        let height: Int
        let rows: ChatVisualParityBytes
        let columns: ChatVisualParityBytes
    }

    struct Scenario: Codable, Equatable {
        let id: String
        let frames: [Frame]
    }

    let schema: String
    let fingerprint: FingerprintSpec
    let tolerance: Double
    let window: [Int]
    let systemVersion: String
    let scenarios: [Scenario]
}

/// The gate's JSON report: the worst frames per scenario and their diff
/// magnitude, written beside the run's artifacts so a failure names its frames.
struct ChatVisualParityReport: Codable, Equatable {
    /// One recorded frame's diff: the largest such diff a candidate run had for
    /// that recorded frame, and the rendered frame it was matched to.
    struct FrameDiff: Codable, Equatable {
        let index: Int
        let phase: String
        let magnitude: Double
        let matchedFrame: Int
        /// The vertical band shift that produced this frame's magnitude.
        let shift: Int
    }

    struct Scenario: Codable, Equatable {
        let id: String
        let recordedFrames: Int
        let renderedFrames: Int
        /// Every compared frame's diff, in frame order.
        let frames: [FrameDiff]
        /// The largest diffs, worst first: what a failure names.
        let worstFrames: [FrameDiff]
        let maximumMagnitude: Double
        let passed: Bool
        let note: String?
    }

    let schema: String
    let mode: String
    let tolerance: Double
    let passed: Bool
    let scenarios: [Scenario]
}

// MARK: - Recording and reporting paths

/// Where the gate reads its committed reference and writes what a run leaves
/// behind. `#filePath` is this file's host path, so a run records and reports in
/// the worktree it was built from, and the artifacts stay under the git-ignored
/// `packages/ios-app/build`.
@MainActor
enum ChatVisualParityStore {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let referenceURL = packageRoot.appending(path: "Tests/Fixtures/ChatVisualParityManifest.json")
    static let artifactsRoot = packageRoot.appending(path: "build/parity-reference")

    /// A missing committed manifest is the recording mode's whole switch: the
    /// gate verifies against it when it exists and records it when it does not,
    /// so no scheme variable or hidden flag decides what a run means.
    static var isRecording: Bool {
        !FileManager.default.fileExists(atPath: referenceURL.path)
    }

    static func scenarioDirectory(_ id: String) -> URL {
        artifactsRoot.appending(path: id, directoryHint: .isDirectory)
    }

    static func writeArtifacts(id: String, frames: [ChatVisualParityFrame], pngs: [Data]) throws {
        let directory = scenarioDirectory(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (frame, png) in zip(frames, pngs) {
            let name = String(format: "frame-%03d-%@.png", frame.index, frame.phase)
            try png.write(to: directory.appending(path: name))
        }
    }

    static func writeManifest(_ manifest: ChatVisualParityManifest) throws {
        try FileManager.default.createDirectory(at: artifactsRoot, withIntermediateDirectories: true)
        try encoded(manifest).write(to: artifactsRoot.appending(path: "manifest.json"))
    }

    static func readManifest() throws -> ChatVisualParityManifest {
        let data = try Data(contentsOf: referenceURL)
        return try JSONDecoder().decode(ChatVisualParityManifest.self, from: data)
    }

    static func writeReport(_ report: ChatVisualParityReport) throws {
        try FileManager.default.createDirectory(at: artifactsRoot, withIntermediateDirectories: true)
        try encoded(report).write(to: artifactsRoot.appending(path: "report.json"))
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}

// MARK: - Driving one scenario

/// Drives one scenario's harness, captures its frames, and owns the scenario's
/// per-frame artifacts.
@MainActor
final class ChatVisualParityRunner {
    let id: String
    let harness: ChatViewScrollHarness
    private(set) var frames: [ChatVisualParityFrame] = []
    private var pngs: [Data] = []
    private let recordsArtifacts: Bool

    init(id: String, harness: ChatViewScrollHarness, recordsArtifacts: Bool) {
        self.id = id
        self.harness = harness
        self.recordsArtifacts = recordsArtifacts
    }

    /// Capture the rendered window as this boundary's frame. The transcript's
    /// settled native offset moves by a fraction of a point run to run, so the
    /// offset is snapped to a whole point first: what the gate compares is then a
    /// deterministic function of the layout rather than of the lazy estimate.
    func capture(_ phase: String) {
        try? harness.snapNativeTranscriptOffsetToWholePoint()
        let rendered = harness.renderedWindowFrame(includingPNG: recordsArtifacts)
        frames.append(ChatVisualParityFrame(
            index: frames.count,
            phase: phase,
            fingerprint: ChatVisualParityFingerprint(
                width: rendered.width,
                height: rendered.height,
                luminance: rendered.luminance
            )
        ))
        if let png = rendered.png { pngs.append(png) }
    }

    /// Advance a fixed number of display boundaries, capturing one frame each:
    /// the sample instants are part of the scenario's input, so a recorded frame
    /// index means the same boundary in every run.
    func advance(_ phase: String, boundaries: Int) async throws {
        for _ in 0..<boundaries {
            try await harness.driveFrameBoundary()
            capture(phase)
        }
    }

    /// Drive display boundaries until the transcript stops changing. A settled
    /// state is timing-independent even though reaching it is not, so scenarios
    /// start their fixed frame sequence from this state.
    func settle(stableBoundaries: Int = 8, cap: Int = 150) async throws {
        var lastChange = harness.recorder.samples.last?.frameIndex ?? 0
        var stable = 0
        for _ in 0..<cap {
            try await harness.driveFrameBoundary()
            let current = harness.recorder.samples.last?.frameIndex ?? 0
            if current == lastChange {
                stable += 1
                if stable >= stableBoundaries { return }
            } else {
                stable = 0
                lastChange = current
            }
        }
    }

    func writeArtifacts() throws {
        guard recordsArtifacts else { return }
        try ChatVisualParityStore.writeArtifacts(id: id, frames: frames, pngs: pngs)
    }
}

// MARK: - Scenarios

@MainActor
struct ChatVisualParityScenario {
    let id: String
    let run: @MainActor () async throws -> ChatVisualParityRunner

    static var all: [ChatVisualParityScenario] {
        [
            ChatVisualParityScenario(id: "opened-long-history-at-rest", run: openedLongHistoryAtRest),
            ChatVisualParityScenario(id: "ordinary-send-keyboard-up", run: ordinarySendWithKeyboardUp),
            ChatVisualParityScenario(id: "streaming-tail-growth", run: streamingTailGrowth),
            ChatVisualParityScenario(id: "queued-card-to-sent-row", run: queuedCardToSentRow),
            ChatVisualParityScenario(id: "tool-chip-entrance", run: toolChipEntrance),
            ChatVisualParityScenario(id: "earlier-page-load-at-rest", run: earlierPageLoadAtRest),
            ChatVisualParityScenario(id: "detached-reader-catch-up", run: detachedReaderCatchUp),
        ]
    }
}

@MainActor
private func runScenario(
    id: String,
    snapshot: SessionSnapshot,
    submitsPrompts: Bool,
    body: @MainActor (ChatVisualParityRunner) async throws -> Void
) async throws -> ChatVisualParityRunner {
    let harness: ChatViewScrollHarness
    if submitsPrompts {
        harness = try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink
        )
    } else {
        harness = try ChatViewScrollHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink
        )
    }
    let runner = ChatVisualParityRunner(
        id: id,
        harness: harness,
        recordsArtifacts: ChatVisualParityStore.isRecording
    )
    do {
        _ = try await harness.recorder.waitUntil { $0.observation.isReady }
        try await body(runner)
        try runner.writeArtifacts()
    } catch {
        await harness.close()
        throw error
    }
    await harness.close()
    return runner
}

/// A long mixed history: one-line replies, multi-paragraph replies with bounded
/// reasoning, Markdown-rich replies with headings, lists, code and a table, and
/// right-aligned user rows. The shapes and their text are fixed, so a recorded
/// frame corresponds to the same content in every run.
private func parityMixedHistory(rowCount: Int) throws -> SessionSnapshot {
    var snapshot = try SessionScenarioBuilder(seed: 1_268).openingTail(targetEncodedBytes: 10_000)
    snapshot.acceptsQueuedPrompts = false
    snapshot.transcript = try (0..<rowCount).map { index in
        switch index % 6 {
        case 1, 4:
            return try parityUserMessage(
                id: "parity-user-\(index)",
                text: "User question \(index) asks about the transcript."
            )
        case 2:
            return try harnessRichAssistantMessage(
                id: "parity-history-\(index)",
                presentationID: "parity-turn-\(index)",
                thinkingLines: index % 12 == 2 ? ["Bounded parity reasoning for row \(index)."] : [],
                text: parityParagraphs(row: index, count: 3)
            )
        case 3:
            return try harnessRichAssistantMessage(
                id: "parity-history-\(index)",
                presentationID: "parity-turn-\(index)",
                thinkingLines: [],
                text: parityMarkdownRow(index)
            )
        default:
            return try harnessRichAssistantMessage(
                id: "parity-history-\(index)",
                presentationID: "parity-turn-\(index)",
                thinkingLines: [],
                text: parityParagraphs(row: index, count: 1 + index % 4)
            )
        }
    }
    snapshot.transcriptStart = 0
    snapshot.transcriptTotal = snapshot.transcript.count
    snapshot.toolExecutions = []
    return snapshot
}

/// A short history that still ends on an assistant row, with earlier pages
/// available so the earlier-messages row is part of the rendered chat.
private func parityShortHistory(rowCount: Int, earlierMessages: Int) throws -> SessionSnapshot {
    var snapshot = try parityMixedHistory(rowCount: rowCount)
    snapshot.transcriptStart = earlierMessages
    snapshot.transcriptTotal = earlierMessages + snapshot.transcript.count
    return snapshot
}

private func parityParagraphs(row: Int, count: Int) -> String {
    (0..<count).map { paragraph in
        "Row \(row) paragraph \(paragraph) keeps this history at a mixed height with deterministic prose."
    }.joined(separator: "\n\n")
}

private func parityMarkdownRow(_ index: Int) -> String {
    """
    ## Parity heading \(index)

    Text with **bold**, *italic*, `inline code` and a [link](https://example.invalid).

    - first item
    - second item

    ```swift
    let parityValue\(index) = \(index)
    ```

    | name | value |
    | --- | ---: |
    | row | \(index) |
    """
}

/// Multiline assistant content, built through JSON serialization because the
/// escaping-free fixture helpers only accept single-line text.
private func parityAssistantMessage(id: String, text: String) throws -> TranscriptItem {
    try decodeTranscriptFixture(
        TranscriptItem.self,
        from: JSONSerialization.data(withJSONObject: [
            "id": id, "parentId": NSNull(), "presentationId": id,
            "timestamp": "2026-01-01T00:00:00Z", "kind": "message", "role": "assistant",
            "content": [["id": "\(id):text", "ordinal": 0, "type": "text", "text": text]],
        ])
    )
}

private func parityUserMessage(id: String, text: String) throws -> TranscriptItem {
    try decodeTranscriptFixture(
        TranscriptItem.self,
        from: JSONSerialization.data(withJSONObject: [
            "id": id, "parentId": NSNull(), "presentationId": id,
            "timestamp": "2026-01-01T00:00:00Z", "kind": "message", "role": "user",
            "content": [["id": "\(id):text", "ordinal": 0, "type": "text", "text": text]],
        ])
    )
}

private func parityStreamingText(step: Int) -> String {
    (1...step).map { paragraph in
        "Streaming paragraph \(paragraph) of step \(step) grows the tail assistant row."
    }.joined(separator: "\n\n")
}

/// (a) An opened long mixed history at rest, pinned at its tail.
@MainActor
private func openedLongHistoryAtRest() async throws -> ChatVisualParityRunner {
    let snapshot = try parityMixedHistory(rowCount: 140)
    return try await runScenario(
        id: "opened-long-history-at-rest",
        snapshot: snapshot,
        submitsPrompts: false
    ) { run in
        try await run.settle()
        try await run.advance("rest", boundaries: 8)
        let tailError = try run.harness.nativeTranscriptDistanceFromTail()
        #expect(tailError <= 2, "the opened history stayed pinned: tail error \(tailError)")
    }
}

/// (b) An ordinary send with the keyboard up. The hosted harness has no
/// software keyboard, so the keyboard is the keyboard-sized viewport change the
/// coordinator's layout transaction consumes, exactly as the CT-2 baseline
/// shapes drive it; the send, the outgoing entrance and the composer collapse
/// are the production ones.
@MainActor
private func ordinarySendWithKeyboardUp() async throws -> ChatVisualParityRunner {
    let snapshot = try parityMixedHistory(rowCount: 60)
    return try await runScenario(
        id: "ordinary-send-keyboard-up",
        snapshot: snapshot,
        submitsPrompts: true
    ) { run in
        let harness = run.harness
        try await run.settle()
        try await run.advance("pinned", boundaries: 2)
        harness.resize(height: 620)
        try await run.advance("keyboard-up", boundaries: 4)
        try harness.setComposerDraftText("Keep the parity transcript stable through this send.")
        try await run.advance("draft", boundaries: 2)
        harness.submitPrompt()
        try await run.advance("outgoing-entrance", boundaries: 10)
        harness.resize(height: 844)
        try await run.advance("keyboard-dismissal", boundaries: 10)
        try await run.advance("settled", boundaries: 3)
        let tailError = try harness.nativeTranscriptDistanceFromTail()
        #expect(tailError <= 2, "the send settled on the native tail: tail error \(tailError)")
    }
}

/// (c) Streaming growth of the tail assistant row.
@MainActor
private func streamingTailGrowth() async throws -> ChatVisualParityRunner {
    var snapshot = try parityMixedHistory(rowCount: 40)
    snapshot.acceptsQueuedPrompts = false
    snapshot.phase = .running
    let initial = snapshot
    return try await runScenario(
        id: "streaming-tail-growth",
        snapshot: snapshot,
        submitsPrompts: false
    ) { run in
        let harness = run.harness
        try await run.settle()
        try await run.advance("rest", boundaries: 2)
        var next = initial
        for step in 1...5 {
            next.streaming = try parityAssistantMessage(
                id: "parity-stream",
                text: parityStreamingText(step: step)
            )
            next.revision += 1
            next.eventSequence += 1
            harness.replaceAuthoritativeSnapshot(next)
            // The growing row's own realization is not reproducible boundary for
            // boundary on the recorded lazy container (see the scenario's note in
            // `docs/development.md`), so the frame is taken once the growth has
            // landed.
            try await run.settle()
            try await run.advance("growth-\(step)", boundaries: 2)
        }
    }
}

/// (d) A queued card's cross-fade and shrink into its canonical sent row.
@MainActor
private func queuedCardToSentRow() async throws -> ChatVisualParityRunner {
    var initial = try parityShortHistory(rowCount: 9, earlierMessages: 0)
    initial.phase = .running
    initial.streaming = initial.transcript.last
    initial.queueRevision += 1
    initial.queuedItems = [
        .init(id: "parity-queued-operation", behavior: .steer, text: "A queued parity prompt", attachmentCount: 0)
    ]
    var canonical = initial
    canonical.revision += 1
    canonical.eventSequence += 1
    canonical.queueRevision += 1
    canonical.queuedItems = []
    canonical.transcript.append(try parityUserMessage(
        id: "queued-message-parity-queued-operation",
        text: "A queued parity prompt"
    ))
    canonical.transcriptTotal = (canonical.transcriptTotal ?? canonical.transcript.count - 1) + 1
    return try await runScenario(
        id: "queued-card-to-sent-row",
        snapshot: initial,
        submitsPrompts: false
    ) { run in
        let harness = run.harness
        try await run.settle()
        try await run.advance("queued-card", boundaries: 2)
        harness.replaceAuthoritativeSnapshot(canonical)
        try await run.advance("replacement", boundaries: 2)
        // The queued card's height interpolation passes through a state the
        // recorded container reaches in one run and not the next, so the
        // replacement's remaining frames are its landed state.
        try await run.settle()
        try await run.advance("replacement-settled", boundaries: 3)
        let tailError = try harness.nativeTranscriptDistanceFromTail()
        #expect(tailError <= 2, "the queued replacement held the tail: tail error \(tailError)")
    }
}

/// (e) A tool chip's entrance on a running call, then its completion.
@MainActor
private func toolChipEntrance() async throws -> ChatVisualParityRunner {
    var snapshot = try parityShortHistory(rowCount: 9, earlierMessages: 0)
    snapshot.acceptsQueuedPrompts = false
    let initial = snapshot
    var running = snapshot
    running.phase = .running
    running.toolExecutions = [harnessRuntimeTool(status: .running, groupFinalized: false)]
    running.eventSequence += 1
    var completed = running
    completed.toolExecutions = [harnessRuntimeTool(status: .completed, groupId: "settled-group")]
    completed.eventSequence += 1
    return try await runScenario(
        id: "tool-chip-entrance",
        snapshot: initial,
        submitsPrompts: false
    ) { run in
        let harness = run.harness
        try await run.settle()
        try await run.advance("rest", boundaries: 2)
        harness.replaceAuthoritativeSnapshot(running)
        try await run.advance("chip-entrance", boundaries: 2)
        try await run.settle()
        try await run.advance("chip-entrance-settled", boundaries: 2)
        harness.replaceAuthoritativeSnapshot(completed)
        try await run.advance("chip-completion", boundaries: 2)
        try await run.settle()
        try await run.advance("chip-completion-settled", boundaries: 2)
    }
}

/// (f) An earlier-page load at rest. The short history's earlier-messages row is
/// visible, so the load's own state — the row's loading presentation and the
/// anchor the page restores — is what the frames carry.
@MainActor
private func earlierPageLoadAtRest() async throws -> ChatVisualParityRunner {
    let snapshot = try parityShortHistory(rowCount: 6, earlierMessages: 40)
    return try await runScenario(
        id: "earlier-page-load-at-rest",
        snapshot: snapshot,
        submitsPrompts: false
    ) { run in
        let harness = run.harness
        try await run.settle()
        try await run.advance("rest", boundaries: 2)
        #expect(harness.drivePrepend(), "the earlier-messages row admitted its page load")
        try await run.advance("loading", boundaries: 4)
        harness.releasePrependPage()
        try await run.advance("completing", boundaries: 4)
    }
}

/// (g) A detached reader receiving a new projection, then its catch-up.
@MainActor
private func detachedReaderCatchUp() async throws -> ChatVisualParityRunner {
    let snapshot = try parityShortHistory(rowCount: 9, earlierMessages: 0)
    return try await runScenario(
        id: "detached-reader-catch-up",
        snapshot: snapshot,
        submitsPrompts: false
    ) { run in
        let harness = run.harness
        try await run.settle()
        try await run.advance("rest", boundaries: 2)
        let bottom = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_000, containerHeight: 400)
        let away = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_000, containerHeight: 400)
        harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
        harness.driveNativeOwnership(true)
        harness.driveGeometry(previous: bottom, current: away)
        harness.drivePhase(from: .interacting, to: .idle, geometry: away)
        harness.driveNativeOwnership(false)
        try await run.advance("detached", boundaries: 2)
        var updated = snapshot
        updated.transcript.append(try harnessMessage(id: "parity-detached-tail"))
        updated.transcriptTotal = (updated.transcriptTotal ?? updated.transcript.count - 1) + 1
        updated.revision += 1
        updated.eventSequence += 1
        harness.replaceAuthoritativeSnapshot(updated)
        try await run.advance("frozen", boundaries: 3)
        harness.driveCatchUp(reduceMotion: true)
        try await run.advance("catch-up", boundaries: 4)
        harness.driveGeometry(previous: away, current: bottom, viewport: true)
        try await run.advance("settled", boundaries: 3)
    }
}

// MARK: - The gate

@MainActor
enum ChatVisualParityGate {
    static func run() async throws {
        let recording = ChatVisualParityStore.isRecording
        var runs: [ChatVisualParityRunner] = []
        for scenario in ChatVisualParityScenario.all {
            do {
                runs.append(try await scenario.run())
            } catch {
                Issue.record("visual parity scenario \(scenario.id) did not run: \(error)")
            }
        }
        if recording {
            try record(runs)
        } else {
            try verify(runs)
        }
    }

    private static func record(_ runs: [ChatVisualParityRunner]) throws {
        let manifest = ChatVisualParityManifest(
            schema: "tron.chat-visual-parity.v1",
            fingerprint: .init(
                rowStep: ChatVisualParitySpec.rowStep,
                columnStep: ChatVisualParitySpec.columnStep,
                alignmentBands: ChatVisualParitySpec.alignmentBands,
                matchWindow: ChatVisualParitySpec.matchWindow
            ),
            tolerance: ChatVisualParitySpec.tolerance,
            window: [390, 844],
            systemVersion: UIDevice.current.systemVersion,
            scenarios: runs.map { run in
                ChatVisualParityManifest.Scenario(
                    id: run.id,
                    frames: run.frames.map { frame in
                        ChatVisualParityManifest.Frame(
                            index: frame.index,
                            phase: frame.phase,
                            width: frame.fingerprint.width,
                            height: frame.fingerprint.height,
                            rows: ChatVisualParityBytes(frame.fingerprint.rows),
                            columns: ChatVisualParityBytes(frame.fingerprint.columns)
                        )
                    }
                )
            }
        )
        try ChatVisualParityStore.writeManifest(manifest)
        for run in runs {
            print("PARITY-RECORD scenario=\(run.id) frames=\(run.frames.count) artifacts=\(ChatVisualParityStore.scenarioDirectory(run.id).path)")
            #expect(!run.frames.isEmpty, "\(run.id) recorded no frames")
        }
        print("PARITY-RECORD manifest=\(ChatVisualParityStore.artifactsRoot.appending(path: "manifest.json").path) scenarios=\(runs.count)")
    }

    private static func verify(_ runs: [ChatVisualParityRunner]) throws {
        let manifest = try ChatVisualParityStore.readManifest()
        guard manifest.fingerprint.rowStep == ChatVisualParitySpec.rowStep,
              manifest.fingerprint.columnStep == ChatVisualParitySpec.columnStep,
              manifest.fingerprint.alignmentBands == ChatVisualParitySpec.alignmentBands,
              manifest.window == [390, 844] else {
            Issue.record("the committed reference was recorded at a different fingerprint resolution or window; re-record it")
            return
        }
        let tolerance = min(ChatVisualParitySpec.tolerance, manifest.tolerance)
        var scenarios: [ChatVisualParityReport.Scenario] = []
        var notes: [String] = []
        for run in runs {
            let scenario = compare(run: run, reference: manifest.scenarios.first { $0.id == run.id }, tolerance: tolerance)
            scenarios.append(scenario)
            let worst = scenario.worstFrames.first.map {
                "frame\($0.index):\($0.phase)@matched\($0.matchedFrame)@shift\($0.shift)"
            } ?? "none"
            print("PARITY-GATE scenario=\(scenario.id) frames=\(scenario.renderedFrames)"
                + " maxDiff=\(String(format: "%.5f", scenario.maximumMagnitude)) worst=\(worst)"
                + " tolerance=\(String(format: "%.5f", tolerance)) verdict=\(scenario.passed ? "pass" : "FAIL")")
            if !scenario.passed {
                notes.append("\(scenario.id): worst \(worst) at \(String(format: "%.5f", scenario.maximumMagnitude))"
                    + (scenario.note.map { " (\($0))" } ?? ""))
            }
        }
        let report = ChatVisualParityReport(
            schema: "tron.chat-visual-parity-report.v1",
            mode: "verify",
            tolerance: tolerance,
            passed: notes.isEmpty,
            scenarios: scenarios
        )
        try ChatVisualParityStore.writeReport(report)
        print("PARITY-GATE report=\(ChatVisualParityStore.artifactsRoot.appending(path: "report.json").path) verdict=\(report.passed ? "pass" : "FAIL")")
        for note in notes {
            Issue.record("visual parity gate failed: \(note)")
        }
        #expect(runs.count == manifest.scenarios.count, "every recorded scenario rendered")
    }

    /// Compare one scenario's rendered frames against its recorded ones. A
    /// rendered frame is matched to the recorded frame at the same state within
    /// `matchWindow`, so the reference container's own frame-to-frame timing is
    /// not read as a different picture, and every rendered frame must match some
    /// recorded frame in return, so a container cannot add states the chat never
    /// showed.
    private static func compare(
        run: ChatVisualParityRunner,
        reference: ChatVisualParityManifest.Scenario?,
        tolerance: Double
    ) -> ChatVisualParityReport.Scenario {
        guard let reference else {
            return .init(
                id: run.id, recordedFrames: 0, renderedFrames: run.frames.count,
                frames: [], worstFrames: [], maximumMagnitude: .infinity, passed: false,
                note: "the committed manifest records no such scenario"
            )
        }
        let window = ChatVisualParitySpec.matchWindow
        let recorded = reference.frames.map { frame in
            ChatVisualParityFingerprint(
                width: frame.width,
                height: frame.height,
                rows: frame.rows.values,
                columns: frame.columns.values
            )
        }
        let rendered = run.frames.map(\.fingerprint)
        var shape: String?
        if reference.frames.count != run.frames.count {
            shape = "the candidate rendered \(run.frames.count) frames, the reference recorded \(reference.frames.count)"
        } else {
            for (index, frame) in run.frames.enumerated()
            where frame.fingerprint.width != reference.frames[index].width
                || frame.fingerprint.height != reference.frames[index].height {
                shape = "frame \(index) rendered at \(frame.fingerprint.width)x\(frame.fingerprint.height), recorded at \(reference.frames[index].width)x\(reference.frames[index].height)"
                break
            }
        }
        guard shape == nil else {
            return .init(
                id: run.id, recordedFrames: reference.frames.count, renderedFrames: run.frames.count,
                frames: [], worstFrames: [], maximumMagnitude: .infinity, passed: false, note: shape
            )
        }
        func nearest(candidate: ChatVisualParityFingerprint, in range: ClosedRange<Int>) -> (magnitude: Double, frame: Int, shift: Int) {
            var best = (magnitude: Double.infinity, frame: 0, shift: 0)
            for index in range {
                let diff = ChatVisualParityFingerprint.magnitude(
                    candidate,
                    recorded[index],
                    alignmentBands: ChatVisualParitySpec.alignmentBands
                )
                if diff.magnitude < best.magnitude {
                    best = (diff.magnitude, index, diff.shift)
                }
            }
            return best
        }
        var diffs: [ChatVisualParityReport.FrameDiff] = []
        var unmatchedRendered: [ChatVisualParityReport.FrameDiff] = []
        for index in recorded.indices {
            let range = max(0, index - window)...min(recorded.count - 1, index + window)
            let best = nearest(candidate: rendered[index], in: range)
            diffs.append(.init(
                index: index,
                phase: reference.frames[index].phase,
                magnitude: best.magnitude,
                matchedFrame: best.frame,
                shift: best.shift
            ))
        }
        for index in rendered.indices {
            let range = max(0, index - window)...min(rendered.count - 1, index + window)
            var best = (magnitude: Double.infinity, frame: 0)
            for referenceIndex in range {
                let diff = ChatVisualParityFingerprint.magnitude(
                    rendered[index],
                    recorded[referenceIndex],
                    alignmentBands: ChatVisualParitySpec.alignmentBands
                )
                if diff.magnitude < best.magnitude {
                    best = (diff.magnitude, referenceIndex)
                }
            }
            guard best.magnitude > tolerance else { continue }
            unmatchedRendered.append(.init(
                index: index,
                phase: run.frames[index].phase,
                magnitude: best.magnitude,
                matchedFrame: best.frame,
                shift: 0
            ))
        }
        let worst = diffs.sorted { $0.magnitude > $1.magnitude }.prefix(5)
        let candidateNote = unmatchedRendered.prefix(5).map {
            "rendered frame \($0.index):\($0.phase) has no recorded match (\(String(format: "%.5f", $0.magnitude)))"
        }.joined(separator: "; ")
        return .init(
            id: run.id,
            recordedFrames: reference.frames.count,
            renderedFrames: run.frames.count,
            frames: diffs,
            worstFrames: Array(worst),
            maximumMagnitude: diffs.map(\.magnitude).max() ?? .infinity,
            passed: diffs.allSatisfy { $0.magnitude <= tolerance } && unmatchedRendered.isEmpty,
            note: candidateNote.isEmpty ? nil : candidateNote
        )
    }

        return .init(
            id: run.id,
            recordedFrames: reference.frames.count,
            renderedFrames: run.frames.count,
            frames: diffs,
            worstFrames: Array(worst),
            maximumMagnitude: maximum,
            passed: shape == nil && diffs.count == reference.frames.count && (diffs.allSatisfy { $0.magnitude <= tolerance }),
            note: shape
        )
    }
}

@MainActor
@Suite("Chat visual parity gate", .serialized)
struct ChatVisualParityTests {
    @Test("recorded reference frames match the rendered transcript within tolerance")
    func recordedReferenceFramesMatchRenderedTranscript() async throws {
        try await withTestWatchdog(timeout: .seconds(300)) {
            try await ChatVisualParityGate.run()
        }
    }
}
