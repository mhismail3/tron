import CoreGraphics
import SwiftUI

/// Pure layout constants for the onboarding wizard shell.
///
/// Keeping these values out of `WizardView` gives tests a stable
/// surface for the invariants users can feel immediately: the opening
/// gate steps share one content size, and the bottom action bar is
/// pinned to the same insets regardless of which step body is sliding.
enum WizardLayout {
    static let width: CGFloat = 480
    static let horizontalPadding: CGFloat = 32
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 24
    static let headerHeight: CGFloat = 28
    static let headerBodySpacing: CGFloat = 18
    static let bottomBarHeight: CGFloat = 54
    static let buttonCornerRadius: CGFloat = 11
    static let progressBarWidth: CGFloat = 82
    static let progressBarHeight: CGFloat = 8
    static let progressBarMinFillWidth: CGFloat = progressBarHeight

    static let transitionAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let progressAnimation = transitionAnimation
    static let resizeDuration: TimeInterval = 0.42

    static func contentHeightDelta(from oldStep: WizardStep, to newStep: WizardStep) -> CGFloat {
        newStep.preferredHeight - oldStep.preferredHeight
    }

    static func shouldResizeWindow(from oldStep: WizardStep, to newStep: WizardStep) -> Bool {
        abs(contentHeightDelta(from: oldStep, to: newStep)) >= 1
    }
}
