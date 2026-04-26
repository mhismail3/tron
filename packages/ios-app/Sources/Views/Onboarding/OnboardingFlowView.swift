import SwiftUI

/// Root of the iOS onboarding sheet. iOS onboarding has one job: connect
/// this device to the Mac server that the Mac app already installed.
///
/// **Why a sheet** instead of a full-screen first-run gate:
///   - The dashboard mounts immediately, so a fresh install still looks
///     like the app.
///   - Pairing is the only required first-run action; providers,
///     telemetry, and notification preferences live in Settings.
///   - The sheet can expand for keyboard entry but starts at a medium
///     detent so setup feels lightweight.
///
/// **Lifecycle**:
///   1. `TronMobileApp.readyContent()` mounts this view in a sheet when
///      `@AppStorage("onboardingComplete") == false`.
///   2. The user pairs with a running Mac server.
///   3. On successful pairing, `OnboardingState.complete()` flips
///      `@AppStorage("onboardingComplete") = true` and the sheet dismisses.
struct OnboardingFlowView: View {
    @State var state: OnboardingState
    let dependencies: DependencyContainer
    let onComplete: () -> Void

    init(
        state: OnboardingState,
        dependencies: DependencyContainer,
        onComplete: @escaping () -> Void
    ) {
        _state = State(initialValue: state)
        self.dependencies = dependencies
        self.onComplete = onComplete
    }

    var body: some View {
        PairingStep(
            state: state,
            dependencies: dependencies,
            onPaired: onComplete
        )
    }
}
