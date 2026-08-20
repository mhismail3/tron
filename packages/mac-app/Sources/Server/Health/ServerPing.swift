import Foundation

/// Result of a single authenticated Tron Gateway probe. The four non-success cases
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

/// One-shot `system.info` request over the stable Tron Gateway protocol. Used
/// by the install step's "wait for Tron" loop and by the menu bar poller.
enum ServerPing {
    static let requestID = "mac-system-info"
    static let supportedProtocolVersion = 3
    static let minimumProtocolVersion = 3

    /// Performs a single ping with a default 3 s timeout. Classifies
    /// failures so the caller can render the right state without
    /// guessing.
    static func ping(host: String, port: Int, token: String?, timeout: TimeInterval = 3) async -> ServerPingResult {
        guard let url = socketURL(host: host, port: port) else {
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
            "protocolVersion": supportedProtocolVersion,
        ]
        let payload: [String: Any] = [
            "type": "request",
            "id": requestID,
            "method": "system.info",
            "params": [:],
        ]
        guard let helloData = try? JSONSerialization.data(withJSONObject: hello, options: []),
              let helloString = String(data: helloData, encoding: .utf8),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return .malformedResponse
        }

        do {
            // The Gateway requires the client hello before it emits its own
            // hello. Do not pipeline the request: accepting a response before
            // validating the server's transport version would turn an older or
            // incompatible peer into a false health result.
            try await task.send(.string(helloString))
            guard let serverHello = messageData(from: try await task.receive()),
                  decodeHello(data: serverHello) else {
                return .malformedResponse
            }
            try await task.send(.string(str))

            for _ in 0..<8 {
                let message = try await task.receive()
                guard let raw = messageData(from: message) else {
                    return .malformedResponse
                }

                switch decodeFrame(data: raw) {
                case .result(let info):
                    return .success(info)
                case .ignore:
                    continue
                case .error, .malformed:
                    return .malformedResponse
                }
            }

            return .malformedResponse
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

    static func socketURL(host: String, port: Int) -> URL? {
        GatewaySocketURL.make(host: host, port: port)
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
            let gatewayVersion: String
            let protocolVersion: Int
            let minProtocolVersion: Int
            let machineId: String
            let gatewayChannel: String
            let sourceRevision: String?
            let buildFingerprint: String?
            let runtimeEpoch: String?
        }
    }

    static func decodeHello(data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              json["type"] as? String == "hello",
              json["protocolVersion"] as? Int == supportedProtocolVersion,
              json["minProtocolVersion"] as? Int == minimumProtocolVersion else {
            return false
        }
        return true
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
              !value.gatewayVersion.isEmpty,
              value.protocolVersion == supportedProtocolVersion,
              value.minProtocolVersion == minimumProtocolVersion,
              !value.machineId.isEmpty,
              GatewayPayloadStore.validComponent(
                value.gatewayChannel,
                maximumLength: GatewayPayloadStore.channelComponentLimit
              ) else {
            return .malformed
        }
        return .result(ServerPingInfo(
            version: value.gatewayVersion,
            gatewayChannel: value.gatewayChannel,
            sourceRevision: value.sourceRevision,
            buildFingerprint: value.buildFingerprint,
            runtimeEpoch: value.runtimeEpoch
        ))
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

enum GatewaySocketURL {
    static func make(host: String, port: Int) -> URL? {
        guard !host.isEmpty, host.utf8.count <= 255, (1...65_535).contains(port),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        var components = URLComponents()
        components.scheme = "ws"
        if host.contains(":") {
            guard TailscaleProbe.isIPv6(host), !host.contains("[") && !host.contains("]") else { return nil }
            components.percentEncodedHost = "[\(host.lowercased())]"
        } else {
            components.host = host
        }
        components.port = port
        components.path = "/v1/socket"
        return components.url
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
