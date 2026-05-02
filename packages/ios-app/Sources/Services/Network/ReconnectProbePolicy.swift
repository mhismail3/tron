import Foundation

/// Normal automatic recovery for unexpected socket loss.
///
/// A paired Mac that does not accept a fresh WebSocket quickly is usually asleep,
/// offline, or unreachable from the phone. The app therefore performs one short
/// automatic probe and then parks in the user-retryable failed state instead of
/// looping through visible retry windows.
struct ReconnectProbePolicy: Sendable, Equatable {
    let maxAutomaticAttempts: Int
    let probeTimeout: TimeInterval

    init(
        maxAutomaticAttempts: Int = 1,
        probeTimeout: TimeInterval = 2.0
    ) {
        precondition(maxAutomaticAttempts > 0, "Reconnect attempts must be positive")
        precondition(probeTimeout > 0, "Reconnect probe timeout must be positive")
        self.maxAutomaticAttempts = maxAutomaticAttempts
        self.probeTimeout = probeTimeout
    }
}
