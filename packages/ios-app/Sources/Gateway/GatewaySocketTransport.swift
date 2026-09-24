import Foundation

final class GatewayPingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var terminalResult: Result<Void, Error>?

    /// Cancellation can precede continuation installation. Remember the winner
    /// and do not enqueue a ping when cancellation already owns completion.
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

struct GatewaySocketMetadata: Sendable, Equatable {
    let closeCode: Int?
    let httpStatusCode: Int?
    /// Milliseconds from task start until the WebSocket opened; nil when it
    /// never opened. Distinguishes a path that never reached the Mac from a
    /// Mac that accepted the socket but did not answer.
    var transportOpenMilliseconds: Int? = nil
    /// URLSession reported waiting for connectivity during this task.
    var waitedForConnectivity = false
}

protocol GatewaySocketConnection: Sendable {
    func send(_ data: Data) async throws
    func ping() async throws
    func receive() async throws -> Data
    func close() async
    func metadata() async -> GatewaySocketMetadata
}

extension GatewaySocketConnection {
    func metadata() async -> GatewaySocketMetadata { GatewaySocketMetadata(closeCode: nil, httpStatusCode: nil) }
}


struct GatewaySocketFactory: Sendable {
    let makeConnection: @Sendable (URLRequest) -> any GatewaySocketConnection

    static let urlSession = GatewaySocketFactory { request in
        URLSessionGatewaySocketConnection(request: request)
    }
}

/// A byte-only transport owner. Actor isolation confines the non-value
/// URLSession and WebSocket task to one Sendable owner under Swift 6.
private final class GatewayWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var closeCode: Int?
    private var httpStatusCode: Int?
    private let startedAt = ContinuousClock.now
    private var openedAt: ContinuousClock.Instant?
    private var waitedForConnectivity = false

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
        lock.lock(); self.closeCode = closeCode.rawValue; lock.unlock()
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
            waitedForConnectivity: waitedForConnectivity
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

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = GatewayConnectionPolicy.requestInactivityTimeout
        let delegate = GatewayWebSocketDelegate()
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
        // The caller owns a bounded timeout around this callback. Observing the
        // completion is important: enqueueing a ping is not proof that the
        // peer or path is alive. The completion owner also settles cancellation
        // and close, so a late/missing CFNetwork callback cannot retain a task.
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
            // The epoch owner decides transport retirement. Canceling a
            // completed/obsolete probe must not close a healthy socket later.
            completion.cancel()
        }
    }

    func metadata() -> GatewaySocketMetadata {
        let observed = delegate.metadata()
        // Async send/receive failure can resume before the delegate queue runs.
        // The exact URLSession task's immutable response/close facts are the
        // same authority, not a delay or a guess from localized error prose.
        return GatewaySocketMetadata(
            closeCode: observed.closeCode ?? (task.closeCode == .invalid ? nil : task.closeCode.rawValue),
            httpStatusCode: observed.httpStatusCode ?? (task.response as? HTTPURLResponse)?.statusCode,
            transportOpenMilliseconds: observed.transportOpenMilliseconds,
            waitedForConnectivity: observed.waitedForConnectivity
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
        // Allow a close frame a short opportunity to leave, then force release
        // of the one-task session. This preserves graceful teardown on healthy
        // paths without retaining dead CFNetwork epochs during reconnect loops.
        session.finishTasksAndInvalidate()
        let retiringSession = session
        Task.detached {
            try? await Task.sleep(for: GatewayConnectionPolicy.gracefulCloseLimit)
            retiringSession.invalidateAndCancel()
        }
    }
}
