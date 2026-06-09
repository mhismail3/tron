import Foundation
import Testing

@testable import TronMobile

@Suite("DiagnosticsBundleBuilder")
@MainActor
struct DiagnosticsBundleBuilderTests {
    @Test("event sanitizer keeps only allowlisted scalar fields")
    func eventSanitizerUsesAllowlist() {
        let event = SessionEvent(
            id: "event-raw",
            parentId: "parent-raw",
            sessionId: "session-raw",
            workspaceId: "workspace-raw",
            type: "capability.invocation.started",
            timestamp: "2026-04-29T21:00:00Z",
            sequence: 1,
            payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "durationMs": AnyCodable(42),
                "arguments": AnyCodable(#"{"path":"/Users/alice/project/file.swift"}"#),
                "prompt": AnyCodable("secret prompt body"),
                "output": AnyCodable("secret output body"),
            ]
        )

        let summary = DiagnosticsEventSanitizer.summarize(event)
        #expect(summary.idHash != "event-raw")
        #expect(summary.payload["modelPrimitiveName"]?.stringValue == "execute")
        #expect(summary.payload["durationMs"]?.intValue == 42)
        #expect(summary.payload["arguments"] == nil)
        #expect(summary.payload["prompt"] == nil)
        #expect(summary.payload["output"] == nil)
    }

    @Test("error summaries redact and bound message text")
    func errorSummaryRedactsMessage() {
        let event = SessionEvent(
            id: "error-raw",
            parentId: nil,
            sessionId: "session-raw",
            workspaceId: "workspace-raw",
            type: "error.capability",
            timestamp: "2026-04-29T21:00:00Z",
            sequence: 2,
            payload: [
                "errorClass": AnyCodable("io"),
                "errorMessage": AnyCodable("Bearer 1234567890abcdef1234567890 failed at /Users/alice/project"),
            ]
        )

        let summary = DiagnosticsEventSanitizer.summarize(event)
        let message = summary.payload["errorMessage"]?.stringValue ?? ""
        #expect(summary.payload["errorClass"]?.stringValue == "io")
        #expect(!message.contains("1234567890abcdef1234567890"))
        #expect(!message.contains("/Users/alice"))
        #expect(message.count <= 240)
    }

    @Test("builder creates JSON attachment with deterministic name and MIME")
    func builderCreatesJSONAttachment() async throws {
        let harness = try await makeHarness()
        try await harness.database.sessions.insert(makeSession(eventCount: 1))
        try await harness.database.events.insert(makeEvent(sequence: 0))

        let fixedDate = try #require(ISO8601DateFormatter().date(from: "2026-04-29T21:00:00Z"))
        let attachment = try await harness.builder(now: { fixedDate }, iosLogs: []).build()

        #expect(attachment.mimeType == "application/json")
        #expect(attachment.fileName == "tron-diagnostics-20260429-210000Z.json")
        #expect(attachment.logSummary.iosLogCount == 0)
        #expect(attachment.logSummary.serverLogCount == 0)
        #expect(attachment.logSummary.earliestLogTimestamp == nil)
        #expect(attachment.logSummary.latestLogTimestamp == nil)

        let object = try JSONSerialization.jsonObject(with: attachment.data) as? [String: Any]
        let manifest = object?["manifest"] as? [String: Any]
        let counts = manifest?["counts"] as? [String: Any]
        #expect(counts?["events"] as? Int == 1)
        let json = String(data: attachment.data, encoding: .utf8) ?? ""
        #expect(!json.contains("secret prompt body"))
        #expect(!json.contains("/Users/alice"))
        await harness.cleanup()
    }

    @Test("builder reports metadata from actual included local log timestamps")
    func builderReportsIncludedLogMetadata() async throws {
        let harness = try await makeHarness()
        let first = try #require(ISO8601DateFormatter().date(from: "2026-04-29T21:00:00Z"))
        let last = try #require(ISO8601DateFormatter().date(from: "2026-04-29T21:15:30Z"))
        let logs: [(Date, LogCategory, LogLevel, String)] = [
            (first, .general, .info, "local one"),
            (last, .network, .warning, "local two"),
        ]

        let attachment = try await harness.builder(iosLogs: logs).build()

        #expect(attachment.logSummary.iosLogCount == 2)
        #expect(attachment.logSummary.serverLogCount == 0)
        #expect(attachment.logSummary.earliestLogTimestamp == first)
        #expect(attachment.logSummary.latestLogTimestamp == last)
        await harness.cleanup()
    }

