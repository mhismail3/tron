import Foundation

// ARCHITECTURE: ~966 lines — connection state machine (7 states), reconnection strategies
// (single normal probe + deploy-aware), bounded ping verification, heartbeat loop, message
// routing, and background state management.
// These are tightly coupled transport concerns that share connection state. Pragmatic trigger:
// if a third reconnection strategy is needed.

// MARK: - Connection State

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, nextRetrySeconds: Int)
    case deployRestarting(remainingSeconds: Int)  // Server deploying, patient reconnection
    case failed(reason: String)
    /// Server rejected the WS upgrade with HTTP 401 — bearer token is missing,
    /// expired, or rotated. Read-only state; user must re-pair via the
    /// `ConnectionStatusPill` CTA before reconnect can resume.
    case unauthorized(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isReconnecting: Bool {
        switch self {
        case .reconnecting, .deployRestarting: return true
        default: return false
        }
    }

    /// Whether the user can interact with the session (send messages, etc.)
    /// Only true when fully connected - reconnecting is read-only mode.
    /// `.unauthorized` is read-only — user must re-pair before interacting.
    var canInteract: Bool {
        if case .connected = self { return true }
        return false
    }

    /// True when no further automatic reconnect is in flight and the user
    /// must take action (manual retry or re-pair). Used by the
    /// `ConnectionStatusPill` to surface tap-to-fix CTAs.
    var requiresUserAction: Bool {
        switch self {
        case .failed, .unauthorized: return true
        default: return false
        }
    }

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting(let attempt, let seconds): return "Reconnecting (\(attempt)) in \(seconds)s..."
        case .deployRestarting(let seconds): return "Server deploying... \(seconds)s"
        case .failed(let reason): return "Failed: \(reason)"
        case .unauthorized: return "Re-pair this server (Tap to fix)"
        }
    }
}

// MARK: - WebSocket Errors

enum EngineConnectionError: Error, LocalizedError, Sendable, Equatable {
    case notConnected
    case timeout
    case invalidResponse
    case connectionFailed(String)
    case encodingError
    case decodingError(String)
    /// Server returned HTTP 401 on the WS upgrade — bearer token missing,
    /// wrong, or rotated. Surfaces as `ConnectionState.unauthorized`.
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .timeout: return "Request timed out"
        case .invalidResponse: return "Invalid response from server"
        case .connectionFailed(let reason): return "Connection failed: \(reason)"
        case .encodingError: return "Failed to encode request"
        case .decodingError(let detail): return "Failed to decode response: \(detail)"
        case .unauthorized(let reason): return "Unauthorized: \(reason)"
        }
    }
}

// MARK: - Bearer Token Provider

/// Strategy for resolving a bearer token to attach to the WebSocket upgrade
/// request. Returns `nil` if no token is available; the request goes out
/// without an Authorization header, the server returns 401, and
/// `EngineConnection` transitions to `ConnectionState.unauthorized`.
typealias BearerTokenProvider = @MainActor () -> String?

