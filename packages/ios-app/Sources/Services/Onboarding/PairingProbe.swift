import Foundation

/// Result of one PairingProbe attempt — narrow enum so the caller can
/// branch on every outcome without inspecting NSError details.
enum PairingProbeOutcome: Equatable, Sendable {
    /// `system::ping` returned success. The optional `serverVersion` lets
    /// the UI confirm "you're talking to Tron 0.1.0-beta.1".
    case ok(serverVersion: String?)
    /// HTTP 401 on the WebSocket upgrade — bearer wrong/missing/rotated.
    case unauthorized
    /// `system::ping` returned `CLIENT_VERSION_UNSUPPORTED`. The
    /// `serverVersion` flows into the user-facing error message so the
    /// UI can say "Update to v0.6.0 on your Mac". `"unknown"` when the
    /// server didn't include the version in `details`.
    case incompatible(serverVersion: String)
    /// Anything else — connection refused, DNS failure, malformed engine
    /// envelope, or an unexpected server response. The `reason` is
    /// best-effort prose for diagnostics.
    case unreachable(reason: String)

    /// Map into the `PairingStepConnectError` taxonomy used by
    /// `PairingStepValidator.classify(error:hostHint:)`. `.ok` returns
    /// `nil` because success has no error payload.
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

    var logSummary: String {
        switch self {
        case .ok(let serverVersion):
            return "ok serverVersion=\(serverVersion ?? "unknown")"
        case .unauthorized:
            return "unauthorized"
        case .incompatible(let serverVersion):
            return "incompatible serverVersion=\(serverVersion)"
        case .unreachable(let reason):
            return "unreachable reason=\(reason)"
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
/// protocol `hello`, invokes `system::ping`, and waits up to 10s for the
/// matching response.
///
/// The probe deliberately uses its own `URLSession` (not the shared one
/// owned by `EngineConnection`) so there is **no chance** of mutating
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

        logger.info("Pairing probe starting: \(NetworkDiagnosticsFormatter.redactedURLSummary(url))", category: .websocket)
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        logger.debug("Pairing probe upgrade request: \(NetworkDiagnosticsFormatter.requestSummary(request))", category: .websocket)

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
        logger.debug("Pairing probe WebSocket task resumed", category: .websocket)

        let helloId = UUID().uuidString
        let helloPayload = Self.helloRequestData(
            protocolVersion: 1,
            clientVersion: AppConstants.canonicalVersion,
            requestId: helloId
        )

        do {
            try await task.send(Self.engineTextMessage(from: helloPayload))
            logger.debug("Pairing probe sent hello id=\(helloId)", category: .websocket)
        } catch {
            // Most likely a connection-refused or 401 — drain the delegate.
            return await Self.classifyTransportError(error, delegate: delegate, phase: "hello-send")
        }

        let requestId = UUID().uuidString
        let payload = Self.pingRequestData(
            protocolVersion: 1,
            clientVersion: AppConstants.canonicalVersion,
            requestId: requestId
        )

        do {
            try await task.send(Self.engineTextMessage(from: payload))
            logger.debug("Pairing probe sent system::ping id=\(requestId)", category: .websocket)
        } catch {
            return await Self.classifyTransportError(error, delegate: delegate, phase: "ping-send")
        }

        do {
            let outcome = try await Self.receivePingResponseWithTimeout(
                task: task,
                requestId: requestId,
                seconds: probeTimeout
            )
            logger.info("Pairing probe completed: \(outcome.logSummary)", category: .websocket)
            return outcome
        } catch {
            return await Self.classifyTransportError(error, delegate: delegate, phase: "receive-ping")
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
        return "ws://\(bracketed):\(port)/engine"
    }

    /// Build the engine protocol hello frame sent before the pairing
    /// probe invoke.
    ///
    /// `nonisolated` so tests can call without crossing an actor.
    nonisolated static func helloRequestData(
        protocolVersion: Int,
        clientVersion: String,
        requestId: String
    ) -> Data {
        let body: [String: Any] = [
            "type": "hello",
            "id": requestId,
            "protocolVersion": protocolVersion,
            "clientName": "tron-ios-pairing",
            "clientVersion": clientVersion,
        ]
        return try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Engine protocol frame invoking the canonical `system::ping`
    /// capability. Mirrors the shape iOS sends from the live engine client
    /// so onboarding probes the production capability path.
    ///
    /// `nonisolated` so tests can call without crossing an actor.
    nonisolated static func pingRequestData(
        protocolVersion: Int,
        clientVersion: String,
        requestId: String
    ) -> Data {
        let body: [String: Any] = [
            "type": "invoke",
            "id": requestId,
            "functionId": "system::ping",
            "payload": [
                "protocolVersion": protocolVersion,
                "clientVersion": clientVersion,
            ],
        ]
        // Force-try is safe: every value is a JSON-serializable primitive.
        return try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    nonisolated static func engineTextMessage(from data: Data) -> URLSessionWebSocketTask.Message {
        .string(String(decoding: data, as: UTF8.self))
    }

    /// Map the raw engine response envelope bytes to a
    /// `PairingProbeOutcome`. Pure — the heart of the test suite.
    ///
    /// `nonisolated` so tests can call without crossing an actor.
    nonisolated static func classify(envelope data: Data) -> PairingProbeOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreachable(reason: "Server returned an unparseable response")
        }
        return classifyResponseObject(object)
    }

    /// Classify one incoming WebSocket frame while waiting for the
    /// specific `system::ping` response this probe sent. The server can
    /// emit event frames before the response; the production engine client
    /// matches by correlation id, so the probe must do the same.
    nonisolated static func classifyFrame(
        envelope data: Data,
        expectedRequestId: String
    ) -> PairingProbeFrame {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .outcome(.unreachable(reason: "Server returned an unparseable response"))
        }

        guard responseID(object["id"], matches: expectedRequestId) else {
            return .ignore
        }

        return .outcome(classifyResponseObject(object))
    }

    private nonisolated static func classifyResponseObject(_ object: [String: Any]) -> PairingProbeOutcome {
        if let ok = object["ok"] as? Bool, ok {
            let result = object["result"] as? [String: Any]
            let child = result?["child"] as? [String: Any]
            if let error = child?["error"] as? [String: Any] {
                return classifyEngineError(error)
            }
            let value = child?["value"] as? [String: Any]
            let serverVersion = value?["serverVersion"] as? String
            return .ok(serverVersion: serverVersion)
        }
        if let error = object["error"] as? [String: Any],
           let code = error["code"] as? String {
            return classifyEngineError(error, code: code)
        }
        return .unreachable(reason: "Server returned an unexpected response")
    }

    private nonisolated static func classifyEngineError(
        _ error: [String: Any],
        code explicitCode: String? = nil
    ) -> PairingProbeOutcome {
        let code = explicitCode ?? error["kind"] as? String ?? error["code"] as? String
        let details = error["details"] as? [String: Any]
        let detailCode = details?["code"] as? String
        if code == "CLIENT_VERSION_UNSUPPORTED" || detailCode == "CLIENT_VERSION_UNSUPPORTED" {
            let nestedDetails = details?["details"] as? [String: Any]
            let serverVersion = nestedDetails?["serverVersion"] as? String
                ?? details?["serverVersion"] as? String
                ?? "unknown"
            return .incompatible(serverVersion: serverVersion)
        }
        let message = error["message"] as? String
            ?? details?["message"] as? String
            ?? code
            ?? "Engine invocation failed"
        return .unreachable(reason: message)
    }

    private nonisolated static func responseID(_ value: Any?, matches expectedID: String) -> Bool {
        if let string = value as? String {
            return string == expectedID
        }
        return false
    }

    /// Translate a thrown URLSession / WebSocketTask error into the
    /// outcome enum. If the upgrade was rejected with 401 the delegate
    /// will have observed it; otherwise we treat as `.unreachable`.
    nonisolated private static func classifyTransportError(
        _ error: Error,
        delegate: ProbeSessionDelegate,
        phase: String
    ) async -> PairingProbeOutcome {
        if await delegate.waitForUnauthorized(timeout: .milliseconds(250)) {
            logger.warning("Pairing probe unauthorized during \(phase)", category: .websocket)
            return .unauthorized
        }
        let nsError = error as NSError
        if nsError.code == NSURLErrorUserAuthenticationRequired {
            logger.warning("Pairing probe unauthorized during \(phase): \(NetworkDiagnosticsFormatter.errorSummary(error))", category: .websocket)
            return .unauthorized
        }
        logger.warning("Pairing probe failed during \(phase): \(NetworkDiagnosticsFormatter.errorSummary(error))", category: .websocket)
        return .unreachable(reason: nsError.localizedDescription)
    }

    /// Receive frames until the matching ping response arrives. The server
    /// can emit event frames first, especially `connection.established`, so
    /// reading a single frame is not enough.
    private static func receivePingResponseWithTimeout(
        task: URLSessionWebSocketTask,
        requestId: String,
        seconds: TimeInterval
    ) async throws -> PairingProbeOutcome {
        try await withThrowingTaskGroup(of: PairingProbeOutcome.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard let data = Self.messageData(from: message) else {
                        return .unreachable(reason: "Unexpected message type from server")
                    }
                    switch Self.classifyFrame(envelope: data, expectedRequestId: requestId) {
                    case .ignore:
                        continue
                    case .outcome(let outcome):
                        return outcome
                    }
                }
                throw CancellationError()
            }
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

    private nonisolated static func messageData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            return Data(text.utf8)
        @unknown default:
            return nil
        }
    }
}

