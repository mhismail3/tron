import SwiftUI
import TronMobileCore
import UIKit

/// Named chat-owned motion curves. Distinct values remain separate until a
/// frame-verified product decision explicitly unifies them.
enum ChatMotion {
    #if HOSTED_TEST
    /// Pixel conformance slows the test-host clock without changing release
    /// animations or the geometry suites' real-time motion measurements.
    nonisolated(unsafe) static var hostedTestAnimationScale = 1.0
    #endif

    private static func scaled(_ animation: Animation) -> Animation {
        #if HOSTED_TEST
        animation.speed(1 / hostedTestAnimationScale)
        #else
        animation
        #endif
    }

    private static func scaledOptional(_ animation: Animation?) -> Animation? {
        animation.map(scaled)
    }

    private static func scaledDuration(_ duration: TimeInterval) -> TimeInterval {
        #if HOSTED_TEST
        duration * hostedTestAnimationScale
        #else
        duration
        #endif
    }

    // Arrive
    static let transcriptRevealDuration: TimeInterval = 0.18
    static let promptArriveDuration: TimeInterval = 0.28
    static func transcriptReveal(reduceMotion: Bool) -> Animation {
        scaled(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: transcriptRevealDuration))
    }
    static func promptArrive(reduceMotion: Bool) -> Animation {
        scaled(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: promptArriveDuration))
    }
    static func transcriptViewReveal(reduceMotion: Bool) -> Animation {
        scaled(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.26))
    }
    static func floatingDisplayArrive(reduceMotion: Bool) -> Animation {
        scaled(reduceMotion ? .linear(duration: 0.10) : .smooth(duration: 0.22))
    }
    static func notificationArrive(reduceMotion: Bool) -> Animation {
        scaled(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.22))
    }
    static func attachmentArrive(reduceMotion: Bool) -> Animation {
        scaled(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.22))
    }
    static func eventArrive(reduceMotion: Bool) -> Animation? {
        scaledOptional(reduceMotion ? nil : .smooth(duration: 0.24))
    }
    static func disclosureFade(reduceMotion: Bool) -> Animation? {
        scaledOptional(reduceMotion ? nil : .easeOut(duration: 0.10))
    }
    static func attachmentPreview(reduceMotion: Bool) -> Animation? {
        scaledOptional(reduceMotion ? nil : .easeInOut(duration: 0.16))
    }
    static func controlArrive(reduceMotion: Bool) -> Animation? {
        scaledOptional(reduceMotion ? nil : .smooth(duration: 0.18))
    }

    // Replace
    static func queuedPromptReplace(reduceMotion: Bool) -> Animation? {
        scaledOptional(reduceMotion ? .linear(duration: 0.10) : .smooth(duration: 0.16))
    }
    static func toolValueReplace(reduceMotion: Bool) -> Animation {
        scaled(reduceMotion ? .linear(duration: 0.10) : .smooth(duration: 0.20))
    }
    // Resize
    static var streamingResize: Animation { scaled(.smooth(duration: 0.16)) }
    static var composerAccessoryResize: Animation { scaled(.smooth(duration: 0.24)) }
    static func composerSurfaceResize(reduceMotion: Bool) -> Animation {
        scaled(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.86, blendDuration: 0.06))
    }
    static func composerStructuralResize(reduceMotion: Bool) -> Animation {
        reduceMotion ? scaled(.easeOut(duration: 0.12)) : composerStructuralSpring
    }
    // Depart (available to the transcript departure owner).
    static var transcriptDepart: Animation { scaled(.smooth(duration: 0.16)) }

    // Move
    static var floatingDisplayMove: Animation { scaled(.smooth(duration: 0.28)) }
    static var cameraControl: Animation { scaled(.smooth(duration: 0.28)) }
    static var floatingDisplayInstall: Animation { scaled(.linear(duration: 0)) }

    // Control
    static var composerStructuralSpring: Animation { scaled(.spring(response: 0.32, dampingFraction: 0.82)) }
    static var composerControlSpring: Animation { scaled(.spring(response: 0.35, dampingFraction: 0.8)) }
    static var composerModeSpring: Animation { scaled(.spring(response: 0.22, dampingFraction: 0.72)) }
    static var keyboardControl: Animation { scaled(.easeOut(duration: 0.22)) }
    static var composerTap: Animation { scaled(.easeOut(duration: 0.08)) }
    static func composerMode(reduceMotion: Bool) -> Animation? {
        scaledOptional(reduceMotion ? nil : .easeInOut(duration: 0.20))
    }
    static var questionProgressControl: Animation { scaled(.snappy(duration: 0.24)) }
    static var extensionSelectionControl: Animation { scaled(.smooth(duration: 0.24)) }
    static var extensionQuestionControl: Animation { scaled(.easeInOut(duration: 0.18)) }

    // Scroll positioning remains owned by ChatScrollCoordinator, not row motion.
    static func catchUpScroll(reduceMotion: Bool) -> ChatScrollAnimation {
        reduceMotion ? .disabled : .smooth(duration: scaledDuration(0.30))
    }
    static func historyScroll(reduceMotion: Bool) -> ChatScrollAnimation {
        reduceMotion ? .disabled : .smooth(duration: scaledDuration(0.30))
    }
    static var semanticRowScroll: ChatScrollAnimation { .smooth(duration: scaledDuration(0.25)) }

    // ChatLayoutTransaction keeps its geometry/keyboard API and uses these values.
    static let layoutSmoothDuration: TimeInterval = 0.34
    static let processOrbModeDuration: TimeInterval = 0.34
    static func processOrbMode(reduceMotion: Bool) -> Animation {
        scaled(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: processOrbModeDuration))
    }
    static func smooth(duration: TimeInterval) -> Animation { scaled(.smooth(duration: duration)) }
    static func keyboardCurve(_ curve: UIView.AnimationCurve, duration: TimeInterval) -> Animation {
        let animation: Animation = switch curve {
        case .easeInOut: .easeInOut(duration: duration)
        case .easeIn: .easeIn(duration: duration)
        case .easeOut: .easeOut(duration: duration)
        case .linear: .linear(duration: duration)
        @unknown default: .easeInOut(duration: duration)
        }
        return scaled(animation)
    }
}
