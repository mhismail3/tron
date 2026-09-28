import Foundation
import TronMobileCore

package struct HTTPDataTransport: Sendable {
    package let dataForRequest: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    package func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await dataForRequest(request)
    }

    package static let urlSession = HTTPDataTransport { request in
        try await BoundedURLSessionDataLoader.load(
            request,
            maximumBytes: GatewayPairingPolicy.maximumResponseBytes
        )
    }
}
