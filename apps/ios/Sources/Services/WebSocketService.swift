import Foundation
import Combine
import os

// MARK: - Connection State

enum ConnectionState: Equatable {
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

enum WebSocketError: Error, LocalizedError {
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

actor WebSocketService {
    private let logger = Logger(subsystem: "com.tron.mobile", category: "WebSocket")

    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    private let serverURL: URL
    private var isConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let reconnectDelay: TimeInterval = 2.0
    private let requestTimeout: TimeInterval = 30.0

    // Pending requests awaiting responses
    private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]

    // Publishers for external observation
    nonisolated let eventSubject = PassthroughSubject<Data, Never>()
    nonisolated let connectionSubject = CurrentValueSubject<ConnectionState, Never>(.disconnected)

    nonisolated var events: AnyPublisher<Data, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    nonisolated var connectionState: AnyPublisher<ConnectionState, Never> {
        connectionSubject.eraseToAnyPublisher()
    }

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    // MARK: - Connection Management

    func connect() async {
        guard !isConnected else {
            logger.debug("Already connected, skipping connect request")
            return
        }

        connectionSubject.send(.connecting)
        logger.info("Connecting to \(self.serverURL.absoluteString)")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300

        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: serverURL)
        request.timeoutInterval = 30

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        isConnected = true
        reconnectAttempts = 0
        connectionSubject.send(.connected)
        logger.info("Connected successfully")

        // Start receive loop
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // Start heartbeat
        pingTask = Task { [weak self] in
            await self?.heartbeatLoop()
        }
    }

    func disconnect() {
        logger.info("Disconnecting")
        isConnected = false
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        // Fail all pending requests
        for (id, continuation) in pendingRequests {
            continuation.resume(throwing: WebSocketError.notConnected)
            pendingRequests.removeValue(forKey: id)
        }

        connectionSubject.send(.disconnected)
    }

    // MARK: - Request/Response

    func send<P: Encodable, R: Decodable>(
        method: String,
        params: P
    ) async throws -> R {
        guard isConnected, let task = webSocketTask else {
            throw WebSocketError.notConnected
        }

        let request = RPCRequest(method: method, params: params)
        let requestId = request.id

        guard let data = try? JSONEncoder().encode(request) else {
            throw WebSocketError.encodingError
        }

        logger.debug("Sending: \(method) id=\(requestId)")

        // Send the message
        let message = URLSessionWebSocketTask.Message.data(data)
        try await task.send(message)

        // Wait for response with timeout
        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingRequests[requestId] = continuation

            // Set up timeout
            Task {
                try? await Task.sleep(for: .seconds(requestTimeout))
                if let pending = await self.pendingRequests.removeValue(forKey: requestId) {
                    pending.resume(throwing: WebSocketError.timeout)
                }
            }
        }

        // Decode response
        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode(RPCResponse<R>.self, from: responseData)
            if response.success, let result = response.result {
                return result
            } else if let error = response.error {
                throw error
            } else {
                throw WebSocketError.invalidResponse
            }
        } catch let error as RPCError {
            throw error
        } catch let error as WebSocketError {
            throw error
        } catch {
            throw WebSocketError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        while isConnected {
            do {
                guard let message = try await webSocketTask?.receive() else {
                    logger.warning("Receive returned nil")
                    break
                }

                let data: Data
                switch message {
                case .data(let d):
                    data = d
                case .string(let text):
                    guard let d = text.data(using: .utf8) else { continue }
                    data = d
                @unknown default:
                    continue
                }

                await handleMessage(data)

            } catch {
                if isConnected {
                    logger.error("Receive error: \(error.localizedDescription)")
                    await handleDisconnect()
                }
                break
            }
        }
    }

    private func handleMessage(_ data: Data) async {
        // Check if it's a response (has 'id' field) or event (has 'type' field)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("Received non-JSON message")
            return
        }

        if let id = json["id"] as? String {
            // RPC Response - resolve pending request
            if let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(returning: data)
                logger.debug("Resolved response for id=\(id)")
            } else {
                logger.warning("Received response for unknown id=\(id)")
            }
        } else if json["type"] != nil {
            // Server Event - publish to subscribers
            eventSubject.send(data)
        } else {
            logger.debug("Received message without id or type")
        }
    }

    // MARK: - Heartbeat

    private func heartbeatLoop() async {
        while isConnected {
            try? await Task.sleep(for: .seconds(30))
            guard isConnected else { break }

            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    webSocketTask?.sendPing { error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
                logger.debug("Ping successful")
            } catch {
                logger.warning("Ping failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect() async {
        isConnected = false
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil

        // Fail pending requests
        for (id, continuation) in pendingRequests {
            continuation.resume(throwing: WebSocketError.connectionFailed("Disconnected"))
            pendingRequests.removeValue(forKey: id)
        }

        // Auto-reconnect with exponential backoff
        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = reconnectDelay * pow(1.5, Double(reconnectAttempts - 1))
            connectionSubject.send(.reconnecting(attempt: reconnectAttempts))

            logger.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempts))")
            try? await Task.sleep(for: .seconds(delay))

            if !isConnected {
                await connect()
            }
        } else {
            connectionSubject.send(.failed(reason: "Max reconnection attempts reached"))
            logger.error("Max reconnection attempts reached")
        }
    }

    // MARK: - State

    func getConnectionState() -> ConnectionState {
        connectionSubject.value
    }
}
