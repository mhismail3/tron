import Foundation
import Testing
@testable import TronMobileCore
import UIKit

@testable import TronMobile

/// Row stability is what a lazy stack cannot be told about: a row that mounts,
/// then changes its own height, moves every row between it and the reader. The
/// fixtures here drive the real hosted `ChatView` through a detach, to the
/// oldest loaded row and back, twice, with one row of every kind in the
/// transcript, and report what each row did after it mounted:
///
/// - `ChatHostedProbe`'s per-mount record: the first settled frame height and
///   every later change under the same installed projection;
/// - the row content's own view identity, so an admission or a handoff that
///   switched a row's structure (a remount that discards its state) is visible;
/// - whether the collapsed display pill stayed collapsed;
/// - whether the inline displays reached a stable height.
///
/// The journey is a measurement, not a gate: it asserts only that the scenario
/// ran. The counts it prints and writes are the evidence a fix is judged by.
@MainActor
@Suite("Chat row stability", .serialized, .enabled(if: UIValidationTier.isActive))
struct ChatRowStabilityTests {
    @Test("every row kind survives detach, oldest-row and return without a post-mount resize")
    func rowStabilityJourney() async throws {
        try await withTestWatchdog(timeout: .seconds(150)) {
            let snapshot = try rowStabilitySnapshot()
            try await withStabilityHarness(snapshot: snapshot) { harness in
                var report = RowStabilityReport()
                var oldestVisibleRowIDs: [String] = []
                var oldestOffsetY = CGFloat.infinity
                let open = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                        && $0.observation.isReady
                        && $0.observation.geometry.distanceFromBottom
                            <= ChatTranscriptGeometry.catchUpDistance
                }
                #expect(open.observation.installedProjectionRowCount > RowStabilityFixture.rowIDs.count)
                try await driveBoundaries(3, harness: harness)
                report.capture(phase: "open", harness: harness)

                // A discrete insertion runs the entrance path while the reader
                // is pinned, so the row content's identity across its admission
                // is part of this journey's evidence rather than a separate
                // fixture.
                let entranceBaseline = harness.probeObservation.animatedEntranceCount
                harness.replaceAuthoritativeSnapshot(
                    try insertingEntranceRow(into: snapshot)
                )
                _ = try await harness.recorder.waitUntil {
                    $0.observation.animatedEntranceCount > entranceBaseline
                }
                try await driveBoundaries(10, harness: harness)
                report.capture(phase: "entrance", harness: harness)

                // Detach with a real scroll: the native transcript view moves
                // first, and the reader's own interaction phase is admitted
                // through the coordinator's real phase path. The native
                // callbacks stay admitted throughout (`.native` probe mode), so
                // the geometry the coordinator sees is the real one.
                try harness.displaceNativeTranscriptFromTail(by: 240)
                try await driveBoundaries(2, harness: harness)
                harness.drivePhase(
                    from: .idle,
                    to: .interacting,
                    geometry: harness.probeObservation.geometry
                )
                try harness.displaceNativeTranscriptFromTail(by: 900)
                try await driveBoundaries(3, harness: harness)
                harness.drivePhase(
                    from: .interacting,
                    to: .idle,
                    geometry: harness.probeObservation.geometry
                )
                try await driveBoundaries(2, harness: harness)
                #expect(harness.probeObservation.isDetached, "the journey did not detach")
                report.capture(phase: "detached", harness: harness)

                for round in 1...2 {
                    try harness.displaceNativeTranscriptFromTail(by: 1_000_000)
                    try await driveBoundaries(4, harness: harness)
                    report.capture(phase: "oldest-\(round)", harness: harness)
                    // What is really on screen is the mounted native rows, not
                    // the probe's retained frame bookkeeping.
                    oldestVisibleRowIDs = harness.recorder.samples.last?
                        .nativeRows.filter(\.isVisible).map(\.semanticID) ?? []
                    oldestOffsetY = harness.probeObservation.geometry.offsetY

                    try harness.displaceNativeTranscriptFromTail(by: 0)
                    try await driveBoundaries(4, harness: harness)
                    report.capture(phase: "return-\(round)", harness: harness)
                }

                // The journey ran: every fixture row was realized and measured
                // by the time the reader came back, at least one of them left
                // the lazy range and mounted again, and the pinned tail is
                // exact again at the end.
                let returned = report.heightsByPhase["return-2"] ?? [:]
                for id in RowStabilityFixture.rowIDs {
                    #expect(returned[id] != nil, "fixture row \(id) was never measured")
                }
                #expect(
                    oldestOffsetY <= 1,
                    "the journey never reached the oldest loaded row (offset \(oldestOffsetY))"
                )
                #expect(
                    oldestVisibleRowIDs.contains(RowStabilityFixture.oldestHistoryID)
                        || oldestVisibleRowIDs.contains("stability-history-1"),
                    "the oldest history rows were not on screen at the oldest phase"
                )
                #expect(
                    !oldestVisibleRowIDs.contains(RowStabilityFixture.codeTableID),
                    "the newest fixture row was still on screen at the oldest row"
                )

                report.finish(harness: harness)
                #expect(
                    report.remountedRowCount > 0,
                    "no fixture row left the lazy range, so the journey never remounted one"
                )
                // A settled row's height comes from its content, not from when
                // it was measured: the thinking trace's estimate left its first
                // mount 50 pt short of the measured viewport and only a remount
                // reached it (F2).
                let phaseVariants = report.phaseVariantRows
                #expect(
                    phaseVariants.isEmpty,
                    "a settled row changed height between phases: \(phaseVariants)"
                )
                // The rewrite measures the trace in the layout that places it;
                // without those measurements the trace loses its tap target and
                // its tail fade, which nothing else observes.
                let traces = harness.probeObservation.thinkingTraceMeasurements
                #expect(traces.count == 1, "the fixture has one thinking run: \(traces.keys.sorted())")
                let trace = try #require(traces.values.first,
                    "the wrapped thinking trace never reported its measurements")
                #expect(
                    trace.overflowing,
                    "a wrapped thinking trace must read as overflowing: \(trace)"
                )
                #expect(trace.referenceHeight > 0, "the reference lines were never measured")
                #expect(
                    trace.contentHeight > trace.referenceHeight,
                    "the wrapped paragraph is taller than its four reference lines: \(trace)"
                )
                print(report.line)
                try report.write()
                print("ROW-STABILITY report=\(RowStabilityReport.reportURL.path)")
            }
        }
    }

    @Test("a discrete insertion's admission keeps the row content's identity")
    func entranceAdmissionKeepsRowContentIdentity() async throws {
        try await withTestWatchdog(timeout: .seconds(60)) {
            let snapshot = try rowStabilitySnapshot()
            try await withStabilityHarness(snapshot: snapshot) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1 && $0.observation.isReady
                }
                try await driveBoundaries(3, harness: harness)
                let baseline = harness.probeObservation.animatedEntranceCount
                harness.replaceAuthoritativeSnapshot(try insertingEntranceRow(into: snapshot))
                _ = try await harness.recorder.waitUntil {
                    $0.observation.animatedEntranceCount > baseline
                }
                try await driveBoundaries(10, harness: harness)
                let observation = harness.probeObservation
                #expect(
                    observation.animatedEntranceCount > baseline,
                    "the insertion never admitted an animated entrance"
                )
                // The row content below the admission is one structure: an
                // admission that switched it would record a second identity for
                // the same row, and would re-measure the row after it mounted.
                #expect(
                    observation.rowIdentityInstanceCounts[RowStabilityFixture.entranceRowID] == 1,
                    "the admission switched the row content's view identity"
                )
                #expect(
                    observation.rowFrames[RowStabilityFixture.entranceRowID]?.height ?? 0 > 0,
                    "the inserted row never published a frame"
                )
            }
        }
    }

    @Test("the canonical prompt handoff keeps one row content identity")
    func canonicalPromptHandoffKeepsRowContentIdentity() async throws {
        try await withTestWatchdog(timeout: .seconds(60)) {
            let promptText = "A prompt whose canonical row must keep its identity."
            var initial = try SessionScenarioBuilder(seed: 1_327).openingTail(targetEncodedBytes: 10_000)
            initial.acceptsQueuedPrompts = false
            let snapshot = initial
            try await withComposerSubmissionHarness(snapshot: snapshot) { harness in
                _ = try await harness.recorder.waitUntil { $0.observation.isReady }
                try await driveBoundaries(3, harness: harness)
                try harness.setComposerDraftText(promptText)
                harness.submitPrompt()
                _ = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains {
                        $0.physicalID.hasPrefix("outgoing-submission:") && $0.isVisible
                    }
                }
                var acknowledged = snapshot
                acknowledged.transcript.append(try decodeTranscriptFixture(
                    TranscriptItem.self,
                    from: try JSONSerialization.data(withJSONObject: [
                        "id": "canonical-prompt",
                        "parentId": NSNull(),
                        "presentationId": harnessHostedPromptOperationID,
                        "timestamp": "2026-01-01T00:01:00Z",
                        "kind": "message",
                        "role": "user",
                        "content": [[
                            "id": "canonical-text",
                            "ordinal": 0,
                            "type": "text",
                            "text": promptText,
                        ]],
                    ])
                ))
                acknowledged.transcriptTotal = acknowledged.transcript.count
                harness.replaceAuthoritativeSnapshot(acknowledged)
                _ = try await harness.recorder.waitUntil {
                    $0.nativeRows.contains { $0.semanticID == "canonical-prompt" && $0.isVisible }
                }
                for _ in 0..<40 { try await harness.driveFrameBoundary() }
                let observation = harness.probeObservation
                #expect(
                    observation.rowIdentityInstanceCounts["canonical-prompt"] == 1,
                    "the canonical handoff switched the prompt row's content identity"
                )
            }
        }
    }

    @Test("a truncated error notice keeps one pill structure across its measurement")
    func truncatedNoticeKeepsOnePillStructure() async throws {
        try await withTestWatchdog(timeout: .seconds(60)) {
            var snapshot = try SessionScenarioBuilder(seed: 1_327).openingTail(targetEncodedBytes: 10_000)
            snapshot.transcript.append(try decodeTranscriptFixture(
                TranscriptItem.self,
                from: try JSONSerialization.data(withJSONObject: assistantMessage(
                    id: "stability-notice-reply",
                    content: [[
                        "id": "stability-notice-reply:text",
                        "ordinal": 0,
                        "type": "text",
                        "text": "A reply that failed after it started.",
                    ]],
                    errorMessage: RowStabilityFixture.truncatedError
                ))
            ))
            snapshot.transcriptTotal = (snapshot.transcriptTotal ?? snapshot.transcript.count - 1) + 1
            let initial = snapshot
            try await withStabilityHarness(snapshot: initial) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.isReady
                        && $0.nativeRows.contains { $0.semanticID == "stability-notice-reply" }
                }
                try await driveBoundaries(12, harness: harness)
                let observation = harness.probeObservation
                // The notice's title is truncated, so the pill is interactive
                // and glass; the measurement that decides it arrives after the
                // first layout pass and must not switch the pill's structure.
                #expect(
                    observation.rowIdentityInstanceCounts["embedded-notice"] == 1,
                    "the truncation measurement remounted the notice pill"
                )
            }
        }
    }
}

