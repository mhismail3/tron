import Foundation
import Testing

@testable import TronMobile

private final class LockedBearerToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) {
        self.value = value
    }

    func read() -> String {
        lock.withLock { value }
    }

    func replace(with value: String) {
        lock.withLock { self.value = value }
    }
}

/// Behavioral tests for `EngineConnection`'s bearer-token integration —
/// Pairing bearer auth on the WS upgrade
/// request, plus the new `.unauthorized` state machine path).
///
/// These tests exercise the upgrade-request shape and the state-machine
/// transitions without doing real network I/O. End-to-end "real 401 from
/// real server" is verified by the Rust integration test that rejects
/// missing or stale bearer tokens and by the iOS `.unauthorized` state
/// transition tests below.
@Suite("EngineConnection bearer auth")
@MainActor
struct WebSocketAuthTests {

    private func makeURL() -> URL {
        URL(string: "ws://127.0.0.1:55555/nonexistent")!
    }

    // MARK: - Upgrade request shape

    @Test("upgrade request includes Bearer header when provider returns a token")
    func upgradeRequestHasBearerHeader() {
        let token = "test-bearer-token-43-chars-base64-padding-eq"
        let ws = EngineConnection(serverURL: makeURL()) { token }

        let request = ws.makeUpgradeRequest()

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }

    @Test("upgrade request omits Authorization when provider returns nil")
    func upgradeRequestOmitsHeaderWhenNil() {
        // Mirrors an unpaired server: a server entry exists but no bearer is
        // in Keychain. The header must not be sent so the server's 401
        // response triggers `.unauthorized` rather than the request being
        // silently rejected with the wrong token.
        let ws = EngineConnection(serverURL: makeURL()) { nil }

        let request = ws.makeUpgradeRequest()

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("upgrade request omits Authorization when no provider is supplied")
    func upgradeRequestOmitsHeaderWithoutProvider() {
        // Call sites without a paired-server token send no header; the server
        // responds 401 and the UI moves into the re-pair flow.
        let ws = EngineConnection(serverURL: makeURL())

        let request = ws.makeUpgradeRequest()

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("provider is re-evaluated on every upgrade — token rotation flows through")
    func providerEvaluatedPerUpgrade() {
        // Token rotation on the server side means the user re-pairs via the
        // .unauthorized CTA, which writes a fresh token into the Keychain.
        // The provider closure must re-read on every connect so the next
        // attempt picks up the rotated token.
        let current = LockedBearerToken("old-token")
        let ws = EngineConnection(serverURL: makeURL()) { current.read() }

        #expect(ws.makeUpgradeRequest().value(forHTTPHeaderField: "Authorization") == "Bearer old-token")

        current.replace(with: "new-token")

        #expect(ws.makeUpgradeRequest().value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
    }

    @Test("upgrade request preserves the configured timeout")
    func upgradeRequestKeepsTimeout() {
        let ws = EngineConnection(serverURL: makeURL()) { "tok" }

        let request = ws.makeUpgradeRequest()

        #expect(request.timeoutInterval == 30)
    }

    @Test("engine protocol requests are sent as WebSocket text frames")
    func engineMessagesUseTextFrames() throws {
        let data = try #require(#"{"type":"hello","id":"req-1"}"#.data(using: .utf8))

        let frame = EngineConnection.engineTextMessage(from: data)

        switch frame {
        case .string(let text):
            #expect(text == #"{"type":"hello","id":"req-1"}"#)
        case .data:
            Issue.record("engine protocol JSON must be sent as a WebSocket text frame")
        @unknown default:
            Issue.record("unexpected WebSocket frame type")
        }
    }

    @Test("hello advertises the canonical outbound frame budget")
    func helloDecodesFrameBudget() throws {
        let data = Data(#"{"type":"hello.ok","id":"h1","protocolVersion":1,"minimumSupportedVersion":1,"serverId":"tron-engine","maxMessageSize":157286400}"#.utf8)

        let result = try JSONDecoder().decode(EngineHelloResult.self, from: data)

        #expect(result.maxMessageSize == 150 * 1024 * 1024)
    }

    @Test("outbound requests fail before transport when they exceed the negotiated budget")
    func outboundFrameBudgetIsEnforced() throws {
        try EngineConnection.validateOutboundMessageSize(actualBytes: 64, maxBytes: 64)

        do {
            try EngineConnection.validateOutboundMessageSize(actualBytes: 65, maxBytes: 64)
            Issue.record("expected an oversized message error")
        } catch let error as EngineConnectionError {
            #expect(error == .messageTooLarge(actualBytes: 65, maxBytes: 64))
        }
    }

    @Test("URLSession WebSocket delegate exposes the open and close selectors")
    func webSocketDelegateSelectorsMatchURLSession() {
        let ws = EngineConnection(serverURL: makeURL())
        let delegate = EngineConnectionSessionDelegate(owner: ws)

        #expect(delegate.responds(to: #selector(URLSessionWebSocketDelegate.urlSession(_:webSocketTask:didOpenWithProtocol:))))
        #expect(delegate.responds(to: #selector(URLSessionWebSocketDelegate.urlSession(_:webSocketTask:didCloseWith:reason:))))
    }

    // MARK: - .unauthorized state machine

    @Test("markUnauthorized parks state in .unauthorized with the supplied reason")
    func markUnauthorizedTransitionsState() {
        let ws = EngineConnection(serverURL: makeURL())
        #expect(ws.connectionState == .disconnected)

        ws.markUnauthorized(reason: "Server rejected authentication")

        #expect(ws.connectionState == .unauthorized(reason: "Server rejected authentication"))
    }

    @Test(".unauthorized is distinct from .failed and .disconnected")
    func unauthorizedDistinctFromOtherTerminalStates() {
        let unauthorized: ConnectionState = .unauthorized(reason: "x")
        let failed: ConnectionState = .failed(reason: "x")
        let disconnected: ConnectionState = .disconnected

        #expect(unauthorized != failed)
        #expect(unauthorized != disconnected)
        #expect(failed != disconnected)
    }

    @Test(".unauthorized.canInteract is false (read-only mode)")
    func unauthorizedIsReadOnly() {
        let state: ConnectionState = .unauthorized(reason: "x")
        #expect(state.canInteract == false)
        #expect(state.isConnected == false)
        #expect(state.isReconnecting == false)
    }

    @Test(".unauthorized displayText surfaces a re-pair CTA copy")
    func unauthorizedDisplayCopy() {
        let state: ConnectionState = .unauthorized(reason: "Server rejected authentication")
        // Lock in the user-facing copy so accidental refactors of the pill
        // text are caught here rather than in manual QA.
        #expect(state.displayText.lowercased().contains("re-pair"))
    }

    // MARK: - Manual retry from .unauthorized

    @Test("manualRetry from .unauthorized clears the state and attempts to connect")
    func manualRetryFromUnauthorized() async {
        // After the user re-pairs (writes a new token + restarts the WS),
        // calling manualRetry must NOT leave us stuck in .unauthorized. The
        // state should advance toward .connecting (and then likely fail
        // with .reconnecting since the URL is bogus — that's OK; the assert
        // is that we left .unauthorized).
        var requests: [URLRequest] = []
        let ws = EngineConnection(
            serverURL: makeURL(),
            sessionAttemptDirective: { request in
                requests.append(request)
                return .handledFailure
            }
        )
        ws.setBackgroundState(true)
        ws.markUnauthorized(reason: "Server rejected authentication")
        #expect(ws.connectionState == .unauthorized(reason: "Server rejected authentication"))

        await ws.manualRetry()

        if case .unauthorized = ws.connectionState {
            Issue.record("manualRetry left state in .unauthorized")
        }
        #expect(requests.count == 1)
        #expect(requests.first?.url == makeURL())
        #expect(ws.urlSession == nil)
        #expect(ws.engineConnectionTask == nil)
    }

    // MARK: - Unpaired server path

    @Test("nil-token provider produces no header and accepts a 401-driven .unauthorized transition")
    func nilTokenProviderToUnauthorized() {
        // Compose the contract: a provider returning nil produces a request
        // with no Authorization header. The integration with URLSessionDelegate
        // (Phase 3.5) marks the resulting 401 as `.unauthorized`. The unit
        // test simulates the second half via direct `markUnauthorized`.
        let ws = EngineConnection(serverURL: makeURL()) { nil }

        let request = ws.makeUpgradeRequest()
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        ws.markUnauthorized(reason: "Server rejected authentication (no token)")
        #expect(ws.connectionState == .unauthorized(reason: "Server rejected authentication (no token)"))
    }
}

@Suite("EngineConnection request transport")
@MainActor
struct WebSocketRequestTransportTests {

    private func makeTask() -> URLSessionWebSocketTask {
        URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:55555/nonexistent")!
        )
    }

    @Test("retired receive or heartbeat owner cannot disconnect replacement")
    func retiredLoopOwnerLeavesReplacementConnected() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!
        )
        let retiredTask = makeTask()
        let replacementTask = makeTask()
        defer {
            retiredTask.cancel()
            replacementTask.cancel()
        }

        let retiredGeneration = connection.installTransportOwnership(retiredTask)
        connection.isConnectedFlag = true
        let replacementGeneration = connection.installTransportOwnership(replacementTask)
        connection.connectionState = .connected

        #expect(!connection.ownsTransport(retiredTask, generation: retiredGeneration))
        #expect(connection.ownsTransport(replacementTask, generation: replacementGeneration))

        await connection.handleDisconnect(
            expectedTask: retiredTask,
            expectedGeneration: retiredGeneration
        )

        #expect(connection.engineConnectionTask === replacementTask)
        #expect(connection.isConnectedFlag)
        #expect(connection.connectionState == .connected)
    }

