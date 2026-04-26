import Foundation

// ARCHITECTURE: ~634 lines — connection state machine (7 states), reconnection strategies
// (normal + deploy-aware), heartbeat loop, message routing, and background state management.
// These are tightly coupled transport concerns that share connection state. Pragmatic trigger:
// if a third reconnection strategy is needed.

// MARK: - Connection State

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, nextRetrySeconds: Int)  // Enhanced with countdown
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

enum WebSocketError: Error, LocalizedError, Sendable, Equatable {
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
/// request. Returns `nil` if no token is available — the request goes out
/// without an Authorization header, the server returns 401 in enforced mode,
/// and `WebSocketService` transitions to `ConnectionState.unauthorized`.
typealias BearerTokenProvider = @MainActor () -> String?

// MARK: - WebSocket Service

@Observable
@MainActor
final class WebSocketService {

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    private let serverURL: URL
    private var isConnectedFlag = false
    private var reconnectAttempts = 0

    /// Reconnection backoff policy — exponential 2s / 4s / 8s across 3 attempts (14s total).
    private let backoff = BackoffPolicy()

    private let requestTimeout: TimeInterval = 30.0

    /// Task for reconnection (can be cancelled for manual retry)
    private var reconnectTask: Task<Void, Never>?

    private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// Prevents concurrent connection attempts (race condition guard)
    private var isConnectionInProgress = false

    private(set) var connectionState: ConnectionState = .disconnected

    /// Event callback with pre-extracted type and sessionId to avoid double JSON parsing.
    /// Parameters: (rawData, eventType, sessionId) — type/sessionId are nil for RPC responses.
    var onEvent: ((Data, String?, String?) -> Void)?

    // MARK: - Background State

    /// Tracks whether the app is in the background to pause heartbeats and save battery
    /// Note: We only pause heartbeats, we don't disconnect - reconnecting is expensive and error-prone
    private var isInBackground = false

    // MARK: - Deploy Restart State

    /// Set when the server broadcasts `server.restarting` before a deploy shutdown.
    /// Triggers patient reconnection instead of the normal 3-attempt reconnect.
    private var isDeployRestarting = false

    /// Expected total restart time in milliseconds (from server event).
    private var deployRestartExpectedMs: Int = 0

    /// Bearer token resolver invoked on every WS upgrade. `nil` means "send
    /// no Authorization header" — used by presets that have not completed
    /// bearer pairing on this device.
    private let bearerTokenProvider: BearerTokenProvider?

    /// URLSession delegate that notices HTTP 401 on the upgrade and routes
    /// to `markUnauthorized(reason:)`. Held strong here because URLSession
    /// keeps a strong reference to its delegate; we own the lifetime so the
    /// session can be torn down cleanly on disconnect.
    private var sessionDelegate: WebSocketSessionDelegate?

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
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil
        pingTask?.cancel(); pingTask = nil
        receiveTask?.cancel(); receiveTask = nil

        failPendingRequests(error: WebSocketError.unauthorized(reason))

        connectionState = .unauthorized(reason: reason)
    }

    // MARK: - Connection Management

    func connect() async {
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

        connectionState = .connecting
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
        let delegate = WebSocketSessionDelegate(owner: self)
        sessionDelegate = delegate

        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        urlSession = session

        let request = makeUpgradeRequest()

        logger.verbose("Creating WebSocket task...", category: .websocket)
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.maximumMessageSize = 150 * 1024 * 1024  // 150MB — matches server limit; covers 15-min voice notes at 48kHz (~115MB base64)
        webSocketTask?.resume()
        logger.verbose("WebSocket task resumed", category: .websocket)

        // Mark as connected optimistically - the receive loop will detect failures quickly
        // Note: We do NOT reset reconnectAttempts here because we don't know if connection is real yet.
        // It gets reset after a successful ping verifies the connection, or on manual retry.
        isConnectedFlag = true
        connectionState = .connected
        logger.logWebSocketState("Connected", details: "Successfully connected to \(serverURL.host ?? "unknown")")
        logger.info("Connected successfully to \(self.serverURL.absoluteString)", category: .websocket)

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        logger.verbose("Receive loop started", category: .websocket)

        pingTask = Task { [weak self] in
            await self?.heartbeatLoop()
        }
        logger.verbose("Heartbeat loop started", category: .websocket)
    }

