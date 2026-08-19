import Testing
@testable import TronMobile

@Suite("Gateway diagnostics boundary")
struct GatewayDiagnosticsServiceTests {
    @Test("git inspection owns its exact target and typed projection")
    func gitInspection() async throws {
        let recorder = DiagnosticsRequestRecorder(responses: [
            .object([
                "isRepository": .bool(true),
                "branch": .string("main"),
                "dirty": .bool(true),
            ]),
        ])
        let service = GatewayDiagnosticsService(request: { method, params in
            try await recorder.request(method: method, params: params)
        })

        let inspection = try await service.inspectGit(path: "/workspace/project")
        #expect(inspection == GitInspection(isRepository: true, branch: "main", isDirty: true))
        #expect(await recorder.requests == [DiagnosticsRecordedRequest(
            method: "git.inspect",
            params: .object(["path": .string("/workspace/project")])
        )])
    }

    @Test("logs remain newest-first and malformed records are skipped")
    func logs() async throws {
        let recorder = DiagnosticsRequestRecorder(responses: [
            .object(["records": .array([
                .object([
                    "timestamp": .string("2026-08-16T00:00:00Z"),
                    "level": .string("info"),
                    "message": .string("first"),
                ]),
                .object([
                    "timestamp": .string("malformed"),
                    "level": .string("warning"),
                ]),
                .object([
                    "timestamp": .string("2026-08-16T00:00:01Z"),
                    "level": .string("error"),
                    "message": .string("last"),
                ]),
            ])]),
        ])
        let service = GatewayDiagnosticsService(request: { method, params in
            try await recorder.request(method: method, params: params)
        })

        let records = try await service.logs(limit: 300)
        #expect(records.map(\.message) == ["last", "first"])
        #expect(records.map(\.level) == ["error", "info"])
        #expect(await recorder.requests == [DiagnosticsRecordedRequest(
            method: "system.logs",
            params: .object(["limit": .number(300)])
        )])
    }

    @Test("profile-qualified logs keep identical records distinct")
    func profileQualifiedLogs() {
        let record = GatewayLogRecord(timestamp: "2026-08-16T00:00:00Z", level: "info", message: "ready")
        let first = GatewayProfileLogRecord(profileID: "server-a", profileLabel: "Server A", record: record)
        let second = GatewayProfileLogRecord(profileID: "server-b", profileLabel: "Server B", record: record)

        #expect(first.id != second.id)
        #expect(first.record == second.record)
    }

    @Test("non-repository and absent records retain empty presentation semantics")
    func emptyValues() async throws {
        let recorder = DiagnosticsRequestRecorder(responses: [
            .object(["isRepository": .bool(false)]),
            .object([:]),
        ])
        let service = GatewayDiagnosticsService(request: { method, params in
            try await recorder.request(method: method, params: params)
        })

        #expect(try await service.inspectGit(path: "/tmp").isRepository == false)
        #expect(try await service.logs(limit: 0).isEmpty)
    }
}

private struct DiagnosticsRecordedRequest: Equatable, Sendable {
    let method: String
    let params: JSONValue
}

private actor DiagnosticsRequestRecorder {
    private var responses: [JSONValue]
    private(set) var requests: [DiagnosticsRecordedRequest] = []

    init(responses: [JSONValue]) { self.responses = responses }

    func request(method: String, params: JSONValue) throws -> JSONValue {
        requests.append(DiagnosticsRecordedRequest(method: method, params: params))
        guard !responses.isEmpty else {
            throw GatewayFailure(code: "missing_fixture", message: "Missing fixture", retryable: false, details: nil)
        }
        return responses.removeFirst()
    }
}
