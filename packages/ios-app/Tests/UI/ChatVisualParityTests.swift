import Foundation
import Testing
@testable import TronMobileCore
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
    /// The fingerprint's resolution, in points per row band and column band.
    static let rowStep = 2
    static let columnStep = 8

    /// The scale a sampled frame is rendered at. Half scale is what keeps a
    /// capture inside a display period — measured about 20 ms against about
    /// 110 ms at 1x, where the forced full-window screen update and the
    /// full-resolution profiles dominated the cost — and two points per pixel
    /// still resolves the row bands the gate compares. The scale is recorded in
    /// the committed manifest because a fingerprint is only comparable at the
    /// scale its reference was sampled at.
    static let renderScale: CGFloat = 0.5
    static let pointsPerPixel = Int(1 / renderScale)

    /// Per-frame tolerance where neither side moved: the normalized RMS luminance
    /// difference of a candidate frame against its recorded reference frame over
    /// both profiles, after the bounded vertical alignment below. It is stated
    /// here, recorded in the committed manifest, and set from the largest
    /// difference the three-run determinism check measured on unchanged code plus
    /// a margin. `packages/ios-app/docs/development.md` owns the recorded numbers
    /// and the margin each negative control showed.
    static let tolerance = 0.025

    /// The bound a transition frame is judged against. The display boundary a
    /// transition lands on is not reproducible on this lane: a capture must force
    /// a screen update to carry the animation at all (measured at about 60 ms a
    /// boundary), so one boundary is a quarter of the send entrance's 280 ms and
    /// the recorded transition's own frame-to-frame timing is not a picture
    /// difference. The bound allows that jitter; it is not widened to hide a
    /// different picture, and `development.md` states what it cannot resolve (a
    /// sub-60 ms phase difference, which is why a 14-point rise and a 280 ms
    /// against 200 ms entrance stay device checks).
    static let transitionTolerance = 0.065

    /// The phases whose frames are transitions. The classification is the
    /// scenario's own and the report names the phase of every frame it judged, so
    /// which frames are compared tightly is reviewable rather than inferred from
    /// how far a recorded frame happened to move. Every phase not named here is
    /// judged against `tolerance`, so a new phase is tight by default.
    private static let transitionPhases: Set<String> = [
        "keyboard-up", "keyboard-dismissal", "outgoing-entrance",
        "growth-1", "growth-2", "growth-3", "growth-4", "growth-5",
        "replacement", "chip-entrance", "chip-completion",
        "loading", "completing", "catch-up",
    ]

    static func isTransitionPhase(_ phase: String) -> Bool {
        transitionPhases.contains(phase)
    }

    /// How far a candidate frame may be re-aligned vertically, in points, before
    /// its diff counts, at half-point steps. A pinned transcript settles within a
    /// point or two run to run — the harness's own tail checks allow 2 — so an
    /// unaligned comparison would measure the recorded container's own settle as
    /// if it were a layout change.
    static let alignmentPoints = 2.0

    /// How many frames away a candidate frame may be matched to a recorded frame.
    /// Every display frame is captured now, so a recorded frame index is the same
    /// animation frame in the next run up to the boundary the animation's own
    /// start lands on. One boundary is about 20 ms, and matching a frame one
    /// boundary away moves the send entrance's 20-point rise by about a point,
    /// less than the 6 points a 14-point rise differs by. A wider window would
    /// let a candidate match a recorded frame at a different point of the rise
    /// and stop the gate seeing the rise itself.
    static let matchWindow = 1
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

    /// The band resolution a fingerprint is built at, in pixels: the harness
    /// renders the frame at `ChatVisualParitySpec.renderScale` and accumulates
    /// both profiles in one pass over the image.
    static var rowBandPixels: Int {
        max(1, ChatVisualParitySpec.rowStep / ChatVisualParitySpec.pointsPerPixel)
    }

    static var columnBandPixels: Int {
        max(1, ChatVisualParitySpec.columnStep / ChatVisualParitySpec.pointsPerPixel)
    }

    /// The frame the harness rendered for a sample.
    init(_ rendered: ChatViewScrollHarness.ParityFrame) {
        width = rendered.width
        height = rendered.height
        rows = rendered.rows
        columns = rendered.columns
    }

    /// The frame's diff against its reference after the best alignment: the
    /// normalized RMS luminance difference of the row profile (which is what a
    /// vertical move changes) minimized over re-alignments of at most
    /// `alignmentPoints` points at half-point steps, plus the unshifted column
    /// profile. The row profile is resampled by linear interpolation for a
    /// fractional re-alignment, so the ±2-point allowance does not need a finer
    /// stored profile.
    static func magnitude(
        _ candidate: ChatVisualParityFingerprint,
        _ reference: ChatVisualParityFingerprint,
        alignmentPoints: Double
    ) -> (magnitude: Double, shift: Double) {
        guard candidate.rows.count == reference.rows.count,
              candidate.columns.count == reference.columns.count,
              !candidate.rows.isEmpty, !candidate.columns.isEmpty else { return (.infinity, 0) }
        var columnSquared = 0.0
        for (candidateValue, referenceValue) in zip(candidate.columns, reference.columns) {
            let delta = (Double(candidateValue) - Double(referenceValue)) / 255
            columnSquared += delta * delta
        }
        var best = (magnitude: Double.infinity, shift: 0.0)
        var points = -alignmentPoints
        while points <= alignmentPoints {
            defer { points += 0.5 }
            let bands = points / Double(ChatVisualParitySpec.rowStep)
            var squared = 0.0
            var count = 0
            for index in reference.rows.indices {
                let position = Double(index) + bands
                guard position >= 0, position <= Double(candidate.rows.count - 1) else { continue }
                let lower = Int(position.rounded(.down))
                let fraction = position - Double(lower)
                let upper = min(lower + 1, candidate.rows.count - 1)
                let value = Double(candidate.rows[lower]) * (1 - fraction)
                    + Double(candidate.rows[upper]) * fraction
                let delta = (value - Double(reference.rows[index])) / 255
                squared += delta * delta
                count += 1
            }
            guard count > 0 else { continue }
            let magnitude = ((squared + columnSquared) / Double(count + candidate.columns.count)).squareRoot()
            if magnitude < best.magnitude { best = (magnitude, points) }
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
        /// Points per rendered pixel: the scale a frame was sampled at.
        let pointsPerPixel: Int
        /// The comparison's vertical alignment window, in points.
        let alignmentPoints: Double
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
        /// The source revision this scenario's frames were recorded from. The
        /// gate refuses a reference recorded from any revision
        /// `ChatVisualParityReference.recordedRevisions` does not name, so a
        /// reference re-recorded from the container under test cannot judge it.
        let recordedFrom: String
        let frames: [Frame]
    }

    /// The only schema this gate reads. The manifest carries provenance as of
    /// CT-25, which a v1 record cannot: a v1 file is re-recorded rather than
    /// silently trusted without it.
    static let schema = "tron.chat-visual-parity.v2"

    let schema: String
    let fingerprint: FingerprintSpec
    /// The two bounds the reference was recorded with: the stable bound and the
    /// bound for a frame either side moved on.
    let tolerance: Double
    let transitionTolerance: Double
    let window: [Int]
    let systemVersion: String
    let scenarios: [Scenario]
}

