import Foundation

/// Retry policy for engine invocations.
/// Centralizes retry logic so ViewModels don't implement their own retry loops.
struct EngineRetryPolicy: Sendable {
    let maxRetries: Int
    let baseDelayMs: UInt64
    /// Determines if an error is retryable. Return false to fail immediately.
    let isRetryable: @Sendable (Error) -> Bool

    static let `default` = EngineRetryPolicy(
        maxRetries: 3,
        baseDelayMs: 100,
        isRetryable: { _ in true }
    )
}

/// Execute an async operation with retry and exponential backoff.
///
/// - Parameters:
///   - policy: The retry policy to use (defaults to `.default`)
///   - operation: The async throwing operation to retry
/// - Returns: The result of the operation on success
/// - Throws: The last error if all retries are exhausted, or immediately for non-retryable errors
@MainActor
func withRetry<T>(
    policy: EngineRetryPolicy = .default,
    operation: @MainActor () async throws -> T
) async throws -> T {
    precondition(policy.maxRetries >= 1, "EngineRetryPolicy.maxRetries must be >= 1")

    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch {
            if !policy.isRetryable(error) || attempt >= policy.maxRetries {
                throw error
            }
            let delayMs = policy.baseDelayMs * UInt64(1 << (attempt - 1))
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            attempt += 1
        }
    }
}
