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
    struct Generation: Equatable, Sendable {
        let id: Int
        fileprivate(set) var joined: Set<ChatLayoutMutation>
        fileprivate(set) var settled: Set<ChatLayoutMutation>
        fileprivate(set) var clock: ChatLayoutClock?
    }

    private(set) var generation: Generation?
    private var nextGenerationID = 0
    private var keyboardTransition: ChatKeyboardTransition?
    private var reduceMotion = false
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?

    func configure(keyboard: ChatKeyboardTransition?, reduceMotion: Bool) {
        keyboardTransition = keyboard
        self.reduceMotion = reduceMotion
    }

    @discardableResult
    func join(_ mutation: ChatLayoutMutation) -> Int {
        if var current = generation {
            current.joined.insert(mutation)
            generation = current
            return current.id
        }
        nextGenerationID &+= 1
        let opened = Generation(
            id: nextGenerationID,
            joined: [mutation],
            settled: [],
            clock: nil
        )
        generation = opened
        armWatchdog(for: opened.id)
        return opened.id
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
        generation = nil
    }

    private func finish(_ id: Int) {
        guard generation?.id == id else { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        generation = nil
    }

    private func armWatchdog(for id: Int) {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self?.generation?.id == id else { return }
            self?.abandon()
        }
    }
}
