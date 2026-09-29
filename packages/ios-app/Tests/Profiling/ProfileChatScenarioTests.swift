import Foundation
import Synchronization
import SwiftUI
@testable import TronMobileCore
import XCTest
@testable import TronMobile

/// Chat scenarios for `scripts/tron-profile ios`: the production `ChatView`
/// opened through `AppModel`'s real `session.open`/`session.sync` path over the
/// scripted Gateway, then driven by pre-encoded Gateway frames at the
/// Gateway's cadence. Frames are encoded before the measured window so the
/// window contains only what the app does with them.
@MainActor
final class ProfileChatScenarioTests: XCTestCase {
    func testIdleChat() throws {
        try profileScenario("idle-chat", defaultWindow: .seconds(30)) { _ in
            let history = ProfileTranscript.history(seed: 7_101, items: 200)
            return try await ProfileChatRun.make(snapshot: ProfileTranscript.snapshot(seed: 7_101, items: history), frames: [])
        }
    }

    func testStreamingReply() throws {
        try profileScenario("streaming-reply", defaultWindow: .seconds(12)) { window in
            let history = ProfileTranscript.history(seed: 7_201, items: 200)
            let snapshot = try ProfileTranscript.snapshot(seed: 7_201, items: history)
            return try await ProfileChatRun.make(
                snapshot: snapshot,
                frames: ProfileStreamingScript.frames(base: snapshot, window: window)
            )
        }
    }

    func testToolLoop() throws {
        try profileScenario("tool-loop", defaultWindow: .seconds(15)) { window in
            let (history, snapshot) = try ProfileTranscript.pageBoundSession(seed: 7_301)
            return try await ProfileChatRun.make(
                snapshot: snapshot,
                history: history,
                frames: ProfileToolLoopScript.frames(base: snapshot, window: window)
            )
        }
    }
}

/// One scripted Gateway frame at its offset from the window start.
struct ProfileScriptedFrame {
    let offset: Duration
    let topic: String
    let data: Data
    /// The session event sequence this frame installs, when it is sequenced.
    let eventSequence: Int?
}

@MainActor
final class ProfileChatRun: ProfileScenarioRun {
    /// No frame is sent in the window's last second, so the window contains
    /// the processing of every frame it delivered.
    static let drainTail = Duration.seconds(1)

    let fixture: ProfileGatewayFixture
    let snapshot: SessionSnapshot
    private let frames: [ProfileScriptedFrame]
    private var host: UIHostingController<AnyView>?
    let signposts = ProfileOpeningSignposts()
    private var history: [TranscriptItem] = []
    private var resynchronizationsBefore = 0
    private var expectedSequence: Int?
    private var lostMount: String?
    private var repairsExhaustedBefore = 0

    private init(fixture: ProfileGatewayFixture, snapshot: SessionSnapshot, frames: [ProfileScriptedFrame]) {
        self.fixture = fixture
        self.snapshot = snapshot
        self.frames = frames
    }

    /// Connects, publishes a catalog containing the session, answers the chat
    /// opening RPCs with `snapshot`, and mounts the production chat.
    /// `history` is the whole canonical session when `snapshot` holds only
    /// its newest page; older pages are served from it like the Gateway does.
    static func make(
        snapshot: SessionSnapshot,
        history: [TranscriptItem]? = nil,
        frames: [ProfileScriptedFrame],
        draftStore: ((URL) -> ComposerDraftStore)? = nil
    ) async throws -> ProfileChatRun {
        ProfileScenarioLedger.shared.reset()
        let fixture = try ProfileGatewayFixture(composerDraftStore: draftStore)
        let run = ProfileChatRun(fixture: fixture, snapshot: snapshot, frames: frames)
        run.history = history ?? snapshot.transcript
        do {
            try run.scriptChatOpening()
            try await fixture.connect(capabilities: ["sessions.v1", "skill-prompt.v1"])
            guard await fixture.model.refreshSessions() == .published else {
                throw ProfileScenarioError.notReady("session.list did not publish the fixture session")
            }
            let signposts = run.signposts
            run.host = try fixture.mount(NavigationStack {
                ChatView(sessionID: snapshot.sessionId, performanceSignposts: signposts)
            })
        } catch {
            await fixture.teardown()
            throw error
        }
        return run
    }

