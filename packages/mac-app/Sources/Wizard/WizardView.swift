import SwiftUI

/// Top-level wizard. Reads the current `WizardStep` from `WizardState`
/// and dispatches to a per-step view. The shell (header + footer +
/// back button) is shared by `WizardShell`.
///
/// Pass `initialStep` to override the persisted last-visited step. The
/// menu-bar's "Show pairing info…" path uses this to remount the wizard
/// directly at `.pairingInfo` after the user has already onboarded.
struct WizardView: View {
    @Environment(\.environmentSetup) private var setup
    @State private var state: WizardState

    init(initialStep: WizardStep? = nil) {
        _state = State(initialValue: WizardState(initialStep: initialStep))
    }

    var body: some View {
        WizardShell(state: state) {
            switch state.step {
            case .welcome:
                WelcomeStep(state: state)
            case .tailscale:
                TailscaleStep(state: state)
            case .existingInstall:
                ExistingInstallStep(state: state)
            case .permissions:
                PermissionsStep(state: state)
            case .install:
                InstallStep(state: state)
            case .pairingInfo:
                PairingInfoStep(state: state)
            case .done:
                DoneStep(state: state)
            }
        }
        .environment(state)
        .onAppear {
            // Detect existing install on entry so the welcome step's
            // power-user shortcut is wired correctly.
            state.existingInstallStatus = setup.detectExistingInstall()
        }
    }
}

/// Shared chrome around every step: rounded card, header, footer, back
/// button. Mirrors the iOS `OnboardingShell` layout for visual
/// consistency.
struct WizardShell<Content: View>: View {
    @Bindable var state: WizardState
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // ScrollView is defensive — content fits comfortably at the
            // window's ideal size (640×860) but small displays or
            // user-shrunk windows fall back to scrolling instead of
            // clipping.
            ScrollView {
                content()
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(
            minWidth: 580, idealWidth: 640,
            minHeight: 780, idealHeight: 860
        )
        .background(.windowBackground)
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            if state.step != .welcome && state.step != .done {
                Button {
                    state.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
            }
            Spacer()
            ProgressView(value: progressFraction)
                .frame(maxWidth: 200)
            Spacer()
            // Right-side balancer for centered progress
            Color.clear.frame(width: 60)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var progressFraction: Double {
        let cases = WizardStep.allCases
        guard let i = cases.firstIndex(of: state.step) else { return 0 }
        return Double(i + 1) / Double(cases.count)
    }
}
