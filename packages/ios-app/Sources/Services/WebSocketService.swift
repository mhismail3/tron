import Foundation
import Combine
import os

// MARK: - Connection State

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))..."
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

// MARK: - WebSocket Errors

enum WebSocketError: Error, LocalizedError, Sendable {
    case notConnected
    case timeout
    case invalidResponse
    case connectionFailed(String)
    case encodingError
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .timeout: return "Request timed out"
        case .invalidResponse: return "Invalid response from server"
        case .connectionFailed(let reason): return "Connection failed: \(reason)"
        case .encodingError: return "Failed to encode request"
        case .decodingError(let detail): return "Failed to decode response: \(detail)"
        }
    }
}

// MARK: - WebSocket Service

@MainActor
final class WebSocketService: ObservableObject {

    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    private let serverURL: URL
    private var isConnectedFlag = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let reconnectDelay: TimeInterval = 2.0
    private let requestTimeout: TimeInterval = 30.0

    private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// Prevents concurrent connection attempts (race condition guard)
    private var isConnectionInProgress = false

    @Published private(set) var connectionState: ConnectionState = .disconnected

    var onEvent: ((Data) -> Void)?

    // MARK: - Background State

    /// Tracks whether the app is in the background to pause heartbeats and save battery
    /// Note: We only pause heartbeats, we don't disconnect - reconnecting is expensive and error-prone
    private var isInBackground = false

    init(serverURL: URL) {
        self.serverURL = serverURL
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

        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: serverURL)
        request.timeoutInterval = 30

        logger.verbose("Creating WebSocket task...", category: .websocket)
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        logger.verbose("WebSocket task resumed", category: .websocket)

        isConnectedFlag = true
        reconnectAttempts = 0
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
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        let pendingCount = pendingRequests.count
        for (id, continuation) in pendingRequests {
            logger.warning("Cancelling pending request id=\(id)", category: .websocket)
            continuation.resume(throwing: WebSocketError.notConnected)
        }
        pendingRequests.removeAll()

        // Cancel all timeout tasks
        let timeoutCount = timeoutTasks.count
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        logger.debug("Cleared \(pendingCount) pending requests and \(timeoutCount) timeout tasks", category: .websocket)

        connectionState = .disconnected
        logger.logWebSocketState("Disconnected")
    }

    /// Set background state to pause heartbeats and save battery
    /// Call this from scene phase changes in TronMobileApp
    /// Note: We only pause heartbeats, not disconnect - reconnecting is expensive
    func setBackgroundState(_ inBackground: Bool) {
        guard isInBackground != inBackground else { return }
        isInBackground = inBackground

        if inBackground {
            logger.info("App entering background - pausing heartbeats", category: .websocket)
        } else {
            logger.info("App returning to foreground - resuming heartbeats", category: .websocket)
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

        logger.logRPCRequest(method: method, params: params, id: Int(requestId) ?? 0)
        logger.logWebSocketMessage(direction: "→ SEND", type: method, size: data.count, preview: String(data: data, encoding: .utf8))

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
        logger.logWebSocketMessage(direction: "← RECV", type: method, size: responseData.count, preview: String(data: responseData, encoding: .utf8))

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
                logger.debug("Resolved RPC response for id=\(id), remaining pending: \(pendingRequests.count)", category: .websocket)
            } else {
                logger.warning("Received response for unknown/expired id=\(id)", category: .websocket)
            }
        } else if let type = json["type"] as? String {
            // This is an event
            let sessionId = json["sessionId"] as? String
            let eventData = json["data"]
            logger.logEvent(type: type, sessionId: sessionId, data: eventData.map { String(describing: $0).prefix(300).description })
            onEvent?(data)
        } else {
            logger.debug("Received message without id or type: \(String(describing: json.keys))", category: .websocket)
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
            } catch {
                logger.warning("Ping #\(pingCount) failed: \(error.localizedDescription)", category: .websocket)
            }
        }
        logger.verbose("Heartbeat loop exited after \(pingCount) pings", category: .websocket)
    }

    // MARK: - Reconnection

    private func handleDisconnect() async {
        logger.warning("Handling disconnect...", category: .websocket)
        isConnectedFlag = false
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil

        let pendingCount = pendingRequests.count
        for (id, continuation) in pendingRequests {
            logger.debug("Failing pending request id=\(id) due to disconnect", category: .websocket)
            continuation.resume(throwing: WebSocketError.connectionFailed("Disconnected"))
        }
        pendingRequests.removeAll()

        // Cancel all timeout tasks
        let timeoutCount = timeoutTasks.count
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        logger.debug("Cleared \(pendingCount) pending requests and \(timeoutCount) timeout tasks due to disconnect", category: .websocket)

        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = reconnectDelay * pow(1.5, Double(reconnectAttempts - 1))
            connectionState = .reconnecting(attempt: reconnectAttempts)

            logger.info("Reconnecting in \(String(format: "%.1f", delay))s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))", category: .websocket)
            try? await Task.sleep(for: .seconds(delay))

            if !isConnectedFlag {
                logger.info("Starting reconnection attempt \(reconnectAttempts)...", category: .websocket)
                await connect()
            }
        } else {
            connectionState = .failed(reason: "Max reconnection attempts reached")
            logger.error("Max reconnection attempts (\(maxReconnectAttempts)) reached, giving up", category: .websocket)
        }
    }
}
