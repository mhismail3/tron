import Foundation
import Testing
@testable import TronMobile

@Suite("Codex App ViewModel")
@MainActor
struct CodexAppViewModelTests {
    private func server(id: String = "server", host: String = "100.64.0.8") -> PairedServer {
        PairedServer(id: id, label: "Studio", host: host, port: 9847)
    }

    private func status(port: Int = 4500, token: String = "codex-token") -> CodexAppServerStatusResult {
        CodexAppServerStatusResult(
            endpoint: .init(port: port, bearerToken: token),
            listenUrl: "ws://0.0.0.0:\(port)"
        )
    }

    private func threadSummaryResult(id: String = "thr_auto", title: String = "Loaded Thread") -> [String: AnyCodable] {
        [
            "threads": AnyCodable([
                [
                    "id": id,
                    "preview": title,
                    "cwd": "/repo",
                    "modelProvider": "openai",
                    "createdAt": "2026-05-03T00:00:00Z",
                    "path": "/tmp/thread",
                    "cliVersion": "0.128.0",
                    "source": "ios",
                    "turns": []
                ]
            ])
        ]
    }

    private func threadPayload(id: String = "thr_long", messageCount: Int) -> [String: Any] {
        [
            "id": id,
            "preview": "Long thread",
            "cwd": "/repo",
            "modelProvider": "openai",
            "createdAt": "2026-05-03T00:00:00Z",
            "path": "/tmp/thread",
            "cliVersion": "0.128.0",
            "source": "ios",
            "turns": (0..<messageCount).map { index in
                [
                    "id": "turn-\(index)",
                    "items": [
                        [
                            "id": "user-\(index)",
                            "type": "userMessage",
                            "content": [
                                ["type": "text", "text": "message \(index)"]
                            ]
                        ]
                    ]
                ]
            }
        ]
    }

