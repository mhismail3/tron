import Foundation

/// Admission happens on the producer queue before scheduling a MainActor
/// callback. One pending delivery can carry a fresh reactivation value, but
/// scene retirement clears any value captured while the old scene was active.
final class GatewayPathDiagnosticCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: MonotonicClock
    private var active = false
    private var latest: (facts: String, observedAt: Date, instant: ContinuousClock.Instant)?
    private var lastDelivered: String?
    private var updates = 0
    private var scheduled = false

    init(clock: MonotonicClock = .continuous) { self.clock = clock }

    func setActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.active = active
        latest = nil
        updates = 0
        if !active { lastDelivered = nil }
    }

    func offer(_ facts: String) -> Bool {
        guard facts.utf8.count <= 256 else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard active, (latest != nil || facts != lastDelivered) else { return false }
        latest = (facts, .now, clock.now())
        updates = min(1_000_000, updates + 1)
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func take() -> String? {
        lock.lock()
        defer { lock.unlock() }
        scheduled = false
        guard active, let latest else { return nil }
        self.latest = nil
        lastDelivered = latest.facts
        let count = updates
        updates = 0
        return "\(latest.facts) observedAt=\(GatewayTimestamp.string(from: latest.observedAt)) callbackDelayMs=\(diagnosticMilliseconds(latest.instant.duration(to: clock.now()))) coalescedUpdates=\(count)"
    }
}
