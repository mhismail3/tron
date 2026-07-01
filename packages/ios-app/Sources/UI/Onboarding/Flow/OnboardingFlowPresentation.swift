import SwiftUI

/// Central launch and sheet policy for the onboarding/pairing flow.
///
/// The app has several entry points into pairing: first-run bootstrap, Server
/// settings repair/add-server, and pairing URLs. They must all present the same
/// `OnboardingFlowView` with the same sheet geometry so the connect form does
/// not drift into a separate sheet policy.
enum OnboardingLaunchSource: Equatable {
    case firstRun
    case serverSettings
    case pairingURL

    func allowsDismiss(onboardingComplete: Bool) -> Bool {
        switch self {
        case .firstRun:
            return false
        case .serverSettings:
            return true
        case .pairingURL:
            return onboardingComplete
        }
    }
}

enum OnboardingSheetPresentation {
    static let detents: Set<PresentationDetent> = [.medium]
    static let initialDetent: PresentationDetent = .medium

    static func shouldAutoPresent(
        onboardingComplete: Bool,
        onboardingSuppressed: Bool
    ) -> Bool {
        !onboardingComplete && !onboardingSuppressed
    }
}
