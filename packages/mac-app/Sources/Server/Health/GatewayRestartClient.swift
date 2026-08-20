import Foundation

/// The small authenticated administrative client used by the Mac wrapper.
/// Gateway restart is a drain request; launchd remains the process owner and
/// is responsible for relaunching the Gateway after it exits.
enum GatewayRestartClient {
    static let protocolVersion = 3
    static let minimumProtocolVersion = 3
    static let defaultTimeout: TimeInterval = 10
    static let minimumCommandIDLength = 8
    static let maximumCommandIDLength = 160

    struct Response: Codable, Equatable, Sendable {
        let restarting: Bool
        let scheduled: Bool
        let activeSessionIds: [String]

        enum CodingKeys: String, CodingKey {
            case restarting
            case scheduled
            case activeSessionIds = "activeSessionIds"
        }
    }

    enum Failure: Error, Equatable, Sendable {
        case invalidURL
        case missingCredential
        case invalidCommandID
        case unauthorized
        case timeout
        case protocolMismatch
        case malformedResponse
        case transport
        case gateway(code: String, message: String, retryable: Bool)

        var userMessage: String {
            switch self {
            case .invalidURL, .malformedResponse, .protocolMismatch:
                return "The Gateway returned an invalid protocol response."
            case .missingCredential, .unauthorized:
                return "The Mac wrapper could not authenticate to Tron."
            case .invalidCommandID:
                return "The restart request could not be safely created."
            case .timeout:
                return "The Gateway did not respond before the restart request timed out."
            case .transport:
                return "The Gateway could not be reached."
            case .gateway(_, let message, _):
                return message
            }
        }
    }

    enum Frame: Equatable, Sendable {
        case result(Response)
        case ignore
        case error(Failure)
        case malformed
    }

    /// Performs one authenticated Gateway handshake and requests a drain-aware
    /// restart. The command ID is bounded before any network activity, and the
    /// socket is always closed by the caller's defer.
    static func restart(
        host: String,
        port: Int,
        token: String?,
        commandID: String = "mac-restart-\(UUID().uuidString.lowercased())",
        timeout: TimeInterval = defaultTimeout
    ) async throws -> Response {
        guard validCommandID(commandID) else { throw Failure.invalidCommandID }
        guard let token, !token.isEmpty else { throw Failure.missingCredential }
        let request = try makeRequest(host: host, port: port, token: token, timeout: timeout)
        let capture = GatewayRestartWSStatusCapture()
        let session = URLSession(configuration: .ephemeral, delegate: capture, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        do {
            guard let hello = Self.jsonString([
                "type": "hello",
                "protocolVersion": protocolVersion,
                "clientId": UUID().uuidString,
            ]) else { throw Failure.malformedResponse }
            try await task.send(.string(hello))
            guard let hello = messageData(from: try await receive(task: task, timeout: timeout)), decodeHello(data: hello) else {
                throw Failure.protocolMismatch
            }

            let requestData = try JSONSerialization.data(withJSONObject: [
                "type": "request",
                "id": commandID,
                "method": "gateway.restart",
                "params": ["commandId": commandID],
            ])
            guard let requestString = String(data: requestData, encoding: .utf8) else {
                throw Failure.malformedResponse
            }
            try await task.send(.string(requestString))

            for _ in 0..<8 {
                guard let data = messageData(from: try await receive(task: task, timeout: timeout)) else {
                    throw Failure.malformedResponse
                }
                switch decodeFrame(data: data, expectedID: commandID) {
                case .result(let response): return response
                case .ignore: continue
                case .error(let failure): throw failure
                case .malformed: throw Failure.malformedResponse
                }
            }
            throw Failure.timeout
        } catch let failure as Failure {
            throw failure
        } catch {
            if capture.snapshotStatusCode() == 401 { throw Failure.unauthorized }
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw Failure.timeout
            }
            throw Failure.transport
        }
    }

    static func makeRequest(
        host: String,
        port: Int,
        token: String?,
        timeout: TimeInterval = defaultTimeout
    ) throws -> URLRequest {
        guard let token, !token.isEmpty else { throw Failure.missingCredential }
        guard !host.isEmpty,
              host.utf8.count <= 255,
              host.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value >= 0x20 && $0.value != 0x7f }),
              port > 0, port <= 65_535,
              timeout.isFinite, timeout > 0 else { throw Failure.invalidURL }
        guard let url = GatewaySocketURL.make(host: host, port: port) else { throw Failure.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: max(1, timeout))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func validCommandID(_ value: String) -> Bool {
        let count = value.utf8.count
        return count >= minimumCommandIDLength && count <= maximumCommandIDLength
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    static func decodeHello(data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "hello",
              json["protocolVersion"] as? Int == protocolVersion,
              json["minProtocolVersion"] as? Int == minimumProtocolVersion else { return false }
        return true
    }

    static func decodeFrame(data: Data, expectedID: String) -> Frame {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        guard json["id"] as? String == expectedID else { return .ignore }
        guard json["type"] as? String == "response", let ok = json["ok"] as? Bool else {
            return .malformed
        }
        if !ok {
            guard let error = json["error"] as? [String: Any],
                  let code = error["code"] as? String,
                  let message = error["message"] as? String,
                  !code.isEmpty, !message.isEmpty else { return .malformed }
            return .error(.gateway(code: code, message: message, retryable: error["retryable"] as? Bool ?? false))
        }
        guard json["error"] == nil,
              let resultObject = json["result"],
              JSONSerialization.isValidJSONObject(resultObject),
              let resultData = try? JSONSerialization.data(withJSONObject: resultObject),
              let result = try? JSONDecoder().decode(Response.self, from: resultData),
              result.activeSessionIds.allSatisfy({ !$0.isEmpty }) else { return .malformed }
        return .result(result)
    }

    private static func receive(
        task: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) async throws -> URLSessionWebSocketTask.Message {
        guard timeout.isFinite, timeout > 0 else { throw Failure.invalidURL }
        return try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                throw Failure.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func messageData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default: return nil
        }
    }
}

private final class GatewayRestartWSStatusCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode: Int?

    func snapshotStatusCode() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return statusCode
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let status = (task.response as? HTTPURLResponse)?.statusCode else { return }
        lock.lock(); statusCode = status; lock.unlock()
    }
}
