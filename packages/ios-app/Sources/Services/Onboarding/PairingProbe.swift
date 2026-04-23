import Foundation

/// Result of one PairingProbe attempt — narrow enum so the caller can
/// branch on every outcome without inspecting NSError details.
enum PairingProbeOutcome: Equatable {
    /// `system.ping` returned success. The optional `serverVersion` lets
    /// the UI confirm "you're talking to Tron 0.5.0".
    case ok(serverVersion: String?)
    /// HTTP 401 on the WebSocket upgrade — bearer wrong/missing/rotated.
    case unauthorized
    /// `system.ping` returned `CLIENT_VERSION_UNSUPPORTED`. The
    /// `serverVersion` flows into the user-facing error message so the
    /// UI can say "Update to v0.6.0 on your Mac". `"unknown"` when the
    /// server didn't include the version in `details`.
    case incompatible(serverVersion: String)
    /// Anything else — connection refused, DNS failure, malformed RPC
    /// envelope. The `reason` is best-effort prose for diagnostics.
    case unreachable(reason: String)

    /// Bridge to the existing `PairingStepConnectError` taxonomy used by
    /// `PairingStepValidator.classify(error:hostHint:)`. `.ok` returns
    /// `nil` because there's no error to bridge.
    func toConnectError() -> PairingStepConnectError? {
        switch self {
        case .ok:
            return nil
        case .unauthorized:
            return .unauthorized
        case .incompatible(let serverVersion):
            return .incompatible(serverVersion: serverVersion)
        case .unreachable(let reason):
            return .network(NSError(
                domain: "PairingProbe",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: reason]
            ))
        }
    }
}

/// Probe contract used by the onboarding PairingStep to verify a (host,
/// port, token) tuple before committing it. Mocked in tests via
/// `StubPairingProbe`; production uses `URLSessionPairingProbe`.
@MainActor
protocol PairingProbing: Sendable {
    /// Fire one probe and resolve to a classified outcome. Never throws —
    /// all failures are wrapped in `.unreachable` / `.unauthorized` /
    /// `.incompatible`. The view layer can then either commit the pairing
    /// or surface the matching `PairingStepValidator.Failure`.
    func probe(host: String, port: Int, token: String) async -> PairingProbeOutcome
}

// MARK: - Production implementation

/// Concrete `PairingProbing` backed by `URLSessionWebSocketTask`. Opens
/// one upgrade with `Authorization: Bearer <token>`, sends a
/// `system.ping`, and waits up to 10s for a single response.
///
/// The probe deliberately uses its own `URLSession` (not the shared one
/// owned by `WebSocketService`) so there is **no chance** of mutating
/// the live connection state of the active server while onboarding is
/// in flight. The session is invalidated on the way out.
@MainActor
final class URLSessionPairingProbe: PairingProbing {

    /// Wire timeout. The probe is interactive — if the server hasn't
    /// responded in 10s the user wants to know now, not after the
    /// 30s heartbeat budget.
    private let probeTimeout: TimeInterval

    init(probeTimeout: TimeInterval = 10) {
        self.probeTimeout = probeTimeout
    }

    func probe(host: String, port: Int, token: String) async -> PairingProbeOutcome {
        guard let url = URL(string: Self.urlString(host: host, port: port)) else {
            return .unreachable(reason: "Invalid host or port")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = probeTimeout
        configuration.timeoutIntervalForResource = probeTimeout

        // Use a delegate to spot HTTP 401 on the upgrade response — the
        // WS task's `receive()` won't surface the status code directly.
        let delegate = ProbeSessionDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: request)
        task.resume()

        let payload = Self.pingRequestData(
            protocolVersion: 1,
            clientVersion: AppConstants.appVersion,
            requestId: UUID().uuidString
        )

        do {
            try await task.send(.data(payload))
        } catch {
            // Most likely a connection-refused or 401 — drain the delegate.
            return Self.classifyTransportError(error, delegate: delegate)
        }

        do {
            let message = try await Self.receiveWithTimeout(
                task: task,
                seconds: probeTimeout
            )
            switch message {
            case .data(let data):
                return Self.classify(envelope: data)
            case .string(let text):
                let data = text.data(using: .utf8) ?? Data()
                return Self.classify(envelope: data)
            @unknown default:
                return .unreachable(reason: "Unexpected message type from server")
            }
        } catch {
            return Self.classifyTransportError(error, delegate: delegate)
        }
    }

    // MARK: - Pure helpers (testable without network)

