import SwiftUI
import TronMobileCore
import UIKit

enum ChatMotion {
    static let transcriptRevealDuration: TimeInterval = 0.18
    static let promptArriveDuration: TimeInterval = 0.28
    static func transcriptReveal(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: transcriptRevealDuration)
    }
    static func promptArrive(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: promptArriveDuration)
    }
    static func transcriptViewReveal(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.26)
    }
    static func floatingDisplayArrive(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.10) : .smooth(duration: 0.22)
    }
    static func attachmentArrive(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.22)
    }
    static func attachmentPreview(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.16)
    }
    static func controlArrive(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.18)
    }

    static func queuedPromptReplace(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .linear(duration: 0.10) : .smooth(duration: 0.16)
    }
    static func toolValueReplace(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.10) : .smooth(duration: 0.20)
    }
    static let streamingResize = Animation.smooth(duration: 0.16)
    static let composerAccessoryResize = Animation.smooth(duration: 0.24)
    static func composerSurfaceResize(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.86, blendDuration: 0.06)
    }
    static func composerStructuralResize(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : composerStructuralSpring
    }

    static let floatingDisplayMove = Animation.smooth(duration: 0.28)
    static let cameraControl = Animation.smooth(duration: 0.28)
    static let floatingDisplayInstall = Animation.linear(duration: 0)

    static let composerStructuralSpring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let composerControlSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let composerModeSpring = Animation.spring(response: 0.22, dampingFraction: 0.72)
    static let composerTap = Animation.easeOut(duration: 0.08)
    static func composerMode(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.20)
    }
    static let questionProgressControl = Animation.snappy(duration: 0.24)
    static func questionPageTurn(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : questionProgressControl
    }
    static let extensionSelectionControl = Animation.smooth(duration: 0.24)

    static func catchUpScroll(reduceMotion: Bool) -> ChatScrollAnimation {
        reduceMotion ? .disabled : .smooth(duration: 0.30)
    }
    static func historyScroll(reduceMotion: Bool) -> ChatScrollAnimation {
        reduceMotion ? .disabled : .smooth(duration: 0.30)
    }

    static let layoutSmoothDuration: TimeInterval = 0.34
    static let processOrbModeDuration: TimeInterval = 0.34
    static func processOrbMode(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: processOrbModeDuration)
    }
    static func smooth(duration: TimeInterval) -> Animation { .smooth(duration: duration) }
    static func keyboardCurve(_ curve: UIView.AnimationCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeInOut: .easeInOut(duration: duration)
        case .easeIn: .easeIn(duration: duration)
        case .easeOut: .easeOut(duration: duration)
        case .linear: .linear(duration: duration)
        @unknown default: .easeInOut(duration: duration)
        }
    }
}
