import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Workspace inspector request ownership")
struct WorkspaceInspectorOwnerTests {
    @Test("initial inspection and root listing overlap")
    func initialReadsOverlap() async {
        let probe = WorkspaceInitialProbe()
        let service = WorkspaceInspectionService { method, params in
            try await probe.request(method: method, params: params)
        }
        let owner = WorkspaceInspectorOwner()
        let loading = Task { await owner.loadInitial(service: service, sessionID: "session") }

        await probe.waitForBothRequests()
        await probe.respond()
        await loading.value

        #expect(owner.inspection?.root == "/workspace")
        #expect(owner.directory?.path == "")
    }

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

    @Test("failed directory navigation keeps path and rows atomic")
    func failedDirectoryNavigation() async {
        let probe = WorkspaceInspectorProbe()
        let service = WorkspaceInspectionService { method, params in
            try await probe.request(method: method, params: params)
        }
        let owner = WorkspaceInspectorOwner()

        let initial = Task { await owner.loadDirectory(service: service, sessionID: "session", path: "old") }
        await probe.waitUntilRequested("old")
        await probe.respond("old", value: directory(path: "old"))
        await initial.value

        let failed = Task { await owner.loadDirectory(service: service, sessionID: "session", path: "new") }
        await probe.waitUntilRequested("new")
        await probe.fail("new")
        await failed.value

        #expect(owner.currentPath == "old")
        #expect(owner.directory?.path == "old")
        #expect(owner.errorMessage != nil)
    }

    @Test("history projection has a hard retained-page ceiling")
    func boundedHistory() async {
        let probe = WorkspaceHistoryProbe()
        let service = WorkspaceInspectionService { method, params in
            try await probe.request(method: method, params: params)
        }
        let owner = WorkspaceInspectorOwner()

        await owner.loadHistory(service: service, sessionID: "session", append: false)
        for _ in 0..<5 {
            await owner.loadHistory(service: service, sessionID: "session", append: true)
        }

        #expect(owner.commits.count == WorkspaceInspectorOwner.maximumRetainedCommits)
        #expect(owner.historyRows.count == WorkspaceInspectorOwner.maximumRetainedCommits)
        #expect(owner.historyCursor == nil)
        #expect(await probe.requestCount == 4)
    }

    @Test("an empty history page is still a completed projection")
    func emptyHistoryIsLoaded() async {
        let service = WorkspaceInspectionService { method, _ in
            guard method == "session.workspace.git.history.list" else {
                throw GatewayFailure(code: "invalid_test_request", message: method, retryable: false, details: nil)
            }
            return .object(["commits": .array([]), "revision": .string("empty")])
        }
        let owner = WorkspaceInspectorOwner()
        await owner.loadHistory(service: service, sessionID: "session", append: false)
        #expect(owner.hasLoadedHistory)
        #expect(owner.commits.isEmpty)
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

private actor WorkspaceInitialProbe {
    private var methods: Set<String> = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiters: [String: CheckedContinuation<JSONValue, Error>] = [:]

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard params.objectValue?["sessionId"] == .string("session") else {
            throw GatewayFailure(code: "invalid_test_request", message: method, retryable: false, details: nil)
        }
        methods.insert(method)
        if methods.count == 2 {
            requestWaiters.forEach { $0.resume() }
            requestWaiters.removeAll()
        }
        return try await withCheckedThrowingContinuation { responseWaiters[method] = $0 }
    }

    func waitForBothRequests() async {
        if methods.count == 2 { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func respond() {
        responseWaiters.removeValue(forKey: "session.workspace.inspect")?.resume(returning: .object([
            "root": .string("/workspace"),
            "revision": .string("inspection"),
        ]))
        responseWaiters.removeValue(forKey: "session.workspace.list")?.resume(returning: .object([
            "root": .string("/workspace"),
            "path": .string(""),
            "revision": .string("directory"),
            "entries": .array([]),
        ]))
    }
}

private actor WorkspaceHistoryProbe {
    private(set) var requestCount = 0

    func request(method: String, params: JSONValue) throws -> JSONValue {
        guard method == "session.workspace.git.history.list" else {
            throw GatewayFailure(code: "invalid_test_request", message: method, retryable: false, details: nil)
        }
        let page = requestCount
        requestCount += 1
        let start = page * 100
        let commits: [JSONValue] = (start..<(start + 100)).map { index in
            let oid = String(format: "%040x", index + 1)
            let parent = index == 0 ? [] : [JSONValue.string(String(format: "%040x", index))]
            return .object([
                "oid": .string(oid),
                "shortOid": .string(String(oid.prefix(8))),
                "parents": .array(parent),
                "subject": .string("Commit \(index)"),
                "authorName": .string("Author"),
                "authoredAt": .string("2026-08-31T00:00:00Z"),
                "decorations": .array([]),
            ])
        }
        return .object([
            "commits": .array(commits),
            "nextCursor": .string("page-\(page + 1)"),
            "revision": .string("stable"),
        ])
    }
}

private enum WorkspaceProbeFailure: Error, Sendable {
    case requested
}

private actor WorkspaceInspectorProbe {
    private var requests: Set<String> = []
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var responseWaiters: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var queuedResponses: [String: Result<JSONValue, WorkspaceProbeFailure>] = [:]

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == "session.workspace.list",
              let path = params.objectValue?["path"]?.stringValue else {
            throw GatewayFailure(code: "invalid_test_request", message: method, retryable: false, details: nil)
        }
        requests.insert(path)
        requestWaiters.removeValue(forKey: path)?.forEach { $0.resume() }
        if let value = queuedResponses.removeValue(forKey: path) { return try value.get() }
        return try await withCheckedThrowingContinuation { responseWaiters[path] = $0 }
    }

    func waitUntilRequested(_ path: String) async {
        if requests.contains(path) { return }
        await withCheckedContinuation { requestWaiters[path, default: []].append($0) }
    }

    func respond(_ path: String, value: JSONValue) {
        if let waiter = responseWaiters.removeValue(forKey: path) { waiter.resume(returning: value) }
        else { queuedResponses[path] = .success(value) }
    }

    func fail(_ path: String) {
        if let waiter = responseWaiters.removeValue(forKey: path) { waiter.resume(throwing: WorkspaceProbeFailure.requested) }
        else { queuedResponses[path] = .failure(.requested) }
    }
}
