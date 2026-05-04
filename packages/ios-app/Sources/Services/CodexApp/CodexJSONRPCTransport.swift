import Foundation
import Observation

typealias CodexBearerTokenProvider = @MainActor () -> String?
typealias CodexWebSocketFactory = @MainActor (URLRequest) -> any CodexWebSocketTasking

protocol CodexWebSocketTasking: AnyObject, Sendable {
    var maximumMessageSize: Int { get set }

    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func sendPing() async throws
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

@MainActor
protocol CodexAppTransporting: AnyObject {
    var connectionState: ConnectionState { get }
    var onNotification: ((CodexJSONRPCNotification) -> Void)? { get set }
    var onServerRequest: ((CodexJSONRPCServerRequest) -> Void)? { get set }

    func connect() async throws
    func disconnect() async
    func send(method: String, params: [String: AnyCodable]?, timeout: TimeInterval?) async throws -> [String: AnyCodable]
    func notify(method: String, params: [String: AnyCodable]?) async throws
    func respond(_ response: CodexJSONRPCServerResponse) async throws
}

private final class CodexPendingRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: AnyCodable], Error>?

    init(_ continuation: CheckedContinuation<[String: AnyCodable], Error>) {
        self.continuation = continuation
    }

    func resume(returning value: [String: AnyCodable]) {
        resume(.success(value))
    }

    func resume(throwing error: Error) {
        resume(.failure(error))
    }

    private func resume(_ result: Result<[String: AnyCodable], Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

@Observable
@MainActor
final class CodexJSONRPCTransport: CodexAppTransporting {
    private let endpoint: CodexAppEndpoint
    private let bearerTokenProvider: CodexBearerTokenProvider?
    private let requestTimeout: TimeInterval
    private let webSocketFactory: CodexWebSocketFactory?

    @ObservationIgnored
    private var urlSession: URLSession?
    @ObservationIgnored
    private var webSocketTask: (any CodexWebSocketTasking)?
    @ObservationIgnored
    private var receiveTask: Task<Void, Never>?
    @ObservationIgnored
    private var timeoutTasks: [CodexJSONRPCID: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var pendingRequests: [CodexJSONRPCID: CodexPendingRequest] = [:]
    @ObservationIgnored
    private var requestCounter = 0
    @ObservationIgnored
    private var sessionDelegate: CodexWebSocketSessionDelegate?

    var connectionState: ConnectionState = .disconnected
    var onNotification: ((CodexJSONRPCNotification) -> Void)?
    var onServerRequest: ((CodexJSONRPCServerRequest) -> Void)?

    init(
        endpoint: CodexAppEndpoint,
        bearerTokenProvider: CodexBearerTokenProvider? = nil,
        requestTimeout: TimeInterval = 30,
        webSocketFactory: CodexWebSocketFactory? = nil
    ) {
        self.endpoint = endpoint
        self.bearerTokenProvider = bearerTokenProvider
        self.requestTimeout = requestTimeout
        self.webSocketFactory = webSocketFactory
    }

    func makeUpgradeRequest() -> URLRequest {
        var request = URLRequest(url: endpoint.url)
        request.timeoutInterval = 30
        if let token = bearerTokenProvider?(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func connect() async throws {
        if connectionState.isConnected { return }

        do {
            try endpoint.validateSecurity(token: bearerTokenProvider?(), allowInsecureLocalhost: true)
        } catch {
            connectionState = .unauthorized(reason: error.localizedDescription)
            throw error
        }

        connectionState = .connecting
        let upgradeRequest = makeUpgradeRequest()
        let task: any CodexWebSocketTasking
        if let webSocketFactory {
            task = webSocketFactory(upgradeRequest)
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            let delegate = CodexWebSocketSessionDelegate(owner: self)
            sessionDelegate = delegate
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            urlSession = session

            let urlSessionTask = session.webSocketTask(with: upgradeRequest)
            task = CodexURLSessionWebSocketTask(task: urlSessionTask)
        }
        task.maximumMessageSize = 150 * 1024 * 1024
        webSocketTask = task
        task.resume()

        do {
            try await verifyOpen(task)
            connectionState = .connected
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
        } catch {
            let unauthorizedReason: String? = {
                if case let .unauthorized(reason) = connectionState {
                    return reason
                }
                return nil
            }()
            await disconnect()
            if let unauthorizedReason {
                connectionState = .unauthorized(reason: unauthorizedReason)
                throw error
            }
            connectionState = .failed(reason: CodexAppSecretRedactor.redact(error.localizedDescription, token: bearerTokenProvider?()))
            throw error
        }
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
        for pending in pendingRequests.values {
            pending.resume(throwing: CodexTransportError.notConnected)
        }
        pendingRequests.removeAll()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil
        connectionState = .disconnected
    }

    func send(method: String, params: [String: AnyCodable]?, timeout: TimeInterval? = nil) async throws -> [String: AnyCodable] {
        guard connectionState.isConnected, let task = webSocketTask else {
            throw CodexTransportError.notConnected
        }

        let id = nextRequestID()
        let request = CodexJSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        let timeoutInterval = timeout ?? requestTimeout

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: AnyCodable], Error>) in
                let pending = CodexPendingRequest(continuation)
                pendingRequests[id] = pending
                timeoutTasks[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutInterval))
                    await MainActor.run {
                        guard let self, let pending = self.pendingRequests.removeValue(forKey: id) else { return }
                        self.timeoutTasks.removeValue(forKey: id)
                        pending.resume(throwing: CodexTransportError.timeout)
                    }
                }

                Task {
                    do {
                        try await task.send(.string(text))
                    } catch {
                        await MainActor.run {
                            self.timeoutTasks[id]?.cancel()
                            self.timeoutTasks.removeValue(forKey: id)
                            if let pending = self.pendingRequests.removeValue(forKey: id) {
                                pending.resume(throwing: CodexTransportError.requestFailed(error.localizedDescription))
                            }
                            self.connectionState = .failed(reason: CodexAppSecretRedactor.redact(error.localizedDescription, token: self.bearerTokenProvider?()))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.timeoutTasks[id]?.cancel()
                self?.timeoutTasks.removeValue(forKey: id)
                if let pending = self?.pendingRequests.removeValue(forKey: id) {
                    pending.resume(throwing: CancellationError())
                }
            }
        }
    }

    func notify(method: String, params: [String: AnyCodable]?) async throws {
        guard connectionState.isConnected, let task = webSocketTask else {
            throw CodexTransportError.notConnected
        }

        let notification = CodexJSONRPCNotification(method: method, params: params)
        let data = try JSONEncoder().encode(notification)
        try await task.send(.string(String(data: data, encoding: .utf8) ?? "{}"))
    }

    func respond(_ response: CodexJSONRPCServerResponse) async throws {
        guard connectionState.isConnected, let task = webSocketTask else {
            throw CodexTransportError.notConnected
        }

        let data = try JSONEncoder().encode(response)
        try await task.send(.string(String(data: data, encoding: .utf8) ?? "{}"))
    }

    func markUnauthorized(reason: String) {
        let redacted = CodexAppSecretRedactor.redact(reason, token: bearerTokenProvider?())
        connectionState = .unauthorized(reason: redacted)
        Task { await disconnectKeepingUnauthorized(reason: redacted) }
    }

    private func disconnectKeepingUnauthorized(reason: String) async {
        receiveTask?.cancel()
        receiveTask = nil
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil
        for pending in pendingRequests.values {
            pending.resume(throwing: CodexTransportError.unauthorized(reason))
        }
        pendingRequests.removeAll()
        connectionState = .unauthorized(reason: reason)
    }

    private func nextRequestID() -> CodexJSONRPCID {
        requestCounter += 1
        return .int(requestCounter)
    }

    private func verifyOpen(_ task: any CodexWebSocketTasking) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await task.sendPing()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CodexTransportError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func receiveLoop() async {
        while connectionState.isConnected || connectionState == .connecting {
            do {
                guard let message = try await webSocketTask?.receive() else { break }
                let data: Data
                switch message {
                case .data(let payload):
                    data = payload
                case .string(let text):
                    data = Data(text.utf8)
                @unknown default:
                    continue
                }
                handleMessage(data)
            } catch {
                if connectionState.isConnected {
                    connectionState = .failed(reason: CodexAppSecretRedactor.redact(error.localizedDescription, token: bearerTokenProvider?()))
                }
                break
            }
        }
    }

    private func handleMessage(_ data: Data) {
        do {
            switch try CodexInboundMessage.decode(data) {
            case .response(let response):
                handleResponse(response)
            case .notification(let notification):
                onNotification?(notification)
            case .serverRequest(let request):
                onServerRequest?(request)
            }
        } catch {
            TronLogger.shared.warning("Ignored malformed Codex App Server message: \(error.localizedDescription)", category: .network)
        }
    }

    private func handleResponse(_ response: CodexJSONRPCResponse) {
        timeoutTasks[response.id]?.cancel()
        timeoutTasks.removeValue(forKey: response.id)

        guard let pending = pendingRequests.removeValue(forKey: response.id) else {
            return
        }

        if let error = response.error {
            pending.resume(throwing: error)
        } else {
            pending.resume(returning: response.result ?? [:])
        }
    }
}

private final class CodexURLSessionWebSocketTask: CodexWebSocketTasking, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    var maximumMessageSize: Int {
        get { task.maximumMessageSize }
        set { task.maximumMessageSize = newValue }
    }

    func resume() {
        task.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }
}

private final class CodexWebSocketSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    weak var owner: CodexJSONRPCTransport?

    init(owner: CodexJSONRPCTransport) {
        self.owner = owner
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let response = task.response as? HTTPURLResponse,
              response.statusCode == 401
        else { return }

        Task { @MainActor [weak owner] in
            owner?.markUnauthorized(reason: "HTTP 401 during WebSocket upgrade")
        }
    }
}