// MARK: - The journey's phases and report

/// One measured phase: every fixture row's frame height at that phase, plus the
/// probe's own counters.
private struct RowStabilityReport {
    static let schema = "tron.chat-row-stability-report.v1"
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static var directory: URL { packageRoot.appending(path: "build/row-stability") }
    static var reportURL: URL { directory.appending(path: "report.json") }

    var phases: [String] = []
    var heightsByPhase: [String: [String: CGFloat]] = [:]
    /// The native transcript row heights at every display frame of the journey,
    /// grouped by the row's physical mount. A settled row must present one
    /// height per mount: a second height inside one mount is a measurement or
    /// animation that landed after the row was admitted (FM-F3b), and a height
    /// that differs between mounts is a row that laid out from an estimate
    /// until it was remounted (FM-F2a).
    var mountHeights: [String: [UUID: RowMountHeight]] = [:]
    var postMountResizeCount = 0
    var maximumPostMountResize: CGFloat = 0
    var resizedRows: [String] = []
    var remountedRows: [String] = []
    var records: [String: ChatHostedRowStabilityRecord] = [:]
    var identityInstanceCounts: [String: Int] = [:]
    var appearanceCounts: [String: Int] = [:]
    var disappearanceCounts: [String: Int] = [:]
    var excludedRowCount = 0
    var semanticFrameCallbackCount = 0
    /// The compact thinking traces' own measurements: the F2 fix is only real if
    /// the trace still receives them (the tap target, the trait and the mask
    /// read the overflow flag, which nothing else observes).
    var thinkingTraces: [String: ChatHostedThinkingTraceMeasurement] = [:]
    var collapsedStaysCollapsed = false
    var inlineDisplaysPrepared = false
    var inlineDisplaysStable = false
    var entranceIdentityStable = false