    @Test("status is setup required with no active paired server")
    func noActiveServerRequiresSetup() {
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in FakeCodexTransport() }
        )

        viewModel.configure(activeServer: nil)

        #expect(viewModel.connectionState == .failed(reason: "Pair a Tron server first."))
    }

    @Test("configure builds an endpoint from server-owned Codex status")
    func configureBuildsEndpoint() async throws {
        let fake = FakeCodexTransport()
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in fake }
        )

        viewModel.configure(activeServer: server(), serverStatusProvider: { status(port: 4511) })
        try await Task.sleep(for: .milliseconds(25))

        #expect(viewModel.activeEndpoint?.url.absoluteString == "ws://100.64.0.8:4511")
    }

    @Test("dashboard refresh connects and loads threads without manual refresh")
    func dashboardRefreshConnectsAndLoadsThreads() async throws {
        let fake = FakeCodexTransport()
        fake.results["thread/list"] = threadSummaryResult()
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in fake }
        )

        viewModel.configure(activeServer: server(), serverStatusProvider: { status() })
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.connectionState == .connected)
        #expect(fake.sentMethods.contains("initialize"))
        #expect(fake.sentMethods.contains("initialized"))
        #expect(fake.sentMethods.contains("thread/list"))
        #expect(viewModel.state.threads.map(\.id) == ["thr_auto"])
        #expect(viewModel.state.selectedThreadId == nil)
    }

    @Test("dashboard auto refresh keeps polling managed status while disconnected")
    func dashboardAutoRefreshPollsStatusWhileDisconnected() async throws {
        let fake = FakeCodexTransport()
        fake.results["thread/list"] = threadSummaryResult()
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in fake }
        )
        var statusCalls = 0

        viewModel.configure(activeServer: server(), serverStatusProvider: {
            statusCalls += 1
            if statusCalls == 1 {
                return CodexAppServerStatusResult(
                    state: "failed",
                    endpoint: nil,
                    listenUrl: "ws://0.0.0.0:4500",
                    pid: nil,
                    lastError: "managed Codex App Server exited during startup"
                )
            }
            return status()
        })
        try await Task.sleep(for: .milliseconds(25))
        #expect(viewModel.connectionState == .failed(reason: "managed Codex App Server exited during startup"))

        let refreshTask = Task {
            await viewModel.runDashboardAutoRefresh(interval: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(60))
        refreshTask.cancel()
        _ = await refreshTask.result

        #expect(statusCalls >= 2)
        #expect(viewModel.connectionState == .connected)
        #expect(fake.sentMethods.contains("thread/list"))
        #expect(viewModel.state.threads.map(\.id) == ["thr_auto"])
    }

    @Test("foreground recovery reconnects stale Codex socket and reloads selected thread")
    func foregroundRecoveryReconnectsStaleSocket() async throws {
        let fake = FakeCodexTransport()
        fake.results["thread/list"] = threadSummaryResult(id: "thr_focus", title: "Focus Thread")
        fake.results["thread/resume"] = [
            "thread": AnyCodable(threadPayload(id: "thr_focus", messageCount: 3))
        ]
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in fake }
        )
        viewModel.configure(activeServer: server(), serverStatusProvider: { status() })
        try await Task.sleep(for: .milliseconds(25))
        try await viewModel.openThread("thr_focus")

        let connectCountBeforeForeground = fake.connectCount
        let listCountBeforeForeground = fake.sentMethods.filter { $0 == "thread/list" }.count
        let resumeCountBeforeForeground = fake.sentMethods.filter { $0 == "thread/resume" }.count
        fake.failNextSend(
            method: "thread/list",
            error: CodexTransportError.requestFailed("socket closed while app was backgrounded")
        )

        await viewModel.recoverForeground()

        #expect(viewModel.connectionState == .connected)
        #expect(fake.disconnectCount >= 2)
        #expect(fake.connectCount >= connectCountBeforeForeground + 2)
        #expect(fake.sentMethods.filter { $0 == "thread/list" }.count >= listCountBeforeForeground + 2)
        #expect(fake.sentMethods.filter { $0 == "thread/resume" }.count >= resumeCountBeforeForeground + 1)
        #expect(viewModel.state.selectedThreadId == "thr_focus")
        #expect(viewModel.state.messages.last?.content.textContent == "message 2")
        #expect(viewModel.state.errorMessage == nil)
    }

    @Test("configure rejects running server status that omits a required bearer token")
    func configureRejectsMissingManagedToken() async throws {
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in FakeCodexTransport() }
        )

        viewModel.configure(activeServer: server(), serverStatusProvider: {
            CodexAppServerStatusResult(
                endpoint: .init(port: 4511, requiresToken: true, bearerToken: nil),
                listenUrl: "ws://0.0.0.0:4511"
            )
        })
        try await Task.sleep(for: .milliseconds(25))

        #expect(viewModel.activeEndpoint == nil)
        #expect(viewModel.connectionState == .failed(reason: "Remote Codex App Server connections require a bearer token."))
    }

    @Test("sending text starts a new thread if none is selected")
    func sendStartsThread() async throws {
        let fake = FakeCodexTransport()
        fake.results["initialize"] = ["userAgent": AnyCodable("codex-cli/0.128.0")]
        fake.results["thread/list"] = ["threads": AnyCodable([])]
        fake.results["thread/start"] = [
            "thread": AnyCodable([
                "id": "thr_1",
                "preview": "New thread",
                "cwd": "/repo",
                "modelProvider": "openai",
                "createdAt": "2026-05-03T00:00:00Z",
                "path": "/tmp/thread",
                "cliVersion": "0.128.0",
                "source": "ios",
                "turns": []
            ]),
            "model": AnyCodable("gpt-5.4"),
            "modelProvider": AnyCodable("openai"),
            "cwd": AnyCodable("/repo"),
            "approvalPolicy": AnyCodable("on-request"),
            "sandbox": AnyCodable("workspace-write")
        ]
        fake.results["turn/start"] = ["turn": AnyCodable(["id": "turn_1", "items": [], "status": "running"])]
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in fake }
        )
        viewModel.configure(activeServer: server(), serverStatusProvider: { status() })
        try await Task.sleep(for: .milliseconds(25))
        try await viewModel.connect()

        try await viewModel.sendText("hello")

        #expect(fake.sentMethods.contains("thread/start"))
        #expect(fake.sentMethods.contains("turn/start"))
        #expect(viewModel.state.selectedThreadId == "thr_1")
        #expect(viewModel.state.messages.first?.role == .user)
    }

    @Test("approval decision responds with original server request id")
    func approvalDecisionRespondsWithOriginalId() async throws {
        let fake = FakeCodexTransport()
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in fake }
        )
        viewModel.configure(activeServer: server(), serverStatusProvider: { status() })
        try await Task.sleep(for: .milliseconds(25))
        let request = CodexApprovalRequest(
            requestId: .string("approval-id"),
            kind: .command,
            threadId: "thr",
            turnId: "turn",
            itemId: "item",
            reason: nil
        )
        viewModel.state.pendingApprovals = [request]

        try await viewModel.resolveApproval(request, decision: .accept)

        #expect(fake.sentResponses.first?.id == .string("approval-id"))
        #expect(viewModel.state.pendingApprovals.isEmpty)
    }

    @Test("opening long thread shows newest batch and loads earlier entries on demand")
    func openingLongThreadWindowsHistory() async throws {
        let fake = FakeCodexTransport()
        fake.results["thread/list"] = ["threads": AnyCodable([])]
        let count = CodexAppHistoryWindow.initialMessageLimit + 5
        fake.results["thread/resume"] = [
            "thread": AnyCodable(threadPayload(messageCount: count))
        ]
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in fake }
        )
        viewModel.configure(activeServer: server(), serverStatusProvider: { status() })
        try await Task.sleep(for: .milliseconds(25))
        try await viewModel.connect()

        try await viewModel.openThread("thr_long")

        #expect(viewModel.state.messages.count == CodexAppHistoryWindow.initialMessageLimit)
        #expect(viewModel.state.earlierMessages.count == 5)
        #expect(viewModel.state.messages.first?.content.textContent == "message 5")
        #expect(viewModel.state.messages.last?.content.textContent == "message \(count - 1)")
        #expect(viewModel.hasEarlierThreadEntries)

        await viewModel.loadEarlierThreadEntries()

        #expect(viewModel.state.messages.count == count)
        #expect(viewModel.state.earlierMessages.isEmpty)
        #expect(!viewModel.hasEarlierThreadEntries)
        #expect(viewModel.state.messages.first?.content.textContent == "message 0")
    }

    @Test("active paired server swap clears Codex-only state and disconnects old transport")
    func activeServerSwapClearsCodexState() async throws {
        let first = FakeCodexTransport()
        let second = FakeCodexTransport()
        var fakes = [first, second]
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in
                fakes.removeFirst()
            }
        )
        viewModel.configure(activeServer: server(id: "first"), serverStatusProvider: { status(port: 4500) })
        try await Task.sleep(for: .milliseconds(25))
        viewModel.state.threads = [
            CodexThreadSummary(id: "old", title: "Old Thread", cwd: nil, model: nil, createdAt: nil, status: .idle)
        ]
        viewModel.state.selectedThreadId = "old"
        viewModel.state.messages = [
            ChatMessage(id: UUID(), role: .assistant, content: .text("old server"), isStreaming: false)
        ]

        viewModel.configure(activeServer: server(id: "second", host: "100.64.0.9"), serverStatusProvider: { status(port: 4501) })
        try await Task.sleep(for: .milliseconds(25))

        #expect(first.disconnectCount == 1)
        #expect(second.disconnectCount == 0)
        #expect(viewModel.state.threads.isEmpty)
        #expect(viewModel.state.selectedThreadId == nil)
        #expect(viewModel.state.messages.isEmpty)
    }

    @Test("reconfiguring the same server does not disconnect an existing Codex transport")
    func sameServerConfigureKeepsTransport() async throws {
        let fake = FakeCodexTransport()
        fake.results["thread/list"] = ["threads": AnyCodable([])]
        var factoryCalls = 0
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in
                factoryCalls += 1
                return fake
            }
        )

        viewModel.configure(activeServer: server(), serverStatusProvider: { status() })
        try await Task.sleep(for: .milliseconds(25))
        fake.connectionState = .connected
        viewModel.configure(activeServer: server(), serverStatusProvider: { status() })
        try await Task.sleep(for: .milliseconds(25))

        #expect(factoryCalls == 1)
        #expect(fake.disconnectCount == 0)
        #expect(viewModel.connectionState == .connected)
    }

    @Test("new thread preparation opens a draft without creating a server thread")
    func prepareNewThreadCreatesDraftState() async throws {
        let viewModel = CodexAppViewModel(
            transportFactory: { _, _ in FakeCodexTransport() }
        )
        viewModel.state.selectedThreadId = "old"
        viewModel.state.messages = [
            ChatMessage(id: UUID(), role: .assistant, content: .text("old"), isStreaming: false)
        ]

        viewModel.prepareNewThread()

        #expect(viewModel.state.selectedThreadId == nil)
        #expect(viewModel.state.messages.isEmpty)
        #expect(viewModel.state.isDraftingNewThread)
    }
}