    private func scriptChatOpening() throws {
        let session = try JSONValue.encode(snapshot)
        let summary = try JSONValue.encode([SessionSummary(
            id: snapshot.sessionId, name: snapshot.name, cwd: snapshot.cwd, parentSessionId: nil,
            createdAt: "2026-09-01T10:00:00.000Z", updatedAt: "2026-09-01T10:05:00.000Z",
            messageCount: snapshot.transcriptTotal ?? snapshot.transcript.count,
            firstMessage: "Profile chat fixture", phase: snapshot.phase, summaryRevision: 1
        )])
        fixture.handle("session.list") { _ in .object(["sessions": summary, "listRevision": .number(1)]) }
        fixture.handle("session.open") { _ in
            .object([
                "session": session,
                "syncToken": .string("profile-sync"),
                "subscriptionToken": .string("profile-subscription"),
                "completionRevision": .number(0),
            ])
        }
        fixture.handle("session.sync") { _ in .object(["synchronized": .bool(true)]) }
        fixture.handle("session.transcript") { [weak self] params in
            guard let self else { throw CancellationError() }
            return try self.olderPage(params)
        }
        fixture.handle("session.close") { _ in .object(["closed": .bool(true)]) }
        // An empty catalog: the composer's model picker loads it on open, and an
        // unanswered read would put an error notice on screen during the window.
        fixture.handle("provider.list") { _ in .object(["providers": .array([])]) }
        fixture.handle("model.list") { _ in .object(["models": .array([]), "nextCursor": .null]) }
        fixture.handle("session.presentation.set") { params in
            .object([
                "visible": params?.objectValue?["visible"] ?? .bool(true),
                "revision": params?.objectValue?["revision"] ?? .number(0),
            ])
        }
        fixture.handle("session.commands") { _ in .object(["commands": .array([])]) }
        fixture.handle("session.attention.read") { _ in
            .object(["completionRevision": .number(0), "attentionRevision": .number(0), "isUnread": .bool(false)])
        }
    }

    /// The Gateway's `projectTranscriptPage`: newest-first up to 512 items and
    /// 600 KB before `before`, against the current authoritative branch.
    private func olderPage(_ params: JSONValue?) throws -> JSONValue {
        guard let before = params?.objectValue?["before"]?.intValue else {
            throw ProfileScenarioError.workloadDiverged("unscripted forward transcript page")
        }
        let current = fixture.model.authoritativeSnapshot(for: snapshot.sessionId) ?? snapshot
        let pageStart = current.transcriptStart ?? 0
        let total = current.transcriptTotal ?? current.transcript.count
        func entry(_ index: Int) -> TranscriptItem? {
            if index >= pageStart, index - pageStart < current.transcript.count { return current.transcript[index - pageStart] }
            return history.indices.contains(index) ? history[index] : nil
        }
        guard before >= 0, before <= total else { throw ProfileScenarioError.workloadDiverged("transcript page before \(before) of \(total)") }
        var start = before
        var bytes = 2
        var items: [TranscriptItem] = []
        while start > 0, items.count < ProfileTranscript.pageItemBound, let item = entry(start - 1) {
            let itemBytes = try JSONEncoder.gateway.encode(item).count + 1
            if bytes + itemBytes > ProfileTranscript.pageByteBound, !items.isEmpty { break }
            items.insert(item, at: 0)
            bytes += itemBytes
            start -= 1
        }
        ProfileScenarioLedger.shared.add("rpc.transcript_pages")
        var page: [String: JSONValue] = [
            "items": try JSONValue.encode(items), "start": .number(Double(start)), "end": .number(Double(before)),
            "total": .number(Double(total)), "runtimeGeneration": .string(current.runtimeGeneration),
        ]
        if let leaf = current.leafEntryId { page["leafEntryId"] = .string(leaf) }
        if let next = entry(before) { page["nextEntryId"] = .string(next.id) }
        return .object(page)
    }