    @MainActor
    mutating func capture(phase: String, harness: ChatViewScrollHarness) {
        let observation = harness.probeObservation
        phases.append(phase)
        heightsByPhase[phase] = RowStabilityFixture.rowIDs.reduce(into: [:]) { values, id in
            values[id] = observation.rowFrames[id]?.height
        }
        collectNativeHeights(harness)
    }

    /// Drains the retained display-frame samples into the per-mount height
    /// history. Called at every phase boundary so the recorder's bounded window
    /// cannot drop the frames a finding happens in.
    @MainActor
    private mutating func collectNativeHeights(_ harness: ChatViewScrollHarness) {
        for sample in harness.recorder.samples {
            for row in sample.nativeRows where RowStabilityFixture.rowIDs.contains(row.semanticID) {
                guard row.frame.height.isFinite, row.frame.height > 1 else { continue }
                var mounts = mountHeights[row.semanticID, default: [:]]
                mounts[row.instance, default: RowMountHeight(frameIndex: sample.frameIndex)]
                    .record(height: row.frame.height)
                mountHeights[row.semanticID] = mounts
            }
        }
    }

    @MainActor
    mutating func finish(harness: ChatViewScrollHarness) {
        let observation = harness.probeObservation
        records = observation.rowStabilityRecords
        identityInstanceCounts = observation.rowIdentityInstanceCounts
        appearanceCounts = observation.physicalRowAppearanceCounts
        disappearanceCounts = observation.physicalRowDisappearanceCounts
        excludedRowCount = observation.excludedRowStabilityIDs.count
        semanticFrameCallbackCount = observation.semanticFrameCallbackCount
        thinkingTraces = observation.thinkingTraceMeasurements
        postMountResizeCount = observation.postMountResizeCount
        maximumPostMountResize = observation.maximumPostMountResize
        resizedRows = observation.resizedSemanticIDs
        remountedRows = observation.remountedSemanticIDs
        collapsedStaysCollapsed = heightsByPhase["open"]?[RowStabilityFixture.collapsedDisplayID]
            .flatMap { open in
                heightsByPhase["return-2"]?[RowStabilityFixture.collapsedDisplayID]
                    .map { abs($0 - open) <= 0.5 }
            } ?? false
        // The hosted harness has no media source, so an inline display cannot
        // reach its prepared state here; the field reports that honestly and
        // the stability field reports what the row's height did instead.
        inlineDisplaysPrepared = false
        inlineDisplaysStable = RowStabilityFixture.inlineDisplayIDs.allSatisfy { id in
            guard let open = heightsByPhase["open"]?[id],
                  let returned = heightsByPhase["return-2"]?[id] else { return false }
            return abs(returned - open) <= 0.5 && (records[id]?.resizeCount ?? 0) == 0
        }
        // The entrance row's content identity must survive its admission: an
        // admission that switched the row's structure would record a second
        // instance for it.
        entranceIdentityStable = (identityInstanceCounts[RowStabilityFixture.entranceRowID] ?? 0) <= 1
    }

