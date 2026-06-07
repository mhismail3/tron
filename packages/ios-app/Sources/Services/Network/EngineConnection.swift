import Foundation

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

    /// Retry while foreground so dev rebuilds and Mac restarts recover centrally.
    private let reconnectPolicy = ReconnectProbePolicy()

    private let requestTimeout: TimeInterval = 30.0
    nonisolated static let connectionVerificationTimeout: TimeInterval = 10.0
    nonisolated static let connectionOpenTimeout: TimeInterval = 10.0
    nonisolated static let manualRetryOpenTimeout: TimeInterval = connectionOpenTimeout
    nonisolated static let automaticReconnectProbeTimeout: TimeInterval = ReconnectProbePolicy().probeTimeout
    nonisolated static let automaticReconnectRetryDelay: TimeInterval = ReconnectProbePolicy().retryDelay
    nonisolated static let heartbeatInterval: TimeInterval = 5.0
    nonisolated static let failedAfterExhaustionReason = "Connection lost — tap to retry"

    private var reconnectTask: Task<Void, Never>?
    private var openedWebSocketTask: URLSessionWebSocketTask?
    private var openContinuation: SingleResumeContinuationBox?
    private var openTimeoutTask: Task<Void, Never>?

    private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    private var isConnectionInProgress = false

    private(set) var connectionState: ConnectionState = .disconnected

    /// Event callback with the decoded neutral payload plus stream cursor metadata.
    var onEvent: ((EngineEventDelivery) -> Void)?

    // MARK: - Background State

    private var isInBackground = false

    // MARK: - Deploy Restart State

    private var isDeployRestarting = false

    private var deployRestartExpectedMs: Int = 0

    /// Resolver invoked on every WS upgrade. `nil` sends no Authorization header.
    private let bearerTokenProvider: BearerTokenProvider?

    /// Held strongly so delegate lifetime tracks the session.
    private var sessionDelegate: EngineConnectionSessionDelegate?

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

    private func connect(
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
                let shouldRecoverConnection = await MainActor.run {
                    if let pending = self?.pendingRequests.removeValue(forKey: requestId) {
                        logger.error("Request timeout for \(operation) id=\(requestId) after \(timeoutInterval)s", category: .websocket)
                        pending.resume(throwing: EngineConnectionError.timeout)
                        self?.timeoutTasks.removeValue(forKey: requestId)
                        return true
                    }
                    self?.timeoutTasks.removeValue(forKey: requestId)
                    return false
                }
                if shouldRecoverConnection {
                    await self?.handleDisconnect()
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

        if isInBackground {
            connectionState = .disconnected
            return
        }

        if isDeployRestarting {
            reconnectTask = Task { [weak self] in
                await self?.startDeployReconnection()
            }
        } else {
            reconnectTask = Task { [weak self] in
                await self?.startReconnection()
            }
        }
    }

    /// Run foreground reconnect probes until the socket returns or parks.
    private func startReconnection() async {
        guard !isConnectedFlag && !isInBackground && !Task.isCancelled else { return }
        while !isConnectedFlag && !isInBackground && !Task.isCancelled {
            reconnectAttempts += 1

            if let maxAutomaticAttempts = reconnectPolicy.maxAutomaticAttempts,
               reconnectAttempts > maxAutomaticAttempts {
                logger.warning("Automatic reconnect probe budget exhausted - entering read-only mode", category: .websocket)
                reconnectAttempts = 0
                connectionState = .failed(reason: Self.failedAfterExhaustionReason)
                return
            }

            let reconnectingState = ConnectionState.reconnecting(
                attempt: reconnectAttempts,
                nextRetrySeconds: 0
            )
            let attemptBudget = reconnectPolicy.maxAutomaticAttempts.map { "\($0)" } ?? "unbounded"
            logger.info(
                "Starting reconnect probe \(reconnectAttempts)/\(attemptBudget) (timeout: \(reconnectPolicy.probeTimeout)s)",
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

            await waitBeforeNextReconnectProbe(attempt: reconnectAttempts)
        }
    }

    private func waitBeforeNextReconnectProbe(attempt: Int) async {
        let totalDelay = max(0, Int(ceil(reconnectPolicy.retryDelay)))
        guard totalDelay > 0 else { return }

        var remainingSeconds = totalDelay
        while remainingSeconds > 0 && !isConnectedFlag && !isInBackground && !Task.isCancelled {
            connectionState = .reconnecting(
                attempt: attempt,
                nextRetrySeconds: remainingSeconds
            )
            try? await Task.sleep(for: .seconds(1))
            remainingSeconds -= 1
        }
    }

    /// Wait for the deploy window, then reconnect with the patient deploy budget.
    private func startDeployReconnection() async {
        let maxDeployAttempts = 10
        let deployRetryDelay: TimeInterval = 3.0

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

            if reconnectAttempts < maxDeployAttempts && !Task.isCancelled {
                var delay = Int(deployRetryDelay)
                while delay > 0 && !isConnectedFlag && !Task.isCancelled {
                    connectionState = .reconnecting(attempt: reconnectAttempts, nextRetrySeconds: delay)
                    try? await Task.sleep(for: .seconds(1))
                    delay -= 1
                }
            }
        }

        if !isConnectedFlag && !Task.isCancelled {
            logger.warning("Deploy reconnection failed after \(maxDeployAttempts) attempts", category: .websocket)
            isDeployRestarting = false
            deployRestartExpectedMs = 0
            connectionState = .failed(reason: "Server deploy failed - tap to retry")
        }
    }

    /// Manual retry uses the normal open timeout for cold Tailscale/device routes.
    func manualRetry() async {
        guard !isConnectedFlag && !isConnectionInProgress else {
            logger.debug("Manual retry ignored - already connected or connecting", category: .websocket)
            return
        }

        reconnectTask?.cancel()
        reconnectTask = nil

        reconnectAttempts = 0
        isDeployRestarting = false
        deployRestartExpectedMs = 0
        connectionState = .connecting
        logger.info("Manual retry triggered", category: .websocket)

        await connect(
            openTimeout: Self.manualRetryOpenTimeout,
            stateOnStart: .connecting,
            stateOnFailure: .reconnecting(attempt: 0, nextRetrySeconds: 0)
        )

        if case .unauthorized = connectionState {
            return
        }

        if !isConnectedFlag && !isInBackground {
            reconnectTask = Task { [weak self] in
                await self?.startReconnection()
            }
        }
    }
}