private final class SingleResumeContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        resume(.success(()))
    }

    func resume(throwing error: Error) {
        resume(.failure(error))
    }

    private func resume(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - WebSocket Service

@Observable
@MainActor
final class EngineConnection {

    private var urlSession: URLSession?
    private var engineConnectionTask: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    private let serverURL: URL
    private var isConnectedFlag = false
    private var reconnectAttempts = 0

    /// Normal reconnect policy — one short automatic probe before parking in `.failed`.
    private let reconnectPolicy = ReconnectProbePolicy()

    private let requestTimeout: TimeInterval = 30.0
    nonisolated static let connectionVerificationTimeout: TimeInterval = 3.0
    nonisolated static let connectionOpenTimeout: TimeInterval = 10.0
    nonisolated static let manualRetryOpenTimeout: TimeInterval = connectionOpenTimeout
    nonisolated static let automaticReconnectProbeTimeout: TimeInterval = ReconnectProbePolicy().probeTimeout
    nonisolated static let heartbeatInterval: TimeInterval = 5.0
    nonisolated static let failedAfterExhaustionReason = "Connection lost — tap to retry"

    /// Task for reconnection (can be cancelled for manual retry)
    private var reconnectTask: Task<Void, Never>?
    private var openedWebSocketTask: URLSessionWebSocketTask?
    private var openContinuation: SingleResumeContinuationBox?
    private var openTimeoutTask: Task<Void, Never>?

    private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// Prevents concurrent connection attempts (race condition guard)
    private var isConnectionInProgress = false

    private(set) var connectionState: ConnectionState = .disconnected

    /// Event callback with the decoded neutral payload plus stream cursor metadata.
    var onEvent: ((EngineEventDelivery) -> Void)?

    // MARK: - Background State

    /// Tracks whether the app is in the background to pause heartbeats and save battery
    /// Note: We only pause heartbeats, we don't disconnect - reconnecting is expensive and error-prone
    private var isInBackground = false

    // MARK: - Deploy Restart State

    /// Set when the server broadcasts `server.restarting` before a deploy shutdown.
    /// Triggers patient reconnection instead of the normal short reconnect probe.
    private var isDeployRestarting = false

    /// Expected total restart time in milliseconds (from server event).
    private var deployRestartExpectedMs: Int = 0

    /// Bearer token resolver invoked on every WS upgrade. `nil` means "send
    /// no Authorization header" — used by paired servers that have not completed
    /// bearer pairing on this device.
    private let bearerTokenProvider: BearerTokenProvider?

    /// URLSession delegate that notices HTTP 401 on the upgrade and routes
    /// to `markUnauthorized(reason:)`. Held strong here because URLSession
    /// keeps a strong reference to its delegate; we own the lifetime so the
    /// session can be torn down cleanly on disconnect.
    private var sessionDelegate: EngineConnectionSessionDelegate?

    init(serverURL: URL, bearerTokenProvider: BearerTokenProvider? = nil) {
        self.serverURL = serverURL
        self.bearerTokenProvider = bearerTokenProvider
    }

    /// Build the URLRequest used for the WS upgrade. Internal so unit tests
    /// can verify the Authorization header. Re-evaluates `bearerTokenProvider`
    /// on every call so token rotations propagate without re-instantiating
    /// the service.
    func makeUpgradeRequest() -> URLRequest {
        var request = URLRequest(url: serverURL)
        request.timeoutInterval = 30
        if let token = bearerTokenProvider?() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Force the state machine into `.unauthorized(reason:)`. Cancels any
    /// in-flight reconnect, tears down the socket, and parks the service
    /// until the user re-pairs (which surfaces via `manualRetry()` after
    /// the bearer provider returns a fresh token).
    ///
    /// Safe to call from any URLSession delegate callback via `await
    /// MainActor.run` — the actual mutation happens on the main actor.
    func markUnauthorized(reason: String) {
        logger.warning("WS upgrade rejected (401): \(reason)", category: .websocket)

        // Cancel reconnect bookkeeping so we don't immediately re-attempt
        // and burn cycles against a server that will keep returning 401.
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        isDeployRestarting = false
        deployRestartExpectedMs = 0

        isConnectedFlag = false
        openedWebSocketTask = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: EngineConnectionError.unauthorized(reason))
        openContinuation = nil
        engineConnectionTask?.cancel(with: .normalClosure, reason: nil)
        engineConnectionTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil
        pingTask?.cancel(); pingTask = nil
        receiveTask?.cancel(); receiveTask = nil

        failPendingRequests(error: EngineConnectionError.unauthorized(reason))

        connectionState = .unauthorized(reason: reason)
    }

    // MARK: - Connection Management

    func connect() async {
        await connect(
            openTimeout: Self.connectionOpenTimeout,
            stateOnStart: .connecting,
            stateOnFailure: .disconnected
        )
    }

    private func connect(
        openTimeout: TimeInterval,
        stateOnStart: ConnectionState,
        stateOnFailure: ConnectionState
    ) async {
        // Prevent concurrent connection attempts (race condition guard)
        guard !isConnectionInProgress else {
            logger.debug("Connection already in progress, skipping", category: .websocket)
            return
        }

        guard !isConnectedFlag else {
            logger.debug("Already connected, skipping connect request", category: .websocket)
            return
        }

        // Set lock immediately before any async work
        isConnectionInProgress = true
        defer { isConnectionInProgress = false }

        connectionState = stateOnStart
        logger.logWebSocketState("Connecting", details: serverURL.absoluteString)
        logger.info("Connecting to \(self.serverURL.absoluteString)", category: .websocket)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        logger.verbose("URLSession config: requestTimeout=30s, resourceTimeout=300s", category: .websocket)

        // Install a delegate so we can detect HTTP 401 on the upgrade — the
        // delegate routes to `markUnauthorized(reason:)` when it sees a 401
        // response code on the failed task. URLSession retains its delegate,
        // so we hold our own strong reference for symmetric teardown.
        let delegate = EngineConnectionSessionDelegate(owner: self)
        sessionDelegate = delegate

        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        urlSession = session

        let request = makeUpgradeRequest()
        logger.info("WebSocket upgrade request: \(NetworkDiagnosticsFormatter.requestSummary(request))", category: .websocket)

        logger.verbose("Creating WebSocket task...", category: .websocket)
        let task = session.webSocketTask(with: request)
        engineConnectionTask = task
        openedWebSocketTask = nil
        task.maximumMessageSize = 150 * 1024 * 1024  // 150MB — matches server limit; covers 15-min voice notes at 48kHz (~115MB base64)
        task.resume()
        logger.verbose("WebSocket task resumed", category: .websocket)

        do {
            try await waitForOpen(on: task, timeout: openTimeout)
        } catch {
            if case .unauthorized = connectionState {
                return
            }
            logger.warning("WebSocket did not open: \(error.localizedDescription)", category: .websocket)
            cleanupDeadConnection(error: error, stateAfterCleanup: stateOnFailure)
            return
        }

        guard engineConnectionTask === task else {
            logger.debug("Connection verified after socket was torn down", category: .websocket)
            return
        }

        isConnectedFlag = true
        reconnectAttempts = 0
        connectionState = .connected
        logger.logWebSocketState("Connected", details: "Verified connection to \(serverURL.host ?? "unknown")")
        logger.info("Connection verified for \(self.serverURL.absoluteString)", category: .websocket)

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        logger.verbose("Receive loop started", category: .websocket)

        do {
            try await hello()
        } catch {
            logger.warning("Engine hello failed: \(error.localizedDescription)", category: .websocket)
            cleanupDeadConnection(error: error, stateAfterCleanup: stateOnFailure)
            return
        }

        pingTask = Task { [weak self] in
            await self?.heartbeatLoop()
        }
        logger.verbose("Heartbeat loop started", category: .websocket)
    }

    func markWebSocketOpened(_ task: URLSessionWebSocketTask) {
        guard engineConnectionTask === task else { return }
        openedWebSocketTask = task
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume()
        openContinuation = nil
        logger.debug("WebSocket upgrade opened: \(NetworkDiagnosticsFormatter.redactedURLSummary(serverURL))", category: .websocket)
    }

    func markWebSocketClosed(_ task: URLSessionWebSocketTask, closeCode: URLSessionWebSocketTask.CloseCode) async {
        guard engineConnectionTask === task, isConnectedFlag else { return }
        logger.warning("WebSocket closed by server (code: \(closeCode.rawValue))", category: .websocket)
        await handleDisconnect()
    }

    func markWebSocketOpenFailed(_ task: URLSessionTask, error: Error) {
        guard let socketTask = task as? URLSessionWebSocketTask,
              engineConnectionTask === socketTask,
              openContinuation != nil else {
            return
        }
        logger.warning("WebSocket open failed: \(NetworkDiagnosticsFormatter.errorSummary(error))", category: .websocket)
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: error)
        openContinuation = nil
    }

    func markWebSocketOpenTimedOut(timeout: TimeInterval) {
        logger.warning(
            "WebSocket open timed out after \(String(format: "%.1fs", timeout)): \(NetworkDiagnosticsFormatter.redactedURLSummary(serverURL))",
            category: .websocket
        )
    }

    func logWebSocketTaskMetrics(_ metrics: URLSessionTaskMetrics) {
        logger.debug("WebSocket URLSession metrics: \(NetworkDiagnosticsFormatter.metricsSummary(metrics))", category: .websocket)
    }

    func logWebSocketUpgradeResponse(_ response: URLResponse) {
        logger.info("WebSocket upgrade response: \(NetworkDiagnosticsFormatter.responseSummary(response))", category: .websocket)
    }

    func logWebSocketTaskCompletionError(_ error: Error) {
        logger.warning("WebSocket task completed with error: \(NetworkDiagnosticsFormatter.errorSummary(error))", category: .websocket)
    }

    func disconnect() {
        logger.logWebSocketState("Disconnecting")
        logger.info("Disconnecting from server", category: .websocket)
        isConnectedFlag = false
        isDeployRestarting = false
        deployRestartExpectedMs = 0
        openedWebSocketTask = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: EngineConnectionError.notConnected)
        openContinuation = nil

        // Cancel all background tasks
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil

        engineConnectionTask?.cancel(with: .goingAway, reason: nil)
        engineConnectionTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        failPendingRequests(error: EngineConnectionError.notConnected)

        connectionState = .disconnected
        logger.logWebSocketState("Disconnected")
    }

    /// Set background state to pause heartbeats and save battery.
    /// Call this from scene phase changes in TronMobileApp.
    ///
    /// Note: We only pause heartbeats for a live `.connected` socket — reconnecting is
    /// expensive so we don't want to tear that down on every backgrounding.
    ///
    /// When backgrounding mid-reconnect, cancel the probe and reset to `.disconnected` so the
    /// foreground handler can decide whether to run a fresh probe instead of assuming work is
    /// still in flight.
    func setBackgroundState(_ inBackground: Bool) {
        guard isInBackground != inBackground else { return }
        isInBackground = inBackground

        if inBackground {
            logger.info("App entering background - pausing heartbeats", category: .websocket)

            switch connectionState {
            case .connecting, .reconnecting:
                logger.info("Cancelling in-flight reconnect for background transition", category: .websocket)
                reconnectTask?.cancel()
                reconnectTask = nil
                reconnectAttempts = 0
                connectionState = .disconnected
            case .connected, .disconnected, .failed, .deployRestarting, .unauthorized:
                // .unauthorized is a parked state — backgrounding doesn't
                // change it; the user must re-pair when they return.
                break
            }
        } else {
            logger.info("App returning to foreground - resuming heartbeats", category: .websocket)
        }
    }

    /// Signal that the server is about to restart for a deploy.
    /// Sets deploy-aware reconnection mode — more patient than normal reconnection.
    /// Called when the `server.restarting` event is received.
    func setDeployRestarting(expectedMs: Int) {
        isDeployRestarting = true
        deployRestartExpectedMs = expectedMs
        // Show deploy state immediately (even though connection is still alive for now)
        let totalExpectedSeconds = max(1, (expectedMs + 5000) / 1000) // server delay + startup buffer
        connectionState = .deployRestarting(remainingSeconds: totalExpectedSeconds)
        logger.info("Deploy restart signaled: expectedMs=\(expectedMs), totalExpected=\(totalExpectedSeconds)s", category: .websocket)
    }

    /// Verify connection is alive by sending a ping.
    /// Returns true if connection responds, false if dead.
    /// If dead, cleans up stale state so reconnection can proceed.
    func verifyConnection() async -> Bool {
        guard isConnectedFlag, let task = engineConnectionTask else {
            return false
        }

        do {
            try await sendPing(on: task, timeout: Self.connectionVerificationTimeout)
            logger.debug("Connection verification: alive", category: .websocket)
            return true
        } catch {
            logger.warning("Connection verification failed: \(error.localizedDescription)", category: .websocket)
            cleanupDeadConnection(error: error)
            return false
        }
    }

    private func sendPing(on task: URLSessionWebSocketTask, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = SingleResumeContinuationBox(continuation)

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                box.resume(throwing: EngineConnectionError.timeout)
            }

            task.sendPing { error in
                timeoutTask.cancel()
                if let error {
                    box.resume(throwing: error)
                } else {
                    box.resume()
                }
            }
        }
    }

    private func waitForOpen(on task: URLSessionWebSocketTask, timeout: TimeInterval) async throws {
        if openedWebSocketTask === task { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = SingleResumeContinuationBox(continuation)
            openContinuation = box
            logger.debug(
                "Waiting for WebSocket upgrade to open: timeout=\(String(format: "%.1fs", timeout)) url=\(NetworkDiagnosticsFormatter.redactedURLSummary(serverURL))",
                category: .websocket
            )
            openTimeoutTask?.cancel()
            openTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.openContinuation === box else { return }
                    self.markWebSocketOpenTimedOut(timeout: timeout)
                    self.openContinuation = nil
                    self.openTimeoutTask = nil
                    box.resume(throwing: EngineConnectionError.timeout)
                }
            }
        }
    }

    private func cleanupDeadConnection(
        error: Error,
        stateAfterCleanup: ConnectionState = .disconnected
    ) {
        isConnectedFlag = false
        connectionState = stateAfterCleanup
        openedWebSocketTask = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: error)
        openContinuation = nil
        engineConnectionTask?.cancel(with: .abnormalClosure, reason: nil)
        engineConnectionTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        failPendingRequests(error: EngineConnectionError.connectionFailed(error.localizedDescription))
    }

    // MARK: - Engine Protocol Request/Response

    @discardableResult
    func hello(
        sessionId: String? = nil,
        workspaceId: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> EngineHelloResult {
        let message = EngineHelloFrame(
            id: UUID().uuidString,
            protocolVersion: 1,
            clientName: "tron-ios",
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            sessionId: sessionId,
            workspaceId: workspaceId
        )
        return try await sendProtocolMessage(message, id: message.id, operation: "hello", timeout: timeout)
    }

    func invokeRead<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        options: EngineInvocationOptions = EngineInvocationOptions()
    ) async throws -> R {
        try await invoke(functionId: functionId, payload: payload, idempotencyKey: nil, options: options)
    }

    func invokeWrite<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        idempotencyKey: EngineIdempotencyKey,
        options: EngineInvocationOptions = EngineInvocationOptions()
    ) async throws -> R {
        try await invoke(functionId: functionId, payload: payload, idempotencyKey: idempotencyKey, options: options)
    }

    func subscribe(
        topic: String,
        cursor: EngineStreamCursor? = nil,
        filters: [String: AnyCodable]? = nil,
        limit: Int? = nil,
        context: EngineInvocationContext? = nil
    ) async throws -> EngineSubscription {
        let message = EngineSubscribeFrame(
            id: UUID().uuidString,
            topic: topic,
            cursor: cursor?.rawValue,
            filters: filters,
            limit: limit,
            context: context
        )
        return try await sendResponseMessage(message, id: message.id, operation: "subscribe", timeout: nil)
    }

    func poll(
        subscriptionId: String? = nil,
        topic: String? = nil,
        cursor: EngineStreamCursor? = nil,
        filters: [String: AnyCodable]? = nil,
        limit: Int? = nil,
        context: EngineInvocationContext? = nil
    ) async throws -> EngineStreamPage {
        let message = EnginePollFrame(
            id: UUID().uuidString,
            subscriptionId: subscriptionId,
            topic: topic,
            cursor: cursor?.rawValue,
            filters: filters,
            limit: limit,
            context: context
        )
        return try await sendResponseMessage(message, id: message.id, operation: "poll", timeout: nil)
    }

    func ack(subscriptionId: String, cursor: EngineStreamCursor) async throws {
        let message = EngineAckFrame(id: UUID().uuidString, subscriptionId: subscriptionId, cursor: cursor.rawValue)
        let _: EmptyParams = try await sendResponseMessage(message, id: message.id, operation: "ack", timeout: nil)
    }

    private func invoke<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        idempotencyKey: EngineIdempotencyKey?,
        options: EngineInvocationOptions
    ) async throws -> R {
        let requestId = UUID().uuidString
        let message = EngineFunctionCallFrame(
            id: requestId,
            functionId: functionId.rawValue,
            payload: payload,
            expectedRevision: options.expectedRevision,
            idempotencyKey: idempotencyKey?.rawValue,
            context: options.context
        )
        let startTime = CFAbsoluteTimeGetCurrent()
        logger.logEngineRequest(functionId: functionId.rawValue, payload: payload, id: requestId)
        let envelope: EngineFunctionCallEnvelope<R> = try await sendResponseMessage(
            message,
            id: requestId,
            operation: functionId.rawValue,
            timeout: options.timeout
        )
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        if let error = envelope.child.error {
            let protocolError = EngineProtocolError(
                code: error.details?["code"]?.stringValue ?? error.kind ?? "ENGINE_ERROR",
                message: error.details?["message"]?.stringValue ?? error.message ?? "Engine invocation failed",
                details: error.details?["details"]?.dictionaryValue?.mapValues { AnyCodable($0) } ?? error.details
            )
            logger.logEngineResponse(functionId: functionId.rawValue, id: requestId, success: false, duration: duration, error: protocolError.diagnosticSummary)
            throw protocolError
        }
        guard let value = envelope.child.value else {
            logger.logEngineResponse(functionId: functionId.rawValue, id: requestId, success: false, duration: duration, error: "Missing child value")
            throw EngineConnectionError.invalidResponse
        }
        logger.logEngineResponse(functionId: functionId.rawValue, id: requestId, success: true, duration: duration, result: value)
        return value
    }

    private func sendProtocolMessage<M: Encodable, R: Decodable>(
        _ message: M,
        id: String,
        operation: String,
        timeout: TimeInterval?
    ) async throws -> R {
        let data = try await sendMessage(message, id: id, operation: operation, timeout: timeout)
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw EngineConnectionError.decodingError(error.localizedDescription)
        }
    }

    private func sendResponseMessage<M: Encodable, R: Decodable>(
        _ message: M,
        id: String,
        operation: String,
        timeout: TimeInterval?
    ) async throws -> R {
        let data = try await sendMessage(message, id: id, operation: operation, timeout: timeout)
        do {
            let response = try JSONDecoder().decode(EngineResponseEnvelope<R>.self, from: data)
            if response.ok, let result = response.result {
                return result
            }
            if let error = response.error {
                throw error
            }
            throw EngineConnectionError.invalidResponse
        } catch let error as EngineProtocolError {
            throw error
        } catch let error as EngineConnectionError {
            throw error
        } catch {
            throw EngineConnectionError.decodingError(error.localizedDescription)
        }
    }

    private func sendMessage<M: Encodable>(
        _ message: M,
        id requestId: String,
        operation: String,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let timeoutInterval = timeout ?? requestTimeout

        guard isConnectedFlag, let task = engineConnectionTask else {
            logger.error("Cannot send \(operation): not connected (isConnectedFlag=\(isConnectedFlag), task=\(engineConnectionTask != nil ? "exists" : "nil"))", category: .websocket)
            throw EngineConnectionError.notConnected
        }

        guard let data = try? JSONEncoder().encode(message) else {
            logger.error("Failed to encode engine message for \(operation)", category: .websocket)
            throw EngineConnectionError.encodingError
        }

        #if DEBUG || BETA
        logger.logWebSocketMessage(direction: "→ SEND", type: operation, size: data.count, preview: String(data: data, encoding: .utf8))
        #endif

        let socketMessage = Self.engineTextMessage(from: data)
        do {
            try await task.send(socketMessage)
            logger.verbose("Message sent successfully for \(operation) id=\(requestId)", category: .websocket)
        } catch {
            logger.error("Failed to send message for \(operation): \(error.localizedDescription)", category: .websocket)
            if ConnectionErrorClassifier.requiresConnectionRecovery(error) {
                await handleSendTransportFailure(error, operation: operation)
                throw EngineConnectionError.connectionFailed(error.localizedDescription)
            }
            throw error
        }

        logger.verbose("Waiting for response to \(operation) id=\(requestId)...", category: .websocket)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingRequests[requestId] = continuation
            logger.verbose("Registered pending request id=\(requestId), total pending: \(pendingRequests.count)", category: .websocket)

            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutInterval))
                await MainActor.run {
                    if let pending = self?.pendingRequests.removeValue(forKey: requestId) {
                        logger.error("Request timeout for \(operation) id=\(requestId) after \(timeoutInterval)s", category: .websocket)
                        pending.resume(throwing: EngineConnectionError.timeout)
                    }
                    self?.timeoutTasks.removeValue(forKey: requestId)
                }
            }
            timeoutTasks[requestId] = timeoutTask
        }
    }

    nonisolated static func engineTextMessage(from data: Data) -> URLSessionWebSocketTask.Message {
        .string(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Receive Loop

    private func handleSendTransportFailure(_ error: Error, operation: String) async {
        guard isConnectedFlag else { return }
        logger.warning("Send failure indicates connection loss for \(operation): \(error.localizedDescription)", category: .websocket)
        await handleDisconnect()
    }

    private func receiveLoop() async {
        logger.verbose("Receive loop running...", category: .websocket)
        var messageCount = 0

        while isConnectedFlag {
            do {
                guard let message = try await engineConnectionTask?.receive() else {
                    logger.warning("Receive returned nil, exiting loop", category: .websocket)
                    break
                }

                messageCount += 1
                let data: Data
                switch message {
                case .data(let d):
                    data = d
                    logger.verbose("Received binary message #\(messageCount): \(d.count) bytes", category: .websocket)
                case .string(let text):
                    guard let d = text.data(using: .utf8) else {
                        logger.warning("Failed to convert string message to data", category: .websocket)
                        continue
                    }
                    data = d
                    logger.verbose("Received string message #\(messageCount): \(text.prefix(200))", category: .websocket)
                @unknown default:
                    logger.warning("Received unknown message type", category: .websocket)
                    continue
                }

                handleMessage(data)

            } catch {
                if isConnectedFlag {
                    logger.error("Receive loop error: \(error.localizedDescription)", category: .websocket)
                    await handleDisconnect()
                } else {
                    logger.debug("Receive loop ended (disconnected)", category: .websocket)
                }
                break
            }
        }
        logger.verbose("Receive loop exited after \(messageCount) messages", category: .websocket)
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("Received non-JSON message: \(String(data: data, encoding: .utf8) ?? "binary")", category: .websocket)
            return
        }

        if let type = json["type"] as? String, type == "event" {
            guard let eventValue = json["event"],
                  JSONSerialization.isValidJSONObject(eventValue),
                  let eventData = try? JSONSerialization.data(withJSONObject: eventValue),
                  let event = try? JSONDecoder().decode(ServerEventPayload.self, from: eventData) else {
                logger.warning("Received malformed engine event frame", category: .websocket)
                return
            }
            #if DEBUG || BETA
            logger.logEvent(type: event.type, sessionId: event.sessionId, data: event.data.map { String(describing: $0.value).prefix(300).description })
            #endif
            let cursor = (json["cursor"] as? UInt64).map(EngineStreamCursor.init(rawValue:))
            let delivery = EngineEventDelivery(
                topic: json["topic"] as? String,
                subscriptionId: json["subscriptionId"] as? String,
                cursor: cursor,
                event: event,
                eventData: eventData
            )
            onEvent?(delivery)
        } else if let id = json["id"] as? String {
            // This is an engine response - cancel timeout task and resume continuation.
            timeoutTasks[id]?.cancel()
            timeoutTasks.removeValue(forKey: id)

            if let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(returning: data)
                #if DEBUG || BETA
                logger.debug("Resolved engine response for id=\(id), remaining pending: \(pendingRequests.count)", category: .websocket)
                #endif
            } else {
                logger.warning("Received response for unknown/expired id=\(id)", category: .websocket)
            }
        } else {
            logger.warning("Received message without id or type", category: .websocket)
        }
    }

    // MARK: - Heartbeat

    private func heartbeatLoop() async {
        logger.verbose("Heartbeat loop running (interval: \(String(format: "%.0f", Self.heartbeatInterval))s)...", category: .websocket)
        var pingCount = 0

        while isConnectedFlag {
            try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
            guard isConnectedFlag else { break }

            // Skip pings when in background to save battery and radio wake-ups
            if isInBackground {
                logger.verbose("Skipping ping - app in background", category: .websocket)
                continue
            }

            pingCount += 1
            do {
                guard let task = engineConnectionTask else {
                    throw EngineConnectionError.notConnected
                }
                let pingStart = CFAbsoluteTimeGetCurrent()
                try await sendPing(on: task, timeout: Self.connectionVerificationTimeout)
                let pingDuration = (CFAbsoluteTimeGetCurrent() - pingStart) * 1000
                logger.verbose("Ping #\(pingCount) successful (\(String(format: "%.1f", pingDuration))ms)", category: .websocket)

                // Reset reconnect attempts after first successful ping - connection is verified
                if reconnectAttempts > 0 {
                    logger.info("Connection verified via ping - resetting reconnect counter", category: .websocket)
                    reconnectAttempts = 0
                }
            } catch {
                logger.warning("Ping #\(pingCount) failed: \(error.localizedDescription)", category: .websocket)
                await handleDisconnect()
                break
            }
        }
        logger.verbose("Heartbeat loop exited after \(pingCount) pings", category: .websocket)
    }

    // MARK: - Pending Request Cleanup

    /// Fail all pending engine requests and cancel their timeout tasks.
    /// Shared between disconnect() (voluntary) and handleDisconnect() (involuntary).
    private func failPendingRequests(error: Error) {
        let pendingCount = pendingRequests.count
        for (id, continuation) in pendingRequests {
            logger.debug("Failing pending request id=\(id)", category: .websocket)
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()

        let timeoutCount = timeoutTasks.count
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        logger.debug("Cleared \(pendingCount) pending requests and \(timeoutCount) timeout tasks", category: .websocket)
    }

    // MARK: - Reconnection

    private func handleDisconnect() async {
        logger.warning("Handling disconnect...", category: .websocket)
        isConnectedFlag = false
        if !isDeployRestarting {
            connectionState = isInBackground
                ? .disconnected
                : .reconnecting(attempt: 1, nextRetrySeconds: 0)
        }
        openedWebSocketTask = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: EngineConnectionError.notConnected)
        openContinuation = nil
        engineConnectionTask?.cancel(with: .abnormalClosure, reason: nil)
        engineConnectionTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil

        failPendingRequests(error: EngineConnectionError.connectionFailed("Disconnected"))

        // Don't reconnect if in background
        if isInBackground {
            connectionState = .disconnected
            return
        }

        // Use deploy-aware reconnection if we received server.restarting
        if isDeployRestarting {
            reconnectTask = Task { [weak self] in
                await self?.startDeployReconnection()
            }
        } else {
            // Start the single normal reconnect probe in a tracked task.
            reconnectTask = Task { [weak self] in
                await self?.startReconnection()
            }
        }
    }

    /// Run one short automatic reconnect probe.
    /// After that probe fails, park in `.failed` so the user sees "not connected"
    /// until they manually retry or a deploy-aware reconnect is explicitly active.
    private func startReconnection() async {
        guard !isConnectedFlag && !isInBackground && !Task.isCancelled else { return }
        reconnectAttempts += 1

        guard reconnectAttempts <= reconnectPolicy.maxAutomaticAttempts else {
            logger.warning("Automatic reconnect probe budget exhausted - entering read-only mode", category: .websocket)
            reconnectAttempts = 0
            connectionState = .failed(reason: Self.failedAfterExhaustionReason)
            return
        }

        let reconnectingState = ConnectionState.reconnecting(
            attempt: reconnectAttempts,
            nextRetrySeconds: 0
        )
        logger.info(
            "Starting reconnect probe \(reconnectAttempts)/\(reconnectPolicy.maxAutomaticAttempts) (timeout: \(reconnectPolicy.probeTimeout)s)",
            category: .websocket
        )

        await connect(
            openTimeout: reconnectPolicy.probeTimeout,
            stateOnStart: reconnectingState,
            stateOnFailure: reconnectingState
        )

        if isConnectedFlag {
            reconnectAttempts = 0
            return
        }

        if case .unauthorized = connectionState {
            reconnectAttempts = 0
            return
        }

        guard !isInBackground && !Task.isCancelled else { return }

        logger.warning("Reconnect probe failed - entering read-only mode", category: .websocket)
        reconnectAttempts = 0
        connectionState = .failed(reason: Self.failedAfterExhaustionReason)
    }

    /// Deploy-aware reconnection — waits for the server to restart, then reconnects with more patience.
    /// Uses 10 attempts because `server.restarting` told us the server is expected to come back.
    private func startDeployReconnection() async {
        let maxDeployAttempts = 10
        let deployRetryDelay: TimeInterval = 3.0

        // Phase 1: Wait for the server to finish shutting down and restarting.
        // Show countdown during expected restart time.
        let totalWaitSeconds = max(1, (deployRestartExpectedMs + 5000) / 1000)
        logger.info("Deploy reconnection: waiting \(totalWaitSeconds)s for server restart", category: .websocket)

        var remainingSeconds = totalWaitSeconds
        while remainingSeconds > 0 && !Task.isCancelled {
            connectionState = .deployRestarting(remainingSeconds: remainingSeconds)
            try? await Task.sleep(for: .seconds(1))
            remainingSeconds -= 1
        }

        guard !Task.isCancelled else { return }
        connectionState = .deployRestarting(remainingSeconds: 0)

        // Phase 2: Attempt to reconnect.
        reconnectAttempts = 0
        while reconnectAttempts < maxDeployAttempts && !isConnectedFlag && !Task.isCancelled {
            reconnectAttempts += 1
            logger.info("Deploy reconnect attempt \(reconnectAttempts)/\(maxDeployAttempts)", category: .websocket)

            connectionState = .reconnecting(attempt: reconnectAttempts, nextRetrySeconds: 0)
            await connect()

            if isConnectedFlag {
                logger.info("Deploy reconnection successful on attempt \(reconnectAttempts)", category: .websocket)
                isDeployRestarting = false
                deployRestartExpectedMs = 0
                reconnectAttempts = 0
                return
            }

            // Wait before next attempt
            if reconnectAttempts < maxDeployAttempts && !Task.isCancelled {
                var delay = Int(deployRetryDelay)
                while delay > 0 && !isConnectedFlag && !Task.isCancelled {
                    connectionState = .reconnecting(attempt: reconnectAttempts, nextRetrySeconds: delay)
                    try? await Task.sleep(for: .seconds(1))
                    delay -= 1
                }
            }
        }

        // Exhausted all deploy reconnection attempts
        if !isConnectedFlag && !Task.isCancelled {
            logger.warning("Deploy reconnection failed after \(maxDeployAttempts) attempts", category: .websocket)
            isDeployRestarting = false
            deployRestartExpectedMs = 0
            connectionState = .failed(reason: "Server deploy failed - tap to retry")
        }
    }

    /// Manual retry triggered from UI — use the normal open timeout, not the
    /// short automatic reconnect probe, so cold Tailscale/device routes have
    /// enough time to establish before we park in `.failed`.
    func manualRetry() async {
        guard !isConnectedFlag && !isConnectionInProgress else {
            logger.debug("Manual retry ignored - already connected or connecting", category: .websocket)
            return
        }

        // Cancel any ongoing reconnection task to prevent races
        reconnectTask?.cancel()
        reconnectTask = nil

        // Reset attempt counter and deploy state for fresh connection
        reconnectAttempts = 0
        isDeployRestarting = false
        deployRestartExpectedMs = 0
        connectionState = .connecting
        logger.info("Manual retry triggered", category: .websocket)

        await connect(
            openTimeout: Self.manualRetryOpenTimeout,
            stateOnStart: .connecting,
            stateOnFailure: .failed(reason: Self.failedAfterExhaustionReason)
        )

        if case .unauthorized = connectionState {
            return
        }
    }
}