    /// Fixture rows that left the lazy range and mounted again: the journey's
    /// own proof that it exercised the remount path the findings are about.
    var remountedRowCount: Int {
        RowStabilityFixture.rowIDs.count { (appearanceCounts[$0] ?? 0) > 1 }
    }

    /// Rows that presented a height once and a different one at a later display
    /// frame under the same physical mount: a measurement or animation that
    /// arrived after the row mounted (FM-F3b). `stability-entrance` is not
    /// counted, because its admission owns its height by design (FM-F1's
    /// animation) and the probe excludes it too.
    var withinMountVariantRows: [String: String] {
        mountHeights
            .filter { $0.key != RowStabilityFixture.entranceRowID }
            .reduce(into: [:]) { values, entry in
                let changed = entry.value.values.filter { $0.changeCount > 0 }
                guard !changed.isEmpty else { return }
                let maximum = changed.map(\.maximumChange).max() ?? 0
                values[entry.key] = "\(changed.count)/\(entry.value.count)@\(rowStabilityNumber(maximum))"
            }
    }

    /// Rows whose height differed between two of their physical mounts: the
    /// first mount laid the row out from an estimate, and only a later mount
    /// reached the measured height (FM-F2a). The entrance row is excluded for
    /// the same reason as above.
    var crossMountVariantRows: [String: String] {
        mountHeights
            .filter { $0.key != RowStabilityFixture.entranceRowID }
            .reduce(into: [:]) { values, entry in
                let heights = entry.value.values.map(\.latestHeight)
                guard let low = heights.min(), let high = heights.max(),
                      high - low > 0.5 else { return }
                values[entry.key] = "\(rowStabilityNumber(low))..\(rowStabilityNumber(high))"
            }
    }
    /// Rows whose frame height differed between two journey phases: the row's
    /// own geometric height changed while the journey only scrolled (FM-F2a and
    /// FM-F3b are both visible here, because the phase capture reads the row's
    /// published frame rather than a native mount).
    var phaseVariantRows: [String: String] {
        RowStabilityFixture.rowIDs.reduce(into: [:]) { values, id in
            let heights = phases.compactMap { heightsByPhase[$0]?[id] }
            guard let low = heights.min(), let high = heights.max(),
                  high - low > 0.5 else { return }
            values[id] = "\(rowStabilityNumber(low))..\(rowStabilityNumber(high))"
        }
    }

    /// One line in the same spirit as the CT-2 fixtures: every field the
    /// journey reports, so two runs diff directly.
    var line: String {
        "ROW-STABILITY"
            + " phases=\(phases.joined(separator: ","))"
            + " postMountResizes=\(postMountResizeCount)"
            + " maxPostMountResize=\(rowStabilityNumber(maximumPostMountResize))"
            + " resizedRows=\(resizedRows.count)\(resizedRows.isEmpty ? "" : ":\(resizedRows.joined(separator: ","))")"
            + " remountedRows=\(remountedRows.count)\(remountedRows.isEmpty ? "" : ":\(remountedRows.joined(separator: ","))")"
            + " remounts=\(remountedRowCount)/\(RowStabilityFixture.rowIDs.count)"
            + " withinMountVariants=\(rowStabilityVariantSummary(withinMountVariantRows))"
            + " crossMountVariants=\(rowStabilityVariantSummary(crossMountVariantRows))"
            + " phaseVariants=\(rowStabilityVariantSummary(phaseVariantRows))"
            + " thinkingTraces=\(rowStabilityThinkingSummary(thinkingTraces))"
            + " collapsedStaysCollapsed=\(collapsedStaysCollapsed)"
            + " inlineDisplaysPrepared=\(inlineDisplaysPrepared)"
            + " inlineDisplaysStable=\(inlineDisplaysStable)"
            + " entranceIdentityStable=\(entranceIdentityStable)"
            + " excludedRows=\(excludedRowCount)"
            + " semanticFrameCallbacks=\(semanticFrameCallbackCount)"
    }

