import Foundation

struct MonotonicClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (Duration) async throws -> Void

    static let continuous: MonotonicClock = {
        let clock = ContinuousClock()
        return MonotonicClock(
            now: { clock.now },
            sleep: { duration in try await clock.sleep(for: duration) }
        )
    }()
}
