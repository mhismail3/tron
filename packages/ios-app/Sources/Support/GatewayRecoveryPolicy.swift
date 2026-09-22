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
    private var connectedAttemptCharged = false
    private var activeAutomaticAttempts: Set<UUID> = []
    private(set) var firstFailureCode: String?
    private(set) var recoveryEpisodeStartedAt: ContinuousClock.Instant?
    private(set) var recoveryActiveSince: ContinuousClock.Instant?
    private(set) var recoveryActiveDuration: Duration = .zero
    private(set) var knownNoUsablePath = false
    private(set) var fallbackVerificationUsed = false
    private(set) var episodeStopped = false
    private(set) var waitingForPath = false

    var isStopped: Bool { exhausted || nonRetryableStopped || episodeStopped }
    static let stoppedMessage = "Automatic connection recovery stopped. Check the Mac and Tailscale, then use Retry Connection."

    // Every automatic entrypoint (including initial connect after navigation)
    // consumes the same allowance. Otherwise replacing a client bypasses it.
    mutating func beginAutomaticAttemptID() -> UUID? {
        guard !exhausted, !nonRetryableStopped, !episodeStopped, automaticAttempts < Self.maximumAutomaticAttempts else {
            exhausted = true
            return nil
        }
        automaticAttempts += 1
        let id = UUID()
        activeAutomaticAttempts.insert(id)
        return id
    }


    /// Settles one admitted attempt. Only an intentional retirement may return
    /// its charge. Repeated settlement cannot refund a successor's charge.
    @discardableResult
    mutating func settleAutomaticAttempt(_ id: UUID, intentionalRetirement: Bool) -> Bool {
        guard activeAutomaticAttempts.remove(id) != nil else { return false }
        if intentionalRetirement, automaticAttempts > 0 { automaticAttempts -= 1 }
        return true
    }

    mutating func beginRecoveryEpisode(at instant: ContinuousClock.Instant) {
        if recoveryEpisodeStartedAt == nil {
            recoveryEpisodeStartedAt = instant
            fallbackVerificationUsed = false
        }
        if recoveryActiveSince == nil, !knownNoUsablePath { recoveryActiveSince = instant }
    }

    mutating func pauseRecovery(at instant: ContinuousClock.Instant) {
        guard let since = recoveryActiveSince else { return }
        recoveryActiveDuration += since.duration(to: instant)
        recoveryActiveSince = nil
    }

    mutating func resumeRecovery(at instant: ContinuousClock.Instant) {
        guard recoveryEpisodeStartedAt != nil, recoveryActiveSince == nil else { return }
        recoveryActiveSince = instant
    }

    func activeRecoveryDuration(at instant: ContinuousClock.Instant) -> Duration {
        recoveryActiveDuration + (recoveryActiveSince?.duration(to: instant) ?? .zero)
    }

    mutating func notePathHint(satisfied: Bool, at instant: ContinuousClock.Instant) {
        knownNoUsablePath = !satisfied
        if satisfied, !isStopped { resumeRecovery(at: instant) }
        else { pauseRecovery(at: instant) }
        guard satisfied else { return }
        fallbackVerificationUsed = false
        waitingForPath = false
    }

    mutating func consumeFallbackVerification() -> Bool {
        guard !fallbackVerificationUsed else {
            waitingForPath = true
            return false
        }
        fallbackVerificationUsed = true
        return true
    }

    mutating func stopRecoveryEpisode() {
        episodeStopped = true
    }

    mutating func admitFreshForegroundVerification() {
        guard !isStopped else { return }
        fallbackVerificationUsed = false
        waitingForPath = false
    }

    mutating func markConnected(at instant: ContinuousClock.Instant, chargedAttempt: Bool = true) {
        // A usable socket pauses transport repair time, but a provisional hello
        // does not forgive preceding failures or restore an attempt allowance.
        pauseRecovery(at: instant)
        connectedAt = instant
        connectedAttemptCharged = chargedAttempt
    }

    mutating func markStableProof(at instant: ContinuousClock.Instant) {
        automaticAttempts = 0
        firstFailureCode = nil
        exhausted = false
        recoveryEpisodeStartedAt = nil
        recoveryActiveSince = nil
        recoveryActiveDuration = .zero
        knownNoUsablePath = false
        fallbackVerificationUsed = false
        episodeStopped = false
        waitingForPath = false
        connectedAt = instant
        connectedAttemptCharged = false
        activeAutomaticAttempts.removeAll()
    }

    mutating func markConnectionRetired(at instant: ContinuousClock.Instant, stableProof: Bool) {
        guard connectedAt != nil else { return }
        if stableProof {
            markStableProof(at: instant)
        } else if connectedAttemptCharged, automaticAttempts > 0 {
            // A short intentional retirement refunds only the provisional
            // successful attempt; prior transport failures remain charged.
            automaticAttempts -= 1
        }
        self.connectedAt = nil
        connectedAttemptCharged = false
    }

    mutating func markNonRetryableFailure(code: String) {
        nonRetryableStopped = true
        connectedAt = nil
        if firstFailureCode == nil { firstFailureCode = code }
    }

    mutating func markTransportFailure(code: String, at instant: ContinuousClock.Instant, stableProof: Bool = false) {
        if stableProof { markStableProof(at: instant) }
        self.connectedAt = nil
        connectedAttemptCharged = false
        pauseRecovery(at: instant)
        if !knownNoUsablePath { resumeRecovery(at: instant) }
        if firstFailureCode == nil { firstFailureCode = code }
        exhausted = automaticAttempts >= Self.maximumAutomaticAttempts
    }

    mutating func rearmForExplicitRetry() {
        automaticAttempts = 0
        exhausted = false
        nonRetryableStopped = false
        connectedAt = nil
        connectedAttemptCharged = false
        firstFailureCode = nil
        recoveryEpisodeStartedAt = nil
        recoveryActiveSince = nil
        recoveryActiveDuration = .zero
        knownNoUsablePath = false
        fallbackVerificationUsed = false
        episodeStopped = false
        waitingForPath = false
        activeAutomaticAttempts.removeAll()
    }
}

/// Shared per-profile allowance for focused and dashboard executors. The
/// socket owners remain separate, but a role handoff observes one budget and
/// cannot manufacture a fresh automatic attempt allowance.
@MainActor
final class GatewayRecoveryAllowanceStore {
    private var budgets: [String: GatewayRecoveryBudget] = [:]

    subscript(profileID: String) -> GatewayRecoveryBudget? {
        get { budgets[profileID] }
        set { budgets[profileID] = newValue }
    }

    subscript(profileID: String, default defaultValue: GatewayRecoveryBudget) -> GatewayRecoveryBudget {
        get { budgets[profileID] ?? defaultValue }
        set { budgets[profileID] = newValue }
    }

    func prune(keeping profileIDs: Set<String>) {
        budgets = budgets.filter { profileIDs.contains($0.key) }
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