    func write() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: Self.reportURL)
    }

    private var payload: Payload {
        Payload(
            schema: Self.schema,
            phases: phases,
            postMountResizeCount: postMountResizeCount,
            maximumPostMountResize: maximumPostMountResize,
            resizedRows: resizedRows,
            remountedRows: remountedRows,
            withinMountVariantRows: withinMountVariantRows,
            crossMountVariantRows: crossMountVariantRows,
            phaseVariantRows: phaseVariantRows,
            collapsedStaysCollapsed: collapsedStaysCollapsed,
            inlineDisplaysPrepared: inlineDisplaysPrepared,
            inlineDisplaysStable: inlineDisplaysStable,
            entranceIdentityStable: entranceIdentityStable,
            excludedRowCount: excludedRowCount,
            semanticFrameCallbackCount: semanticFrameCallbackCount,
            thinkingTraces: thinkingTraces.mapValues { trace in
                Payload.Trace(
                    contentHeight: trace.contentHeight,
                    referenceHeight: trace.referenceHeight,
                    overflowing: trace.overflowing
                )
            },
            rows: RowStabilityFixture.rowIDs.map { id in
                let record = records[id]
                return Payload.Row(
                    semanticID: id,
                    kind: RowStabilityFixture.kind(for: id),
                    firstHeight: record?.firstHeight,
                    latestHeight: record?.latestHeight,
                    resizeCount: record?.resizeCount ?? 0,
                    maximumResize: record?.maximumResize ?? 0,
                    identityInstances: identityInstanceCounts[id] ?? 0,
                    appearances: appearanceCounts[id] ?? 0,
                    disappearances: disappearanceCounts[id] ?? 0,
                    mounts: (mountHeights[id] ?? [:]).values
                        .sorted { $0.frameIndex < $1.frameIndex }
                        .map { Payload.Mount(frameIndex: $0.frameIndex, first: $0.firstHeight,
                                            latest: $0.latestHeight, changes: $0.changeCount) },
                    heightsByPhase: heightsByPhase.reduce(into: [:]) { values, entry in
                        if let height = entry.value[id] { values[entry.key] = height }
                    }
                )
            }
        )
    }

    private struct Payload: Encodable {
        struct Mount: Encodable {
            let frameIndex: Int
            let first: CGFloat?
            let latest: CGFloat
            let changes: Int
        }

        struct Row: Encodable {
            let semanticID: String
            let kind: String
            let firstHeight: CGFloat?
            let latestHeight: CGFloat?
            let resizeCount: Int
            let maximumResize: CGFloat
            let identityInstances: Int
            let appearances: Int
            let disappearances: Int
            let mounts: [Mount]
            let heightsByPhase: [String: CGFloat]
        }

        let schema: String
        let phases: [String]
        let postMountResizeCount: Int
        let maximumPostMountResize: CGFloat
        let resizedRows: [String]
        let remountedRows: [String]
        let withinMountVariantRows: [String: String]
        let crossMountVariantRows: [String: String]
        let phaseVariantRows: [String: String]
        let collapsedStaysCollapsed: Bool
        let inlineDisplaysPrepared: Bool
        let inlineDisplaysStable: Bool
        let entranceIdentityStable: Bool
        struct Trace: Encodable {
            let contentHeight: CGFloat
            let referenceHeight: CGFloat
            let overflowing: Bool
        }

        let excludedRowCount: Int
        let semanticFrameCallbackCount: Int
        let thinkingTraces: [String: Trace]
        let rows: [Row]
    }
}

/// One physical mount's native row heights across display frames. A settled row
/// presents one height per mount; the second height is the row measuring or
/// animating itself after it was admitted.
private struct RowMountHeight {
    let frameIndex: Int
    private(set) var firstHeight: CGFloat?
    private(set) var latestHeight: CGFloat
    private(set) var changeCount = 0
    private(set) var maximumChange: CGFloat = 0
    init(frameIndex: Int) {
        self.frameIndex = frameIndex
        self.latestHeight = 0
    }

    mutating func record(height: CGFloat) {
        guard firstHeight != nil else {
            firstHeight = height
            latestHeight = height
            return
        }
        if abs(height - latestHeight) > 0.5 {
            changeCount += 1
            maximumChange = max(maximumChange, abs(height - latestHeight))
        }
        latestHeight = height
    }
}

