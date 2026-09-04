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

protocol GatewaySocketConnection: Sendable {
    func send(_ data: Data) async throws
    func ping() async throws
    func receive() async throws -> Data
    func close() async
}

enum GatewaySocketPolicy {
    // Application-owned handshake deadlines and transport-ping cadence are
    // shorter and monotonic. CFNetwork's inactivity timeout must not retire a healthy
    // long-lived WebSocket before those owners can make a decision.
    static let requestTimeout: TimeInterval = 60
    // A graceful close is best effort. A dead path must not retain an invalid
    // URLSession and its WebSocket buffers for the full inactivity timeout as
    // reconnect epochs accumulate.
    static let gracefulCloseLimit: Duration = .seconds(1)
}

struct GatewaySocketFactory: Sendable {
    let makeConnection: @Sendable (URLRequest) -> any GatewaySocketConnection

    static let urlSession = GatewaySocketFactory { request in
        URLSessionGatewaySocketConnection(request: request)
    }
}

/// A byte-only transport owner. Actor isolation confines the non-value
/// URLSession and WebSocket task to one Sendable owner under Swift 6.
private actor URLSessionGatewaySocketConnection: GatewaySocketConnection {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var closed = false
    private var activePing: GatewayPingCompletion?

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = GatewaySocketPolicy.requestTimeout
        let session = URLSession(configuration: configuration)
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
            try? await Task.sleep(for: GatewaySocketPolicy.gracefulCloseLimit)
            retiringSession.invalidateAndCancel()
        }
    }
}
