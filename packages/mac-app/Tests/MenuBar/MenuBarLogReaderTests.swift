import Foundation
import Testing

@testable import TronMac

@Suite("MenuBarLogReader")
struct MenuBarLogReaderTests {
    @Test("decodes logs::recent response")
    func decodesRecentLogsResponse() throws {
        let data = """
        {"type":"response","id":"mac-logs-recent","ok":true,"result":{"child":{"value":{"count":1,"entries":[{"id":7,"timestamp":"2026-04-27T10:00:00Z","level":"info","component":"server","message":"ready","origin":"server","sessionId":null,"errorMessage":null}]}}}}
        """.data(using: .utf8)!

        let frame = MenuBarLogReader.decodeFrame(data: data)

        if case .result(let result) = frame {
            #expect(result.count == 1)
            #expect(result.entries.first?.message == "ready")
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
                errorMessage: "port in use"
            )
        ])

        #expect(text == "[2026-04-27T10:00:00Z] ERROR server: failed - port in use")
    }
}