private func rowStabilityThinkingSummary(
    _ traces: [String: ChatHostedThinkingTraceMeasurement]
) -> String {
    guard !traces.isEmpty else { return "0" }
    return traces.sorted { $0.key < $1.key }
        .map {
            "\($0.key)=content:\(rowStabilityNumber($0.value.contentHeight))"
                + ":reference:\(rowStabilityNumber($0.value.referenceHeight))"
                + ":overflowing:\($0.value.overflowing)"
        }
        .joined(separator: ",")
}

private func rowStabilityVariantSummary(_ values: [String: String]) -> String {
    guard !values.isEmpty else { return "0" }
    return "\(values.count):" + values.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ",")
}

private func rowStabilityNumber(_ value: CGFloat) -> String {
    String(format: "%.1f", Double(value))
}

// MARK: - The transcript under test

/// The one history the journey uses: ordinary rows, then one row of every kind
/// the audit names. The newest rows sit at the tail, so the journey's detach and
/// oldest-row scroll take them out of the lazy range and back.
private enum RowStabilityFixture {
    static let promptAttachmentsID = "stability-prompt-attachments"
    static let thinkingID = "stability-thinking"
    /// A tool run's rendered row identity is `tool-run-` plus its call ID.
    static let inlineDisplayCallIDs = ["stability-display-inline-a", "stability-display-inline-b"]
    static let inlineDisplayIDs = inlineDisplayCallIDs.map { "tool-run-" + $0 }
    static let collapsedDisplayCallID = "stability-display-sheet"
    static let collapsedDisplayID = "tool-run-" + collapsedDisplayCallID
    static let toolRunCallID = "stability-tool-call"
    static let toolRunID = "tool-run-" + toolRunCallID
    static let errorNoticeID = "stability-error-notice"
    static let codeTableID = "stability-code-table"
    static let oldestHistoryID = "stability-history-0"
    /// Inserted after the open, so its admission runs inside the journey.
    static let entranceRowID = "stability-entrance"

    static let rowIDs = [
        entranceRowID,
        promptAttachmentsID,
        thinkingID,
        inlineDisplayIDs[0],
        inlineDisplayIDs[1],
        collapsedDisplayID,
        toolRunID,
        errorNoticeID,
        codeTableID,
    ]

    /// Display artifact identity is a UUID in the display contract.
    static func artifactID(for callID: String) -> String {
        switch callID {
        case inlineDisplayCallIDs[0]: "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc31"
        case inlineDisplayCallIDs[1]: "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc32"
        default: "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc33"
        }
    }

    static func kind(for id: String) -> String {
        switch id {
        case promptAttachmentsID: "prompt-with-attachments"
        case thinkingID: "wrapped-thinking"
        case inlineDisplayIDs[0], inlineDisplayIDs[1]: "inline-markdown-display"
        case collapsedDisplayID: "collapsed-display-card"
        case toolRunID: "tool-run"
        case errorNoticeID: "truncated-error-notice"
        case codeTableID: "code-and-table-response"
        case entranceRowID: "inserted-entrance"
        default: "unknown"
        }
    }

    /// A single wrapped thinking segment: the estimate (`ThinkingBlock`'s
    /// 16 pt a segment) is nowhere near its measured height, which is exactly
    /// the shape whose measurement used to arrive after the row mounted.
    static let wrappedThinking = Array(
        repeating: "Wrapped thinking text that measures far taller than one segment's estimate.",
        count: 4
    ).joined(separator: " ")

    static let codeAndTable = """
        Here is a response with a code block and a table.

        ```swift
        struct Row {
            let height: CGFloat
        }
        ```

        | row kind | post-mount resize |
        | --- | --- |
        | thinking | measured |
        | display | measured |

        The table and the code block are both eager Markdown blocks.
        """

    static let truncatedError = Array(
        repeating: "Provider request failed after the stream started because the upstream connection was reset",
        count: 4
    ).joined(separator: " ")
}

/// The journey's history: enough ordinary rows that the newest ones really
/// leave the lazy range when the reader scrolls to the oldest loaded row, then
/// one row of every kind under test.
private func rowStabilitySnapshot() throws -> SessionSnapshot {
    var snapshot = try SessionScenarioBuilder(seed: 1_327).openingTail(targetEncodedBytes: 4_096)
    let rows = rowStabilityHistoryItems() + rowStabilityItems()
    var parentID: String?
    var items: [TranscriptItem] = []
    for row in rows {
        var row = row
        row["parentId"] = parentID ?? NSNull()
        parentID = row["id"] as? String
        items.append(try decodeTranscriptFixture(
            TranscriptItem.self,
            from: try JSONSerialization.data(withJSONObject: row)
        ))
    }
    snapshot.transcript = items
    snapshot.transcriptStart = 0
    snapshot.transcriptTotal = items.count
    snapshot.toolExecutions = []
    return snapshot
}

