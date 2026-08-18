import Foundation

struct HTTPDataTransport: Sendable {
    let dataForRequest: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await dataForRequest(request)
    }

    static let urlSession = HTTPDataTransport { request in
        try await BoundedURLSessionDataLoader.load(
            request,
            maximumBytes: GatewayPairingPolicy.maximumResponseBytes
        )
    }
}
