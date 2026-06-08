import Foundation

/// Normal automatic recovery for unexpected socket loss.
///
/// Foreground sessions keep probing at a bounded cadence until the engine
/// returns, because dev rebuilds and Mac restarts are expected operator flows.
/// Backgrounding cancels the loop so we do not burn battery while the app is
/// not visible. `maxAutomaticAttempts == nil` means "retry while foreground".
struct ReconnectProbePolicy: Sendable, Equatable {
    let maxAutomaticAttempts: Int?
    let probeTimeout: TimeInterval
    let retryDelay: TimeInterval

    init(
        maxAutomaticAttempts: Int? = nil,
        probeTimeout: TimeInterval = 2.0,
        retryDelay: TimeInterval = 3.0
    ) {
        if let maxAutomaticAttempts {
            precondition(maxAutomaticAttempts > 0, "Reconnect attempts must be positive")
        }
        precondition(probeTimeout > 0, "Reconnect probe timeout must be positive")
        precondition(retryDelay >= 0, "Reconnect retry delay must not be negative")
        self.maxAutomaticAttempts = maxAutomaticAttempts
        self.probeTimeout = probeTimeout
        self.retryDelay = retryDelay
    }
}
