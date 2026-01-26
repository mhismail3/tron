import Foundation

/// Centralized error types for the application.
/// Provides structured error handling with context for debugging.
enum AppError: Error, LocalizedError {
    // MARK: - Database Errors

    /// Failed to read from database
    case databaseRead(context: String, underlying: Error)

    /// Failed to write to database
    case databaseWrite(context: String, underlying: Error)

    /// Failed to delete from database
    case databaseDelete(context: String, underlying: Error)

    /// Failed to execute database transaction
    case databaseTransaction(context: String, underlying: Error)

    // MARK: - Network/RPC Errors

    /// Failed to encode RPC request
    case rpcEncode(method: String, underlying: Error)

    /// Failed to decode RPC response
    case rpcDecode(method: String, underlying: Error)

    /// WebSocket disconnected unexpectedly
    case websocketDisconnected(reason: String?)

    /// RPC call failed
    case rpcFailed(method: String, message: String)

    // MARK: - Event Processing Errors

    /// Failed to parse event data
    case eventParseFailed(type: String, underlying: Error)

    /// Failed to transform event to chat message
    case eventTransformFailed(type: String, reason: String)

    /// Unknown or unsupported event type
    case eventUnknownType(type: String)

    // MARK: - Tool Processing Errors

    /// Failed to parse tool result
    case toolResultParseFailed(toolName: String, underlying: Error)

    /// Tool output is invalid or malformed
    case toolOutputInvalid(toolName: String, reason: String)

    // MARK: - State Errors

    /// Message not found by ID
    case messageNotFound(id: UUID)

    /// Session not found by ID
    case sessionNotFound(id: String)

    /// Event not found by ID
    case eventNotFound(id: String)

    // MARK: - File I/O Errors

    /// Failed to read file
    case fileReadFailed(path: String, underlying: Error)

    /// Failed to write file
    case fileWriteFailed(path: String, underlying: Error)

    // MARK: - Encoding/Decoding Errors

    /// JSON encoding failed
    case jsonEncodeFailed(context: String, underlying: Error)

    /// JSON decoding failed
    case jsonDecodeFailed(context: String, underlying: Error)

    // MARK: - LocalizedError Conformance

    var errorDescription: String? {
        switch self {
        // Database
        case .databaseRead(let context, let underlying):
            return "Database read failed (\(context)): \(underlying.localizedDescription)"
        case .databaseWrite(let context, let underlying):
            return "Database write failed (\(context)): \(underlying.localizedDescription)"
        case .databaseDelete(let context, let underlying):
            return "Database delete failed (\(context)): \(underlying.localizedDescription)"
        case .databaseTransaction(let context, let underlying):
            return "Database transaction failed (\(context)): \(underlying.localizedDescription)"

        // Network/RPC
        case .rpcEncode(let method, let underlying):
            return "RPC encode failed for \(method): \(underlying.localizedDescription)"
        case .rpcDecode(let method, let underlying):
            return "RPC decode failed for \(method): \(underlying.localizedDescription)"
        case .websocketDisconnected(let reason):
            return "WebSocket disconnected: \(reason ?? "unknown reason")"
        case .rpcFailed(let method, let message):
            return "RPC call \(method) failed: \(message)"

        // Event Processing
        case .eventParseFailed(let type, let underlying):
            return "Event parse failed for type '\(type)': \(underlying.localizedDescription)"
        case .eventTransformFailed(let type, let reason):
            return "Event transform failed for type '\(type)': \(reason)"
        case .eventUnknownType(let type):
            return "Unknown event type: \(type)"

        // Tool Processing
        case .toolResultParseFailed(let toolName, let underlying):
            return "Tool result parse failed for '\(toolName)': \(underlying.localizedDescription)"
        case .toolOutputInvalid(let toolName, let reason):
            return "Tool output invalid for '\(toolName)': \(reason)"

        // State
        case .messageNotFound(let id):
            return "Message not found: \(id)"
        case .sessionNotFound(let id):
            return "Session not found: \(id)"
        case .eventNotFound(let id):
            return "Event not found: \(id)"

        // File I/O
        case .fileReadFailed(let path, let underlying):
            return "File read failed at \(path): \(underlying.localizedDescription)"
        case .fileWriteFailed(let path, let underlying):
            return "File write failed at \(path): \(underlying.localizedDescription)"

        // Encoding/Decoding
        case .jsonEncodeFailed(let context, let underlying):
            return "JSON encode failed (\(context)): \(underlying.localizedDescription)"
        case .jsonDecodeFailed(let context, let underlying):
            return "JSON decode failed (\(context)): \(underlying.localizedDescription)"
        }
    }

    /// Short code for logging (e.g., "DB_READ", "RPC_DECODE")
    var code: String {
        switch self {
        case .databaseRead: return "DB_READ"
        case .databaseWrite: return "DB_WRITE"
        case .databaseDelete: return "DB_DELETE"
        case .databaseTransaction: return "DB_TX"
        case .rpcEncode: return "RPC_ENCODE"
        case .rpcDecode: return "RPC_DECODE"
        case .websocketDisconnected: return "WS_DISCONNECTED"
        case .rpcFailed: return "RPC_FAILED"
        case .eventParseFailed: return "EVENT_PARSE"
        case .eventTransformFailed: return "EVENT_TRANSFORM"
        case .eventUnknownType: return "EVENT_UNKNOWN"
        case .toolResultParseFailed: return "TOOL_PARSE"
        case .toolOutputInvalid: return "TOOL_INVALID"
        case .messageNotFound: return "MSG_NOT_FOUND"
        case .sessionNotFound: return "SESSION_NOT_FOUND"
        case .eventNotFound: return "EVENT_NOT_FOUND"
        case .fileReadFailed: return "FILE_READ"
        case .fileWriteFailed: return "FILE_WRITE"
        case .jsonEncodeFailed: return "JSON_ENCODE"
        case .jsonDecodeFailed: return "JSON_DECODE"
        }
    }
}
