import Foundation

enum MenuBarLogReadError: Error, Equatable {
    case serverUnavailable
    case gatewayRequestFailed(String)
    case unreadableOutput(String)

    var message: String {
        switch self {
        case .serverUnavailable:
            return "Tron is not reachable."
        case .gatewayRequestFailed(let detail):
            return detail.isEmpty ? "The log request failed." : detail
        case .unreadableOutput(let detail):
            return detail
        }
    }
}

enum MenuBarLogReader {
    static let defaultLimit = 200
    static let requestID = "mac-system-logs"
    static let supportedProtocolVersion = TronGatewayProtocolContract.protocolVersion
    static let minimumProtocolVersion = TronGatewayProtocolContract.minimumProtocolVersion
    // Preserve URLSession's existing 1-MiB capacity: ordinary 200-record logs
    // can exceed the shared health probe's smaller 256-KiB admission limit.
    static let maximumFrameBytes = 1_048_576

    static func fetchRecentLogs(
        host: String,
        port: Int,
        token: String?,
        limit: Int = defaultLimit,
        timeout: TimeInterval = 5
    ) async -> Result<String, MenuBarLogReadError> {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty,
              let url = GatewaySocketURL.make(host: normalizedHost, port: port) else {
            return .failure(.serverUnavailable)
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            // One transport-owned deadline covers hello, send, and every read.
            // Cancellation closes the socket even while receive is suspended.
            let deadline = GatewayWebSocketTransport.Deadline(timeout: timeout)
            let connection = try await GatewayWebSocketTransport.connect(
                request: request,
                protocolVersion: supportedProtocolVersion,
                minimumProtocolVersion: minimumProtocolVersion,
                deadline: deadline,
                maximumFrameBytes: maximumFrameBytes
            )
            defer { connection.close() }
            try await connection.send(jsonObject: [
                "type": "request",
                "id": requestID,
                "method": "system.logs",
                "params": ["limit": limit],
            ], deadline: deadline)

            for _ in 0..<8 {
                guard let raw = try await connection.receiveData(deadline: deadline) else {
                    return .failure(.unreadableOutput("Could not read the log response."))
                }
                switch decodeFrame(data: raw) {
                case .result(let result):
                    return .success(format(result.records))
                case .ignore:
                    continue
                case .error(let message):
                    return .failure(.gatewayRequestFailed(message))
                case .malformed:
                    return .failure(.unreadableOutput("Unexpected log response."))
                }
            }
            return .failure(.serverUnavailable)
        } catch GatewayWebSocketTransport.Failure.invalidHello {
            return .failure(.unreadableOutput("Gateway protocol is not compatible."))
        } catch {
            // This best-effort API retains its existing nonthrowing failure
            // presentation; the transport has already retired cancelled work.
            return .failure(.serverUnavailable)
        }
    }

    enum ResponseFrame: Equatable {
        case result(RecentLogsResult)
        case ignore
        case error(String)
        case malformed
    }

    static func decodeFrame(data: Data, expectedID: String = requestID) -> ResponseFrame {
        let frame: GatewayResponseDecoder.Frame<RecentLogsResult> = GatewayResponseDecoder.decode(
            data: data,
            expectedID: expectedID
        )
        switch frame {
        case .result(let result):
            return .result(result)
        case .ignore:
            return .ignore
        case .error(let error):
            return .error(error?.message ?? "Log request failed")
        case .malformed:
            return .malformed
        }
    }

    static func format(_ records: [RecentLogEntry]) -> String {
        records.map { entry in
            "[\(entry.timestamp)] \(entry.level.uppercased()) TRON: \(entry.message)"
        }
        .joined(separator: "\n")
    }
}

struct RecentLogsResult: Decodable, Equatable {
    var records: [RecentLogEntry]
}

struct RecentLogEntry: Decodable, Equatable {
    var timestamp: String
    var level: String
    var message: String
}
