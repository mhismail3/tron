import Foundation
import Testing

@testable import TronMac

@Suite("MenuBarLogReader")
struct MenuBarLogReaderTests {
    @Test("decodes system.logs response")
    func decodesRecentLogsResponse() throws {
        let data = """
        {"type":"response","id":"mac-system-logs","ok":true,"result":{"records":[{"timestamp":"2026-04-27T10:00:00Z","level":"info","message":"ready"}]}}
        """.data(using: .utf8)!

        let frame = MenuBarLogReader.decodeFrame(data: data)

        if case .result(let result) = frame {
            #expect(result.records.count == 1)
            #expect(result.records.first?.message == "ready")
        } else {
            Issue.record("expected result frame")
        }
    }

    @Test("decodes top-level gateway error")
    func decodesTopLevelGatewayError() throws {
        let data = """
        {"type":"response","id":"mac-system-logs","ok":false,"error":{"code":"invalid_request","message":"limit is invalid","retryable":false}}
        """.data(using: .utf8)!

        #expect(MenuBarLogReader.decodeFrame(data: data) == .error("limit is invalid"))
    }

    @Test("unexpected response envelope is malformed")
    func unexpectedResponseEnvelopeIsMalformed() throws {
        let data = """
        {"type":"response","id":"mac-system-logs","ok":true,"result":{"entries":[]}}
        """.data(using: .utf8)!

        #expect(MenuBarLogReader.decodeFrame(data: data) == .malformed)
    }

    @Test("formats structured rows for display")
    func formatsStructuredRows() {
        let text = MenuBarLogReader.format([
            RecentLogEntry(
                timestamp: "2026-04-27T10:00:00Z",
                level: "error",
                message: "port in use"
            )
        ])

        #expect(text == "[2026-04-27T10:00:00Z] ERROR TRON: port in use")
    }
}
