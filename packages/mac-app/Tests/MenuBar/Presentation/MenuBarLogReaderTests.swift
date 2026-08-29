import Foundation
import Testing

@testable import TronMac

@Suite("MenuBarLogReader")
struct MenuBarLogReaderTests {
    @Test("accepts only the exact supported server hello")
    func decodesServerHello() {
        let accepted = #"{"type":"hello","protocolVersion":4,"minProtocolVersion":4}"#
        let older = #"{"type":"hello","protocolVersion":3,"minProtocolVersion":3}"#
        let future = #"{"type":"hello","protocolVersion":5,"minProtocolVersion":4}"#
        #expect(MenuBarLogReader.decodeHello(data: Data(accepted.utf8)) == .accepted)
        #expect(MenuBarLogReader.decodeHello(data: Data(older.utf8)) == .rejected)
        #expect(MenuBarLogReader.decodeHello(data: Data(future.utf8)) == .rejected)
    }

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

    @Test("log fetching has no production loopback default")
    func logFetchingRequiresExplicitHost() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MenuBar/Presentation/MenuBarLogReader.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("host: String"))
        #expect(!source.contains("127.0.0.1"))
    }

    @Test("explicit log host is used to build the Gateway socket URL")
    func explicitHostBuildsSocketURL() {
        let url = GatewaySocketURL.make(host: "100.64.0.9", port: 9847)
        #expect(url?.host == "100.64.0.9")
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