    func disconnect() {
        logger.logWebSocketState("Disconnecting")
        logger.info("Disconnecting from server", category: .websocket)
        isConnectedFlag = false
        isDeployRestarting = false
        deployRestartExpectedMs = 0

        // Cancel all background tasks
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        failPendingRequests(error: WebSocketError.notConnected)

        connectionState = .disconnected
        logger.logWebSocketState("Disconnected")
    }

    /// Set background state to pause heartbeats and save battery.
    /// Call this from scene phase changes in TronMobileApp.
    ///
    /// Note: We only pause heartbeats for a live `.connected` socket — reconnecting is
    /// expensive so we don't want to tear that down on every backgrounding.
    ///
    /// When backgrounding MID-RECONNECT however, we must clean up: the reconnect Task's
    /// countdown loop guards on `!isInBackground` and exits silently, leaving the state
    /// frozen at e.g. `.reconnecting(attempt: 2, nextRetrySeconds: 2)`. If we then return
    /// to foreground, the scene-phase handler would see `.reconnecting` and believe a
    /// reconnect is already in flight when nothing is actually running. Cancel the Task
    /// and reset to `.disconnected` so the foreground handler triggers a fresh retry.
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
        guard isConnectedFlag, let task = webSocketTask else {
            return false
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            logger.debug("Connection verification: alive", category: .websocket)
            return true
        } catch {
            logger.warning("Connection verification failed: \(error.localizedDescription)", category: .websocket)
            // Connection is dead - clean up stale state
            isConnectedFlag = false
            connectionState = .disconnected
            webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
            webSocketTask = nil
            return false
        }
    }

    // MARK: - Request/Response

    func send<P: Encodable, R: Decodable>(
        method: String,
        params: P,
        timeout: TimeInterval? = nil
    ) async throws -> R {
        let startTime = CFAbsoluteTimeGetCurrent()
        let timeoutInterval = timeout ?? requestTimeout

        guard isConnectedFlag, let task = webSocketTask else {
            logger.error("Cannot send \(method): not connected (isConnectedFlag=\(isConnectedFlag), task=\(webSocketTask != nil ? "exists" : "nil"))", category: .websocket)
            throw WebSocketError.notConnected
        }

        let request = RPCRequest(method: method, params: params)
        let requestId = request.id

        guard let data = try? JSONEncoder().encode(request) else {
            logger.error("Failed to encode request for \(method)", category: .websocket)
            throw WebSocketError.encodingError
        }

        #if DEBUG || BETA
        logger.logRPCRequest(method: method, params: params, id: Int(requestId) ?? 0)
        logger.logWebSocketMessage(direction: "→ SEND", type: method, size: data.count, preview: String(data: data, encoding: .utf8))
        #endif

        let message = URLSessionWebSocketTask.Message.data(data)
        do {
            try await task.send(message)
            logger.verbose("Message sent successfully for \(method) id=\(requestId)", category: .websocket)
        } catch {
            logger.error("Failed to send message for \(method): \(error.localizedDescription)", category: .websocket)
            throw error
        }

        logger.verbose("Waiting for response to \(method) id=\(requestId)...", category: .websocket)

        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingRequests[requestId] = continuation
            logger.verbose("Registered pending request id=\(requestId), total pending: \(pendingRequests.count)", category: .websocket)

            // Store timeout task so it can be cancelled when response arrives
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutInterval))
                await MainActor.run {
                    if let pending = self?.pendingRequests.removeValue(forKey: requestId) {
                        logger.error("Request timeout for \(method) id=\(requestId) after \(timeoutInterval)s", category: .websocket)
                        pending.resume(throwing: WebSocketError.timeout)
                    }
                    self?.timeoutTasks.removeValue(forKey: requestId)
                }
            }
            timeoutTasks[requestId] = timeoutTask
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        #if DEBUG || BETA
        logger.logWebSocketMessage(direction: "← RECV", type: method, size: responseData.count, preview: String(data: responseData, encoding: .utf8))
        #endif

        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode(RPCResponse<R>.self, from: responseData)
            if response.success, let result = response.result {
                logger.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: true, duration: duration, result: result)
                return result
            } else if let error = response.error {
                logger.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: false, duration: duration, error: error.message)
                throw error
            } else {
                logger.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: false, duration: duration, error: "Invalid response structure")
                throw WebSocketError.invalidResponse
            }
        } catch let error as RPCError {
            logger.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: false, duration: duration, error: error.message)
            throw error
        } catch let error as WebSocketError {
            logger.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: false, duration: duration, error: error.localizedDescription)
            throw error
        } catch {
            logger.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: false, duration: duration, error: error.localizedDescription)
            throw WebSocketError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        logger.verbose("Receive loop running...", category: .websocket)
        var messageCount = 0

        while isConnectedFlag {
            do {
                guard let message = try await webSocketTask?.receive() else {
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

        if let id = json["id"] as? String {
            // This is an RPC response - cancel timeout task and resume continuation
            timeoutTasks[id]?.cancel()
            timeoutTasks.removeValue(forKey: id)

            if let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(returning: data)
                #if DEBUG || BETA
                logger.debug("Resolved RPC response for id=\(id), remaining pending: \(pendingRequests.count)", category: .websocket)
                #endif
            } else {
                logger.warning("Received response for unknown/expired id=\(id)", category: .websocket)
            }
        } else if let type = json["type"] as? String {
            let sessionId = json["sessionId"] as? String
            #if DEBUG || BETA
            let eventData = json["data"]
            logger.logEvent(type: type, sessionId: sessionId, data: eventData.map { String(describing: $0).prefix(300).description })
            #endif
            onEvent?(data, type, sessionId)
        } else {
            logger.warning("Received message without id or type", category: .websocket)
        }
    }

    // MARK: - Heartbeat

    private func heartbeatLoop() async {
        logger.verbose("Heartbeat loop running (interval: 30s)...", category: .websocket)
        var pingCount = 0

        while isConnectedFlag {
            try? await Task.sleep(for: .seconds(30))
            guard isConnectedFlag else { break }

            // Skip pings when in background to save battery and radio wake-ups
            if isInBackground {
                logger.verbose("Skipping ping - app in background", category: .websocket)
                continue
            }

            pingCount += 1
            do {
                let pingStart = CFAbsoluteTimeGetCurrent()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    webSocketTask?.sendPing { error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
                let pingDuration = (CFAbsoluteTimeGetCurrent() - pingStart) * 1000
                logger.verbose("Ping #\(pingCount) successful (\(String(format: "%.1f", pingDuration))ms)", category: .websocket)

                // Reset reconnect attempts after first successful ping - connection is verified
                if reconnectAttempts > 0 {
                    logger.info("Connection verified via ping - resetting reconnect counter", category: .websocket)
                    reconnectAttempts = 0
                }
            } catch {
                logger.warning("Ping #\(pingCount) failed: \(error.localizedDescription)", category: .websocket)
            }
        }
        logger.verbose("Heartbeat loop exited after \(pingCount) pings", category: .websocket)
    }

    // MARK: - Pending Request Cleanup

    /// Fail all pending RPC requests and cancel their timeout tasks.
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
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil

        failPendingRequests(error: WebSocketError.connectionFailed("Disconnected"))

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
            // Start persistent reconnection in a tracked task
            reconnectTask = Task { [weak self] in
                await self?.startReconnection()
            }
        }
    }

    /// Exponential reconnection across `backoff.maxAttempts` attempts.
    /// After all attempts exhausted, sets state to .failed for read-only mode.
    /// User can tap the pill to trigger `manualRetry()` which resets the attempt counter.
    private func startReconnection() async {
        reconnectAttempts += 1

        // Check if we've exhausted all attempts
        if reconnectAttempts > backoff.maxAttempts {
            logger.warning("Max reconnection attempts (\(backoff.maxAttempts)) exhausted - entering read-only mode", category: .websocket)
            connectionState = .failed(reason: "Connection lost — tap to retry")
            return
        }

        // Delay scales exponentially per attempt (2s, 4s, 8s — no jitter).
        let delaySeconds = Int(backoff.delay(forAttempt: reconnectAttempts).rounded(.up))
        logger.info("Reconnecting in \(delaySeconds)s (attempt \(reconnectAttempts)/\(backoff.maxAttempts))", category: .websocket)

        // Countdown loop - updates UI every second
        var remainingSeconds = delaySeconds
        while remainingSeconds > 0 && !isConnectedFlag && !isInBackground && !Task.isCancelled {
            connectionState = .reconnecting(attempt: reconnectAttempts, nextRetrySeconds: remainingSeconds)
            try? await Task.sleep(for: .seconds(1))
            remainingSeconds -= 1
        }

        // Check if we should continue (cancelled, connected, or in background)
        guard !isConnectedFlag && !isInBackground && !Task.isCancelled else { return }

        // Update to show 0 seconds remaining / attempting
        connectionState = .reconnecting(attempt: reconnectAttempts, nextRetrySeconds: 0)

        // Attempt to connect
        await connect()

        // If connect() didn't succeed (isConnectedFlag still false), try next attempt
        if !isConnectedFlag && !isInBackground && !Task.isCancelled {
            await startReconnection()
        }
    }

    /// Deploy-aware reconnection — waits for the server to restart, then reconnects with more patience.
    /// Uses 10 attempts (vs 3 for normal) with 3s delays (vs 5s) since we know the server is coming back.
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

    /// Manual retry triggered from UI - resets attempt counter for fresh backoff
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

        await connect()

        // If connection failed, start persistent reconnection in tracked task
        if !isConnectedFlag && !isInBackground {
            reconnectTask = Task { [weak self] in
                await self?.startReconnection()
            }
        }
    }
}

