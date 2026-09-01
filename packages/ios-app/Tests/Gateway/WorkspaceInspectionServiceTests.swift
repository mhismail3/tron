import Foundation
import Testing
@testable import TronMobile

@Suite("Workspace inspection boundary")
struct WorkspaceInspectionServiceTests {
    @Test("session-bound workspace methods preserve exact wire identity")
    func requests() async throws {
        let recorder = WorkspaceRequestRecorder(responses: [
            .object(["root": .string("/workspace"), "revision": .string("one")]),
            .object(["root": .string("/workspace"), "path": .string(""), "revision": .string("two"), "entries": .array([])]),
            .object(["blobId": .string("blob"), "name": .string("File.swift"), "mimeType": .string("text/plain"), "size": .number(4), "revision": .string("three")]),
            .object(["path": .string("File.swift"), "patch": .string("@@ -1 +1 @@\n-old\n+new"), "binary": .bool(false), "truncated": .bool(false), "revision": .string("four")]),
            .object(["commits": .array([]), "revision": .string("five")]),
            .object(["path": .string("File.swift"), "patch": .string("@@ -1 +1 @@\n-old\n+new"), "binary": .bool(false), "truncated": .bool(false), "revision": .string("six")]),
        ])
        let service = WorkspaceInspectionService { method, params in
            try await recorder.request(method: method, params: params)
        }

        _ = try await service.inspect(sessionID: "session")
        _ = try await service.list(sessionID: "session", path: "")
        _ = try await service.file(sessionID: "session", path: "File.swift")
        _ = try await service.diff(sessionID: "session", path: "File.swift", scope: .current)
        _ = try await service.history(sessionID: "session", scope: .currentBranch)
        _ = try await service.commitDiff(sessionID: "session", oid: String(repeating: "a", count: 40), path: "File.swift")

        let requests = await recorder.requests
        #expect(requests.map(\.method) == [
            "session.workspace.inspect",
            "session.workspace.list",
            "session.workspace.file",
            "session.workspace.git.diff",
            "session.workspace.git.history.list",
            "session.workspace.git.history.diff",
        ])
        #expect(requests.allSatisfy { $0.params.objectValue?["sessionId"] == .string("session") })
        #expect(requests[1].params.objectValue?["path"] == nil)
        #expect(requests[3].params.objectValue?["scope"] == .string("current"))
        #expect(requests[4].params.objectValue?["limit"] == .number(40))
        #expect(requests[5].params.objectValue?["oid"] == .string(String(repeating: "a", count: 40)))
        #expect(requests[5].params.objectValue?["path"] == .string("File.swift"))
    }

    @Test("workspace collections reject limit plus one during decoding")
    func boundedCollections() throws {
        let change: JSONValue = .object([
            "path": .string("file"), "originalPath": .null,
            "staged": .bool(false), "unstaged": .bool(true),
            "untracked": .bool(false), "conflicted": .bool(false), "kind": .string("modified"),
        ])
        let exact = JSONValue.object([
            "root": .string("/workspace"), "revision": .string("revision"),
            "repository": .object([
                "root": .string("/workspace"), "branch": .string("main"), "head": .string(String(repeating: "a", count: 40)),
                "detached": .bool(false), "unborn": .bool(false), "dirty": .bool(true),
                "changes": .array(Array(repeating: change, count: 5_000)),
            ]),
        ])
        #expect(try exact.decode(SessionWorkspaceInspection.self).repository?.changes.count == 5_000)

        var overObject = exact.objectValue!
        var repository = overObject["repository"]!.objectValue!
        repository["changes"] = .array(Array(repeating: change, count: 5_001))
        overObject["repository"] = .object(repository)
        #expect(throws: DecodingError.self) {
            _ = try JSONValue.object(overObject).decode(SessionWorkspaceInspection.self)
        }
    }
}

private struct WorkspaceRecordedRequest: Sendable {
    let method: String
    let params: JSONValue
}

private actor WorkspaceRequestRecorder {
    private var responses: [JSONValue]
    private(set) var requests: [WorkspaceRecordedRequest] = []

    init(responses: [JSONValue]) { self.responses = responses }

    func request(method: String, params: JSONValue) throws -> JSONValue {
        requests.append(.init(method: method, params: params))
        guard !responses.isEmpty else {
            throw GatewayFailure(code: "missing_fixture", message: "Missing response", retryable: false, details: nil)
        }
        return responses.removeFirst()
    }
}
