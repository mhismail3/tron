import Foundation

protocol GatewaySocketConnection: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
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
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        self.session = session
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
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
        session.invalidateAndCancel()
    }
}
