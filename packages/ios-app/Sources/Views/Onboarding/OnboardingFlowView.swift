import SwiftUI

/// Root of the iOS onboarding wizard. Switches on
/// `OnboardingState.step`; every step view is a regular SwiftUI view
/// wrapped in `OnboardingShell`.
///
/// **Why a switch + transition** instead of `NavigationStack`:
///   - Onboarding is linear with a single back chevron — `NavigationStack`
///     would add iOS chrome (large titles, swipe-to-dismiss) the design
///     doesn't want.
///   - Each step persists its index in `OnboardingState` so kill+relaunch
///     resumes correctly without modeling routes.
///   - Transitions stay smooth via SwiftUI's matched-geometry / asymmetric
///     transitions on `step.rawValue`.
///
/// **Lifecycle**:
///   1. The first-run gate in `TronMobileApp.readyContent()` mounts this
///      view when `@AppStorage("onboardingComplete") == false`.
///   2. The user walks through `welcome → … → done`.
///   3. On `done`, `OnboardingState.complete()` flips
///      `@AppStorage("onboardingComplete") = true` and the gate swaps in
///      the regular `ContentView` chain.
struct OnboardingFlowView: View {
    @State var state: OnboardingState
    let dependencies: DependencyContainer
    /// Closure injected by the first-run gate so the wizard can request
    /// "we're done — present ContentView". The default just calls
    /// `state.complete()`; tests can capture the call.
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
        ZStack {
            currentStepView
                .id(state.step.rawValue) // re-render on step change so the transition fires
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
        }
        .animation(.easeInOut(duration: 0.22), value: state.step)
    }

    @ViewBuilder
    private var currentStepView: some View {
        switch state.step {
        case .welcome:
            WelcomeStep(state: state)
        case .tailscale:
            TailscaleStep(state: state)
        case .macInstall:
            MacInstallStep(state: state)
        case .pairing:
            PairingStep(state: state, dependencies: dependencies)
        case .provider:
            ProviderStep(state: state, dependencies: dependencies)
        case .telemetryConsent:
            TelemetryConsentStep(state: state)
        case .notifications:
            NotificationsStep(state: state, dependencies: dependencies)
        case .done:
            DoneStep(state: state, onComplete: onComplete)
        }
    }
}
