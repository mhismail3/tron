import Foundation
import Testing
@testable import TronMobile

@MainActor
struct GatewayReconnectScheduleTests {
    @Test("bounded projection retries reuse the shared jittered backoff curve")
    func boundedRetryDelayUsesSharedCurve() {
        let policy = ReconnectDelayPolicy(nextUnitInterval: { 0.5 })
        #expect(policy.delay(forFailureAttempt: 1) == .seconds(2))
        let second = policy.delay(forFailureAttempt: 2)
        #expect(second > .seconds(3.399) && second < .seconds(3.401))
        let third = policy.delay(forFailureAttempt: 3)
        #expect(third > .seconds(5.779) && third < .seconds(5.781))
        #expect(policy.delay(forFailureAttempt: 20) == .seconds(13.5))
    }

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
