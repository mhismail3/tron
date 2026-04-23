import Foundation

/// Simple token-bucket rate limiter. Used to cap Sentry + PostHog
/// event volume per minute so a runaway error loop on-device can't
/// exhaust free-tier quota (see plan §F / §N item 21).
///
/// Invariants:
/// - `capacity >= 0`, `refillPerSecond >= 0`.
/// - Tokens are refilled lazily on each `tryConsume()` call, capped
///   to `capacity` — no unbounded accumulation across idle periods.
/// - Thread-safe via an internal lock; safe to share across
///   concurrent error sites.
///
/// The `now` closure is injectable for tests (pass a mutable clock);
/// production callers use the default `Date.init` to tick realtime.
final class TokenBucket: @unchecked Sendable {
    let capacity: Double
    let refillPerSecond: Double

    private let lock = NSLock()
    private var tokens: Double
    private var lastRefill: Date
    private let clock: () -> Date

    init(capacity: Int, refillPerSecond: Double, now: @escaping () -> Date = { Date() }) {
        self.capacity = Double(capacity)
        self.refillPerSecond = refillPerSecond
        self.tokens = Double(capacity)
        self.clock = now
        self.lastRefill = now()
    }

    /// Attempts to consume one token. Returns true if the event is
    /// allowed to proceed; false if the bucket is empty and the event
    /// should be dropped.
    func tryConsume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        refillLocked()
        if tokens >= 1.0 {
            tokens -= 1.0
            return true
        }
        return false
    }

    private func refillLocked() {
        guard refillPerSecond > 0 else { return }
        let now = clock()
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = now
    }
}

extension TokenBucket {
    /// Per-error-class bucket: 10 events/minute. Used to cap Sentry
    /// volume so a tight retry loop on the same error doesn't page a
    /// full quota.
    static func sentryErrorClass(now: @escaping () -> Date = { Date() }) -> TokenBucket {
        TokenBucket(capacity: 10, refillPerSecond: 10.0 / 60.0, now: now)
    }

    /// Global PostHog bucket: 100 events/minute.
    static func posthogTelemetry(now: @escaping () -> Date = { Date() }) -> TokenBucket {
        TokenBucket(capacity: 100, refillPerSecond: 100.0 / 60.0, now: now)
    }
}