// MARK: - URLSession delegate (401 sniffer)

enum PairingProbeFrame: Equatable {
    case ignore
    case outcome(PairingProbeOutcome)
}

/// Internal delegate the probe attaches to its ephemeral URLSession so
/// it can detect HTTP 401 on the WS upgrade. The probe is `@MainActor`
/// but URLSession callbacks are off-main; the delegate is `Sendable`
/// and writes to a single bool through atomic operations.
final class ProbeSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Set true if any task in this session received a 401 HTTP response
    /// because the `Authorization` header is missing or wrong.
    var observedUnauthorized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _observedUnauthorized
    }

    private let lock = NSLock()
    private var _observedUnauthorized: Bool = false

    func waitForUnauthorized(timeout: Duration) async -> Bool {
        if observedUnauthorized {
            return true
        }
        try? await Task.sleep(for: timeout)
        return observedUnauthorized
    }

    private func markUnauthorized() {
        lock.lock()
        _observedUnauthorized = true
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        logger.debug("Pairing probe URLSession metrics: \(NetworkDiagnosticsFormatter.metricsSummary(metrics))", category: .websocket)
        for transaction in metrics.transactionMetrics {
            if let response = transaction.response {
                logger.info("Pairing probe upgrade response: \(NetworkDiagnosticsFormatter.responseSummary(response))", category: .websocket)
                record(response: response)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let response = task.response {
            logger.info("Pairing probe task response: \(NetworkDiagnosticsFormatter.responseSummary(response))", category: .websocket)
            record(response: response)
        }
        if let error {
            logger.warning("Pairing probe task completed with error: \(NetworkDiagnosticsFormatter.errorSummary(error))", category: .websocket)
        }
    }

    func record(response: URLResponse) {
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 401 {
            markUnauthorized()
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
