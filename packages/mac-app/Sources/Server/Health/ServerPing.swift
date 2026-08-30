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
    static let supportedProtocolVersion = TronGatewayProtocolContract.protocolVersion
    static let minimumProtocolVersion = TronGatewayProtocolContract.minimumProtocolVersion

    /// Performs a single ping with a default 3 s timeout. Classifies
    /// failures so the caller can render the right state without
    /// guessing.
    static func ping(host: String, port: Int, token: String?, timeout: TimeInterval = 3) async throws -> ServerPingResult {
        try Task.checkCancellation()
        guard let url = socketURL(host: host, port: port) else {
            return .unreachable
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "type": "request",
            "id": requestID,
            "method": "system.info",
            "params": [:],
        ]

        do {
            let deadline = GatewayWebSocketTransport.Deadline(timeout: timeout)
            let connection = try await GatewayWebSocketTransport.connect(
                request: request,
                protocolVersion: supportedProtocolVersion,
                minimumProtocolVersion: minimumProtocolVersion,
                deadline: deadline
            )
            defer { connection.close() }
            try await connection.send(jsonObject: payload, deadline: deadline)

            for _ in 0..<8 {
                guard let raw = try await connection.receiveData(deadline: deadline) else {
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            if let transportFailure = error as? GatewayWebSocketTransport.Failure {
                switch transportFailure {
                case .timeout: return .timeout
                case .invalidHello: return .malformedResponse
                case .upgrade(let statusCode) where statusCode == 401: return .unauthorized
                default: break
                }
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .userAuthenticationRequired: return .unauthorized
                case .timedOut: return .timeout
                case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                     .notConnectedToInternet, .dnsLookupFailed: return .unreachable
                case .badServerResponse: return .unauthorized
                default: return .unreachable
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

/// Shared bounded transport for the wrapper's authenticated Gateway probes.
/// Clients retain ownership of their frame decoders and error taxonomies.
///
/// `maximumFrameBytes` is a protocol admission limit at the transport boundary:
/// URLSession may allocate a larger incoming frame before this code sees it, but
/// decoding and retained wrapper work never proceed for an oversized frame.
enum GatewayWebSocketTransport {
    protocol WebSocketTask: AnyObject {
        func resume()
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
        func send(_ message: URLSessionWebSocketTask.Message) async throws
        func receive() async throws -> URLSessionWebSocketTask.Message
    }

    static let maximumFrameBytes = 256 * 1024

    enum Failure: Error, Equatable, Sendable {
        case timeout
        case invalidHello
        case invalidMessage
        case upgrade(statusCode: Int)
    }

    struct Deadline: Sendable {
        private let end: UInt64?

        init(timeout: TimeInterval) {
            guard timeout.isFinite, timeout > 0 else {
                end = nil
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            let delta = UInt64(min(timeout, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
            end = now > UInt64.max - delta ? UInt64.max : now + delta
        }

        var remainingNanoseconds: UInt64? {
            guard let end else { return nil }
            let now = DispatchTime.now().uptimeNanoseconds
            return end > now ? end - now : nil
        }
    }

    final class Connection: @unchecked Sendable {
        let task: any WebSocketTask
        private let session: URLSession
        private let capture: StatusCapture
        private let closeLock = NSLock()
        private var didClose = false

        init(task: any WebSocketTask, session: URLSession, capture: StatusCapture) {
            self.task = task
            self.session = session
            self.capture = capture
            task.resume()
        }

        var statusCode: Int? { capture.statusCode }

        func close() {
            closeLock.lock()
            guard !didClose else { closeLock.unlock(); return }
            didClose = true
            closeLock.unlock()
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        func sendHello(protocolVersion: Int, minimumProtocolVersion: Int, clientID: String? = nil, deadline: Deadline) async throws {
            var hello: [String: Any] = [
                "type": "hello",
                "protocolVersion": protocolVersion,
            ]
            if let clientID { hello["clientId"] = clientID }
            let data = try JSONSerialization.data(withJSONObject: hello)
            guard let string = String(data: data, encoding: .utf8) else {
                throw Failure.invalidHello
            }
            try await bounded(deadline: deadline) { try await self.task.send(.string(string)) }
            guard let response = try await receiveData(deadline: deadline),
                  GatewayWebSocketTransport.validHello(data: response, protocolVersion: protocolVersion, minimumProtocolVersion: minimumProtocolVersion) else {
                throw Failure.invalidHello
            }
        }

        func send(jsonObject: [String: Any], deadline: Deadline) async throws {
            let data = try JSONSerialization.data(withJSONObject: jsonObject)
            guard let string = String(data: data, encoding: .utf8) else {
                throw Failure.invalidMessage
            }
            try await bounded(deadline: deadline) { try await self.task.send(.string(string)) }
        }

        func receiveData(deadline: Deadline) async throws -> Data? {
            let message = try await bounded(deadline: deadline) { try await self.task.receive() }
            switch message {
            case .data(let data):
                guard data.count <= GatewayWebSocketTransport.maximumFrameBytes else {
                    throw Failure.invalidMessage
                }
                return data
            case .string(let string):
                guard string.utf8.count <= GatewayWebSocketTransport.maximumFrameBytes else {
                    throw Failure.invalidMessage
                }
                return Data(string.utf8)
            @unknown default: return nil
            }
        }

        private func bounded<T: Sendable>(deadline: Deadline, operation: @escaping @Sendable () async throws -> T) async throws -> T {
            do {
                try Task.checkCancellation()
            } catch {
                close()
                throw CancellationError()
            }
            guard let remaining = deadline.remainingNanoseconds, remaining > 0 else {
                close()
                throw Failure.timeout
            }
            return try await withTaskCancellationHandler(operation: {
                do {
                    return try await withThrowingTaskGroup(of: T.self) { group in
                        group.addTask { try await operation() }
                        group.addTask {
                            try await Task.sleep(nanoseconds: remaining)
                            throw Failure.timeout
                        }
                        do {
                            let value = try await group.next()!
                            group.cancelAll()
                            return value
                        } catch {
                            // A timeout must close before this scope waits for the
                            // pending URLSession operation to leave the group.
                            group.cancelAll()
                            self.close()
                            if error is CancellationError { throw CancellationError() }
                            throw error
                        }
                    }
                } catch is CancellationError {
                    self.close()
                    throw CancellationError()
                }
            }, onCancel: {
                // URLSession does not observe cancellation of the child task
                // group; synchronously close the underlying operation instead.
                self.close()
            })
        }
    }

    static func connect(
        request: URLRequest,
        protocolVersion: Int,
        minimumProtocolVersion: Int,
        clientID: String? = nil,
        timeout: TimeInterval = 3
    ) async throws -> Connection {
        try await connect(
            request: request,
            protocolVersion: protocolVersion,
            minimumProtocolVersion: minimumProtocolVersion,
            clientID: clientID,
            deadline: Deadline(timeout: timeout)
        )
    }

    static func connect(
        request: URLRequest,
        protocolVersion: Int,
        minimumProtocolVersion: Int,
        clientID: String? = nil,
        deadline: Deadline
    ) async throws -> Connection {
        let capture = StatusCapture()
        let session = URLSession(configuration: .ephemeral, delegate: capture, delegateQueue: nil)
        let connection = Connection(task: session.webSocketTask(with: request), session: session, capture: capture)
        var succeeded = false
        defer { if !succeeded { connection.close() } }
        do {
            try await connection.sendHello(
                protocolVersion: protocolVersion,
                minimumProtocolVersion: minimumProtocolVersion,
                clientID: clientID,
                deadline: deadline
            )
            succeeded = true
            return connection
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let status = connection.statusCode
            if let status, status != 101 { throw Failure.upgrade(statusCode: status) }
            throw error
        }
    }

    static func validHello(data: Data, protocolVersion: Int, minimumProtocolVersion: Int) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["type"] as? String == "hello"
            && json["protocolVersion"] as? Int == protocolVersion
            && json["minProtocolVersion"] as? Int == minimumProtocolVersion
    }

    final class StatusCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?
        var statusCode: Int? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let status = (task.response as? HTTPURLResponse)?.statusCode else { return }
            lock.lock(); value = status; lock.unlock()
        }
    }
}

extension URLSessionWebSocketTask: GatewayWebSocketTransport.WebSocketTask {}
