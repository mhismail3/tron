import Testing
import Foundation

@testable import TronMobile

@Suite("BackoffPolicy")
struct BackoffPolicyTests {

    // MARK: - Defaults

    @Test("default policy matches expected constants")
    func defaultConstants() {
        let policy = BackoffPolicy()
        #expect(policy.maxAttempts == 3)
        #expect(policy.baseUnit == 2.0)
        #expect(policy.cap == 30.0)
        #expect(policy.jitterFraction == 0.0)
    }

    // MARK: - baseDelay table

    @Test(
        "baseDelay follows exponential doubling across 3 default attempts",
        arguments: [
            (1, 2.0),
            (2, 4.0),
            (3, 8.0)
        ]
    )
    func baseDelayTable(attempt: Int, expected: TimeInterval) {
        let policy = BackoffPolicy()
        #expect(policy.baseDelay(forAttempt: attempt) == expected)
    }

    @Test("baseDelay for attempt < 1 returns zero")
    func baseDelayZeroAttempt() {
        let policy = BackoffPolicy()
        #expect(policy.baseDelay(forAttempt: 0) == 0)
        #expect(policy.baseDelay(forAttempt: -5) == 0)
    }

    // MARK: - delay with jitter

    @Test("default (zero-jitter) delay equals baseDelay for every attempt")
    func defaultIsDeterministic() {
        let policy = BackoffPolicy()
        for attempt in 1...policy.maxAttempts {
            #expect(policy.delay(forAttempt: attempt) == policy.baseDelay(forAttempt: attempt))
        }
    }

    @Test("delay with explicit zero jitter equals baseDelay across custom attempts")
    func zeroJitterIsDeterministic() {
        let policy = BackoffPolicy(maxAttempts: 10, baseUnit: 1.0, jitterFraction: 0.0)
        for attempt in 1...10 {
            #expect(policy.delay(forAttempt: attempt) == policy.baseDelay(forAttempt: attempt))
        }
    }

    @Test("delay with jitter stays within [base, base * (1 + jitterFraction)]")
    func jitterBounds() {
        let policy = BackoffPolicy(jitterFraction: 0.3)
        let base = policy.baseDelay(forAttempt: 1)  // 1.0
        let upperBound = base * 1.3

        // Sample 200 times — bounds must hold every time.
        for _ in 0..<200 {
            let d = policy.delay(forAttempt: 1)
            #expect(d >= base)
            #expect(d <= upperBound + 1e-9)
        }
    }

    @Test("capped attempts get capped base + jitter in [30.0, 39.0]")
    func cappedAttemptsJitter() {
        let policy = BackoffPolicy(maxAttempts: 10, baseUnit: 1.0, jitterFraction: 0.3)
        for attempt in 6...10 {
            for _ in 0..<50 {
                let d = policy.delay(forAttempt: attempt)
                #expect(d >= 30.0)
                #expect(d <= 39.0 + 1e-9)
            }
        }
    }

    // MARK: - Custom config

    @Test("custom baseUnit scales the table")
    func customBaseUnit() {
        let policy = BackoffPolicy(baseUnit: 2.0)
        #expect(policy.baseDelay(forAttempt: 1) == 2.0)
        #expect(policy.baseDelay(forAttempt: 2) == 4.0)
        #expect(policy.baseDelay(forAttempt: 3) == 8.0)
    }

    @Test("custom cap limits exponential growth earlier")
    func customCap() {
        let policy = BackoffPolicy(maxAttempts: 10, baseUnit: 1.0, cap: 8.0)
        #expect(policy.baseDelay(forAttempt: 3) == 4.0)
        #expect(policy.baseDelay(forAttempt: 4) == 8.0)
        #expect(policy.baseDelay(forAttempt: 5) == 8.0)  // capped
    }

    @Test("custom jitterFraction expands jitter ceiling")
    func customJitterFraction() {
        let policy = BackoffPolicy(jitterFraction: 0.5)
        let base = policy.baseDelay(forAttempt: 1)
        for _ in 0..<50 {
            let d = policy.delay(forAttempt: 1)
            #expect(d >= base)
            #expect(d <= base * 1.5 + 1e-9)
        }
    }

    // MARK: - Wall-time budget

    @Test("default total wall-time before giving up is 14s (2 + 4 + 8)")
    func walltimeBudget() {
        let policy = BackoffPolicy()
        var total: TimeInterval = 0
        for attempt in 1...policy.maxAttempts {
            total += policy.baseDelay(forAttempt: attempt) * (1.0 + policy.jitterFraction)
        }
        #expect(total == 14.0)
    }

    // MARK: - Seeded determinism

    @Test("delay with seeded RNG is deterministic")
    func seededRNGDeterminism() {
        let policy = BackoffPolicy(maxAttempts: 5, baseUnit: 1.0, jitterFraction: 0.3)
        var rng1 = SeededRNG(seed: 42)
        var rng2 = SeededRNG(seed: 42)
        for attempt in 1...5 {
            let d1 = policy.delay(forAttempt: attempt, using: &rng1)
            let d2 = policy.delay(forAttempt: attempt, using: &rng2)
            #expect(d1 == d2)
        }
    }
}

/// Minimal deterministic RNG for test determinism — linear congruential generator.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed == 0 ? 1 : seed }

    mutating func next() -> UInt64 {
        state &*= 6364136223846793005
        state &+= 1442695040888963407
        return state
    }
}
