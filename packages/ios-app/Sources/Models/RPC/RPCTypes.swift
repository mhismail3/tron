import Foundation

// MARK: - JSON-RPC Base Types

/// JSON-RPC 2.0 style request wrapper
struct RPCRequest<P: Encodable>: Encodable {
    let id: String
    let method: String
    let params: P

    init(method: String, params: P) {
        self.id = UUID().uuidString
        self.method = method
        self.params = params
    }
}

/// JSON-RPC response wrapper
struct RPCResponse<R: Decodable>: Decodable {
    let id: String
    let success: Bool
    let result: R?
    let error: RPCError?
}

/// Known RPC error codes from the server.
///
/// Adding a case here forces every exhaustive switch on
/// `RPCErrorCode` — including `friendlyGitError` — to handle the new
/// case at compile time. Unknown server codes decode to `nil` via
/// `RPCError.errorCode` and callers fall back to the raw message.
enum RPCErrorCode: String, CaseIterable, Sendable {
    case sessionNotFound = "SESSION_NOT_FOUND"
    case agentNotRunning = "AGENT_NOT_RUNNING"
    case invalidParams = "INVALID_PARAMS"
    case methodNotFound = "METHOD_NOT_FOUND"
    case internalError = "INTERNAL_ERROR"

    // Typed git workflow errors — mirror the constants in
    // `packages/agent/src/server/rpc/errors.rs`.
    case protectedBranch = "PROTECTED_BRANCH"
    case noRemote = "NO_REMOTE"
    case nonFastForward = "NON_FAST_FORWARD"
    case gitAuthFailed = "GIT_AUTH_FAILED"
    case gitNetworkError = "GIT_NETWORK_ERROR"
    case worktreeNotFound = "WORKTREE_NOT_FOUND"
    case dirtyWorkingTree = "DIRTY_WORKING_TREE"
    case missingBaseBranch = "MISSING_BASE_BRANCH"
    case refNotFound = "REF_NOT_FOUND"
    case branchExists = "BRANCH_EXISTS"
    case branchActive = "BRANCH_ACTIVE"
    case notGitRepo = "NOT_GIT_REPO"
    case gitError = "GIT_ERROR"

    // Typed event-store errors — mirror `map_event_store_error`.
    case eventNotFound = "EVENT_NOT_FOUND"
    case workspaceNotFound = "WORKSPACE_NOT_FOUND"
    case blobNotFound = "BLOB_NOT_FOUND"

    // Typed cron errors — mirror `map_cron_error`.
    case cronNotFound = "CRON_NOT_FOUND"
    case cronDuplicateName = "CRON_DUPLICATE_NAME"
    case cronInvalidExpression = "CRON_INVALID_EXPRESSION"
    case cronInvalidTimezone = "CRON_INVALID_TIMEZONE"
    case cronTimedOut = "CRON_TIMED_OUT"
    case cronCancelled = "CRON_CANCELLED"

    // Typed auth errors — mirror `map_auth_error`.
    case authNotConfigured = "AUTH_NOT_CONFIGURED"
    case authTokenExpired = "AUTH_TOKEN_EXPIRED"
    case authOauthError = "AUTH_OAUTH_ERROR"

    // Typed import errors — mirror `map_import_error`.
    case importSessionNotFound = "IMPORT_SESSION_NOT_FOUND"
    case importAlreadyImported = "IMPORT_ALREADY_IMPORTED"
    case importEmptySession = "IMPORT_EMPTY_SESSION"
    case importNoClaudeDirectory = "IMPORT_NO_CLAUDE_DIRECTORY"
}

/// RPC error details
struct RPCError: Decodable, Error, LocalizedError, Sendable {
    let code: String
    let message: String
    let details: [String: AnyCodable]?

    var errorDescription: String? { message }

    /// Typed error code (nil for unknown codes)
    var errorCode: RPCErrorCode? { RPCErrorCode(rawValue: code) }
}

/// Empty params for methods that don't require parameters
struct EmptyParams: Codable {}
