import Observation
import UIKit

/// Semantic intent, not a generator choice at each call site. Selection ticks
/// mark deliberate value changes; notifications mark accepted outcomes.
enum TronHaptic: String, CaseIterable, Sendable {
    /// The Home button's hold opened the dashboard menu (#1480).
    case menuOpened
    /// The Gateway accepted a sent prompt.
    case promptSent
    /// One tick of a newly attached photo or file sliding into the composer.
    case attachmentAdded
    /// The agent's run settled normally.
    case runFinished
    /// A worker or subagent delivered a message into the chat.
    case workerMessage
    /// A question sheet (`ask_user`) presented.
    case questionPresented
    /// Any other sheet or system picker presented through the shared presenter.
    case sheetPresented
    case toggleChanged
    case selectionChanged
    case copied
    case answerSubmitted
    case actionFailed
    case terminalBell
}

/// The one haptic seam. UIKit's view-bound feedback generators honor the
/// system's System Haptics setting; a generator plays only while its view (by
/// default the foreground-active scene's key window) is on screen, so nothing
/// plays from the background. Hosted UI journeys read `TronHapticsProbe`,
/// because XCUITest cannot feel the Taptic Engine.
@MainActor
final class TronHaptics {
    static let shared = TronHaptics()

    /// A batch of attachments ticks at most this many times, this far apart, so
    /// a large selection reads as a short cascade, never a continuous buzz.
    static let cascadeLimit = 6
    static let cascadeInterval: Duration = .milliseconds(70)

    private struct Bound {
        weak var view: UIView?
        let generator: UIFeedbackGenerator
    }

    private var generators: [TronHaptic: Bound] = [:]
    private var cascade: Task<Void, Never>?

    private init() {}

    /// Warms the Taptic Engine shortly before a haptic that a touch or an
    /// in-flight request makes likely, so it lands without latency.
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

    /// One tick per item up to `cascadeLimit`, `cascadeInterval` apart,
    /// starting now with the first item's insertion. A newer cascade replaces
    /// the remainder of an older one.
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
/// Every haptic played, in order, so UI journeys prove which event played which
/// pattern and that replayed, aborted or background events play none.
@MainActor @Observable
final class TronHapticsProbe {
    static let shared = TronHapticsProbe()
    var played: [TronHaptic] = []

    func count(_ haptic: TronHaptic) -> Int { played.filter { $0 == haptic }.count }
    /// `promptSent,attachmentAdded,...` in play order, or `none`.
    var summary: String { played.isEmpty ? "none" : played.map(\.rawValue).joined(separator: ",") }
}
#endif
