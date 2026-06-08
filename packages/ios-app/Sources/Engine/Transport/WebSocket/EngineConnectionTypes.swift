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
    /// `ConnectionStatusPill` CTA before reconnect can resume.
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
    /// `ConnectionStatusPill` to surface tap-to-fix CTAs.
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
