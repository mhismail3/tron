import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@Suite("Chat layout transaction")
@MainActor
struct ChatLayoutTransactionTests {
    @Test("overlapping mutations join one generation")
    func joinsActiveGeneration() {
        let transaction = ChatLayoutTransaction()
        let submission = transaction.join(.submission)
        let keyboard = transaction.join(.keyboard)

        #expect(submission == keyboard)
        #expect(transaction.generation?.joined == [.submission, .keyboard])
    }

    @Test("the clock resolves once")
    func resolvesClockOnce() {
        let transaction = ChatLayoutTransaction()
        transaction.configure(
            keyboard: ChatKeyboardTransition(
                targetHeight: 320,
                duration: 0.27,
                curve: .easeOut
            ),
            reduceMotion: false
        )
        _ = transaction.join(.submission)
        _ = transaction.join(.keyboard)

        _ = transaction.animation
        let resolved = transaction.generation?.clock
        transaction.configure(
            keyboard: ChatKeyboardTransition(
                targetHeight: 0,
                duration: 0.8,
                curve: .linear
            ),
            reduceMotion: false
        )

        #expect(resolved == ChatLayoutClock(duration: 0.27, curve: .keyboard(2)))
        #expect(transaction.generation?.clock == resolved)
    }

    @Test("a repeated settled participant reopens in the active generation")
    func repeatedParticipantReopens() throws {
        let transaction = ChatLayoutTransaction()
        let generation = transaction.join(.submission)
        _ = transaction.join(.keyboard)
        transaction.settle(generation, source: .keyboard)

        #expect(transaction.join(.keyboard) == generation)
        transaction.settle(generation, source: .submission)
        #expect(transaction.generation != nil)

        transaction.settle(generation, source: .keyboard)
        #expect(transaction.generation == nil)
        #expect(transaction.consumeTerminalEvents() == [.settled(generation)])
    }

    @Test("settlement is idempotent and waits for every participant")
    func settlement() throws {
        let transaction = ChatLayoutTransaction()
        let generation = transaction.join(.submission)
        _ = transaction.join(.morphFlight)

        transaction.settle(generation, source: .submission)
        transaction.settle(generation, source: .submission)
        #expect(transaction.generation != nil)

        transaction.settle(generation, source: .morphFlight)
        #expect(transaction.generation == nil)
    }

    @Test("abandonment invalidates stale completions")
    func abandonment() {
        let transaction = ChatLayoutTransaction()
        let generation = transaction.join(.submission)
        transaction.abandon()
        transaction.settle(generation, source: .submission)
        #expect(transaction.generation == nil)
        #expect(transaction.abandonedGenerationID == generation)
        #expect(transaction.settledGenerationID == nil)
        #expect(transaction.consumeTerminalEvents() == [.abandoned(generation)])
    }

    @Test("successful settlement is distinct from abandonment")
    func settlementPublishesOnlyCompletedGeneration() {
        let transaction = ChatLayoutTransaction()
        let generation = transaction.join(.submission)
        transaction.settle(generation, source: .submission)

        #expect(transaction.generation == nil)
        #expect(transaction.settledGenerationID == generation)
        #expect(transaction.abandonedGenerationID == nil)
        #expect(transaction.consumeTerminalEvents() == [.settled(generation)])
    }

    @Test("settlement events retain consecutive generations")
    func consecutiveSettlementsAreNotCoalesced() {
        let transaction = ChatLayoutTransaction()
        let first = transaction.join(.submission)
        transaction.settle(first, source: .submission)
        let second = transaction.join(.transcriptGrowth)
        transaction.settle(second, source: .transcriptGrowth)

        #expect(transaction.terminalEventRevision == 2)
        #expect(transaction.consumeTerminalEvents() == [.settled(first), .settled(second)])
        #expect(transaction.consumeTerminalEvents().isEmpty)
    }

    @Test("watchdog abandonment publishes an exact terminal event")
    func watchdogAbandonmentIsObservable() async throws {
        let clock = ManualClock()
        let transaction = ChatLayoutTransaction(clock: clock.clock)
        let generation = transaction.join(.submission)
        try await clock.waitUntilSleeping(count: 1)

        clock.advance(by: .seconds(1))
        for _ in 0..<20 where transaction.generation != nil {
            await Task.yield()
        }

        #expect(transaction.generation == nil)
        #expect(transaction.consumeTerminalEvents() == [.abandoned(generation)])
    }

    @Test("settlement and abandonment preserve terminal order")
    func mixedTerminalEventsAreNotCoalesced() {
        let transaction = ChatLayoutTransaction()
        let first = transaction.join(.submission)
        transaction.abandon()
        let second = transaction.join(.transcriptGrowth)
        transaction.settle(second, source: .transcriptGrowth)

        #expect(transaction.terminalEventRevision == 2)
        #expect(transaction.consumeTerminalEvents() == [.abandoned(first), .settled(second)])
    }

    @Test("Reduce Motion is instant")
    func reduceMotion() {
        let clock = ChatLayoutClock.resolve(
            joined: [.submission, .keyboard],
            keyboard: ChatKeyboardTransition(
                targetHeight: 300,
                duration: 0.25,
                curve: .easeInOut
            ),
            reduceMotion: true
        )
        #expect(clock == ChatLayoutClock(duration: 0, curve: .instant))
        #expect(clock.animation == nil)
    }
}
