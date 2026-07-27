import Foundation

// MARK: - Connection State

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, nextRetrySeconds: Int)
    case deployRestarting(remainingSeconds: Int)  // Server deploying, patient reconnection
    case failed(reason: String)
    /// Server rejected the WS upgrade with HTTP 401 — bearer token is missing,
    /// expired, or rotated. Read-only state; user must re-pair via the
    /// global connection repair UI before reconnect can resume.
    case unauthorized(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isReconnecting: Bool {
        switch self {
        case .reconnecting, .deployRestarting: return true
        default: return false
        }
    }

    /// Whether the user can interact with the session (send messages, etc.)
    /// Only true when fully connected - reconnecting is read-only mode.
    /// `.unauthorized` is read-only — user must re-pair before interacting.
    var canInteract: Bool {
        if case .connected = self { return true }
        return false
    }

    /// True when no further automatic reconnect is in flight and the user
    /// must take action (manual retry or re-pair). Used by the
    /// global connection repair UI to surface tap-to-fix CTAs.
    var requiresUserAction: Bool {
        switch self {
        case .failed, .unauthorized: return true
        default: return false
        }
    }

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting(let attempt, let seconds): return "Reconnecting (\(attempt)) in \(seconds)s..."
        case .deployRestarting(let seconds): return "Server deploying... \(seconds)s"
        case .failed(let reason): return "Failed: \(reason)"
        case .unauthorized: return "Re-pair this server (Tap to fix)"
        }
    }
}

// MARK: - WebSocket Errors

enum EngineConnectionError: Error, LocalizedError, Sendable, Equatable {
    case notConnected
    case timeout
    case invalidResponse
    case connectionFailed(String)
    case encodingError
    case decodingError(String)
    case messageTooLarge(actualBytes: Int, maxBytes: Int)
    /// Server returned HTTP 401 on the WS upgrade — bearer token missing,
    /// wrong, or rotated. Surfaces as `ConnectionState.unauthorized`.
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .timeout: return "Request timed out"
        case .invalidResponse: return "Invalid response from server"
        case .connectionFailed(let reason): return "Connection failed: \(reason)"
        case .encodingError: return "Failed to encode request"
        case .decodingError(let detail): return "Failed to decode response: \(detail)"
        case .messageTooLarge(let actualBytes, let maxBytes):
            let actual = ByteCountFormatter.string(fromByteCount: Int64(actualBytes), countStyle: .file)
            let maximum = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
            return "Message is too large to send (\(actual); server limit \(maximum)). Remove one or more attachments and try again."
        case .unauthorized(let reason): return "Unauthorized: \(reason)"
        }
    }
}

// MARK: - Bearer Token Provider

/// Strategy for resolving a bearer token to attach to the WebSocket upgrade
/// request. Returns `nil` if no token is available; the request goes out
/// without an Authorization header, the server returns 401, and
/// `EngineConnection` transitions to `ConnectionState.unauthorized`.
typealias BearerTokenProvider = @MainActor () -> String?

/// Type-erased immutable result crossing the transport decoding boundary.
final class EngineDecodedResponseBox: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }
}

/// Owns the otherwise non-Sendable generic metatype inside one explicitly
/// audited decoder object. The object is immutable after initialization and
/// executes its operation on the transport decoder actor.
final class EngineResponseDecoder: @unchecked Sendable {
    private let operation: (Data) throws -> Any

    init<Value: Decodable>(_ type: Value.Type) {
        operation = { data in
            try JSONDecoder().decode(type, from: data)
        }
    }

    func decode(from data: Data) throws -> EngineDecodedResponseBox {
        EngineDecodedResponseBox(try operation(data))
    }
}

/// One long-lived executor owns generic response decoding for a connection.
/// This avoids allocating an unstructured detached task for every response
/// while keeping potentially large JSON work off the main actor.
actor EngineResponseDecodingExecutor {
    func decode(
        _ decoder: EngineResponseDecoder,
        from data: Data
    ) throws -> EngineDecodedResponseBox {
        try decoder.decode(from: data)
    }
}

/// Exactly one request record owns both the response continuation and its
/// deadline. The record is removed from `EngineConnection.pendingRequests`
/// before `finish` is called, which makes response, timeout, cancellation, and
/// disconnect mutually exclusive completion paths.
@MainActor
final class EnginePendingRequest {
    private let continuation: CheckedContinuation<Data, Error>
    var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Data, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}

final class SingleResumeContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        resume(.success(()))
    }

    func resume(throwing error: Error) {
        resume(.failure(error))
    }

    private func resume(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
