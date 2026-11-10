import Foundation

final class GatewayPingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var terminalResult: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        let terminal = terminalResult
        if terminal == nil { self.continuation = continuation }
        lock.unlock()
        if let terminal { continuation.resume(with: terminal) }
        return terminal == nil
    }

    func settle(_ result: Result<Void, Error>) {
        lock.lock()
        guard terminalResult == nil else { lock.unlock(); return }
        terminalResult = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() { settle(.failure(CancellationError())) }
}

package struct GatewaySocketMetadata: Sendable, Equatable {
    let closeCode: Int?
    let httpStatusCode: Int?

    package init(closeCode: Int?, httpStatusCode: Int?, transportOpenMilliseconds: Int? = nil, waitedForConnectivity: Bool = false, certificatePinRejected: Bool = false, closeReason: String? = nil) {
        self.closeCode = closeCode
        self.httpStatusCode = httpStatusCode
        self.transportOpenMilliseconds = transportOpenMilliseconds
        self.waitedForConnectivity = waitedForConnectivity
        self.certificatePinRejected = certificatePinRejected
        self.closeReason = closeReason
    }
    var transportOpenMilliseconds: Int? = nil
    var waitedForConnectivity = false
    var certificatePinRejected = false
    var closeReason: String? = nil
}

package protocol GatewaySocketConnection: Sendable {
    func send(_ data: Data) async throws
    func ping() async throws
    func receive() async throws -> Data
    func close() async
    func metadata() async -> GatewaySocketMetadata
}

extension GatewaySocketConnection {
    package func metadata() async -> GatewaySocketMetadata { GatewaySocketMetadata(closeCode: nil, httpStatusCode: nil) }
}


package struct GatewaySocketFactory: Sendable {
    let makeConnection: @Sendable (URLRequest, String?) -> any GatewaySocketConnection

    package init(makeConnection: @escaping @Sendable (URLRequest, String?) -> any GatewaySocketConnection) {
        self.makeConnection = makeConnection
    }

    package init(makeConnection: @escaping @Sendable (URLRequest) -> any GatewaySocketConnection) {
        self.init { request, _ in makeConnection(request) }
    }

    static let urlSession = GatewaySocketFactory { request, pin in
        URLSessionGatewaySocketConnection(request: request, pinnedPublicKey: pin)
    }
}

private final class GatewayWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var closeCode: Int?
    private var closeReason: String?
    private var httpStatusCode: Int?
    private let startedAt = ContinuousClock.now
    private var openedAt: ContinuousClock.Instant?
    private var waitedForConnectivity = false
    private var certificatePinRejected = false
    private let pinnedPublicKey: String?

    init(pinnedPublicKey: String?) {
        self.pinnedPublicKey = pinnedPublicKey
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let pinnedPublicKey,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard GatewayLanPin.admitsServerTrust(trust, pin: pinnedPublicKey) else {
            lock.lock(); certificatePinRejected = true; lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let now = ContinuousClock.now
        lock.lock(); if openedAt == nil { openedAt = now }; lock.unlock()
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        lock.lock(); waitedForConnectivity = true; lock.unlock()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        self.closeCode = closeCode.rawValue
        if let reason { self.closeReason = String(decoding: reason, as: UTF8.self) }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let response = task.response as? HTTPURLResponse {
            lock.lock(); httpStatusCode = response.statusCode; lock.unlock()
        }
    }

    func metadata() -> GatewaySocketMetadata {
        lock.lock(); defer { lock.unlock() }
        return GatewaySocketMetadata(
            closeCode: closeCode,
            httpStatusCode: httpStatusCode,
            transportOpenMilliseconds: openedAt.map { Self.milliseconds(startedAt.duration(to: $0)) },
            waitedForConnectivity: waitedForConnectivity,
            certificatePinRejected: certificatePinRejected,
            closeReason: closeReason
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return max(0, Int(components.seconds) * 1_000 + Int(components.attoseconds / 1_000_000_000_000_000))
    }
}

private actor URLSessionGatewaySocketConnection: GatewaySocketConnection {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let delegate: GatewayWebSocketDelegate
    private var closed = false
    private var activePing: GatewayPingCompletion?

    init(request: URLRequest, pinnedPublicKey: String? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = pinnedPublicKey == nil
        configuration.timeoutIntervalForRequest = GatewayConnectionPolicy.requestInactivityTimeout
        let delegate = GatewayWebSocketDelegate(pinnedPublicKey: pinnedPublicKey)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.delegate = delegate
        self.session = session
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func ping() async throws {
        guard !closed else { throw URLError(.cancelled) }
        let completion = GatewayPingCompletion()
        activePing = completion
        defer { if activePing === completion { activePing = nil } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard completion.install(continuation) else { return }
                task.sendPing { error in
                    completion.settle(
                        error.map { Result<Void, Error>.failure($0) }
                            ?? Result<Void, Error>.success(())
                    )
                }
            }
        } onCancel: {
            completion.cancel()
        }
    }

    func metadata() -> GatewaySocketMetadata {
        let observed = delegate.metadata()
        return GatewaySocketMetadata(
            closeCode: observed.closeCode ?? (task.closeCode == .invalid ? nil : task.closeCode.rawValue),
            httpStatusCode: observed.httpStatusCode ?? (task.response as? HTTPURLResponse)?.statusCode,
            transportOpenMilliseconds: observed.transportOpenMilliseconds,
            waitedForConnectivity: observed.waitedForConnectivity,
            certificatePinRejected: observed.certificatePinRejected,
            closeReason: observed.closeReason ?? task.closeReason.map { String(decoding: $0, as: UTF8.self) }
        )
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data):
            return data
        case .string(let value):
            return Data(value.utf8)
        @unknown default:
            return Data()
        }
    }

    func close() {
        activePing?.cancel()
        activePing = nil
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
        session.finishTasksAndInvalidate()
        let retiringSession = session
        Task.detached {
            try? await Task.sleep(for: GatewayConnectionPolicy.gracefulCloseLimit)
            retiringSession.invalidateAndCancel()
        }
    }
}