    func ready() async throws {
        guard let view = host?.view else { throw ProfileScenarioError.notReady("chat is not mounted") }
        let model = fixture.model
        let sessionID = snapshot.sessionId
        try await profileWaitUntil("chat opened \(sessionID) with live session authority") {
            guard let target = model.mountedPresentationTarget, target.sessionID == sessionID else { return false }
            return model.hasMountedSessionAuthority(target)
        }
        try await profileWaitUntil("transcript rows rendered in the native scroll view") {
            profileViews(UIScrollView.self, in: view).contains { $0.contentSize.height > $0.bounds.height * 2 }
        }
        // The production opening ends its first-ready-frame interval once the
        // transcript is positioned at the tail, or fails it when the layout did
        // not settle within ChatView's own bound.
        let signposts = signposts
        try await profileWaitUntil("chat opening finished its first ready frame", timeout: .seconds(60)) {
            signposts.firstReadyFrameResult != nil
        }
        guard signposts.firstReadyFrameResult == .success else {
            throw ProfileScenarioError.notReady("chat opening did not settle (first ready frame \(signposts.firstReadyFrameResult.map { "\($0)" } ?? "missing"))")
        }
        // Scroll settlement, text preparation and media finish over the next
        // frames; the window measures steady state after them.
        try await Task.sleep(for: .seconds(2))
        guard let target = model.mountedPresentationTarget, target.sessionID == sessionID,
              model.hasMountedSessionAuthority(target) else {
            throw ProfileScenarioError.notReady("chat lost its mounted session authority while settling")
        }
        guard model.visibleNotices.isEmpty else {
            throw ProfileScenarioError.notReady("an in-app notice is on screen: \(model.visibleNotices.map(\.title))")
        }
        if let divergence = renderCheck().divergence {
            throw ProfileScenarioError.notReady("the opened chat is not pinned to its tail: \(divergence)")
        }
    }

    func workload(window: Duration) async throws {
        let ledger = ProfileScenarioLedger.shared
        let resynchronizationsBefore = ledger.snapshot()["rpc.resynchronizations"] ?? 0
        repairsExhaustedBefore = repairsExhausted()
        let start = ContinuousClock.now
        for frame in frames where frame.offset < window - Self.drainTail {
            try await profileSleep(until: frame.offset, from: start)
            try await fixture.deliver(frame: frame.data)
            if lostMount == nil, fixture.model.mountedPresentationTarget?.sessionID != snapshot.sessionId {
                lostMount = "before \(frame.topic) at \(frame.offset)"
            }
            ledger.add("transport.frames.\(frame.topic)")
            ledger.add("transport.bytes.\(frame.topic)", frame.data.count)
        }
        try await profileSleep(until: window, from: start)
        self.resynchronizationsBefore = resynchronizationsBefore
        expectedSequence = frames.last(where: { $0.offset < window - Self.drainTail && $0.eventSequence != nil })?.eventSequence
    }

    /// A pinned chat follows its tail. The newest row must sit at the visual
    /// bottom when the window ends: a chat that stopped following a growing tail
    /// (the ChatScrollCoordinator's `chat.lease.repair-exhausted` mode) leaves
    /// the new rows below the viewport, where SwiftUI does not render them, and
    /// the window measures a fraction of the workload.
    ///
    /// The check is in window coordinates, through the same
    /// `TranscriptWindowOracle` the hosted journeys use: a scroll-space offset
    /// against the estimated content size points at the oldest history once
    /// CT-23 flips the transcript, and would then read a blank chat as followed.
    static let pinnedTailTolerance = TranscriptWindowOracle.profilingTolerance

    func renderCheck() -> ProfileRenderCheck {
        let exhausted = repairsExhausted() - repairsExhaustedBefore
        guard let view = host?.view,
              TranscriptWindowOracle.transcriptScrollView(in: view) != nil else {
            return ProfileRenderCheck(counters: ["followed": 0], divergence: "no transcript scroll view is mounted")
        }
        let bottom = TranscriptWindowOracle.bottom(in: view)
        let distance = bottom.pinnedError
        let followed = TranscriptWindowOracle.isPinned(in: view, tolerance: Self.pinnedTailTolerance)
        let detail = "tail_clearance=\(bottom.clearance.map { String(Int($0.rounded())) } ?? "none") "
            + "band_covered=\(bottom.isBandCovered) "
            + "visible_fraction=\(String(format: "%.2f", Double(bottom.visibleRowFraction))) "
            + "repair_exhausted=\(exhausted)"
        return ProfileRenderCheck(
            counters: ["followed": followed ? 1 : 0],
            divergence: followed ? nil : "the pinned transcript's newest row is \(distance.map { "\(Int($0.rounded()))" } ?? "not measurable") pt from its pinned bottom (\(detail))",
            detail: detail
        )
    }

