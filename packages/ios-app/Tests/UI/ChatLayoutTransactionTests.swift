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
