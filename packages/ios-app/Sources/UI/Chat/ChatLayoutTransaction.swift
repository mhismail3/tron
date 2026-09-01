import Observation
import SwiftUI
import UIKit

enum ChatLayoutMutation: Hashable, Sendable {
    case keyboard
    case submission
    case transcriptGrowth
    case morphFlight
}

struct ChatLayoutClock: Equatable, Sendable {
    enum Curve: Equatable, Sendable {
        case keyboard(Int)
        case smooth
        case spring(response: Double, dampingFraction: Double, blendDuration: Double)
        case instant
    }

    let duration: Double
    let curve: Curve

    static func resolve(
        joined: Set<ChatLayoutMutation>,
        keyboard: ChatKeyboardTransition?,
        reduceMotion: Bool
    ) -> Self {
        if reduceMotion { return Self(duration: 0, curve: .instant) }
        if joined.contains(.keyboard), let keyboard {
            return Self(
                duration: max(0, keyboard.duration),
                curve: .keyboard(keyboard.curve.rawValue)
            )
        }
        if joined.contains(.submission) {
            return Self(
                duration: 0.40,
                curve: .spring(response: 0.40, dampingFraction: 0.86, blendDuration: 0.08)
            )
        }
        return Self(duration: 0.34, curve: .smooth)
    }

    var animation: Animation? {
        switch curve {
        case .instant:
            nil
        case .smooth:
            .smooth(duration: duration)
        case let .spring(response, dampingFraction, blendDuration):
            .spring(
                response: response,
                dampingFraction: dampingFraction,
                blendDuration: blendDuration
            )
        case let .keyboard(rawValue):
            switch UIView.AnimationCurve(rawValue: rawValue) ?? .easeInOut {
            case .easeInOut:
                .easeInOut(duration: duration)
            case .easeIn:
                .easeIn(duration: duration)
            case .easeOut:
                .easeOut(duration: duration)
            case .linear:
                .linear(duration: duration)
            @unknown default:
                .easeInOut(duration: duration)
            }
        }
    }
}

@MainActor
@Observable
final class ChatLayoutTransaction {
    enum TerminalEvent: Equatable, Sendable {
        case settled(Int)
        case abandoned(Int)
        /// Observation stopped consuming exact outcomes. The viewport owner
        /// must cancel transient leases rather than guess which event survived.
        case overflow
    }

    struct ParticipantTicket: Equatable, Sendable {
        let generationID: Int
        let mutation: ChatLayoutMutation
        let revision: Int
    }

    struct Generation: Equatable, Sendable {
        let id: Int
        fileprivate(set) var joined: Set<ChatLayoutMutation>
        fileprivate(set) var settled: Set<ChatLayoutMutation>
        fileprivate(set) var participantRevisions: [ChatLayoutMutation: Int]
        fileprivate(set) var clock: ChatLayoutClock?
    }

    private(set) var generation: Generation?
    /// Only a completed generation may authorize scroll-lease settlement.
    /// Abandonment is intentionally observable as a different terminal fact so
    /// interrupted background/layout work cannot masquerade as success.
    private(set) var settledGenerationID: Int?
    private(set) var abandonedGenerationID: Int?
    private(set) var terminalEventRevision = 0
    private(set) var pendingTerminalEvents: [TerminalEvent] = []
    private var nextGenerationID = 0
    private let clock: MonotonicClock
    private var keyboardTransition: ChatKeyboardTransition?
    private var reduceMotion = false
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?

    init(clock: MonotonicClock = .continuous) {
        self.clock = clock
    }

    func configure(keyboard: ChatKeyboardTransition?, reduceMotion: Bool) {
        keyboardTransition = keyboard
        self.reduceMotion = reduceMotion
    }

    @discardableResult
    func join(_ mutation: ChatLayoutMutation) -> Int {
        joinParticipant(mutation).generationID
    }

    /// Returns an exact participant ticket for sources that can repeat within
    /// one generation (notably keyboard transitions). An older animation
    /// completion cannot settle a newer revision of the same participant.
    @discardableResult
    func joinParticipant(_ mutation: ChatLayoutMutation) -> ParticipantTicket {
        if var current = generation {
            let revision = (current.participantRevisions[mutation] ?? 0) &+ 1
            current.joined.insert(mutation)
            current.settled.remove(mutation)
            current.participantRevisions[mutation] = revision
            generation = current
            return ParticipantTicket(
                generationID: current.id,
                mutation: mutation,
                revision: revision
            )
        }
        nextGenerationID &+= 1
        let opened = Generation(
            id: nextGenerationID,
            joined: [mutation],
            settled: [],
            participantRevisions: [mutation: 1],
            clock: nil
        )
        generation = opened
        armWatchdog(for: opened.id)
        return ParticipantTicket(
            generationID: opened.id,
            mutation: mutation,
            revision: 1
        )
    }

    var animation: Animation? {
        guard var current = generation else { return nil }
        if current.clock == nil {
            current.clock = ChatLayoutClock.resolve(
                joined: current.joined,
                keyboard: keyboardTransition,
                reduceMotion: reduceMotion
            )
        }
        generation = current
        return current.clock?.animation
    }

    func settle(_ ticket: ParticipantTicket) {
        guard generation?.id == ticket.generationID,
              generation?.participantRevisions[ticket.mutation] == ticket.revision else { return }
        settle(ticket.generationID, source: ticket.mutation)
    }

    func settle(_ id: Int, source: ChatLayoutMutation) {
        guard var current = generation, current.id == id, current.joined.contains(source) else {
            return
        }
        current.settled.insert(source)
        guard current.settled == current.joined else {
            generation = current
            return
        }
        finish(id)
    }

    func settleAll(_ id: Int) {
        guard generation?.id == id else { return }
        finish(id)
    }

    func abandon() {
        watchdogTask?.cancel()
        watchdogTask = nil
        guard let id = generation?.id else { return }
        abandonedGenerationID = id
        generation = nil
        publishTerminal(.abandoned(id))
    }

    /// Records exact terminal outcomes until the bounded queue overflows, then
    /// emits one fail-closed recovery event. SwiftUI may coalesce observable
    /// mutations; abandonment must still reach the viewport owner so a command
    /// lease cannot remain installed after its layout participant dies.
    func consumeTerminalEvents() -> [TerminalEvent] {
        let events = pendingTerminalEvents
        pendingTerminalEvents.removeAll(keepingCapacity: true)
        return events
    }

    private func finish(_ id: Int) {
        guard generation?.id == id else { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        settledGenerationID = id
        generation = nil
        publishTerminal(.settled(id))
    }

    private func publishTerminal(_ event: TerminalEvent) {
        if pendingTerminalEvents.contains(.overflow) {
            terminalEventRevision &+= 1
            return
        }
        if pendingTerminalEvents.count >= 32 {
            pendingTerminalEvents = [.overflow]
        } else {
            pendingTerminalEvents.append(event)
        }
        terminalEventRevision &+= 1
    }

    private func armWatchdog(for id: Int) {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(.seconds(1))
            guard !Task.isCancelled, self?.generation?.id == id else { return }
            self?.abandon()
        }
    }
}
