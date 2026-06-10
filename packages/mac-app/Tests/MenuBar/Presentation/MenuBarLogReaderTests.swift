import Foundation
import Testing

@testable import TronMac

@Suite("MenuBarLogReader")
struct MenuBarLogReaderTests {
    @Test("decodes logs::recent response")
    func decodesRecentLogsResponse() throws {
        let data = """
        {"type":"response","id":"mac-logs-recent","ok":true,"result":{"child":{"value":{"count":1,"entries":[{"id":7,"timestamp":"2026-04-27T10:00:00Z","level":"info","component":"server","message":"ready","origin":"server","sessionId":"session-1","workspaceId":"workspace-1","traceId":"trace-1","errorMessage":null}]}}}}
        """.data(using: .utf8)!

        let frame = MenuBarLogReader.decodeFrame(data: data)

        if case .result(let result) = frame {
            #expect(result.count == 1)
            #expect(result.entries.first?.message == "ready")
            #expect(result.entries.first?.sessionId == "session-1")
            #expect(result.entries.first?.workspaceId == "workspace-1")
            #expect(result.entries.first?.traceId == "trace-1")
        } else {
            Issue.record("expected result frame")
        }
    }

    @Test("formats structured rows for display")
    func formatsStructuredRows() {
        let text = MenuBarLogReader.format([
            RecentLogEntry(
                id: 1,
                timestamp: "2026-04-27T10:00:00Z",
                level: "error",
                component: "server",
                message: "failed",
                origin: "server",
                sessionId: nil,
                workspaceId: nil,
                traceId: nil,
                errorMessage: "port in use"
            )
        ])

        #expect(text == "[2026-04-27T10:00:00Z] ERROR server: failed - port in use")
    }
}
