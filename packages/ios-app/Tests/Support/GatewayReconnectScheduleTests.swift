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

    @Test("a path change cancels the pending wait at once and restarts the curve")
    func pathChangeRestartsTheCurve() async throws {
        let clock = ManualClock()
        let schedule = GatewayReconnectSchedule(clock: clock.clock, delayPolicy: .init(nextUnitInterval: { 0.5 }))
        // One failure's wait outlives its interval, so the curve has grown to
        // the second step before the path change.
        let first = Task { await schedule.afterFailure() }
        try await clock.waitUntilSleeping(count: 1, duration: .seconds(2))
        clock.advance(by: .seconds(2))
        #expect(await first.value)
        let second = Task { await schedule.afterFailure() }
        try await clock.waitUntilSleeping(count: 1, duration: .seconds(3.4000000000000004))

        schedule.restartForPathChange()

        #expect(await second.value)
        #expect(clock.activeSleeperCount() == 0)
        // The next wait is the base interval again, not the third step.
        let third = Task { await schedule.afterFailure() }
        try await clock.waitUntilSleeping(count: 1, duration: .seconds(2))
        schedule.cancel()
        #expect(!(await third.value))
        #expect(clock.recordedSleeps() == [.seconds(2), .seconds(3.4000000000000004), .seconds(2)])
    }
}
