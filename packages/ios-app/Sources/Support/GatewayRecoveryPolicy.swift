import Foundation

/// Bounds automatic transport recovery for one paired profile. A successful
/// hello is only provisional: the budget resets after an epoch has remained
/// connected for the stable interval, not after every handshake.
struct GatewayRecoveryBudget: Sendable, Equatable {
    static let maximumAutomaticAttempts = 3
    static let stableEpochDuration: Duration = .seconds(30)

    private(set) var automaticAttempts = 0
    private(set) var exhausted = false
    private(set) var nonRetryableStopped = false
    private(set) var connectedAt: ContinuousClock.Instant?
    private(set) var firstFailureCode: String?

    var isStopped: Bool { exhausted || nonRetryableStopped }
    static let stoppedMessage = "Automatic connection recovery stopped. Check the Mac and Tailscale, then use Retry Connection."

    // Every automatic entrypoint (including initial connect after navigation)
    // consumes the same allowance. Otherwise replacing a client bypasses it.
    mutating func beginAutomaticAttempt() -> Bool {
        guard !exhausted, !nonRetryableStopped, automaticAttempts < Self.maximumAutomaticAttempts else {
            exhausted = true
            return false
        }
        automaticAttempts += 1
        return true
    }

    mutating func markConnected(at instant: ContinuousClock.Instant) {
        connectedAt = instant
    }

    mutating func markConnectionRetired(at instant: ContinuousClock.Instant) {
        guard let connectedAt else { return }
        if connectedAt.duration(to: instant) >= Self.stableEpochDuration {
            automaticAttempts = 0
            firstFailureCode = nil
            exhausted = false
        } else if automaticAttempts > 0 {
            // A short intentional retirement refunds only the provisional
            // successful attempt; prior transport failures remain charged.
            automaticAttempts -= 1
        }
        self.connectedAt = nil
    }

    mutating func markNonRetryableFailure(code: String) {
        nonRetryableStopped = true
        connectedAt = nil
        if firstFailureCode == nil { firstFailureCode = code }
    }

    mutating func markTransportFailure(code: String, at instant: ContinuousClock.Instant) {
        if let connectedAt,
           connectedAt.duration(to: instant) >= Self.stableEpochDuration {
            automaticAttempts = 0
            firstFailureCode = nil
            exhausted = false
        }
        self.connectedAt = nil
        if firstFailureCode == nil { firstFailureCode = code }
        exhausted = automaticAttempts >= Self.maximumAutomaticAttempts
    }

    mutating func rearmForExplicitRetry() {
        automaticAttempts = 0
        exhausted = false
        nonRetryableStopped = false
        connectedAt = nil
        firstFailureCode = nil
    }
}

enum GatewayRecoveryFailurePolicy {
    static let nonRetryableCodes: Set<String> = [
        "identity_mismatch",
        "protocol_mismatch",
    ]

    static func isNonRetryable(_ error: Error) -> Bool {
        guard let failure = error as? GatewayFailure else { return false }
        return !failure.retryable || nonRetryableCodes.contains(failure.code)
    }
}