// MARK: - Engine Protocol Frames

private struct EngineHelloFrame: Encodable {
    let type = "hello"
    let id: String
    let protocolVersion: UInt64
    let clientName: String?
    let clientVersion: String?
    let sessionId: String?
    let workspaceId: String?
}

struct EngineHelloResult: Decodable, Equatable, Sendable {
    let type: String
    let id: String?
    let protocolVersion: UInt64
    let minimumSupportedVersion: UInt64
    let serverId: String
    let currentCatalogRevision: UInt64
}

private struct EngineFunctionCallFrame<P: Encodable>: Encodable {
    let type = "invoke"
    let id: String
    let functionId: String
    let payload: P
    let expectedRevision: UInt64?
    let idempotencyKey: String?
    let context: EngineInvocationContext?
}

private struct EngineSubscribeFrame: Encodable {
    let type = "subscribe"
    let id: String
    let topic: String
    let cursor: UInt64?
    let filters: [String: AnyCodable]?
    let limit: Int?
    let context: EngineInvocationContext?
}

private struct EnginePollFrame: Encodable {
    let type = "poll"
    let id: String
    let subscriptionId: String?
    let topic: String?
    let cursor: UInt64?
    let filters: [String: AnyCodable]?
    let limit: Int?
    let context: EngineInvocationContext?
}

