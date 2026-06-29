import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("LogsClient Tests")
struct LogsClientTests {

    @Test("recentLogs throws when engineConnection is nil")
    func recentLogsNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = LogsClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.recentLogs()
        }
    }

    @Test("recentLogs clamps request limit")
    func recentLogsClampsLimit() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        let client = LogsClient(transport: transport)

        transport.readHandler = { functionId, payload, _ in
            #expect(functionId.rawValue == "logs::recent")
            #expect((payload as? LogsRecentParams)?.limit == 1000)
            #expect((payload as? LogsRecentParams)?.sessionId == nil)
            #expect((payload as? LogsRecentParams)?.workspaceId == nil)
            #expect((payload as? LogsRecentParams)?.traceId == nil)
            return LogsRecentResult(entries: [], count: 0)
        }

        _ = try await client.recentLogs(limit: 10_000)
        #expect(transport.lastReadFunctionId?.rawValue == "logs::recent")
    }

    @Test("recentLogs sends optional correlation filters")
    func recentLogsSendsCorrelationFilters() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        let client = LogsClient(transport: transport)

        transport.readHandler = { functionId, payload, _ in
            #expect(functionId.rawValue == "logs::recent")
            let params = try #require(payload as? LogsRecentParams)
            #expect(params.limit == 50)
            #expect(params.sessionId == "session-1")
            #expect(params.workspaceId == "workspace-1")
            #expect(params.traceId == "trace-1")
            return LogsRecentResult(entries: [], count: 0)
        }

        _ = try await client.recentLogs(
            limit: 50,
            sessionId: "session-1",
            workspaceId: "workspace-1",
            traceId: "trace-1"
        )
    }

    @Test("ingestLogs writes entries")
    func ingestLogsWritesEntries() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        let client = LogsClient(transport: transport)
        let entry = ClientLogEntry(
            timestamp: "2026-06-08T00:00:00.000Z",
            level: "info",
            category: "test",
            message: "hello"
        )

        transport.writeHandler = { functionId, payload, _, _ in
            #expect(functionId.rawValue == "logs::ingest")
            let params = try #require(payload as? LogsIngestParams)
            #expect(params.entries == [entry])
            #expect(params.sessionId == "session-1")
            #expect(params.workspaceId == nil)
            #expect(params.traceId == nil)
            return LogsIngestResult(success: true, inserted: 1)
        }

        let result = try await client.ingestLogs(
            entries: [entry],
            idempotencyKey: .userAction("logs.ingest.test"),
            sessionId: "session-1"
        )
        #expect(result.inserted == 1)
        #expect(transport.lastWriteFunctionId?.rawValue == "logs::ingest")
    }

}
