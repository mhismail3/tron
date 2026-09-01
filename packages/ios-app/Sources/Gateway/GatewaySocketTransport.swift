import Foundation

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
        // Enqueue the control frame without awaiting CFNetwork's callback.
        // URLSession does not guarantee that callback after cancellation, so
        // awaiting it would let one dead path retain the liveness task forever.
        // Server-side consecutive-miss policy owns pong timeout/retirement.
        task.sendPing { _ in }
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