private struct EngineAckFrame: Encodable {
    let type = "ack"
    let id: String
    let subscriptionId: String
    let cursor: UInt64
}

private struct EngineResponseEnvelope<R: Decodable>: Decodable {
    let type: String
    let id: String?
    let ok: Bool
    let result: R?
    let error: EngineProtocolError?
    let traceId: String?
    let catalogRevision: UInt64?
}

// MARK: - URLSession Delegate

/// `URLSession` + `URLSessionWebSocket` delegate that detects HTTP 401 on
/// the WS upgrade and routes the failure to `EngineConnection.markUnauthorized`.
///
/// URLSession retains its delegate; `EngineConnection` holds a strong
/// reference here so the delegate's lifetime tracks the session — and
/// `urlSession(_:didBecomeInvalidWithError:)` clears that reference when the
/// session is torn down (manual disconnect, retry, unauthorized).
final class EngineConnectionSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Stored as `weak` to avoid the URLSession ↔ delegate ↔ service retain
    /// cycle. `@unchecked Sendable` because Swift can't reason about the
    /// `weak` storage being safely accessed across actor boundaries — we
    /// hop to MainActor inside every callback before touching `owner`.
    private weak var ownerRef: EngineConnection?

    init(owner: EngineConnection) {
        self.ownerRef = owner
    }

    /// Snapshot the weak ref; the only caller is the `MainActor.run` body
    /// inside the URLSession callbacks below.
    @MainActor
    private func owner() -> EngineConnection? { ownerRef }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            owner()?.markWebSocketOpened(webSocketTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            await owner()?.markWebSocketClosed(webSocketTask, closeCode: closeCode)
        }
    }

    /// URLSession exposes failed WebSocket upgrade responses most reliably
    /// through task metrics. A 401 means the bearer token is
    /// wrong/missing/rotated — route to `markUnauthorized` so the state
    /// machine parks for re-pair.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        Task { @MainActor in
            owner()?.logWebSocketTaskMetrics(metrics)
        }
        for transaction in metrics.transactionMetrics {
            if let response = transaction.response {
                Task { @MainActor in
                    owner()?.logWebSocketUpgradeResponse(response)
                }
                record(response: response)
            }
        }
    }

    /// Some failed upgrades only expose their response at completion, so
    /// keep this as a second chance after metrics collection.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let response = task.response {
            Task { @MainActor in
                owner()?.logWebSocketUpgradeResponse(response)
            }
            record(response: response)
        }
        guard let error else { return }
        Task { @MainActor in
            owner()?.logWebSocketTaskCompletionError(error)
            owner()?.markWebSocketOpenFailed(task, error: error)
        }
    }

    private func record(response: URLResponse) {
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 401 else {
            return
        }
        Task { @MainActor in
            owner()?.markUnauthorized(reason: "Server rejected authentication")
        }
    }
}