// MARK: - URLSession Delegate

/// `URLSession` + `URLSessionWebSocket` delegate that detects HTTP 401 on
/// the WS upgrade and routes the failure to `WebSocketService.markUnauthorized`.
///
/// URLSession retains its delegate; `WebSocketService` holds a strong
/// reference here so the delegate's lifetime tracks the session — and
/// `urlSession(_:didBecomeInvalidWithError:)` clears that reference when the
/// session is torn down (manual disconnect, retry, unauthorized).
final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Stored as `weak` to avoid the URLSession ↔ delegate ↔ service retain
    /// cycle. `@unchecked Sendable` because Swift can't reason about the
    /// `weak` storage being safely accessed across actor boundaries — we
    /// hop to MainActor inside every callback before touching `owner`.
    private weak var ownerRef: WebSocketService?

    init(owner: WebSocketService) {
        self.ownerRef = owner
    }

    /// Snapshot the weak ref; the only caller is the `MainActor.run` body
    /// inside the URLSession callbacks below.
    @MainActor
    private func owner() -> WebSocketService? { ownerRef }

    /// URLSession exposes failed WebSocket upgrade responses most reliably
    /// through task metrics. A 401 means the bearer token is
    /// wrong/missing/rotated — route to `markUnauthorized` so the state
    /// machine parks for re-pair.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        for transaction in metrics.transactionMetrics {
            if let response = transaction.response {
                record(response: response)
            }
        }
    }

    /// Some failed upgrades only expose their response at completion, so
    /// keep this as a second chance after metrics collection.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let response = task.response {
            record(response: response)
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