    /// Evidence only: the chat trace ring is bounded, so this counts the
    /// retained warnings.
    private func repairsExhausted() -> Int {
        fixture.model.chatInteractionTrace.diagnosticRecords(limit: ChatInteractionTrace.maximumRecords)
            .count { $0.record.event == "chat.lease.repair-exhausted" }
    }

    func verify() async throws {
        let resynchronizations = (ProfileScenarioLedger.shared.snapshot()["rpc.resynchronizations"] ?? 0) - resynchronizationsBefore
        guard resynchronizations == 0 else {
            throw ProfileScenarioError.workloadDiverged(
                "the app resynchronized \(resynchronizations) time(s); the scripted event sequence was not admitted"
            )
        }
        if let expected = expectedSequence {
            let model = fixture.model
            let sessionID = snapshot.sessionId
            // The drain tail normally covers the last frame's processing; a
            // loaded host gets a bounded grace period outside the window.
            try? await profileWaitUntil("last scripted event installed", timeout: .seconds(10)) {
                (model.authoritativeSnapshot(for: sessionID)?.eventSequence ?? 0) >= expected
            }
            let installed = model.authoritativeSnapshot(for: sessionID)?.eventSequence
            guard installed == expected else {
                let target = model.mountedPresentationTarget
                throw ProfileScenarioError.workloadDiverged(
                    "installed event sequence \(installed.map(String.init) ?? "none"), expected \(expected); "
                        + "mounted \(target.map { "\($0.sessionID)#\($0.generation)" } ?? "none"), "
                        + "authority \(target.map(model.hasMountedSessionAuthority) ?? false), "
                        + "selected sequence \(model.selectedSnapshot.map { String($0.eventSequence) } ?? "none"), "
                        + "mount lost \(lostMount ?? "never"), "
                        + "connection \(model.connectionState), notices \(model.visibleNotices.map(\.title)), "
                        + "ledger \(ProfileScenarioLedger.shared.snapshot().sorted { $0.key < $1.key })"
                )
            }
        }
    }

    var surface: UIView? { host?.view }

    func teardown() async {
        await fixture.teardown()
    }
}

/// Deterministic transcripts with realistic prose, Markdown, tool calls and
/// tool results (the shared scenario builder's rows are single repeated
/// characters, which lay out unlike real text).
enum ProfileTranscript {
    static let timestamp = "2026-09-01T10:00:00.000Z"

    struct Words {
        private var state: UInt64
        private static let vocabulary = [
            "the", "session", "gateway", "request", "renders", "transcript", "quickly", "before", "after", "every",
            "update", "cache", "stores", "value", "and", "then", "returns", "result", "for", "this", "layout", "row",
            "keeps", "stable", "identity", "while", "streaming", "text", "arrives", "from", "model", "with", "tool",
            "output", "that", "changes", "state", "only", "when", "needed", "so", "scroll", "position", "holds",
        ]

        init(seed: Int) { state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 | 1 }

        mutating func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }

        mutating func sentence(_ count: Int) -> String {
            let words = (0..<count).map { _ in Self.vocabulary[next(Self.vocabulary.count)] }
            return words.joined(separator: " ").prefix(1).uppercased() + words.joined(separator: " ").dropFirst() + "."
        }

        mutating func paragraph(_ sentences: Int) -> String {
            (0..<sentences).map { _ in sentence(8 + next(10)) }.joined(separator: " ")
        }

        /// A Markdown reply: paragraphs, a list, inline code and sometimes a
        /// fenced block, the shapes the chat's text preparation handles.
        mutating func markdown(paragraphs: Int) -> String {
            var blocks: [String] = []
            for index in 0..<paragraphs {
                switch (index + next(3)) % 4 {
                case 0: blocks.append("## \(sentence(3).dropLast())")
                case 1: blocks.append((0..<3).map { _ in "- \(sentence(5)) Uses `value\(next(9))`." }.joined(separator: "\n"))
                case 2: blocks.append("```swift\nlet value = \(next(1000))\nprint(value)\n```")
                default: break
                }
                blocks.append(paragraph(2 + next(3)))
            }
            return blocks.joined(separator: "\n\n")
        }

