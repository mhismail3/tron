import Foundation

package enum GatewayRecoveryFailurePolicy {
    package static let nonRetryableCodes: Set<String> = [
        "unauthenticated",
        "forbidden",
        "protocol_mismatch",
        "identity_mismatch",
    ]

    package static func isNonRetryable(_ error: Error) -> Bool {
        guard let failure = error as? GatewayFailure else { return false }
        return nonRetryableCodes.contains(failure.code)
    }
}