/// Twenty-four ordinary rows. The lazy stack must be able to drop the fixture
/// rows when the reader is at the oldest one, so the history is tall enough that
/// they sit outside its realization range.
private func rowStabilityHistoryItems() -> [[String: Any]] {
    (0..<24).map { index in
        let id = "stability-history-\(index)"
        if index.isMultiple(of: 3) {
            return userMessage(
                id: id,
                text: "History prompt \(index): a question long enough to wrap onto a second line of the transcript."
            )
        }
        return assistantMessage(
            id: id,
            content: [
                [
                    "id": "\(id):text",
                    "ordinal": 0,
                    "type": "text",
                    "text": "History reply \(index) with two short paragraphs.\n\nThe second paragraph keeps the row taller than one line, so the lazy stack has real work to drop.",
                ],
            ]
        )
    }
}

/// The snapshot with one more assistant row at the tail: a discrete insertion
/// the transcript must admit with an entrance.
private func insertingEntranceRow(into snapshot: SessionSnapshot) throws -> SessionSnapshot {
    var updated = snapshot
    updated.transcript.append(try decodeTranscriptFixture(
        TranscriptItem.self,
        from: try JSONSerialization.data(withJSONObject: assistantMessage(
            id: RowStabilityFixture.entranceRowID,
            content: [
                [
                    "id": "\(RowStabilityFixture.entranceRowID):text",
                    "ordinal": 0,
                    "type": "text",
                    "text": "An inserted reply whose admission owns the row content's identity.",
                ],
            ]
        ))
    ))
    updated.transcriptTotal = (updated.transcriptTotal ?? updated.transcript.count - 1) + 1
    updated.revision += 1
    updated.eventSequence += 1
    return updated
}

private func userMessage(id: String, text: String) -> [String: Any] {
    [
        "id": id,
        "parentId": NSNull(),
        "presentationId": id,
        "timestamp": "2026-01-01T00:00:00Z",
        "kind": "message",
        "role": "user",
        "content": [
            [
                "id": "\(id):text",
                "ordinal": 0,
                "type": "text",
                "text": text,
            ],
        ],
    ]
}

private func rowStabilityItems() -> [[String: Any]] {
    var items: [[String: Any]] = []
    items.append(userPromptWithAttachments(
        id: RowStabilityFixture.promptAttachmentsID
    ))
    items.append(assistantMessage(
        id: RowStabilityFixture.thinkingID,
        content: [
            [
                "id": "\(RowStabilityFixture.thinkingID):thinking",
                "ordinal": 0,
                "thinkingRunOrdinal": 0,
                "type": "thinking",
                "text": RowStabilityFixture.wrappedThinking,
            ],
            [
                "id": "\(RowStabilityFixture.thinkingID):text",
                "ordinal": 1,
                "type": "text",
                "text": "The wrapped thinking row above is the row under test.",
            ],
        ]
    ))
    items.append(contentsOf: inlineDisplayRows(
        callID: RowStabilityFixture.inlineDisplayCallIDs[0],
        title: "Inline Markdown A"
    ))
    items.append(contentsOf: inlineDisplayRows(
        callID: RowStabilityFixture.inlineDisplayCallIDs[1],
        title: "Inline Markdown B"
    ))
    items.append(contentsOf: inlineDisplayRows(
        callID: RowStabilityFixture.collapsedDisplayCallID,
        title: "Sheet Markdown",
        surface: "sheet",
        tapAction: "none"
    ))
    items.append(contentsOf: toolRunRows(callID: RowStabilityFixture.toolRunCallID))
    items.append(assistantMessage(
        id: RowStabilityFixture.errorNoticeID,
        content: [
            [
                "id": "\(RowStabilityFixture.errorNoticeID):text",
                "ordinal": 0,
                "type": "text",
                "text": "A reply that failed after it started.",
            ],
        ],
        errorMessage: RowStabilityFixture.truncatedError
    ))
    items.append(assistantMessage(
        id: RowStabilityFixture.codeTableID,
        content: [
            [
                "id": "\(RowStabilityFixture.codeTableID):text",
                "ordinal": 0,
                "type": "text",
                "text": RowStabilityFixture.codeAndTable,
            ],
        ]
    ))
    return items
}

private func userPromptWithAttachments(id: String) -> [String: Any] {
    [
        "id": id,
        "parentId": NSNull(),
        "presentationId": id,
        "timestamp": "2026-01-01T00:00:00Z",
        "kind": "message",
        "role": "user",
        "content": [
            [
                "id": "\(id):image",
                "ordinal": 0,
                "type": "image",
                "blobId": "stability-attachment-image",
                "mimeType": "image/jpeg",
            ],
            [
                "id": "\(id):file",
                "ordinal": 1,
                "type": "text",
                "text": "",
                "attachment": ["name": "stability-notes.txt", "mimeType": "text/plain", "size": 42],
                "blobId": "stability-attachment-file",
            ],
            [
                "id": "\(id):text",
                "ordinal": 2,
                "type": "text",
                "text": "A prompt with one image and one file attachment.",
            ],
        ],
    ]
}

