import Observation
import UIKit

struct ChatKeyboardTransition: Equatable, Sendable {
    let targetHeight: CGFloat
    let duration: Double
    let curve: UIView.AnimationCurve

    var isVisible: Bool { targetHeight > 0 }
}

@MainActor
@Observable
final class ChatKeyboardObserver {
    private(set) var transition: ChatKeyboardTransition?
    private(set) var revision = 0
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private weak var ownerWindow: UIWindow?

    var isVisible: Bool { transition?.isVisible == true }

    func setOwnerWindow(_ window: UIWindow?) {
        ownerWindow = window
    }

    func transitionArrived(after admittedRevision: Int) -> Bool {
        revision != admittedRevision
    }

    func start(center: NotificationCenter = .default) {
        guard tokens.isEmpty else { return }
        let names: [NSNotification.Name] = [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillHideNotification,
        ]
        tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let values = notification.userInfo ?? [:]
                let duration = max(
                    0,
                    (values[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
                )
                let rawCurve = (values[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
                    ?? UIView.AnimationCurve.easeInOut.rawValue
                let endFrame = (values[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let isHide = notification.name == UIResponder.keyboardWillHideNotification
                // The observer is registered on the main queue. Update the
                // primitive transition in this callback, not in a deferred Task,
                // so send() can read the UIKit clock after resigning.
                MainActor.assumeIsolated {
                    self?.receive(
                        endFrame: endFrame,
                        duration: duration,
                        rawCurve: rawCurve,
                        isHide: isHide
                    )
                }
            }
        }
    }

    func stop(center: NotificationCenter = .default) {
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll(keepingCapacity: false)
        transition = nil
    }

    private func receive(
        endFrame: CGRect?,
        duration: Double,
        rawCurve: Int,
        isHide: Bool
    ) {
        let curve = UIView.AnimationCurve(rawValue: rawCurve) ?? .easeInOut
        let localFrame = endFrame.flatMap { frame in
            ownerWindow?.convert(frame, from: nil)
        }
        let targetHeight = Self.targetHeight(
            localFrame: localFrame,
            windowBounds: ownerWindow?.bounds ?? .null,
            isHide: isHide
        )
        transition = ChatKeyboardTransition(
            targetHeight: targetHeight,
            duration: duration,
            curve: curve
        )
        revision &+= 1
    }

    static func targetHeight(
        localFrame: CGRect?,
        windowBounds: CGRect,
        isHide: Bool
    ) -> CGFloat {
        guard !isHide, let localFrame, !windowBounds.isNull else { return 0 }
        let intersection = windowBounds.intersection(localFrame)
        return intersection.isNull ? 0 : max(0, intersection.height)
    }
}
