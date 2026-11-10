import Foundation

package struct MonotonicClock: Sendable {
    package let now: @Sendable () -> ContinuousClock.Instant
    package let sleep: @Sendable (Duration) async throws -> Void
    let gridOrigin: ContinuousClock.Instant

    package init(
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        gridOrigin: ContinuousClock.Instant
    ) {
        self.now = now
        self.sleep = sleep
        self.gridOrigin = gridOrigin
    }

    package static let continuous: MonotonicClock = {
        let clock = ContinuousClock()
        return MonotonicClock(
            now: { clock.now },
            sleep: { duration in try await clock.sleep(for: duration) },
            gridOrigin: clock.now
        )
    }()

    package func gridTick(after instant: ContinuousClock.Instant, every interval: Duration) -> ContinuousClock.Instant {
        let period = Self.nanoseconds(interval)
        precondition(period > 0)
        let elapsed = Self.nanoseconds(gridOrigin.duration(to: instant))
        let completedPeriods = elapsed >= 0 ? elapsed / period : -((-elapsed + period - 1) / period)
        return gridOrigin + .nanoseconds((completedPeriods + 1) * period)
    }

    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }
}