private func assistantMessage(
    id: String,
    content: [[String: Any]],
    errorMessage: String? = nil
) -> [String: Any] {
    var item: [String: Any] = [
        "id": id,
        "parentId": NSNull(),
        "presentationId": id,
        "timestamp": "2026-01-01T00:00:00Z",
        "kind": "message",
        "role": "assistant",
        "content": content,
        "provider": "test",
        "modelId": "synthetic",
        "stopReason": "stop",
    ]
    if let errorMessage { item["errorMessage"] = errorMessage }
    return item
}

/// One display tool call and its result: the call is a `display` tool call on
/// the assistant row, the result carries the display projection. Two of these
/// adjacent are the two inline Markdown displays the audit names.
private func inlineDisplayRows(
    callID: String,
    title: String,
    surface: String = "inline",
    tapAction: String = "sheet"
) -> [[String: Any]] {
    let requestID = "\(callID)-request"
    let resultID = "\(callID)-result"
    return [
        assistantMessage(
            id: requestID,
            content: [
                [
                    "id": "\(callID)-call-content",
                    "ordinal": 0,
                    "type": "toolCall",
                    "toolCallId": callID,
                    "name": "display",
                    "arguments": ["presentation": ["surface": surface]],
                ],
            ]
        ),
        [
            "id": resultID,
            "parentId": requestID,
            "presentationId": resultID,
            "timestamp": "2026-01-01T00:00:01Z",
            "kind": "message",
            "role": "toolResult",
            "content": [
                [
                    "id": "\(resultID)-text",
                    "ordinal": 0,
                    "type": "text",
                    "text": "Displayed \(title).",
                ],
            ],
            "toolCallId": callID,
            "toolName": "display",
            "isError": false,
            "display": [
                "schema": "tron.display.v1",
                "displayId": callID,
                "revision": 1,
                "title": title,
                "altText": "\(title) fixture.",
                "kind": "markdown",
                "presentation": ["requestedSurface": surface, "inlineTapAction": tapAction],
                "eligibleSurfaces": ["sheet", "inline"],
                "fallbackText": "\(title) fixture.",
                "artifact": [
                    "id": RowStabilityFixture.artifactID(for: callID),
                    "name": "\(callID).md",
                    "mimeType": "text/markdown",
                    "size": 335,
                    "kind": "markdown",
                ],
            ],
        ],
    ]
}

/// One ordinary tool run: a call on the assistant row and its result.
private func toolRunRows(callID: String) -> [[String: Any]] {
    let requestID = "\(callID)-request"
    let resultID = "\(callID)-result"
    return [
        assistantMessage(
            id: requestID,
            content: [
                [
                    "id": "\(resultID)-call-content",
                    "ordinal": 0,
                    "type": "toolCall",
                    "toolCallId": callID,
                    "name": "read",
                    "arguments": ["path": "README.md"],
                ],
            ]
        ),
        [
            "id": resultID,
            "parentId": requestID,
            "presentationId": resultID,
            "timestamp": "2026-01-01T00:00:01Z",
            "kind": "message",
            "role": "toolResult",
            "content": [
                [
                    "id": "\(resultID)-text",
                    "ordinal": 0,
                    "type": "text",
                    "text": "Read the README.",
                ],
            ],
            "toolCallId": callID,
            "toolName": "read",
            "isError": false,
        ],
    ]
}

// MARK: - Driving the real hosted chat

/// A harness whose probe admits native scroll callbacks, so the journey moves
/// the real transcript view and the coordinator observes the real geometry.
/// The reader's interaction phase is admitted through the coordinator's own
/// phase path because the harness cannot inject a UIKit drag.
@MainActor
private func withStabilityHarness(
    snapshot: SessionSnapshot,
    operation: @escaping @MainActor (ChatViewScrollHarness) async throws -> Void
) async throws {
    let harness = try ChatViewScrollHarness(
        snapshot: snapshot,
        displayFrameScheduler: .displayLink,
        scrollCallbackMode: .native
    )
    do {
        try await operation(harness)
    } catch {
        await harness.close()
        throw error
    }
    await harness.close()
}

/// The composer-submission harness for the canonical handoff: a real outgoing
/// submission the authoritative snapshot then acknowledges.
@MainActor
private func withComposerSubmissionHarness(
    snapshot: SessionSnapshot,
    operation: @escaping @MainActor (ChatViewScrollHarness) async throws -> Void
) async throws {
    let harness = try await ChatViewScrollHarness.composerSubmissionHarness(
        snapshot: snapshot,
        displayFrameScheduler: .displayLink
    )
    do {
        try await operation(harness)
    } catch {
        await harness.close()
        throw error
    }
    await harness.close()
}

@MainActor
private func driveBoundaries(_ count: Int, harness: ChatViewScrollHarness) async throws {
    for _ in 0..<count { try await harness.driveFrameBoundary() }
}
