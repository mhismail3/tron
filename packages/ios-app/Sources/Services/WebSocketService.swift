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

    @Published private(set) var connectionState: ConnectionState = .disconnected

    var onEvent: ((Data) -> Void)?

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    // MARK: - Connection Management

    func connect() async {
        guard !isConnectedFlag else {
            log.debug("Already connected, skipping connect request", category: .websocket)
            return
        }

        connectionState = .connecting
        log.logWebSocketState("Connecting", details: serverURL.absoluteString)
        log.info("Connecting to \(self.serverURL.absoluteString)", category: .websocket)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        log.verbose("URLSession config: requestTimeout=30s, resourceTimeout=300s", category: .websocket)

        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: serverURL)
        request.timeoutInterval = 30

        log.verbose("Creating WebSocket task...", category: .websocket)
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        log.verbose("WebSocket task resumed", category: .websocket)

        isConnectedFlag = true
        reconnectAttempts = 0
        connectionState = .connected
        log.logWebSocketState("Connected", details: "Successfully connected to \(serverURL.host ?? "unknown")")
        log.info("Connected successfully to \(self.serverURL.absoluteString)", category: .websocket)

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        log.verbose("Receive loop started", category: .websocket)

        pingTask = Task { [weak self] in
            await self?.heartbeatLoop()
        }
        log.verbose("Heartbeat loop started", category: .websocket)
    }

    func disconnect() {
        log.logWebSocketState("Disconnecting")
        log.info("Disconnecting from server", category: .websocket)
        isConnectedFlag = false
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        let pendingCount = pendingRequests.count
        for (id, continuation) in pendingRequests {
            log.warning("Cancelling pending request id=\(id)", category: .websocket)
            continuation.resume(throwing: WebSocketError.notConnected)
        }
        pendingRequests.removeAll()
        log.debug("Cleared \(pendingCount) pending requests", category: .websocket)

        connectionState = .disconnected
        log.logWebSocketState("Disconnected")
    }

    // MARK: - Request/Response

    func send<P: Encodable, R: Decodable>(
        method: String,
        params: P
    ) async throws -> R {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard isConnectedFlag, let task = webSocketTask else {
            log.error("Cannot send \(method): not connected (isConnectedFlag=\(isConnectedFlag), task=\(webSocketTask != nil ? "exists" : "nil"))", category: .websocket)
            throw WebSocketError.notConnected
        }

        let request = RPCRequest(method: method, params: params)
        let requestId = request.id

        guard let data = try? JSONEncoder().encode(request) else {
            log.error("Failed to encode request for \(method)", category: .websocket)
            throw WebSocketError.encodingError
        }

        log.logRPCRequest(method: method, params: params, id: Int(requestId) ?? 0)
        log.logWebSocketMessage(direction: "→ SEND", type: method, size: data.count, preview: String(data: data, encoding: .utf8))

        let message = URLSessionWebSocketTask.Message.data(data)
        do {
            try await task.send(message)
            log.verbose("Message sent successfully for \(method) id=\(requestId)", category: .websocket)
        } catch {
            log.error("Failed to send message for \(method): \(error.localizedDescription)", category: .websocket)
            throw error
        }

        log.verbose("Waiting for response to \(method) id=\(requestId)...", category: .websocket)

        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingRequests[requestId] = continuation
            log.verbose("Registered pending request id=\(requestId), total pending: \(pendingRequests.count)", category: .websocket)

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.requestTimeout ?? 30))
                await MainActor.run {
                    if let pending = self?.pendingRequests.removeValue(forKey: requestId) {
                        log.error("Request timeout for \(method) id=\(requestId) after \(self?.requestTimeout ?? 30)s", category: .websocket)
                        pending.resume(throwing: WebSocketError.timeout)
                    }
                }
            }
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        log.logWebSocketMessage(direction: "← RECV", type: method, size: responseData.count, preview: String(data: responseData, encoding: .utf8))

        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode(RPCResponse<R>.self, from: responseData)
            if response.success, let result = response.result {
                log.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: true, duration: duration, result: result)
                return result
            } else if let error = response.error {
                log.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: false, duration: duration, error: error.message)
                throw error
            } else {
                log.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: false, duration: duration, error: "Invalid response structure")
                throw WebSocketError.invalidResponse
            }
        } catch let error as RPCError {
            log.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: false, duration: duration, error: error.message)
            throw error
        } catch let error as WebSocketError {
            log.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: false, duration: duration, error: error.localizedDescription)
            throw error
        } catch {
            log.logRPCResponse(method: method, id: Int(requestId) ?? 0, success: false, duration: duration, error: error.localizedDescription)
            throw WebSocketError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        log.verbose("Receive loop running...", category: .websocket)
        var messageCount = 0

        while isConnectedFlag {
            do {
                guard let message = try await webSocketTask?.receive() else {
                    log.warning("Receive returned nil, exiting loop", category: .websocket)
                    break
                }

                messageCount += 1
                let data: Data
                switch message {
                case .data(let d):
                    data = d
                    log.verbose("Received binary message #\(messageCount): \(d.count) bytes", category: .websocket)
                case .string(let text):
                    guard let d = text.data(using: .utf8) else {
                        log.warning("Failed to convert string message to data", category: .websocket)
                        continue
                    }
                    data = d
                    log.verbose("Received string message #\(messageCount): \(text.prefix(200))", category: .websocket)
                @unknown default:
                    log.warning("Received unknown message type", category: .websocket)
                    continue
                }

                handleMessage(data)

            } catch {
                if isConnectedFlag {
                    log.error("Receive loop error: \(error.localizedDescription)", category: .websocket)
                    await handleDisconnect()
                } else {
                    log.debug("Receive loop ended (disconnected)", category: .websocket)
                }
                break
            }
        }
        log.verbose("Receive loop exited after \(messageCount) messages", category: .websocket)
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.warning("Received non-JSON message: \(String(data: data, encoding: .utf8) ?? "binary")", category: .websocket)
            return
        }

        if let id = json["id"] as? String {
            // This is an RPC response
            if let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(returning: data)
                log.debug("Resolved RPC response for id=\(id), remaining pending: \(pendingRequests.count)", category: .websocket)
            } else {
                log.warning("Received response for unknown/expired id=\(id)", category: .websocket)
            }
        } else if let type = json["type"] as? String {
            // This is an event
            let sessionId = json["sessionId"] as? String
            let eventData = json["data"]
            log.logEvent(type: type, sessionId: sessionId, data: eventData.map { String(describing: $0).prefix(300).description })
            onEvent?(data)
        } else {
            log.debug("Received message without id or type: \(String(describing: json.keys))", category: .websocket)
        }
    }

    // MARK: - Heartbeat

    private func heartbeatLoop() async {
        log.verbose("Heartbeat loop running (interval: 30s)...", category: .websocket)
        var pingCount = 0

        while isConnectedFlag {
            try? await Task.sleep(for: .seconds(30))
            guard isConnectedFlag else { break }

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
                log.verbose("Ping #\(pingCount) successful (\(String(format: "%.1f", pingDuration))ms)", category: .websocket)
            } catch {
                log.warning("Ping #\(pingCount) failed: \(error.localizedDescription)", category: .websocket)
            }
        }
        log.verbose("Heartbeat loop exited after \(pingCount) pings", category: .websocket)
    }

    // MARK: - Reconnection

    private func handleDisconnect() async {
        log.warning("Handling disconnect...", category: .websocket)
        isConnectedFlag = false
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil

        let pendingCount = pendingRequests.count
        for (id, continuation) in pendingRequests {
            log.debug("Failing pending request id=\(id) due to disconnect", category: .websocket)
            continuation.resume(throwing: WebSocketError.connectionFailed("Disconnected"))
        }
        pendingRequests.removeAll()
        log.debug("Cleared \(pendingCount) pending requests due to disconnect", category: .websocket)

        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = reconnectDelay * pow(1.5, Double(reconnectAttempts - 1))
            connectionState = .reconnecting(attempt: reconnectAttempts)

            log.info("Reconnecting in \(String(format: "%.1f", delay))s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))", category: .websocket)
            try? await Task.sleep(for: .seconds(delay))

            if !isConnectedFlag {
                log.info("Starting reconnection attempt \(reconnectAttempts)...", category: .websocket)
                await connect()
            }
        } else {
            connectionState = .failed(reason: "Max reconnection attempts reached")
            log.error("Max reconnection attempts (\(maxReconnectAttempts)) reached, giving up", category: .websocket)
        }
    }
}