/// The provenance rule the committed reference lives under.
///
/// A reference is only a reference if it was recorded before the container it
/// judges. Every scenario in the manifest names the source revision its frames
/// came from, and verification refuses any revision this reviewed set does not
/// name. A recording run writes the revision it ran from, so a reference
/// re-recorded from the candidate container — CT-23's flipped transcript
/// included — cannot pass the gate until the change that re-records it also adds
/// its revision here, in the review that owns the CT-12 rule in
/// `packages/ios-app/docs/development.md`: the reference is recorded from the
/// current path before a container change, never from the candidate.
enum ChatVisualParityReference {
    /// One entry per reviewed recording session.
    static let recordedRevisions: Set<String> = [
        // CT-12's reference, re-recorded per display frame by CT-14 on the
        // unchanged chat before any container change.
        "eed1e15a5de1a4ef0f66e338f89e9be7508e266c",
        // The CT-25 scenarios (safe-area keyboard inset, short transcript,
        // oldest row at the visual top), recorded on the same path.
        "2297defc9efd0bfd3478544d566433e59e78ce3e",
    ]

    /// The source revision this run is running against, as
    /// `scripts/tron-ios-test` passes it through `TEST_RUNNER_`. A bare
    /// `xcodebuild test-without-building` has no revision to record with, so the
    /// gate verifies the committed reference there and refuses to record a new
    /// one.
    static var runRevision: String? {
        let revision = ProcessInfo.processInfo.environment["TRON_SOURCE_REVISION"]
        return (revision?.isEmpty == false) ? revision : nil
    }
}

