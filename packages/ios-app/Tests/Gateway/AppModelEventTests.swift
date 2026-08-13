import Foundation
import Testing
@testable import TronMobile

private final class EventFixtureBundleMarker {}

@Suite("Authoritative gateway event projection")
@MainActor
struct AppModelEventTests {
    @Test("onboarding waits for launch credential resolution")
    func onboardingLaunchResolution() {
        #expect(!OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: false,
            connectionState: .unpaired,
            setupComplete: true
        ))
        #expect(!OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: true,
            connectionState: .connected,
            setupComplete: true
        ))
        #expect(OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: true,
            connectionState: .unpaired,
            setupComplete: true
        ))
        #expect(OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: true,
            connectionState: .connected,
            setupComplete: false
        ))
    }

    @Test("portable tool and extension events update native session state in sequence")
    func portableSessionEvents() async throws {
        let snapshot = try loadSnapshot()
        let model = AppModel()
        model.selectedSessionID = snapshot.sessionId
        model.snapshots[snapshot.sessionId] = snapshot

        let completedTool: JSONValue = .object([
            "toolCallId": .string("live-tool"), "toolName": .string("bash"), "order": .number(0), "status": .string("completed"),
            "arguments": .object(["command": .string("build")]), "result": .object(["content": .string("done")]),
            "output": .string("done"), "isError": .bool(false),
            "startedAt": .string("2026-01-01T00:00:10Z"), "updatedAt": .string("2026-01-01T00:00:12Z"),
            "lastProgressAt": .string("2026-01-01T00:00:12Z"), "completedAt": .string("2026-01-01T00:00:12Z"),
            "durationMs": .number(2_000), "progressSequence": .number(4),
        ])
        await model.handle(event(topic: "session.toolProgress", snapshot: snapshot, sequence: 88, data: completedTool))
        #expect(model.selectedSnapshot?.toolExecutions.first?.status == .completed)

        let staleTool: JSONValue = .object([
            "toolCallId": .string("live-tool"), "toolName": .string("bash"), "order": .number(0), "status": .string("running"),
            "arguments": .object(["command": .string("build")]), "isError": .bool(false),
            "startedAt": .string("2026-01-01T00:00:10Z"), "updatedAt": .string("2026-01-01T00:00:13Z"),
            "lastProgressAt": .string("2026-01-01T00:00:13Z"), "progressSequence": .number(3),
        ])
        await model.handle(event(topic: "session.toolProgress", snapshot: snapshot, sequence: 89, data: staleTool))
        #expect(model.selectedSnapshot?.toolExecutions.first?.status == .completed)
        #expect(model.selectedSnapshot?.toolExecutions.first?.output == "done")
        #expect(model.selectedSnapshot?.toolExecutions.first?.durationMs == 2_000)

        let interactions: JSONValue = .array([
            .object(["id": .string("confirm"), "method": .string("confirm"), "title": .string("Proceed?"), "message": .string("Check")]),
        ])
        var afterStale = snapshot
        afterStale.eventSequence = 89
        await model.handle(event(topic: "session.interactions", snapshot: afterStale, sequence: 90, data: interactions))
        #expect(model.selectedSnapshot?.extensionUI.pendingInteractions.first?.method == .confirm)

        let editor: JSONValue = .object([
            "action": .string("set"), "text": .string("replacement"), "fullText": .string("replacement"), "revision": .number(4),
        ])
        var afterInteraction = snapshot
        afterInteraction.eventSequence = 90
        await model.handle(event(topic: "session.editorText", snapshot: afterInteraction, sequence: 91, data: editor))
        #expect(model.editorRequest?.fullText == "replacement")
        #expect(model.selectedSnapshot?.eventSequence == 91)
    }

    @Test("fresh presentation replaces expanded history while reconnect preserves it")
    func snapshotInstallModes() throws {
        let baseline = try loadSnapshot()
        var expanded = baseline
        expanded.transcriptStart = 10
        expanded.transcriptTotal = 10 + expanded.transcript.count
        var authoritative = baseline
        authoritative.eventSequence += 1
        authoritative.transcript = Array(baseline.transcript.suffix(3))
        authoritative.transcriptStart = 15
        authoritative.transcriptTotal = 18

        let fresh = AppModel.installingSnapshot(
            current: expanded,
            authoritative: authoritative,
            mode: .freshPresentation
        )
        #expect(fresh.transcript.map(\.id) == authoritative.transcript.map(\.id))
        #expect(fresh.transcriptStart == 15)

        let reconnected = AppModel.installingSnapshot(
            current: expanded,
            authoritative: authoritative,
            mode: .reconnect
        )
        #expect(reconnected.transcript.count >= authoritative.transcript.count)
        #expect(reconnected.eventSequence == authoritative.eventSequence)
    }

    @Test("live snapshots preserve explicitly loaded history while advancing the authoritative tail")
    func liveSnapshotPreservesLoadedTranscript() throws {
        let baseline = try loadSnapshot()
        var current = baseline
        current.transcript = Array(baseline.transcript.prefix(8))
        current.transcriptStart = 20
        current.transcriptTotal = 28

        var incoming = baseline
        incoming.eventSequence += 1
        incoming.transcript = Array(baseline.transcript[5...])
        incoming.transcriptStart = 25
        incoming.transcriptTotal = 31

        let merged = AppModel.mergingVisibleTranscript(current: current, authoritative: incoming)
        #expect(merged.transcript.map(\.id) == current.transcript.map(\.id) + incoming.transcript.dropFirst(3).map(\.id))
        #expect(merged.transcriptStart == 20)
        #expect(merged.transcriptTotal == 31)
        #expect(merged.eventSequence == incoming.eventSequence)
    }

    @Test("active adjacent pages append without evicting the visible baseline")
    func activeAdjacentPageAppends() throws {
        let baseline = try loadSnapshot()
        var current = baseline
        current.transcript = Array(baseline.transcript.prefix(5))
        current.transcriptStart = 20
        current.transcriptTotal = 25

        var adjacent = baseline
        adjacent.eventSequence += 1
        adjacent.phase = .running
        adjacent.transcript = Array(baseline.transcript.suffix(3))
        adjacent.transcriptStart = 25
        adjacent.transcriptTotal = 28

        let merged = AppModel.mergingVisibleTranscript(current: current, authoritative: adjacent)
        #expect(merged.transcript.map(\.id) == current.transcript.map(\.id) + adjacent.transcript.map(\.id))
        #expect(merged.transcriptStart == 20)
        #expect(merged.transcriptTotal == 28)
    }

    @Test("active compact snapshots cannot blank an already visible transcript")
    func activeSnapshotCannotBlankTranscript() throws {
        let current = try loadSnapshot()
        var compact = current
        compact.eventSequence += 1
        compact.phase = .running
        compact.transcript = []
        compact.transcriptStart = compact.transcriptTotal

        let merged = AppModel.mergingVisibleTranscript(current: current, authoritative: compact)
        #expect(merged.transcript.map(\.id) == current.transcript.map(\.id))
        #expect(merged.transcriptStart == current.transcriptStart)
        #expect(merged.phase == .running)
    }

    @Test("a changed branch replaces rather than combines unrelated transcripts")
    func branchReplacementDoesNotMerge() throws {
        let current = try loadSnapshot()
        var branch = current
        branch.eventSequence += 1
        branch.transcript = [try JSONDecoder.gateway.decode(TranscriptItem.self, from: Data("""
        {"id":"new-root","parentId":null,"timestamp":"2026-01-02T00:00:00Z","kind":"message","role":"user","content":[{"id":"new-root:0","type":"text","text":"new branch"}]}
        """.utf8))]
        branch.transcriptStart = 0
        branch.transcriptTotal = 1

        let merged = AppModel.mergingVisibleTranscript(current: current, authoritative: branch)
        #expect(merged.transcript.map(\.id) == ["new-root"])
    }

    @Test("global summaries update dashboard activity without opening that chat")
    func dashboardSummaryUpdates() async {
        let model = AppModel()
        model.sessions = [SessionSummary(
            id: "background", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 1, firstMessage: "Original", phase: .idle
        )]

        await model.handle(GatewayEvent(
            type: "event", topic: "session.summary", sessionId: nil,
            payload: .object([
                "sessionId": .string("background"), "summaryRevision": .number(1), "phase": .string("running"),
                "updatedAt": .string("2026-01-01T00:00:01Z"), "messageCount": .number(2),
                "firstMessage": .string("Original")
            ])
        ))

        #expect(model.sessions.first?.phase == .running)
        #expect(model.sessions.first?.messageCount == 2)

        await model.handle(GatewayEvent(
            type: "event", topic: "session.summary", sessionId: nil,
            payload: .object([
                "sessionId": .string("background"), "summaryRevision": .number(1), "phase": .string("idle"),
                "updatedAt": .string("2026-01-01T00:00:00Z"), "messageCount": .number(1),
                "firstMessage": .string("Stale")
            ])
        ))
        #expect(model.sessions.first?.phase == .running)
        #expect(model.sessions.first?.firstMessage == "Original")
    }

    @Test("disconnect removes live dashboard claims until authoritative reconnect")
    func disconnectClearsLiveDashboardPhase() async {
        let model = AppModel()
        model.sessions = [SessionSummary(
            id: "active", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: 1, firstMessage: "Active", phase: .running
        )]
        await model.handle(GatewayEvent(
            type: "event", topic: "transport.disconnected", sessionId: nil,
            payload: .object(["message": .string("offline")])
        ))
        #expect(model.sessions.first?.phase == .interrupted)
    }

    @Test("structure, context, and resource events invalidate their live surfaces")
    func surfaceInvalidations() async throws {
        let snapshot = try loadSnapshot()
        let model = AppModel()
        model.selectedSessionID = snapshot.sessionId
        model.snapshots[snapshot.sessionId] = snapshot

        await model.handle(event(topic: "session.structureChanged", snapshot: snapshot, sequence: 88, data: .object([
            "branchChanged": .bool(false)
        ])))
        #expect(model.selectedSessionStructureRevision == 1)
        #expect(model.selectedSessionContextRevision == 1)

        var advanced = snapshot
        advanced.eventSequence = 88
        await model.handle(event(topic: "session.resourcesChanged", snapshot: advanced, sequence: 89, data: .object([:])))
        #expect(model.selectedSessionResourceRevision == 1)
        #expect(model.selectedSessionContextRevision == 2)
    }

    @Test("terminal output is deduplicated and ordered")
    func terminalOutputOrdering() async {
        let model = AppModel()
        func output(_ sequence: Int, _ data: String) -> GatewayEvent {
            GatewayEvent(type: "event", topic: "terminal.output", sessionId: nil, payload: .object([
                "terminalId": .string("terminal"), "sequence": .number(Double(sequence)), "data": .string(data)
            ]))
        }
        await model.handle(output(1, "one"))
        await model.handle(output(1, "duplicate"))
        await model.handle(output(2, "two"))
        #expect(model.terminalChunks["terminal"]?.map(\.data) == ["one", "two"])
    }

    @Test("unrendered sequenced events still advance the authoritative cursor")
    func unrenderedEventsAdvanceCursor() async throws {
        let snapshot = try loadSnapshot()
        let model = AppModel()
        model.selectedSessionID = snapshot.sessionId
        model.snapshots[snapshot.sessionId] = snapshot

        await model.handle(event(topic: "session.futureEvent", snapshot: snapshot, sequence: 88, data: .object([:])))
        await model.handle(event(topic: "session.notification", snapshot: snapshot, sequence: 89, data: .object([
            "type": .string("info"), "message": .string("Caught up")
        ])))

        #expect(model.selectedSnapshot?.eventSequence == 89)
        #expect(model.notifications.last == "Caught up")
    }

    @Test("configured default model is preferred over catalog order")
    func configuredDefaultModel() async {
        let model = AppModel()
        model.models = [
            ModelSummary(provider: "openai-codex", id: "gpt-5.3-codex-spark", name: "GPT-5.3 Codex Spark", reasoning: true, input: ["text"], contextWindow: 1, maxTokens: 1, available: true),
            ModelSummary(provider: "openai-codex", id: "gpt-5.6-sol", name: "GPT-5.6 Sol", reasoning: true, input: ["text"], contextWindow: 1, maxTokens: 1, available: true),
        ]
        model.settings = .object([
            "effective": .object([
                "defaultModel": .object(["provider": .string("openai-codex"), "id": .string("gpt-5.6-sol")]),
            ]),
        ])

        #expect(model.configuredDefaultModel?.id == "gpt-5.6-sol")
        #expect(model.preferredAvailableModel?.id == "gpt-5.6-sol")
    }

    @Test("global configuration invalidations are accepted without session sequencing")
    func globalConfigurationInvalidations() async {
        let model = AppModel()
        await model.handle(GatewayEvent(type: "event", topic: "settings.changed", sessionId: nil, payload: .object([:])))
        await model.handle(GatewayEvent(type: "event", topic: "providers.changed", sessionId: nil, payload: .object([:])))
        await model.handle(GatewayEvent(type: "event", topic: "packages.changed", sessionId: nil, payload: .object([:])))
        await model.handle(GatewayEvent(type: "event", topic: "models.customChanged", sessionId: nil, payload: .object([:])))
        // These events invalidate each scoped owner rather than being mistaken
        // for session-sequenced events. Visible surfaces then reload their scope.
        #expect(model.settingsRevision == 1)
        #expect(model.providerRevision == 1)
        #expect(model.packageRevision == 1)
        #expect(model.customModelRevision == 1)
        #expect(model.lastError == nil)
    }

    @Test("foreground transport interruption reconnects without a user error alert")
    func foregroundTransportErrorPresentation() {
        #expect(!AppModel.shouldSurface(GatewayFailure(
            code: "disconnected",
            message: "Software caused connection abort",
            retryable: true,
            details: nil
        )))
        #expect(!AppModel.shouldSurface(URLError(.networkConnectionLost)))
        #expect(!AppModel.shouldSurface(NSError(domain: NSPOSIXErrorDomain, code: 53)))
        #expect(AppModel.shouldSurface(GatewayFailure(
            code: "invalid_request",
            message: "Choose a valid setting.",
            retryable: false,
            details: nil
        )))
    }

    @Test("successful session synchronization removes only its temporary catch-up notice")
    func sessionCatchUpNoticeLifecycle() {
        let notices = [
            "Package operation completed",
            AppModel.sessionCatchUpNotice,
            "Provider login completed",
            AppModel.sessionCatchUpNotice,
        ]
        #expect(AppModel.removingSessionCatchUpNotice(from: notices) == [
            "Package operation completed",
            "Provider login completed",
        ])
    }

    @Test("cached active dashboard rows never masquerade as live after relaunch")
    func cachedActivityIsInterrupted() {
        let summary = SessionSummary(
            id: "cached", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: 1, firstMessage: "Cached", phase: .running
        )
        #expect(summary.safeCachedProjection.phase == .interrupted)
        #expect(SessionSummary(
            id: "idle", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: summary.createdAt, updatedAt: summary.updatedAt,
            messageCount: 1, firstMessage: "Idle", phase: .idle
        ).safeCachedProjection.phase == .idle)
    }

    @Test("changing sessions clears secondary projections before their authoritative reload")
    func switchingSessionClearsSecondaryProjections() {
        let model = AppModel()
        model.selectedSessionID = "first"
        model.context = .object(["session": .string("first")])
        model.resources = .object(["session": .string("first")])
        model.sessionTree = [SessionTreeNode(
            id: "entry", parentId: nil, timestamp: "2026-01-01T00:00:00Z", kind: "message",
            label: nil, preview: "First", role: .user, depth: 0, childCount: 0, isCurrentPath: true
        )]

        model.selectedSessionID = "second"

        #expect(model.context == nil)
        #expect(model.resources == nil)
        #expect(model.sessionTree.isEmpty)
        #expect(model.commands.isEmpty)
    }

    @Test("OAuth URL and device-code notifications are retained for native presentation")
    func authEvents() async {
        let model = AppModel()
        await model.handle(GatewayEvent(
            type: "event", topic: "auth.event", sessionId: nil,
            payload: .object([
                "operationId": .string("auth-operation"),
                "event": .object([
                    "type": .string("device_code"), "userCode": .string("ABCD-EFGH"),
                    "verificationUri": .string("https://example.invalid/device"), "expiresInSeconds": .number(600),
                ]),
            ])
        ))
        #expect(model.authEvent?.kind == .deviceCode)
        #expect(model.authEvent?.userCode == "ABCD-EFGH")
    }

    private func event(topic: String, snapshot: SessionSnapshot, sequence: Int, data: JSONValue) -> GatewayEvent {
        GatewayEvent(type: "event", topic: topic, sessionId: snapshot.sessionId, payload: .object([
            "runtimeGeneration": .string(snapshot.runtimeGeneration),
            "eventSequence": .number(Double(sequence)),
            "revision": .number(Double(snapshot.revision + sequence)),
            "data": data,
        ]))
    }

    private func loadSnapshot() throws -> SessionSnapshot {
        let bundle = Bundle(for: EventFixtureBundleMarker.self)
        let url = bundle.url(forResource: "session-snapshot-v2", withExtension: "json")
            ?? bundle.url(forResource: "session-snapshot-v2", withExtension: "json", subdirectory: "protocol-fixtures")
        return try JSONDecoder.gateway.decode(SessionSnapshot.self, from: Data(contentsOf: #require(url)))
    }
}
