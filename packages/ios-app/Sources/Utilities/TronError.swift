import Foundation

// MARK: - Unified Error Types

/// Top-level error namespace for all Tron-related errors
enum TronError: Error, LocalizedError, Sendable {
    /// Network/connection related errors
    case network(NetworkError)

    /// Database/persistence errors
    case database(DatabaseError)

    /// Session management errors
    case session(SessionError)

    /// RPC/API errors
    case rpc(TronRPCError)

    /// Audio recording errors
    case audio(AudioError)

    /// Generic errors with message
    case generic(String)

    var errorDescription: String? {
        switch self {
        case .network(let error):
            return error.errorDescription
        case .database(let error):
            return error.errorDescription
        case .session(let error):
            return error.errorDescription
        case .rpc(let error):
            return error.errorDescription
        case .audio(let error):
            return error.errorDescription
        case .generic(let message):
            return message
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .network(let error):
            return error.recoverySuggestion
        case .database(let error):
            return error.recoverySuggestion
        case .session(let error):
            return error.recoverySuggestion
        case .rpc(let error):
            return error.recoverySuggestion
        case .audio(let error):
            return error.recoverySuggestion
        case .generic:
            return nil
        }
    }

    /// Whether this error is recoverable/retryable
    var isRecoverable: Bool {
        switch self {
        case .network(let error):
            return error.isRecoverable
        case .database:
            return false
        case .session(let error):
            return error.isRecoverable
        case .rpc(let error):
            return error.isRecoverable
        case .audio(let error):
            return error.isRecoverable
        case .generic:
            return false
        }
    }
}

// MARK: - Network Errors

enum NetworkError: Error, LocalizedError, Sendable {
    case connectionFailed(underlying: String?)
    case timeout
    case invalidURL
    case serverUnreachable
    case sslError

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let underlying):
            if let underlying { return "Connection failed: \(underlying)" }
            return "Connection failed"
        case .timeout:
            return "Request timed out"
        case .invalidURL:
            return "Invalid server URL"
        case .serverUnreachable:
            return "Server unreachable"
        case .sslError:
            return "SSL/TLS error"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .connectionFailed:
            return "Check your network connection and try again"
        case .timeout:
            return "The server is taking too long to respond. Try again later."
        case .invalidURL:
            return "Check the server URL in settings"
        case .serverUnreachable:
            return "Make sure Claude Code is running on your Mac"
        case .sslError:
            return "There was a security error. Try restarting the server."
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .connectionFailed, .timeout, .serverUnreachable:
            return true
        case .invalidURL, .sslError:
            return false
        }
    }
}

// MARK: - Database Errors

enum DatabaseError: Error, LocalizedError, Sendable {
    case initializationFailed(String)
    case queryFailed(String)
    case insertFailed(String)
    case deleteFailed(String)
    case migrationFailed(String)
    case corruptedData

    var errorDescription: String? {
        switch self {
        case .initializationFailed(let detail):
            return "Database initialization failed: \(detail)"
        case .queryFailed(let detail):
            return "Database query failed: \(detail)"
        case .insertFailed(let detail):
            return "Failed to save data: \(detail)"
        case .deleteFailed(let detail):
            return "Failed to delete data: \(detail)"
        case .migrationFailed(let detail):
            return "Database migration failed: \(detail)"
        case .corruptedData:
            return "Database contains corrupted data"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .initializationFailed, .migrationFailed, .corruptedData:
            return "Try reinstalling the app or clearing app data"
        case .queryFailed, .insertFailed, .deleteFailed:
            return "Try again or restart the app"
        }
    }
}

// MARK: - Session Errors

enum SessionError: Error, LocalizedError, Sendable {
    case noActiveSession
    case sessionNotFound(String)
    case createFailed(String)
    case resumeFailed(String)
    case forkFailed(String)
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No active session"
        case .sessionNotFound(let id):
            return "Session not found: \(id)"
        case .createFailed(let detail):
            return "Failed to create session: \(detail)"
        case .resumeFailed(let detail):
            return "Failed to resume session: \(detail)"
        case .forkFailed(let detail):
            return "Failed to fork session: \(detail)"
        case .invalidState(let detail):
            return "Invalid session state: \(detail)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noActiveSession:
            return "Start a new session or select an existing one"
        case .sessionNotFound:
            return "The session may have been deleted. Start a new session."
        case .createFailed, .resumeFailed, .forkFailed:
            return "Try again or check the server connection"
        case .invalidState:
            return "Refresh the session or start a new one"
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .noActiveSession, .sessionNotFound:
            return true
        case .createFailed, .resumeFailed, .forkFailed:
            return true
        case .invalidState:
            return false
        }
    }
}

// MARK: - RPC Errors

enum TronRPCError: Error, LocalizedError, Sendable {
    case notConnected
    case requestFailed(code: Int, message: String)
    case decodingFailed(String)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to server"
        case .requestFailed(let code, let message):
            return "RPC error \(code): \(message)"
        case .decodingFailed(let detail):
            return "Failed to decode response: \(detail)"
        case .timeout:
            return "Request timed out"
        case .cancelled:
            return "Request was cancelled"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notConnected:
            return "Connect to the server first"
        case .requestFailed:
            return "Try the operation again"
        case .decodingFailed:
            return "The server sent an unexpected response"
        case .timeout:
            return "The server is taking too long. Try again."
        case .cancelled:
            return nil
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .notConnected, .timeout:
            return true
        case .requestFailed, .decodingFailed, .cancelled:
            return false
        }
    }
}

// MARK: - Audio Errors

enum AudioError: Error, LocalizedError, Sendable {
    case permissionDenied
    case deviceUnavailable
    case recordingFailed(String)
    case transcriptionFailed(String)
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied"
        case .deviceUnavailable:
            return "Audio device unavailable"
        case .recordingFailed(let detail):
            return "Recording failed: \(detail)"
        case .transcriptionFailed(let detail):
            return "Transcription failed: \(detail)"
        case .playbackFailed(let detail):
            return "Playback failed: \(detail)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "Enable microphone access in Settings > Privacy > Microphone"
        case .deviceUnavailable:
            return "Check that your device has a working microphone"
        case .recordingFailed, .transcriptionFailed, .playbackFailed:
            return "Try again or restart the app"
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .permissionDenied:
            return false
        case .deviceUnavailable, .recordingFailed, .transcriptionFailed, .playbackFailed:
            return true
        }
    }
}