        mutating func output(bytes: Int) -> String {
            var lines: [String] = []
            var total = 0
            while total < bytes {
                let line = "\(next(9999)): \(sentence(6))"
                lines.append(line)
                total += line.utf8.count + 1
            }
            return lines.joined(separator: "\n")
        }
    }

    static func id(_ seed: Int, _ index: Int, _ suffix: String? = nil) -> String {
        let base = String(format: "profile-%05d-%06d", seed, index)
        return suffix.map { "\(base)-\($0)" } ?? base
    }

    static func part(_ id: String, _ ordinal: Int, _ type: ContentPart.Kind, text: String? = nil,
                     thinkingRun: Int? = nil, toolCallId: String? = nil, name: String? = nil,
                     arguments: JSONValue? = nil) -> ContentPart {
        ContentPart(
            id: id, ordinal: ordinal, thinkingRunOrdinal: thinkingRun, type: type, text: text,
            attachment: nil, redacted: nil, mimeType: nil, blobId: nil, toolCallId: toolCallId,
            name: name, arguments: arguments
        )
    }

    static func message(id: String, parent: String?, role: TranscriptItem.Role, content: [ContentPart],
                        presentationID: String? = nil, toolCallId: String? = nil, toolName: String? = nil) -> TranscriptItem {
        .message(MessageTranscriptItem(
            id: id, parentId: parent, timestamp: timestamp, kind: .message, role: role,
            presentationId: presentationID ?? id, content: content,
            provider: role == .assistant ? "profile" : nil, modelId: role == .assistant ? "profile-model" : nil,
            stopReason: role == .assistant ? "stop" : nil, errorMessage: nil,
            toolCallId: toolCallId, toolName: toolName, isError: role == .toolResult ? false : nil,
            details: nil, usage: nil, startedAt: nil, completedAt: nil, durationMs: nil,
            lastProgressAt: nil, progressSequence: nil
        ))
    }

    /// Four-item turns: prompt, tool call, tool result, Markdown answer.
    static func item(seed: Int, index: Int, words: inout Words, toolOutputBytes: Int) -> TranscriptItem {
        let id = id(seed, index)
        let parent = index == 0 ? nil : Self.id(seed, index - 1)
        let call = Self.id(seed, index - (index % 4) + 1, "call")
        switch index % 4 {
        case 0:
            return message(id: id, parent: parent, role: .user, content: [part("\(id)-text", 0, .text, text: words.paragraph(1 + words.next(2)))])
        case 1:
            return message(id: id, parent: parent, role: .assistant, content: [
                part("\(id)-text", 0, .text, text: words.sentence(10)),
                part("\(id)-tool", 1, .toolCall, toolCallId: call, name: "read",
                     arguments: .object(["path": .string("Sources/File\(words.next(40)).swift")])),
            ])
        case 2:
            return message(id: id, parent: parent, role: .toolResult,
                           content: [part("\(id)-result", 0, .text, text: words.output(bytes: toolOutputBytes))],
                           toolCallId: call, toolName: "read")
        default:
            return message(id: id, parent: parent, role: .assistant, content: [part("\(id)-text", 0, .text, text: words.markdown(paragraphs: 2 + words.next(3)))])
        }
    }

    static func history(seed: Int, items: Int, toolOutputBytes: Int = 600) -> [TranscriptItem] {
        var words = Words(seed: seed)
        return (0..<items).map { item(seed: seed, index: $0, words: &words, toolOutputBytes: toolOutputBytes) }
    }

    /// An authoritative snapshot whose page is `items`, the newest tail of a
    /// longer canonical session.
    static func snapshot(seed: Int, items: [TranscriptItem], priorItems: Int = 0) throws -> SessionSnapshot {
        var snapshot = try SessionScenarioBuilder(seed: seed).openingTail(targetEncodedBytes: 4_096)
        snapshot.name = "Profile fixture"
        snapshot.transcript = items
        snapshot.transcriptStart = priorItems
        snapshot.transcriptTotal = priorItems + items.count
        snapshot.leafEntryId = items.last?.id
        return snapshot
    }

    /// The Gateway's authoritative page bound: at most 512 items and 600 KB of
    /// encoded transcript.
    static let pageItemBound = SessionSnapshot.maximumTranscriptItems
    static let pageByteBound = 600_000

    /// A 1,200-entry canonical session and its newest page at the bounds.
    static func pageBoundSession(seed: Int) throws -> (history: [TranscriptItem], snapshot: SessionSnapshot) {
        let items = history(seed: seed, items: 1_200, toolOutputBytes: 2_400)
        var page = Array(items.suffix(pageItemBound))
        while try encodedBytes(page) > pageByteBound - 20_000 { page.removeFirst() }
        return (items, try snapshot(seed: seed, items: page, priorItems: items.count - page.count))
    }

    static func encodedBytes(_ items: [TranscriptItem]) throws -> Int {
        try JSONEncoder.gateway.encode(items).count
    }

    static func frame(topic: String, sessionID: String?, payload: JSONValue) throws -> Data {
        var object: [String: JSONValue] = ["type": .string("event"), "topic": .string(topic), "payload": payload]
        if let sessionID { object["sessionId"] = .string(sessionID) }
        return try JSONEncoder.gateway.encode(JSONValue.object(object))
    }

    static func sessionEvent(topic: String, snapshot: SessionSnapshot, sequence: Int, data: JSONValue, offset: Duration) throws -> ProfileScriptedFrame {
        let payload: JSONValue = .object([
            "sessionId": .string(snapshot.sessionId),
            "runtimeGeneration": .string(snapshot.runtimeGeneration),
            "eventSequence": .number(Double(sequence)),
            "revision": .number(Double(snapshot.revision)),
            "data": data,
        ])
        return ProfileScriptedFrame(offset: offset, topic: topic,
                                    data: try frame(topic: topic, sessionID: snapshot.sessionId, payload: payload),
                                    eventSequence: sequence)
    }

    static func snapshotEvent(_ snapshot: SessionSnapshot, offset: Duration) throws -> ProfileScriptedFrame {
        ProfileScriptedFrame(offset: offset, topic: "session.snapshot",
                             data: try frame(topic: "session.snapshot", sessionID: snapshot.sessionId, payload: JSONValue.encode(snapshot)),
                             eventSequence: snapshot.eventSequence)
    }

    static func summaryEvent(_ snapshot: SessionSnapshot, revision: Int, offset: Duration) throws -> ProfileScriptedFrame {
        let update = SessionSummaryUpdate(
            sessionId: snapshot.sessionId, summaryRevision: revision, phase: snapshot.phase, name: snapshot.name,
            updatedAt: GatewayTimestamp.preciseString(from: Date(timeIntervalSince1970: 1_790_000_000 + offset.profileSeconds)),
            activeSince: snapshot.phase == .running ? "2026-09-01T10:00:00.000Z" : nil,
            messageCount: snapshot.transcriptTotal ?? snapshot.transcript.count, firstMessage: "Profile chat fixture"
        )
        return ProfileScriptedFrame(offset: offset, topic: "session.summary",
                                    data: try frame(topic: "session.summary", sessionID: nil, payload: JSONValue.encode(update)),
                                    eventSequence: nil)
    }

    /// Appends `item` as a canonical entry and slides the page to the bounds.
    static func appending(_ item: TranscriptItem, to snapshot: SessionSnapshot) throws -> SessionSnapshot {
        var next = snapshot
        next.transcript.append(item)
        next.transcriptTotal = (snapshot.transcriptTotal ?? snapshot.transcript.count) + 1
        next.leafEntryId = item.id
        next.eventSequence += 1
        next.revision += 1
        while next.transcript.count > 1 {
            let overItems = next.transcript.count > pageItemBound
            let overBytes = try encodedBytes(next.transcript) > pageByteBound
            guard overItems || overBytes else { break }
            next.transcript.removeFirst()
            next.transcriptStart = (next.transcriptStart ?? 0) + 1
        }
        return next
    }
}

