import Foundation

/// Result of a single `system::ping` engine probe. The four non-success cases
/// drive distinct UI affordances in the menu bar / wizard so the user
/// gets the right action ("re-pair" vs "wait for boot" vs "check
/// network").
///
/// INVARIANT: `ServerStatusPoller.singleSnapshot` MUST map ping
/// results into explicit menu-bar states:
/// - `.success` → `.running`
/// - `.unauthorized` → `.unauthorized`
/// - `.unreachable`, `.timeout`, `.malformedResponse` → ask launchd;
///   unloaded maps to `.paused`, loaded maps to `.failed(reason:)`.
enum ServerPingResult: Sendable, Equatable {
    case success(ServerPingInfo)
    case unauthorized
    case unreachable
    case timeout
    case malformedResponse
}

/// One-shot `system::ping` over the engine WebSocket protocol. Used by the install step's
/// "wait for server" loop AND by the menu bar's status poller.
enum ServerPing {
    static let requestID = "mac-system-ping"
    static let helloID = "mac-engine-hello"

    /// Performs a single ping with a default 3 s timeout. Classifies
    /// failures so the caller can render the right state without
    /// guessing.
    static func ping(host: String, port: Int, token: String?, timeout: TimeInterval = 3) async -> ServerPingResult {
        guard let url = URLComponents(string: "ws://\(host):\(port)/engine")?.url else {
            return .unreachable
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Delegate captures the HTTP upgrade status code so we can
        // distinguish a 401 rejection from a generic transport error.
        let capture = WSStatusCapture()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: capture,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let hello: [String: Any] = [
            "type": "hello",
            "id": helloID,
            "protocolVersion": 1,
            "clientName": "tron-mac",
            "clientVersion": "tron-mac-wrapper",
        ]
        let payload: [String: Any] = [
            "type": "invoke",
            "id": requestID,
            "functionId": "system::ping",
            "payload": [
                "protocolVersion": 1,
                "clientVersion": "tron-mac-wrapper",
            ]
        ]
        guard let helloData = try? JSONSerialization.data(withJSONObject: hello, options: []),
              let helloString = String(data: helloData, encoding: .utf8),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return .malformedResponse
        }

        do {
            try await task.send(.string(helloString))
            try await task.send(.string(str))

            var sawServerFrame = false
            for _ in 0..<8 {
                let message = try await task.receive()
                guard let raw = messageData(from: message) else {
                    return .malformedResponse
                }

                switch decodeFrame(data: raw) {
                case .result(let info):
                    return .success(info)
                case .ignore:
                    sawServerFrame = true
                    continue
                case .error:
                    return .malformedResponse
                case .malformed:
                    return .malformedResponse
                }
            }

            return sawServerFrame ? .unauthorized : .malformedResponse
        } catch {
            // Server returned a non-101 status during upgrade — most
            // commonly 401 when auth fails. The delegate captured it.
            if let status = capture.snapshotStatusCode(), status == 401 {
                return .unauthorized
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .userAuthenticationRequired:
                    return .unauthorized
                case .timedOut:
                    return .timeout
                case .cannotConnectToHost,
                     .cannotFindHost,
                     .networkConnectionLost,
                     .notConnectedToInternet,
                     .dnsLookupFailed:
                    return .unreachable
                case .badServerResponse:
                    // No status code captured but server replied with
                    // something non-WS. Treat as unauthorized (most
                    // likely cause: wrong/missing token); the menu bar
                    // gets the same recovery affordance either way.
                    return .unauthorized
                default:
                    return .unreachable
                }
            }
            return .unreachable
        }
    }

    enum ResponseFrame: Equatable {
        case result(ServerPingInfo)
        case ignore
        case error
        case malformed
    }

    private struct PingResponseFrame: Decodable {
        let type: String
        let id: String
        let ok: Bool
        let result: ResultFrame?

        struct ResultFrame: Decodable {
            let pong: Bool
            let timestamp: String
            let serverVersion: String
            let serverProtocolVersion: Int
            let minClientProtocolVersion: Int
            let compatible: Bool
        }
    }

    static func decodeFrame(
        data: Data,
        expectedID: String = requestID
    ) -> ResponseFrame {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return .malformed
        }
        guard responseID(json["id"], matches: expectedID) else {
            return .ignore
        }
        guard let frame = try? JSONDecoder().decode(PingResponseFrame.self, from: data),
              frame.type == "response",
              frame.id == expectedID else {
            return .malformed
        }
        if json["error"] != nil || !frame.ok {
            return .error
        }
        guard let value = frame.result,
              value.pong,
              !value.timestamp.isEmpty,
              !value.serverVersion.isEmpty,
              value.compatible else {
            return .malformed
        }
        return .result(ServerPingInfo(version: value.serverVersion))
    }

    private static func messageData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            return nil
        }
    }

    private static func responseID(_ value: Any?, matches expectedID: String) -> Bool {
        if let string = value as? String {
            return string == expectedID
        }
        return false
    }
}

/// Captures the HTTP upgrade response status code via the URLSession
/// delegate callbacks. Thread-safe via NSLock so it can be touched from
/// the URLSession's delegate queue and the awaiter.
private final class WSStatusCapture: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode: Int?

    func snapshotStatusCode() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return statusCode
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let http = task.response as? HTTPURLResponse {
            lock.lock()
            statusCode = http.statusCode
            lock.unlock()
        }
    }
}