/// The gate's JSON report: the worst frames per scenario and their diff
/// magnitude, written beside the run's artifacts so a failure names its frames.
struct ChatVisualParityReport: Codable, Equatable {
    /// One recorded frame's diff: the largest such diff a candidate run had for
    /// that recorded frame, the rendered frame it was matched to, and the bound
    /// it was judged against.
    struct FrameDiff: Codable, Equatable {
        let index: Int
        let phase: String
        let magnitude: Double
        let matchedFrame: Int
        /// The vertical band shift that produced this frame's magnitude.
        let shift: Double
        let allowed: Double
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
    let transitionTolerance: Double
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

    /// The mode a run is in is decided by the committed reference itself: a
    /// scenario it does not already hold is recorded, and every scenario it holds
    /// is verified. There is no scheme variable or hidden flag, so what a run
    /// means is reviewable from the manifest it read.
    static var isRecording: Bool {
        (try? readManifest()) == nil
    }

    /// Whether the committed reference already holds this scenario's frames: the
    /// recording mode's per-scenario question, which decides whether a run writes
    /// this scenario's PNG artifacts.
    static func holdsReference(for id: String) -> Bool {
        (try? readManifest())?.scenarios.contains { $0.id == id } ?? false
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

    /// Capture the transcript region as this boundary's frame. The transcript's
    /// settled native offset moves by a fraction of a point run to run, so the
    /// offset is snapped to a whole point first: what the gate compares is then a
    /// deterministic function of the layout rather than of the lazy estimate.
    /// CT-25 measured removing it (see the plan's stage B2 entry): the gate stays
    /// green, but the existing opened-long-history reference's stable frames move
    /// to 0.019 of their 0.025 bound, so the snap still carries the reference's
    /// determinism and F9's removal belongs with CT-23's exact origin.
    func capture(_ phase: String) {
        try? harness.snapNativeTranscriptOffsetToWholePoint()
        let rendered = harness.renderedParityFrame(
            scale: ChatVisualParitySpec.renderScale,
            rowBandPixels: ChatVisualParityFingerprint.rowBandPixels,
            columnBandPixels: ChatVisualParityFingerprint.columnBandPixels,
            includingPNG: true
        )
        frames.append(ChatVisualParityFrame(
            index: frames.count,
            phase: phase,
            fingerprint: ChatVisualParityFingerprint(rendered)
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

    /// Drive the keyboard's own inset transition, capturing one frame per step:
    /// the keyboard's intermediate positions are the input CT-23's swapped inset
    /// margins have to reproduce, and `resize(height:)` — which every other
    /// scenario's keyboard stands in with — never produced them.
    func driveKeyboardInset(_ transition: KeyboardInsetTransition, phase: String) async throws {
        harness.beginKeyboardInset(transition)
        for step in 1...max(1, transition.boundaries) {
            harness.applyKeyboardInset(transition, step: step)
            try await harness.driveFrameBoundary()
            capture(phase)
        }
    }

    /// Drive display boundaries until the rendered region stops changing. The
    /// recorder's sample stream only advances when the transcript's layout
    /// changes, so a transform-only entrance — the appended row's fade and rise,
    /// for instance — would look settled while it is still moving, and the
    /// frames taken after it would land on an animation. A settled state is
    /// timing-independent even though reaching it is not, so scenarios start
    /// their fixed frame sequences from one. A boundary is about one display
    /// frame, so the stability window is stated in boundaries and its default
    /// covers a quarter second of rendered stillness.
    func settle(stableBoundaries: Int = 12, cap: Int = 160) async throws {
        var previous: ChatVisualParityFingerprint?
        var stable = 0
        for _ in 0..<cap {
            try await harness.driveFrameBoundary()
            try? harness.snapNativeTranscriptOffsetToWholePoint()
            let fingerprint = ChatVisualParityFingerprint(harness.renderedParityFrame(
                scale: ChatVisualParitySpec.renderScale,
                rowBandPixels: ChatVisualParityFingerprint.rowBandPixels,
                columnBandPixels: ChatVisualParityFingerprint.columnBandPixels,
                includingPNG: false
            ))
            defer { previous = fingerprint }
            guard let previous,
                  previous.rows.count == fingerprint.rows.count,
                  previous.columns.count == fingerprint.columns.count else { continue }
            let changed = zip(previous.rows, fingerprint.rows).contains { abs(Int($0) - Int($1)) > 1 }
                || zip(previous.columns, fingerprint.columns).contains { abs(Int($0) - Int($1)) > 1 }
            if changed {
                stable = 0
            } else {
                stable += 1
                if stable >= stableBoundaries { return }
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
            ChatVisualParityScenario(id: "keyboard-safe-area-inset", run: keyboardSafeAreaInset),
            ChatVisualParityScenario(id: "short-transcript-at-rest", run: shortTranscriptAtRest),
            ChatVisualParityScenario(id: "oldest-row-at-visual-top", run: oldestRowAtVisualTop),
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
        recordsArtifacts: !ChatVisualParityStore.holdsReference(for: id)
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

/// The transcript's pinned state in window coordinates, for a parity failure
/// message: the visual gap between the newest row and the composer (12 pt while
/// pinned), whether the pinned bottom band was covered, and how much of the
/// visible transcript the rows covered.
@MainActor
private func parityPinnedDescription(_ harness: ChatViewScrollHarness) -> String {
    let bottom = harness.transcriptBottom()
    return "clearance=\(harness.newestRowClearance().map { String(format: "%.1f", Double($0)) } ?? "none")"
        + " bandCovered=\(bottom.isBandCovered)"
        + " visibleFraction=\(String(format: "%.2f", Double(bottom.visibleRowFraction)))"
}

private func parityStreamingText(step: Int) -> String {
    (1...step).map { paragraph in
        "Streaming paragraph \(paragraph) of step \(step) grows the tail assistant row."
    }.joined(separator: "\n\n")
}

/// How many driven boundaries each transition's frames are sampled over. A
/// boundary is about one display frame on this lane, so the counts come from the
/// transitions' own durations: the send entrance is a 280 ms easeOut, its
/// composer collapse a 360 ms spring and the keyboard's viewport change lands in
/// the same layout transaction, so the send choreography is sampled over about a
/// second of frames.
private enum ParityTransitionFrames {
    static let keyboardViewport = 30
    static let sendChoreography = 45
    static let streamingGrowth = 25
    static let queuedReplacement = 25
    static let toolChip = 20
    static let earlierPage = 15
    static let catchUp = 20
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
        // The 140-row history's lazy realization keeps settling after the first
        // stable boundaries, and which rows are mounted at the first captured
        // frame differed by up to 0.043 run to run when the scenario captured
        // straight after the default window, so this scenario waits for a longer
        // run of rendered stillness before its frames.
        try await run.settle(stableBoundaries: 40, cap: 240)
        try await run.advance("rest", boundaries: 8)
        #expect(
            run.harness.isPinnedToBottom(),
            "the opened history stayed pinned: \(parityPinnedDescription(run.harness))"
        )
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
        try await run.advance("keyboard-up", boundaries: ParityTransitionFrames.keyboardViewport)
        try harness.setComposerDraftText("Keep the parity transcript stable through this send.")
        // The composer's own text install is a state, not part of the send
        // choreography this scenario drives.
        try await run.settle()
        try await run.advance("draft", boundaries: 2)
        harness.submitPrompt()
        try await run.advance("outgoing-entrance", boundaries: ParityTransitionFrames.sendChoreography)
        harness.resize(height: 844)
        try await run.advance("keyboard-dismissal", boundaries: ParityTransitionFrames.keyboardViewport)
        try await run.advance("settled", boundaries: 3)
        #expect(
            harness.isPinnedToBottom(),
            "the send settled on the pinned bottom: \(parityPinnedDescription(harness))"
        )
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
            // The growth's own frames are the transition this scenario gates, so
            // they are captured before the scenario waits for the settled state.
            try await run.advance("growth-\(step)", boundaries: ParityTransitionFrames.streamingGrowth)
            try await run.settle()
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
        try await run.advance("replacement", boundaries: ParityTransitionFrames.queuedReplacement)
        try await run.settle()
        try await run.advance("replacement-settled", boundaries: 3)
        #expect(
            harness.isPinnedToBottom(),
            "the queued replacement held the pinned bottom: \(parityPinnedDescription(harness))"
        )
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
        try await run.advance("chip-entrance", boundaries: ParityTransitionFrames.toolChip)
        try await run.settle()
        try await run.advance("chip-entrance-settled", boundaries: 2)
        harness.replaceAuthoritativeSnapshot(completed)
        try await run.advance("chip-completion", boundaries: ParityTransitionFrames.toolChip)
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
        try await run.advance("loading", boundaries: ParityTransitionFrames.earlierPage)
        harness.releasePrependPage()
        try await run.advance("completing", boundaries: ParityTransitionFrames.earlierPage)
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
        try await run.advance("catch-up", boundaries: ParityTransitionFrames.catchUp)
        harness.driveGeometry(previous: away, current: bottom, viewport: true)
        try await run.settle()
        try await run.advance("settled", boundaries: 3)
    }
}

// MARK: - The gate

/// (h) The keyboard's own inset transition over a mixed history, with a
/// multi-line composer growth. `resize(height:)` — which the other keyboard
/// scenario stands in with — changes the whole window, which the flip does not
/// touch; a keyboard changes only the composer's own bottom safe area, which is
/// exactly the edge CT-23 has to re-apply swapped. Frames: the pinned rest, the
/// show transition's intermediate insets, the composer's own growth at full
/// keyboard, the dismissal's intermediate insets and the settled rest.
@MainActor
private func keyboardSafeAreaInset() async throws -> ChatVisualParityRunner {
    let snapshot = try parityMixedHistory(rowCount: 60)
    return try await runScenario(
        id: "keyboard-safe-area-inset",
        snapshot: snapshot,
        submitsPrompts: true
    ) { run in
        let harness = run.harness
        try await run.settle()
        try await run.advance("pinned", boundaries: 2)
        try await run.driveKeyboardInset(.show(boundaries: 8), phase: "keyboard-up")
        try await run.settle()
        try await run.advance("keyboard-up-settled", boundaries: 2)
        try harness.setComposerDraftText(
            "First line of the draft\nSecond line\nThird line\nFourth line"
        )
        try await run.settle()
        try await run.advance("composer-growth", boundaries: 2)
        try harness.setComposerDraftText("")
        try await run.settle()
        try await run.advance("composer-cleared", boundaries: 2)
        try await run.driveKeyboardInset(.hide(boundaries: 8), phase: "keyboard-dismissal")
        try await run.settle()
        try await run.advance("dismissal-settled", boundaries: 3)
        #expect(
            harness.isPinnedToBottom(),
            "the keyboard scenario settled on the pinned bottom: \(parityPinnedDescription(harness))"
        )
    }
}

/// (i) A short transcript that does not fill the screen: the newest row rests on
/// the composer with blank space above it. None of the seven CT-12 scenarios
/// covers it, and a flip that anchors the wrong edge shows the newest rows at the
/// visual top with the old top padding under the composer.
@MainActor
private func shortTranscriptAtRest() async throws -> ChatVisualParityRunner {
    let snapshot = try parityShortHistory(rowCount: 4, earlierMessages: 0)
    return try await runScenario(
        id: "short-transcript-at-rest",
        snapshot: snapshot,
        submitsPrompts: false
    ) { run in
        try await run.settle()
        try await run.advance("rest", boundaries: 8)
        let clearance = try #require(run.harness.newestRowClearance())
        #expect(
            clearance >= -2 && clearance <= 32,
            "the short transcript rests on the composer: \(parityPinnedDescription(run.harness))"
        )
    }
}

/// (j) A reader scrolled to the oldest loaded row: the transcript's 12 pt top
/// padding and the earlier-messages row are what the frames carry. Every CT-12
/// scenario starts from the tail, so the far end of the content — where the flip
/// moves its top padding and the earlier-messages row — was never recorded.
@MainActor
private func oldestRowAtVisualTop() async throws -> ChatVisualParityRunner {
    let snapshot = try parityShortHistory(rowCount: 60, earlierMessages: 40)
    return try await runScenario(
        id: "oldest-row-at-visual-top",
        snapshot: snapshot,
        submitsPrompts: false
    ) { run in
        try await run.settle()
        // A visual distance past the whole history puts the real reader at the
        // oldest end; `scrollReader` clamps to the transcript's legal range.
        try run.harness.scrollReader(byVisualPoints: 10_000_000)
        try await run.settle(stableBoundaries: 24)
        try await run.advance("oldest", boundaries: 6)
        #expect(!run.harness.isPinnedToBottom(), "the reader left the pinned bottom")
    }
}

@MainActor
enum ChatVisualParityGate {
    static func run() async throws {
        let committed = try? ChatVisualParityStore.readManifest()
        let recorded = Set(committed?.scenarios.map(\.id) ?? [])
        let missing = ChatVisualParityScenario.all.filter { !recorded.contains($0.id) }
        var runs: [ChatVisualParityRunner] = []
        for scenario in ChatVisualParityScenario.all {
            do {
                runs.append(try await scenario.run())
            } catch {
                Issue.record("visual parity scenario \(scenario.id) did not run: \(error)")
            }
        }
        guard missing.isEmpty, let committed else {
            try record(committed: committed, runs: runs, recording: missing)
            return
        }
        try verify(runs, against: committed)
    }

    /// Record the scenarios the committed reference does not have yet, merge them
    /// into it, and fail the run. Every entry the reference already holds stays
    /// byte-identical: CT-25's rule is that a new scenario is recorded from the
    /// current path, never that the existing reference is re-recorded. Failing
    /// after writing is deliberate: a grown reference cannot pass in the run that
    /// grew it, so `ChatVisualParityReference.recordedRevisions` has to name this
    /// recording for the gate to pass again, which is the review that makes the
    /// new frames reviewable.
    private static func record(
        committed: ChatVisualParityManifest?,
        runs: [ChatVisualParityRunner],
        recording missing: [ChatVisualParityScenario]
    ) throws {
        guard let revision = ChatVisualParityReference.runRevision else {
            let message: String = "the parity reference was not recorded: this run has no "
                + "source revision (run it through scripts/tron-ios-test, which passes the "
                + "revision it runs against)"
            Issue.record(Comment(rawValue: message))
            return
        }
        let recordedRuns = missing.isEmpty
            ? runs
            : runs.filter { run in missing.contains { $0.id == run.id } }
        let additions = recordedRuns.map { run in
            ChatVisualParityManifest.Scenario(
                id: run.id,
                recordedFrom: revision,
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
        let manifest = ChatVisualParityManifest(
            schema: ChatVisualParityManifest.schema,
            fingerprint: committed?.fingerprint ?? .init(
                rowStep: ChatVisualParitySpec.rowStep,
                columnStep: ChatVisualParitySpec.columnStep,
                pointsPerPixel: ChatVisualParitySpec.pointsPerPixel,
                alignmentPoints: ChatVisualParitySpec.alignmentPoints,
                matchWindow: ChatVisualParitySpec.matchWindow
            ),
            tolerance: committed?.tolerance ?? ChatVisualParitySpec.tolerance,
            transitionTolerance: committed?.transitionTolerance
                ?? ChatVisualParitySpec.transitionTolerance,
            window: committed?.window ?? [390, 844],
            systemVersion: committed?.systemVersion ?? UIDevice.current.systemVersion,
            scenarios: (committed?.scenarios ?? [])
                + additions.filter { addition in
                    !(committed?.scenarios.contains { $0.id == addition.id } ?? false)
                }
        )
        try ChatVisualParityStore.writeManifest(manifest)
        for run in recordedRuns {
            print("PARITY-RECORD scenario=\(run.id) frames=\(run.frames.count) revision=\(revision) artifacts=\(ChatVisualParityStore.scenarioDirectory(run.id).path)")
            #expect(!run.frames.isEmpty, "\(run.id) recorded no frames")
        }
        print("PARITY-RECORD manifest=\(ChatVisualParityStore.artifactsRoot.appending(path: "manifest.json").path) scenarios=\(manifest.scenarios.count) added=\(additions.count) copyTo=\(ChatVisualParityStore.referenceURL.path)")
        let grew: String = "the committed parity reference grew by \(additions.count) "
            + "scenario(s) recorded from \(revision); add that revision to "
            + "ChatVisualParityReference.recordedRevisions, commit the manifest, and re-run "
            + "to verify"
        Issue.record(Comment(rawValue: grew))
    }

    private static func verify(
        _ runs: [ChatVisualParityRunner],
        against manifest: ChatVisualParityManifest
    ) throws {
        guard manifest.schema == ChatVisualParityManifest.schema else {
            Issue.record(
                "the committed reference is \(manifest.schema), which carries no provenance; re-record it"
            )
            return
        }
        let unreviewed = manifest.scenarios.filter {
            !ChatVisualParityReference.recordedRevisions.contains($0.recordedFrom)
        }
        guard unreviewed.isEmpty else {
            let provenance = unreviewed
                .map { "\($0.id)@\($0.recordedFrom)" }
                .joined(separator: ", ")
            let message: String = "the committed reference holds frames recorded from an "
                + "unreviewed revision (\(provenance)); a reference re-recorded from the "
                + "container under test cannot judge it"
            Issue.record(Comment(rawValue: message))
            return
        }
        guard manifest.fingerprint.rowStep == ChatVisualParitySpec.rowStep,
              manifest.fingerprint.columnStep == ChatVisualParitySpec.columnStep,
              manifest.fingerprint.pointsPerPixel == ChatVisualParitySpec.pointsPerPixel,
              manifest.fingerprint.alignmentPoints == ChatVisualParitySpec.alignmentPoints,
              manifest.window == [390, 844] else {
            Issue.record("the committed reference was recorded at a different fingerprint resolution or window; re-record it")
            return
        }
        let tolerance = min(ChatVisualParitySpec.tolerance, manifest.tolerance)
        let transitionTolerance = min(
            ChatVisualParitySpec.transitionTolerance,
            manifest.transitionTolerance
        )
        var scenarios: [ChatVisualParityReport.Scenario] = []
        var notes: [String] = []
        for run in runs {
            let scenario = compare(
                run: run,
                reference: manifest.scenarios.first { $0.id == run.id },
                tolerance: tolerance,
                transitionTolerance: transitionTolerance
            )
            scenarios.append(scenario)
            let failing = scenario.frames.filter { $0.magnitude > $0.allowed }
            let worst = (failing.isEmpty ? scenario.worstFrames : Array(failing.prefix(5))).first.map {
                "frame\($0.index):\($0.phase)@matched\($0.matchedFrame)@shift\($0.shift)@allowed\(String(format: "%.3f", $0.allowed))"
            } ?? "none"
            print("PARITY-GATE scenario=\(scenario.id) frames=\(scenario.renderedFrames)"
                + " maxDiff=\(String(format: "%.5f", scenario.maximumMagnitude)) worst=\(worst)"
                + " tolerance=\(String(format: "%.5f", tolerance))"
                + " transitionTolerance=\(String(format: "%.5f", transitionTolerance))"
                + " verdict=\(scenario.passed ? "pass" : "FAIL")")
            if !scenario.passed {
                notes.append("\(scenario.id): worst \(worst) at \(String(format: "%.5f", scenario.maximumMagnitude))"
                    + (scenario.note.map { " (\($0))" } ?? ""))
            }
        }
        let report = ChatVisualParityReport(
            schema: "tron.chat-visual-parity-report.v1",
            mode: "verify",
            tolerance: tolerance,
            transitionTolerance: transitionTolerance,
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

    /// Compare one scenario's rendered frames against its recorded ones. Every
    /// display frame of a transition is recorded, so a rendered frame is matched
    /// to the recorded frame at the same state within `matchWindow` — wide enough
    /// for the boundary the animation's own start lands on, narrow enough that a
    /// different rise still has to match the recorded rise — and every rendered
    /// frame must match some recorded frame in return, so a container cannot add
    /// states the chat never showed.
    private static func compare(
        run: ChatVisualParityRunner,
        reference: ChatVisualParityManifest.Scenario?,
        tolerance: Double,
        transitionTolerance: Double
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
        /// The bound a compared frame is judged against: the transition bound
        /// where either side's phase is a transition, the stable bound otherwise.
        func allowed(recordedPhase: String, renderedPhase: String) -> Double {
            ChatVisualParitySpec.isTransitionPhase(recordedPhase)
                || ChatVisualParitySpec.isTransitionPhase(renderedPhase)
                ? transitionTolerance
                : tolerance
        }
        func nearest(candidate: ChatVisualParityFingerprint, in range: ClosedRange<Int>) -> (magnitude: Double, frame: Int, shift: Double) {
            var best = (magnitude: Double.infinity, frame: 0, shift: 0.0)
            for index in range {
                let diff = ChatVisualParityFingerprint.magnitude(
                    candidate,
                    recorded[index],
                    alignmentPoints: ChatVisualParitySpec.alignmentPoints
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
                shift: best.shift,
                allowed: allowed(
                    recordedPhase: reference.frames[index].phase,
                    renderedPhase: run.frames[best.frame].phase
                )
            ))
        }
        for index in rendered.indices {
            let range = max(0, index - window)...min(rendered.count - 1, index + window)
            var best = (magnitude: Double.infinity, frame: 0)
            for referenceIndex in range {
                let diff = ChatVisualParityFingerprint.magnitude(
                    rendered[index],
                    recorded[referenceIndex],
                    alignmentPoints: ChatVisualParitySpec.alignmentPoints
                )
                if diff.magnitude < best.magnitude {
                    best = (diff.magnitude, referenceIndex)
                }
            }
            guard best.magnitude > allowed(
                recordedPhase: reference.frames[best.frame].phase,
                renderedPhase: run.frames[index].phase
            ) else { continue }
            unmatchedRendered.append(.init(
                index: index,
                phase: run.frames[index].phase,
                magnitude: best.magnitude,
                matchedFrame: best.frame,
                shift: 0,
                allowed: allowed(
                    recordedPhase: reference.frames[best.frame].phase,
                    renderedPhase: run.frames[index].phase
                )
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
            passed: diffs.allSatisfy { $0.magnitude <= $0.allowed } && unmatchedRendered.isEmpty,
            note: candidateNote.isEmpty ? nil : candidateNote
        )
    }
}

@MainActor
@Suite("Chat visual parity gate", .serialized, .enabled(if: UIValidationTier.isActive))
struct ChatVisualParityTests {
    // A measurement, not a unit invariant: it renders the chat hundreds of
    // times, so it runs only in the UIValidation tier (see `UIValidationTier`).
    @Test("recorded reference frames match the rendered transcript within tolerance")
    func recordedReferenceFramesMatchRenderedTranscript() async throws {
        try await withTestWatchdog(timeout: .seconds(300)) {
            try await ChatVisualParityGate.run()
        }
    }
}