/// `session.progress` at the Gateway's cadence: the SDK reports a token every
/// 12.5 ms; `RuntimeSlot.emitProgress` sends the first update after a quiet
/// window at once, then at most one frame per 150 ms window (a window that
/// sent re-arms the timer; only an empty window ends the throttle). Every frame
/// carries the cumulative reply: a thinking segment for the first 3 s, then
/// Markdown text.
enum ProfileStreamingScript {
    static let tokenInterval = Duration.microseconds(12_500)
    static let flushWindow = Duration.milliseconds(150)
    static let thinkingDuration = Duration.seconds(3)
    static let tokenCharacters = 4

    static func frames(base: SessionSnapshot, window: Duration) throws -> [ProfileScriptedFrame] {
        var words = ProfileTranscript.Words(seed: 9_001)
        let promptID = ProfileTranscript.id(9_001, 0, "prompt")
        let prompt = ProfileTranscript.message(id: promptID, parent: base.leafEntryId, role: .user,
                                               content: [ProfileTranscript.part("\(promptID)-text", 0, .text, text: words.paragraph(2))])
        var accepted = try ProfileTranscript.appending(prompt, to: base)
        accepted.phase = .running
        var frames = [try ProfileTranscript.snapshotEvent(accepted, offset: .zero)]
        var sequence = accepted.eventSequence

        let thinking = words.paragraph(40)
        let reply = words.markdown(paragraphs: 30)
        let startedAt = Duration.milliseconds(50)
        var updates: [(Duration, Int)] = []
        var token = 0
        while startedAt + tokenInterval * token < window {
            updates.append((startedAt + tokenInterval * token, token))
            token += 1
        }
        let thinkingTokens = Int(thinkingDuration.profileMilliseconds * 1_000 / tokenInterval.profileMicroseconds)
        func message(tokens: Int) throws -> JSONValue {
            let thinkingCharacters = min(thinking.count, min(tokens, thinkingTokens) * tokenCharacters)
            let replyCharacters = min(reply.count, max(0, tokens - thinkingTokens) * tokenCharacters)
            var content = [ProfileTranscript.part("streaming-thinking", 0, .thinking,
                                                  text: String(thinking.prefix(thinkingCharacters)), thinkingRun: 0)]
            if replyCharacters > 0 {
                content.append(ProfileTranscript.part("streaming-text", 1, .text, text: String(reply.prefix(replyCharacters))))
            }
            return try JSONValue.encode(ProfileTranscript.message(
                id: "streaming", parent: promptID, role: .assistant, content: content, presentationID: "stream:profile"
            ))
        }
        // Replay RuntimeSlot's throttle: an immediate first frame, then one
        // frame per window while updates keep arriving.
        var timerFires: Duration?
        var pending: Int?
        func emit(_ tokens: Int, at offset: Duration) throws {
            sequence += 1
            frames.append(try ProfileTranscript.sessionEvent(
                topic: "session.progress", snapshot: accepted, sequence: sequence,
                data: .object(["message": message(tokens: tokens + 1)]), offset: offset
            ))
        }
        func fireTimers(through offset: Duration, inclusive: Bool) throws {
            while let fires = timerFires, inclusive ? fires <= offset : fires < offset {
                if let sent = pending {
                    try emit(sent, at: fires)
                    pending = nil
                    timerFires = fires + flushWindow
                } else {
                    timerFires = nil
                }
            }
        }
        for (offset, tokens) in updates {
            try fireTimers(through: offset, inclusive: true)
            pending = tokens
            if timerFires == nil {
                timerFires = offset + flushWindow
                try emit(tokens, at: offset)
                pending = nil
            }
        }
        try fireTimers(through: window, inclusive: false)
        return frames
    }
}