    @Test("current transport owner can perform terminal disconnect cleanup")
    func currentLoopOwnerDisconnectsCurrentTransport() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!
        )
        let currentTask = makeTask()
        defer { currentTask.cancel() }

        let generation = connection.installTransportOwnership(currentTask)
        connection.isConnectedFlag = true
        connection.connectionState = .connected
        connection.isInBackground = true

        await connection.handleDisconnect(
            expectedTask: currentTask,
            expectedGeneration: generation
        )

        #expect(connection.engineConnectionTask == nil)
        #expect(!connection.isConnectedFlag)
        #expect(connection.connectionState == .disconnected)
        #expect(connection.transportGeneration != generation)
    }

    @Test("send failure from a retired socket cannot disconnect its replacement")
    func staleSendFailureLeavesReplacementConnected() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!
        )
        let retiredTask = makeTask()
        let replacementTask = makeTask()
        defer {
            retiredTask.cancel()
            replacementTask.cancel()
        }
        connection.engineConnectionTask = replacementTask
        connection.isConnectedFlag = true
        connection.connectionState = .connected

        await connection.handleSendTransportFailure(
            URLError(.networkConnectionLost),
            operation: "agent::prompt",
            failedTask: retiredTask
        )

        #expect(connection.engineConnectionTask === replacementTask)
        #expect(connection.isConnectedFlag)
        #expect(connection.connectionState == .connected)
    }

    @Test("send failure from the current socket performs terminal cleanup")
    func currentSendFailureDisconnectsCurrentSocket() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!
        )
        let currentTask = makeTask()
        defer { currentTask.cancel() }
        connection.engineConnectionTask = currentTask
        connection.isConnectedFlag = true
        connection.connectionState = .connected
        connection.isInBackground = true

        await connection.handleSendTransportFailure(
            URLError(.networkConnectionLost),
            operation: "agent::prompt",
            failedTask: currentTask
        )

        #expect(connection.engineConnectionTask == nil)
        #expect(!connection.isConnectedFlag)
        #expect(connection.connectionState == .disconnected)
    }

    @Test("completion from the current established socket retires its transport loops")
    func currentTaskCompletionRetiresTransportLoops() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!
        )
        let currentTask = makeTask()
        let pingTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(60))
        }
        let receiveTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(60))
        }
        defer {
            currentTask.cancel()
            pingTask.cancel()
            receiveTask.cancel()
        }
        connection.engineConnectionTask = currentTask
        connection.pingTask = pingTask
        connection.receiveTask = receiveTask
        connection.sessionDelegate = EngineConnectionSessionDelegate(owner: connection)
        connection.isConnectedFlag = true
        connection.connectionState = .connected
        connection.isInBackground = true

        await connection.handleWebSocketTaskCompletion(
            currentTask,
            error: URLError(.networkConnectionLost)
        )

        #expect(connection.engineConnectionTask == nil)
        #expect(connection.pingTask == nil)
        #expect(connection.receiveTask == nil)
        #expect(connection.sessionDelegate == nil)
        #expect(pingTask.isCancelled)
        #expect(receiveTask.isCancelled)
        #expect(!connection.isConnectedFlag)
        #expect(connection.connectionState == .disconnected)
    }

    @Test("completion from a retired socket cannot disconnect its replacement")
    func retiredTaskCompletionLeavesReplacementConnected() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!
        )
        let retiredTask = makeTask()
        let replacementTask = makeTask()
        defer {
            retiredTask.cancel()
            replacementTask.cancel()
        }
        connection.engineConnectionTask = replacementTask
        connection.isConnectedFlag = true
        connection.connectionState = .connected

        await connection.handleWebSocketTaskCompletion(
            retiredTask,
            error: URLError(.networkConnectionLost)
        )

        #expect(connection.engineConnectionTask === replacementTask)
        #expect(connection.isConnectedFlag)
        #expect(connection.connectionState == .connected)
    }

    @Test("completion without an error still retires the current established socket")
    func cleanTaskCompletionRetiresCurrentSocket() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!
        )
        let currentTask = makeTask()
        defer { currentTask.cancel() }
        connection.engineConnectionTask = currentTask
        connection.isConnectedFlag = true
        connection.connectionState = .connected
        connection.isInBackground = true

        await connection.handleWebSocketTaskCompletion(currentTask, error: nil)

        #expect(connection.engineConnectionTask == nil)
        #expect(!connection.isConnectedFlag)
        #expect(connection.connectionState == .disconnected)
    }
}
