import Foundation
import Network

/// Lightweight TCP listener that intercepts an OAuth loopback redirect
/// (`http://localhost:<port>?code=...`) and responds with an HTTP 302
/// to a custom URL scheme so ASWebAuthenticationSession can auto-close.
@MainActor
final class OAuthLoopbackServer {
    private var listener: NWListener?
    private let port: UInt16
    private let redirectScheme: String

    init(port: UInt16, redirectScheme: String) {
        self.port = port
        self.redirectScheme = redirectScheme
    }

    func start() throws {
        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OAuthLoopbackError.invalidPort
        }
        listener = try NWListener(using: params, on: nwPort)
        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let data,
                      let request = String(data: data, encoding: .utf8),
                      let firstLine = request.components(separatedBy: "\r\n").first else {
                    connection.cancel()
                    return
                }

                // Parse "GET /?code=...&scope=... HTTP/1.1"
                let parts = firstLine.components(separatedBy: " ")
                guard parts.count >= 2,
                      let url = URL(string: "http://localhost\(parts[1])"),
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    connection.cancel()
                    return
                }

                // Forward all query params to the custom scheme redirect
                var redirect = URLComponents()
                redirect.scheme = self.redirectScheme
                redirect.host = "callback"
                redirect.queryItems = components.queryItems

                let location = redirect.url?.absoluteString ?? "\(self.redirectScheme)://callback"
                let response = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\n\r\n"

                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })

                self.stop()
            }
        }
    }
}

enum OAuthLoopbackError: LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "Invalid loopback port"
        }
    }
}
