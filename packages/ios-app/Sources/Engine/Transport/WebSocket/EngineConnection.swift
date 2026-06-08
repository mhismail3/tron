import Foundation

// MARK: - WebSocket Service

@Observable
@MainActor
final class EngineConnection {

    var urlSession: URLSession?
    var engineConnectionTask: URLSessionWebSocketTask?
    var pingTask: Task<Void, Never>?
    var receiveTask: Task<Void, Never>?

    let serverURL: URL
    var isConnectedFlag = false
    var reconnectAttempts = 0

    /// Retry while foreground so dev rebuilds and Mac restarts recover centrally.
    let reconnectPolicy = ReconnectProbePolicy()

    let requestTimeout: TimeInterval = 30.0
    nonisolated static let connectionVerificationTimeout: TimeInterval = 10.0
    nonisolated static let connectionOpenTimeout: TimeInterval = 10.0
    nonisolated static let manualRetryOpenTimeout: TimeInterval = connectionOpenTimeout
    nonisolated static let automaticReconnectProbeTimeout: TimeInterval = ReconnectProbePolicy().probeTimeout
    nonisolated static let automaticReconnectRetryDelay: TimeInterval = ReconnectProbePolicy().retryDelay
    nonisolated static let heartbeatInterval: TimeInterval = 5.0
    nonisolated static let failedAfterExhaustionReason = "Connection lost — tap to retry"

    var reconnectTask: Task<Void, Never>?
    var openedWebSocketTask: URLSessionWebSocketTask?
    var openContinuation: SingleResumeContinuationBox?
    var openTimeoutTask: Task<Void, Never>?

    var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]
    var timeoutTasks: [String: Task<Void, Never>] = [:]

    var isConnectionInProgress = false

    var connectionState: ConnectionState = .disconnected

    /// Event callback with the decoded neutral payload plus stream cursor metadata.
    var onEvent: ((EngineEventDelivery) -> Void)?

    // MARK: - Background State

    var isInBackground = false

    // MARK: - Deploy Restart State

    var isDeployRestarting = false

    var deployRestartExpectedMs: Int = 0

    /// Resolver invoked on every WS upgrade. `nil` sends no Authorization header.
    let bearerTokenProvider: BearerTokenProvider?

    /// Held strongly so delegate lifetime tracks the session.
    var sessionDelegate: EngineConnectionSessionDelegate?

    init(serverURL: URL, bearerTokenProvider: BearerTokenProvider? = nil) {
        self.serverURL = serverURL
        self.bearerTokenProvider = bearerTokenProvider
    }

    /// Build the URLRequest used for the WS upgrade.
    func makeUpgradeRequest() -> URLRequest {
        var request = URLRequest(url: serverURL)
        request.timeoutInterval = 30
        if let token = bearerTokenProvider?() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Force the state machine into `.unauthorized(reason:)` until re-pair.
    func markUnauthorized(reason: String) {
        logger.warning("WS upgrade rejected (401): \(reason)", category: .websocket)

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

    func connect(
        openTimeout: TimeInterval,
        stateOnStart: ConnectionState,
        stateOnFailure: ConnectionState
    ) async {
        guard !isConnectionInProgress else {
            logger.debug("Connection already in progress, skipping", category: .websocket)
            return
        }

        guard !isConnectedFlag else {
            logger.debug("Already connected, skipping connect request", category: .websocket)
            return
        }

        isConnectionInProgress = true
        defer { isConnectionInProgress = false }

        connectionState = stateOnStart
        logger.logWebSocketState("Connecting", details: serverURL.absoluteString)
        logger.info("Connecting to \(self.serverURL.absoluteString)", category: .websocket)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        logger.verbose("URLSession config: requestTimeout=30s, resourceTimeout=300s", category: .websocket)

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
        task.maximumMessageSize = 150 * 1024 * 1024  // 150MB — matches server limit for large inline payloads.
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

    /// Pause heartbeat work and cancel in-flight reconnects while backgrounded.
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
                break
            }
        } else {
            logger.info("App returning to foreground - resuming heartbeats", category: .websocket)
        }
    }

    /// Signal that the server is about to restart for a deploy.
    func setDeployRestarting(expectedMs: Int) {
        isDeployRestarting = true
        deployRestartExpectedMs = expectedMs
        let totalExpectedSeconds = max(1, (expectedMs + 5000) / 1000) // server delay + startup buffer
        connectionState = .deployRestarting(remainingSeconds: totalExpectedSeconds)
        logger.info("Deploy restart signaled: expectedMs=\(expectedMs), totalExpected=\(totalExpectedSeconds)s", category: .websocket)
    }

    /// Verify connection liveness by pinging and cleaning up stale state on failure.
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

    func sendPing(on task: URLSessionWebSocketTask, timeout: TimeInterval) async throws {
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

}