/// A tool-calling loop on a page-bound transcript. Every 1.5 s the agent
/// appends a tool call (snapshot + summary), the tool reports progress at
/// 5/s for 1.2 s, and its result is appended (snapshot + summary): the
/// Gateway republishes the full page on every canonical append.
enum ProfileToolLoopScript {
    static let cycle = Duration.milliseconds(1_500)
    static let progressInterval = Duration.milliseconds(200)
    static let progressUpdates = 6

    static func frames(base: SessionSnapshot, window: Duration) throws -> [ProfileScriptedFrame] {
        var words = ProfileTranscript.Words(seed: 9_101)
        var frames: [ProfileScriptedFrame] = []
        var current = base
        current.phase = .running
        var summaryRevision = 1
        var index = 0
        while cycle * index + .milliseconds(50) < window {
            let start = cycle * index + .milliseconds(50)
            let callID = ProfileTranscript.id(9_101, index, "loop-call")
            let callItemID = ProfileTranscript.id(9_101, index, "loop-assistant")
            let call = ProfileTranscript.message(id: callItemID, parent: current.leafEntryId, role: .assistant, content: [
                ProfileTranscript.part("\(callItemID)-text", 0, .text, text: words.sentence(12)),
                ProfileTranscript.part("\(callItemID)-tool", 1, .toolCall, toolCallId: callID, name: "bash",
                                       arguments: .object(["command": .string("swift test --filter Case\(index)")])),
            ])
            current = try ProfileTranscript.appending(call, to: current)
            let startedAt = GatewayTimestamp.preciseString(from: Date(timeIntervalSince1970: 1_790_000_000 + start.profileSeconds))
            let running = ToolExecutionState(
                toolCallId: callID, toolName: "bash", order: index, status: .running,
                arguments: .object(["command": .string("swift test --filter Case\(index)")]),
                partialResult: nil, result: nil, isError: false, startedAt: startedAt, updatedAt: startedAt
            )
            current.toolExecutions = [running]
            frames.append(try ProfileTranscript.snapshotEvent(current, offset: start))
            summaryRevision += 1
            frames.append(try ProfileTranscript.summaryEvent(current, revision: summaryRevision, offset: start))
            var output = ""
            for update in 1...progressUpdates {
                let offset = start + progressInterval * update
                output += words.output(bytes: 160) + "\n"
                let updatedAt = GatewayTimestamp.preciseString(from: Date(timeIntervalSince1970: 1_790_000_000 + offset.profileSeconds))
                let progress = ToolExecutionState(
                    toolCallId: callID, toolName: "bash", order: index, status: .running,
                    arguments: running.arguments,
                    partialResult: .object(["content": .array([.object(["type": .string("text"), "text": .string(output)])])]),
                    result: nil, output: output, isError: false, startedAt: startedAt, updatedAt: updatedAt,
                    lastProgressAt: updatedAt, progressSequence: update
                )
                current.eventSequence += 1
                frames.append(try ProfileTranscript.sessionEvent(
                    topic: "session.toolProgress", snapshot: current, sequence: current.eventSequence,
                    data: JSONValue.encode(progress), offset: offset
                ))
                current.toolExecutions = [progress]
            }
            let resultOffset = start + progressInterval * (progressUpdates + 1)
            let resultID = ProfileTranscript.id(9_101, index, "loop-result")
            let result = ProfileTranscript.message(id: resultID, parent: current.leafEntryId, role: .toolResult,
                                                   content: [ProfileTranscript.part("\(resultID)-text", 0, .text, text: output)],
                                                   toolCallId: callID, toolName: "bash")
            current = try ProfileTranscript.appending(result, to: current)
            let completedAt = GatewayTimestamp.preciseString(from: Date(timeIntervalSince1970: 1_790_000_000 + resultOffset.profileSeconds))
            current.toolExecutions = [ToolExecutionState(
                toolCallId: callID, toolName: "bash", order: index, status: .completed,
                arguments: running.arguments, partialResult: nil,
                result: .object(["content": .array([.object(["type": .string("text"), "text": .string(output)])])]),
                output: output, isError: false, startedAt: startedAt, updatedAt: completedAt,
                completedAt: completedAt, durationMs: Int((resultOffset - start).profileMilliseconds)
            )]
            frames.append(try ProfileTranscript.snapshotEvent(current, offset: resultOffset))
            summaryRevision += 1
            frames.append(try ProfileTranscript.summaryEvent(current, revision: summaryRevision, offset: resultOffset))
            index += 1
        }
        return frames
    }
}

extension Duration {
    var profileMicroseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }
}

/// Forwards every chat signpost to the production signposter and records the
/// outcome of the opening's first ready frame, the app's own readiness signal.
final class ProfileOpeningSignposts: PerformanceSignposting {
    private let result = Mutex<PerformanceResult?>(nil)

    var firstReadyFrameResult: PerformanceResult? { result.withLock { $0 } }

    func begin(_ operation: PerformanceOperation) -> PerformanceInterval {
        SystemPerformanceSignposts.shared.begin(operation)
    }

    func end(_ interval: PerformanceInterval, result outcome: PerformanceResult, metrics: PerformanceMetrics) {
        if interval.operation == .firstReadyFrame {
            result.withLock { if $0 == nil || $0 == .discarded || $0 == .cancelled { $0 = outcome } }
        }
        SystemPerformanceSignposts.shared.end(interval, result: outcome, metrics: metrics)
    }
}
