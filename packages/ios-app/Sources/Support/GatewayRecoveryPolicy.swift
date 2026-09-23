import Foundation

enum GatewayRecoveryFailurePolicy {
    static let nonRetryableCodes: Set<String> = [
        "unauthenticated",
        "forbidden",
        "protocol_mismatch",
        "identity_mismatch",
    ]

    static func isNonRetryable(_ error: Error) -> Bool {
        guard let failure = error as? GatewayFailure else { return false }
        return nonRetryableCodes.contains(failure.code)
    }
}