@MainActor
private final class FakeCodexTransport: CodexAppTransporting {
    var connectionState: ConnectionState = .disconnected
    var onNotification: ((CodexJSONRPCNotification) -> Void)?
    var onServerRequest: ((CodexJSONRPCServerRequest) -> Void)?
    var sentMethods: [String] = []
    var sentResponses: [CodexJSONRPCServerResponse] = []
    var results: [String: [String: AnyCodable]] = [:]
    var failures: [String: [Error]] = [:]
    var connectCount = 0
    var disconnectCount = 0

    func connect() async throws {
        connectCount += 1
        connectionState = .connected
    }

    func disconnect() async {
        disconnectCount += 1
        connectionState = .disconnected
    }

    func send(method: String, params: [String: AnyCodable]?, timeout: TimeInterval?) async throws -> [String: AnyCodable] {
        sentMethods.append(method)
        if var methodFailures = failures[method], !methodFailures.isEmpty {
            let failure = methodFailures.removeFirst()
            failures[method] = methodFailures
            connectionState = .failed(reason: failure.localizedDescription)
            throw failure
        }
        return results[method] ?? [:]
    }

    func notify(method: String, params: [String: AnyCodable]?) async throws {
        sentMethods.append(method)
    }

    func respond(_ response: CodexJSONRPCServerResponse) async throws {
        sentResponses.append(response)
    }

    func failNextSend(method: String, error: Error) {
        failures[method, default: []].append(error)
    }
}