    @Test("builder truncates event summaries at the event cap")
    func builderTruncatesEvents() async throws {
        let harness = try await makeHarness()
        let totalEvents = 5_001
        try await harness.database.sessions.insert(makeSession(eventCount: totalEvents))
        try await harness.database.events.insertBatch((0..<totalEvents).map { makeEvent(sequence: $0) })

        let attachment = try await harness.builder().build()
        let object = try JSONSerialization.jsonObject(with: attachment.data) as? [String: Any]
        let manifest = object?["manifest"] as? [String: Any]
        let counts = manifest?["counts"] as? [String: Any]
        let truncated = manifest?["truncated"] as? [String: Any]

        #expect(counts?["events"] as? Int == 5_000)
        #expect(truncated?["events"] as? Bool == true)
        await harness.cleanup()
    }

    @Test("delivery planner is mail-only without Mail or recipient")
    func deliveryPlannerFallbacks() {
        #expect(
            FeedbackDeliveryPlanner.route(configuredRecipient: nil, canSendMail: true)
                == .mailUnavailable(message: FeedbackDeliveryPlanner.missingRecipientMessage)
        )
        #expect(
            FeedbackDeliveryPlanner.route(configuredRecipient: "feedback@example.invalid", canSendMail: false)
                == .mailUnavailable(message: FeedbackDeliveryPlanner.mailUnavailableMessage)
        )
        #expect(
            FeedbackDeliveryPlanner.route(configuredRecipient: "feedback@example.invalid", canSendMail: true)
                == .mail(recipient: "feedback@example.invalid")
        )
    }

    private func makeHarness() async throws -> DiagnosticsHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsBundleBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = EventDatabase(temporaryCachePath: directory.appendingPathComponent("events.db").path)
        try await database.initialize()
        let engineClient = EngineClient(serverURL: URL(string: "ws://paired-server-required.invalid:1/engine")!)
        let eventStoreManager = EventStoreManager(eventDB: database, engineClient: engineClient)
        let metricKitStore = MetricKitDiagnosticsStore(
            directoryURL: directory.appendingPathComponent("MetricKit", isDirectory: true)
        )
        return DiagnosticsHarness(
            directory: directory,
            database: database,
            eventStoreManager: eventStoreManager,
            engineClient: engineClient,
            metricKitStore: metricKitStore
        )
    }

    private func makeSession(eventCount: Int) -> CachedSession {
        CachedSession(
            id: "session-raw",
            workspaceId: "workspace-raw",
            rootEventId: "event-root",
            headEventId: "event-head",
            title: "Secret title",
            latestModel: "claude-test",
            workingDirectory: "/Users/alice/project",
            createdAt: "2026-04-29T20:00:00Z",
            lastActivityAt: "2026-04-29T21:00:00Z",
            archivedAt: nil,
            eventCount: eventCount,
            messageCount: 1,
            inputTokens: 10,
            outputTokens: 20,
            lastTurnInputTokens: 10,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: 0.01
        )
    }

    private func makeEvent(sequence: Int) -> SessionEvent {
        SessionEvent(
            id: "event-\(sequence)",
            parentId: sequence == 0 ? nil : "event-\(sequence - 1)",
            sessionId: "session-raw",
            workspaceId: "workspace-raw",
            type: "capability.invocation.started",
            timestamp: "2026-04-29T21:00:00Z",
            sequence: sequence,
            payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "prompt": AnyCodable("secret prompt body"),
                "arguments": AnyCodable(#"{"path":"/Users/alice/project/file.swift"}"#),
            ]
        )
    }
}

@MainActor
private struct DiagnosticsHarness {
    let directory: URL
    let database: EventDatabase
    let eventStoreManager: EventStoreManager
    let engineClient: EngineClient
    let metricKitStore: MetricKitDiagnosticsStore

    func builder(
        now: @escaping () -> Date = { Date() },
        iosLogs: [(Date, LogCategory, LogLevel, String)] = []
    ) -> DiagnosticsBundleBuilder {
        DiagnosticsBundleBuilder(
            eventDatabase: database,
            eventStoreManager: eventStoreManager,
            engineEndpoint: DiagnosticsEngineEndpoint(
                isConnected: { engineClient.connectionState.isConnected },
                connectionStateName: { "disconnected" },
                currentSessionId: { engineClient.currentSessionId },
                recentServerLogs: { _ in [] }
            ),
            activeServer: nil,
            metricKitStore: metricKitStore,
            now: now,
            iosLogsProvider: { iosLogs }
        )
    }

    func cleanup() async {
        await database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
