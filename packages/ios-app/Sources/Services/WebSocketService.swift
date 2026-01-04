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
    private let logger = Logger(subsystem: "com.tron.mobile", category: "WebSocket")

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
            logger.debug("Already connected, skipping connect request")
            return
        }

        connectionState = .connecting
        logger.info("Connecting to \(self.serverURL.absoluteString)")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300

        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: serverURL)
        request.timeoutInterval = 30

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        isConnectedFlag = true
        reconnectAttempts = 0
        connectionState = .connected
        logger.info("Connected successfully")

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        pingTask = Task { [weak self] in
            await self?.heartbeatLoop()
        }
    }

    func disconnect() {
        logger.info("Disconnecting")
        isConnectedFlag = false
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: WebSocketError.notConnected)
        }
        pendingRequests.removeAll()

        connectionState = .disconnected
    }

    // MARK: - Request/Response

    func send<P: Encodable, R: Decodable>(
        method: String,
        params: P
    ) async throws -> R {
        guard isConnectedFlag, let task = webSocketTask else {
            throw WebSocketError.notConnected
        }

        let request = RPCRequest(method: method, params: params)
        let requestId = request.id

        guard let data = try? JSONEncoder().encode(request) else {
            throw WebSocketError.encodingError
        }

        logger.debug("Sending: \(method) id=\(requestId)")

        let message = URLSessionWebSocketTask.Message.data(data)
        try await task.send(message)

        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingRequests[requestId] = continuation

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.requestTimeout ?? 30))
                await MainActor.run {
                    if let pending = self?.pendingRequests.removeValue(forKey: requestId) {
                        pending.resume(throwing: WebSocketError.timeout)
                    }
                }
            }
        }

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
        while isConnectedFlag {
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

                handleMessage(data)

            } catch {
                if isConnectedFlag {
                    logger.error("Receive error: \(error.localizedDescription)")
                    await handleDisconnect()
                }
                break
            }
        }
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("Received non-JSON message")
            return
        }

        if let id = json["id"] as? String {
            if let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(returning: data)
                logger.debug("Resolved response for id=\(id)")
            } else {
                logger.warning("Received response for unknown id=\(id)")
            }
        } else if json["type"] != nil {
            onEvent?(data)
        } else {
            logger.debug("Received message without id or type")
        }
    }

    // MARK: - Heartbeat

    private func heartbeatLoop() async {
        while isConnectedFlag {
            try? await Task.sleep(for: .seconds(30))
            guard isConnectedFlag else { break }

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
        isConnectedFlag = false
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: WebSocketError.connectionFailed("Disconnected"))
        }
        pendingRequests.removeAll()

        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = reconnectDelay * pow(1.5, Double(reconnectAttempts - 1))
            connectionState = .reconnecting(attempt: reconnectAttempts)

            logger.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempts))")
            try? await Task.sleep(for: .seconds(delay))

            if !isConnectedFlag {
                await connect()
            }
        } else {
            connectionState = .failed(reason: "Max reconnection attempts reached")
            logger.error("Max reconnection attempts reached")
        }
    }
}
