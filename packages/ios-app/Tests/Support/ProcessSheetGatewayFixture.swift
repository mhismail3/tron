import Foundation
@testable import TronMobile

/// Real GatewayClient request/response admission, with no network or canonical runtime.
@MainActor
final class ProcessSheetGatewayFixture {
    let socket = ScriptedGatewaySocket()
    let client: GatewayClient
    let profile = GatewayProfile(id: "process-sheet", label: "Fixture", host: "localhost", port: 9847, machineId: "fixture")

    init(transport: BoundedHTTPDataTransport = .urlSession) {
        client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                               boundedHTTPDataTransport: transport)
    }

    func connect(model: AppModel? = nil, capabilities: [String] = []) async throws {
        let connecting = Task {
            if let model { try await model.connectHostedGateway(profile: profile, token: "fixture-token") }
            else { _ = try await client.connect(profile: profile, token: "fixture-token") }
        }
        defer { connecting.cancel() }
        try await waitForRequest(at: 0)
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("hello"), "gatewayVersion": .string("1"), "piVersion": .string("1"),
            "protocolVersion": .number(5), "minProtocolVersion": .number(5),
            "machineId": .string("fixture"), "machineName": .string("Fixture"),
            "gatewayChannel": .string("stable"), "capabilities": .array(capabilities.map(JSONValue.string)),
        ])))
        try await connecting.value
    }

    func waitForRequest(at index: Int) async throws {
        let socket = socket
        try await withTestWatchdog { try await socket.waitUntilSent(count: index + 1) }
    }

    func respond(at index: Int, method: String, result: JSONValue) async throws {
        try await waitForRequest(at: index)
        let request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[index])
        guard request.objectValue?["method"]?.stringValue == method, let id = request.objectValue?["id"]?.stringValue else {
            throw GatewayFailure(code: "invalid_fixture_request", message: "Expected \(method)", retryable: false, details: nil)
        }
        var result = result
        if method == "session.processTranscript.open",
           var object = result.objectValue, object["leaseId"]?.stringValue == "lease-worker",
           let viewerID = request.objectValue?["params"]?.objectValue?["viewerId"]?.stringValue {
            object["leaseId"] = .string(viewerID)
            result = .object(object)
        }
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result,
        ])))
    }

    static func process(_ id: String = "worker") -> SessionProcessActivity {
        SessionProcessActivity(
            processId: id, kind: .subagent, executionMode: .asynchronous, source: .delegatedAgent,
            lifecycle: SessionProcessLifecycle(state: .completed, sequence: 1, observedAt: "2026-01-01T00:00:02Z",
                terminalAt: "2026-01-01T00:00:02Z", recentUntil: "2026-01-01T00:05:02Z"),
            visibility: .historical, startedAt: "2026-01-01T00:00:00Z", title: "worker",
            durationMs: 2_000, toolCallId: "call-\(id)", runId: "run-\(id)"
        )
    }

    static func history(ids: [String] = ["worker"], revision: String = "history-1", next: String? = nil) throws -> JSONValue {
        .object([
            "activities": .array(try ids.map { try JSONValue.encode(process($0)) }),
            "historyRevision": .string(revision), "nextCursor": next.map(JSONValue.string) ?? .null,
        ])
    }

    static func transcript(texts: [String]) throws -> JSONValue {
        let items = try texts.enumerated().map { index, text in
            try JSONValue.encode(decodeTranscriptFixture(TranscriptItem.self, from: JSONEncoder.gateway.encode(JSONValue.object([
                "id": .string("entry-\(index)"), "parentId": index > 0 ? .string("entry-\(index - 1)") : .null,
                "timestamp": .string("2026-01-01T00:00:01Z"), "kind": .string("message"), "role": .string("assistant"),
                "content": .array([.object(["id": .string("text-\(index)"), "type": .string("text"), "text": .string(text)])]),
            ]))))
        }
        return .object([
            "leaseId": .string("lease-worker"), "processId": .string("worker"), "childSessionRef": .string("child-worker"),
            "revision": .string("transcript-1"), "page": .object([
                "items": .array(items), "start": .number(0), "end": .number(Double(items.count)), "total": .number(Double(items.count)),
                "nextEntryId": .null, "leafEntryId": items.last?.objectValue?["id"] ?? .null,
            ]),
        ])
    }
}
