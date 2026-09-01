import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Workspace inspector request ownership")
struct WorkspaceInspectorOwnerTests {
    @Test("newer directory navigation rejects a late older response")
    func directoryGeneration() async {
        let probe = WorkspaceInspectorProbe()
        let service = WorkspaceInspectionService { method, params in
            try await probe.request(method: method, params: params)
        }
        let owner = WorkspaceInspectorOwner()

        let first = Task { await owner.loadDirectory(service: service, sessionID: "session", path: "old") }
        await probe.waitUntilRequested("old")
        let second = Task { await owner.loadDirectory(service: service, sessionID: "session", path: "new") }
        await probe.waitUntilRequested("new")

        await probe.respond("new", value: directory(path: "new"))
        await second.value
        #expect(owner.directory?.path == "new")

        await probe.respond("old", value: directory(path: "old"))
        await first.value
        #expect(owner.directory?.path == "new")
    }

    @Test("cancel retires visible loading state and late publication")
    func cancellation() async {
        let probe = WorkspaceInspectorProbe()
        let service = WorkspaceInspectionService { method, params in
            try await probe.request(method: method, params: params)
        }
        let owner = WorkspaceInspectorOwner()
        let loading = Task { await owner.loadDirectory(service: service, sessionID: "session", path: "folder") }
        await probe.waitUntilRequested("folder")
        #expect(owner.loadingDirectory)

        owner.cancel()
        #expect(!owner.loadingDirectory)
        await probe.respond("folder", value: directory(path: "folder"))
        await loading.value
        #expect(owner.directory == nil)
    }

    private func directory(path: String) -> JSONValue {
        .object([
            "root": .string("/workspace"),
            "path": .string(path),
            "parent": .string(""),
            "revision": .string(path),
            "entries": .array([]),
        ])
    }
}

private actor WorkspaceInspectorProbe {
    private var requests: Set<String> = []
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var responseWaiters: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var queuedResponses: [String: JSONValue] = [:]

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == "session.workspace.list",
              let path = params.objectValue?["path"]?.stringValue else {
            throw GatewayFailure(code: "invalid_test_request", message: method, retryable: false, details: nil)
        }
        requests.insert(path)
        requestWaiters.removeValue(forKey: path)?.forEach { $0.resume() }
        if let value = queuedResponses.removeValue(forKey: path) { return value }
        return try await withCheckedThrowingContinuation { responseWaiters[path] = $0 }
    }

    func waitUntilRequested(_ path: String) async {
        if requests.contains(path) { return }
        await withCheckedContinuation { requestWaiters[path, default: []].append($0) }
    }

    func respond(_ path: String, value: JSONValue) {
        if let waiter = responseWaiters.removeValue(forKey: path) { waiter.resume(returning: value) }
        else { queuedResponses[path] = value }
    }
}