    /// Build the WebSocket upgrade URL. IPv6 literals get bracketed per
    /// RFC 3986; everything else is interpolated as-is.
    ///
    /// `nonisolated` so test code (which runs without an actor context)
    /// can call this directly. The function is pure — no isolation needed.
    nonisolated static func urlString(host: String, port: Int) -> String {
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return "ws://\(bracketed):\(port)/ws"
    }

    /// JSON-RPC frame the server's `PingHandler` consumes. Mirrors the
    /// shape iOS already sends from `MiscClient.ping()` so the server
    /// path under test is the production path.
    ///
    /// `nonisolated` so tests can call without crossing an actor.
    nonisolated static func pingRequestData(
        protocolVersion: Int,
        clientVersion: String,
        requestId: String
    ) -> Data {
        let body: [String: Any] = [
            "id": requestId,
            "method": "system.ping",
            "params": [
                "protocolVersion": protocolVersion,
                "clientVersion": clientVersion,
            ],
        ]
        // Force-try is safe: every value is a JSON-serializable primitive.
        return try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Map the raw RPC envelope bytes to a `PairingProbeOutcome`. Pure —
    /// the heart of the test suite.
    ///
    /// `nonisolated` so tests can call without crossing an actor.
    nonisolated static func classify(envelope data: Data) -> PairingProbeOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreachable(reason: "Server returned an unparseable response")
        }
        if let success = object["success"] as? Bool, success {
            let result = object["result"] as? [String: Any]
            let serverVersion = result?["serverVersion"] as? String
            return .ok(serverVersion: serverVersion)
        }
        if let error = object["error"] as? [String: Any],
           let code = error["code"] as? String {
            if code == "CLIENT_VERSION_UNSUPPORTED" {
                let details = error["details"] as? [String: Any]
                let serverVersion = details?["serverVersion"] as? String ?? "unknown"
                return .incompatible(serverVersion: serverVersion)
            }
            let message = error["message"] as? String ?? code
            return .unreachable(reason: message)
        }
        return .unreachable(reason: "Server returned an unexpected response")
    }

    /// Translate a thrown URLSession / WebSocketTask error into the
    /// outcome enum. If the upgrade was rejected with 401 the delegate
    /// will have observed it; otherwise we treat as `.unreachable`.
    nonisolated private static func classifyTransportError(
        _ error: Error,
        delegate: ProbeSessionDelegate
    ) -> PairingProbeOutcome {
        if delegate.observedUnauthorized {
            return .unauthorized
        }
        let nsError = error as NSError
        if nsError.code == NSURLErrorUserAuthenticationRequired {
            return .unauthorized
        }
        return .unreachable(reason: nsError.localizedDescription)
    }

    /// Wrap `URLSessionWebSocketTask.receive()` in a timeout so the probe
    /// can't hang forever if the server accepts the upgrade but never
    /// emits a ping reply.
    private static func receiveWithTimeout(
        task: URLSessionWebSocketTask,
        seconds: TimeInterval
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorTimedOut,
                    userInfo: [NSLocalizedDescriptionKey: "Server didn't reply to ping in time"]
                )
            }
            // The first thing back wins; cancel the rest.
            // Force-unwrap is safe: we just added two tasks.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - URLSession delegate (401 sniffer)

/// Internal delegate the probe attaches to its ephemeral URLSession so
/// it can detect HTTP 401 on the WS upgrade. The probe is `@MainActor`
/// but URLSession callbacks are off-main; the delegate is `Sendable`
/// and writes to a single bool through atomic operations.
final class ProbeSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Set true if any task in this session received a 401 HTTP response
    /// (which is what a `auth.enforced=true` server emits when the
    /// `Authorization` header is missing or wrong).
    private(set) var observedUnauthorized: Bool = false

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let httpResponse = task.response as? HTTPURLResponse,
           httpResponse.statusCode == 401 {
            observedUnauthorized = true
        }
    }
}

// MARK: - Test stub

#if DEBUG
/// In-memory `PairingProbing` for tests + SwiftUI previews. Never
/// touches the network. The next outcome is what `probe()` returns; the
/// last call's parameters are captured for assertions.
@MainActor
final class StubPairingProbe: PairingProbing {
    var nextOutcome: PairingProbeOutcome = .ok(serverVersion: nil)
    private(set) var lastHost: String?
    private(set) var lastPort: Int?
    private(set) var lastToken: String?

    func probe(host: String, port: Int, token: String) async -> PairingProbeOutcome {
        lastHost = host
        lastPort = port
        lastToken = token
        return nextOutcome
    }
}
#endif
