import Foundation

/// Retry backoff policy: exponential doubling with a per-attempt cap and a total attempt
/// budget. Pure value type — no state, no clock dependency — so it's trivially testable.
///
/// Default policy: 2s, 4s, 8s across 3 attempts. No jitter — delays are exact.
/// Total wall-time before giving up: 14s.
struct BackoffPolicy: Sendable, Equatable {
    let maxAttempts: Int
    let baseUnit: TimeInterval
    let cap: TimeInterval
    let jitterFraction: Double

    init(
        maxAttempts: Int = 3,
        baseUnit: TimeInterval = 2.0,
        cap: TimeInterval = 30.0,
        jitterFraction: Double = 0.0
    ) {
        self.maxAttempts = maxAttempts
        self.baseUnit = baseUnit
        self.cap = cap
        self.jitterFraction = jitterFraction
    }

    /// Deterministic base delay for `attempt` without jitter.
    /// Doubles `baseUnit` each attempt, capped at `cap`. Returns 0 for attempts < 1.
    func baseDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return 0 }
        let exp = pow(2.0, Double(attempt - 1)) * baseUnit
        return min(exp, cap)
    }

    /// Delay with uniform jitter in `[base, base * (1 + jitterFraction)]`.
    /// Pass a seeded `RandomNumberGenerator` for deterministic tests.
    func delay<G: RandomNumberGenerator>(forAttempt attempt: Int, using rng: inout G) -> TimeInterval {
        let base = baseDelay(forAttempt: attempt)
        guard jitterFraction > 0 else { return base }
        let jitter = Double.random(in: 0..<jitterFraction, using: &rng)
        return base * (1.0 + jitter)
    }

    /// Convenience: uses `SystemRandomNumberGenerator`.
    func delay(forAttempt attempt: Int) -> TimeInterval {
        var rng = SystemRandomNumberGenerator()
        return delay(forAttempt: attempt, using: &rng)
    }
}
