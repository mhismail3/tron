import Testing
import Foundation

@testable import TronMobile

@Suite("TokenBucket")
struct TokenBucketTests {

    @Test("allows up to capacity events before tripping the limiter")
    func allowsUpToCapacity() {
        let bucket = TokenBucket(capacity: 3, refillPerSecond: 0.0, now: { Date(timeIntervalSince1970: 0) })
        #expect(bucket.tryConsume())
        #expect(bucket.tryConsume())
        #expect(bucket.tryConsume())
        #expect(!bucket.tryConsume())
    }

    @Test("refills partially over time")
    func refillsOverTime() {
        var clock = Date(timeIntervalSince1970: 0)
        let bucket = TokenBucket(capacity: 2, refillPerSecond: 1.0, now: { clock })
        #expect(bucket.tryConsume())
        #expect(bucket.tryConsume())
        #expect(!bucket.tryConsume())

        clock = Date(timeIntervalSince1970: 1.0)
        #expect(bucket.tryConsume())
        #expect(!bucket.tryConsume())
    }

    @Test("refill caps at capacity — no unbounded overflow")
    func refillCapsAtCapacity() {
        var clock = Date(timeIntervalSince1970: 0)
        let bucket = TokenBucket(capacity: 2, refillPerSecond: 10.0, now: { clock })
        // Drain the bucket.
        _ = bucket.tryConsume()
        _ = bucket.tryConsume()

        // Advance a full second — should refill to capacity, not beyond.
        clock = Date(timeIntervalSince1970: 100)
        #expect(bucket.tryConsume())
        #expect(bucket.tryConsume())
        #expect(!bucket.tryConsume()) // only 2 available despite 100s elapsed
    }

    @Test("sentry-class defaults — 10 events per minute, capacity 10")
    func sentryClassDefaults() {
        var clock = Date(timeIntervalSince1970: 0)
        let bucket = TokenBucket.sentryErrorClass(now: { clock })
        for _ in 0..<10 {
            #expect(bucket.tryConsume())
        }
        #expect(!bucket.tryConsume()) // eleventh in same minute drops

        clock = Date(timeIntervalSince1970: 60) // 1 minute later — capacity refilled.
        for _ in 0..<10 {
            #expect(bucket.tryConsume())
        }
    }

    @Test("posthog defaults — 100 events per minute")
    func posthogDefaults() {
        var clock = Date(timeIntervalSince1970: 0)
        let bucket = TokenBucket.posthogTelemetry(now: { clock })
        for _ in 0..<100 {
            #expect(bucket.tryConsume())
        }
        #expect(!bucket.tryConsume())
    }
}
