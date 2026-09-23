import Foundation
import Testing
@testable import TronMobile

@MainActor
struct GatewayReconnectScheduleTests {
    @Test("cancellation ends a pending reconnect delay without waking it")
    func cancellationEndsPendingDelay() async throws {
        let clock = ManualClock()
        let schedule = GatewayReconnectSchedule(clock: clock.clock, delayPolicy: .init(nextUnitInterval: { 0.5 }))
        let wait = Task { await schedule.afterFailure() }
        try await clock.waitUntilSleeping(count: 1, duration: .seconds(2))

        schedule.cancel()
        #expect(!(await wait.value))
        #expect(clock.activeSleeperCount() == 0)
    }

    @Test("acceleration wakes one pending reconnect delay exactly once")
    func accelerationWakesOnce() async throws {
        let clock = ManualClock()
        let schedule = GatewayReconnectSchedule(clock: clock.clock, delayPolicy: .init(nextUnitInterval: { 0.5 }))
        let wait = Task { await schedule.afterFailure() }
        try await clock.waitUntilSleeping(count: 1, duration: .seconds(2))

        schedule.accelerate()
        schedule.accelerate()
        #expect(await wait.value)
        #expect(clock.activeSleeperCount() == 0)
    }
}
