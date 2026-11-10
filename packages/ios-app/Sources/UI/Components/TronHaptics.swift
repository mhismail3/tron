import Observation
import SwiftUI
import UIKit

enum TronHaptic: String, CaseIterable, Sendable {
    case menuOpened
    case promptSent
    case attachmentAdded
    case runFinished
    case workerMessage
    case questionPresented
    case sheetPresented
    case toggleChanged
    case selectionChanged
    case copied
    case answerSubmitted
    case actionFailed
    case terminalBell
}

@MainActor
final class TronHaptics {
    static let shared = TronHaptics()

    static let cascadeLimit = 6
    static let cascadeInterval: Duration = .milliseconds(70)

    private struct Bound {
        weak var view: UIView?
        let generator: UIFeedbackGenerator
    }

    private var generators: [TronHaptic: Bound] = [:]
    private var cascade: Task<Void, Never>?

    private init() {}

    func prepare(_ haptic: TronHaptic, in view: UIView? = nil) {
        generator(for: haptic, in: view)?.prepare()
    }

    func play(_ haptic: TronHaptic, in view: UIView? = nil, at location: CGPoint? = nil) {
        guard let generator = generator(for: haptic, in: view) else { return }
        #if HOSTED_TEST
        TronHapticsProbe.shared.played.append(haptic)
        #endif
        switch generator {
        case let impact as UIImpactFeedbackGenerator:
            if let location { impact.impactOccurred(at: location) } else { impact.impactOccurred() }
        case let selection as UISelectionFeedbackGenerator:
            selection.selectionChanged()
        case let notification as UINotificationFeedbackGenerator:
            notification.notificationOccurred(haptic == .actionFailed ? .error : haptic == .terminalBell ? .warning : .success)
        default:
            break
        }
    }

    func changeToggle(from current: Bool, to value: Bool? = nil, apply: (Bool) -> Void) {
        let next = value ?? !current
        guard next != current else { return }
        play(.toggleChanged)
        apply(next)
    }

    func toggleBinding(_ binding: Binding<Bool>, enabled: Bool = true) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue }, set: { next in
            guard enabled else { return }
            self.changeToggle(from: binding.wrappedValue, to: next) { binding.wrappedValue = $0 }
        })
    }

    func playCascade(_ haptic: TronHaptic, count: Int) {
        cascade?.cancel()
        cascade = nil
        let ticks = min(count, Self.cascadeLimit)
        guard ticks > 0 else { return }
        play(haptic)
        guard ticks > 1 else { return }
        prepare(haptic)
        cascade = Task { @MainActor [weak self] in
            for _ in 1..<ticks {
                try? await Task.sleep(for: Self.cascadeInterval)
                guard !Task.isCancelled else { return }
                self?.play(haptic)
            }
        }
    }

    private func generator(for haptic: TronHaptic, in view: UIView?) -> UIFeedbackGenerator? {
        guard let anchor = view ?? Self.foregroundWindow() else { return nil }
        if let bound = generators[haptic], bound.view === anchor { return bound.generator }
        let generator: UIFeedbackGenerator = switch haptic {
        case .menuOpened: UIImpactFeedbackGenerator(style: .medium, view: anchor)
        case .promptSent: UIImpactFeedbackGenerator(style: .light, view: anchor)
        case .attachmentAdded: UISelectionFeedbackGenerator(view: anchor)
        case .runFinished: UINotificationFeedbackGenerator(view: anchor)
        case .workerMessage: UIImpactFeedbackGenerator(style: .soft, view: anchor)
        case .questionPresented: UIImpactFeedbackGenerator(style: .rigid, view: anchor)
        case .sheetPresented: UIImpactFeedbackGenerator(style: .medium, view: anchor)
        case .toggleChanged, .selectionChanged: UISelectionFeedbackGenerator(view: anchor)
        case .copied: UIImpactFeedbackGenerator(style: .light, view: anchor)
        case .answerSubmitted, .actionFailed, .terminalBell: UINotificationFeedbackGenerator(view: anchor)
        }
        generators[haptic] = Bound(view: anchor, generator: generator)
        return generator
    }

    private static func foregroundWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
    }
}

#if HOSTED_TEST
@MainActor @Observable
final class TronHapticsProbe {
    static let shared = TronHapticsProbe()
    var played: [TronHaptic] = []

    func count(_ haptic: TronHaptic) -> Int { played.filter { $0 == haptic }.count }
    var summary: String { played.isEmpty ? "none" : played.map(\.rawValue).joined(separator: ",") }
}
#endif
