import SwiftUI

/// Top-level wizard. Reads the current `WizardStep` from `WizardState`
/// and dispatches to a per-step view. The shell (top-bar with progress,
/// glass canvas, animated step transitions) is shared by `WizardShell`.
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
            state.existingInstallStatus = setup.detectExistingInstall()
        }
    }
}

/// Shared chrome — single liquid-glass canvas with the system traffic
/// lights floating in the top-left and a slim progress bar in the
/// top-right. No separator between the top region and the content; the
/// whole window is one continuous surface.
///
/// Layout:
/// ```
/// ┌───────────────────────────────────┐
/// │ ●●●            ████░░░░░░         │
/// │                                   │
/// │      [step content fills here]    │
/// │                                   │
/// └───────────────────────────────────┘
/// ```
struct WizardShell<Content: View>: View {
    @Bindable var state: WizardState
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            // Per-step content fills the full window so it can lay out
            // its own title at the top-left (with breathing room for
            // the traffic lights) and its CTAs at the bottom.
            content()
                .padding(.top, 36)        // clear the traffic-light row
                .padding(.bottom, 24)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
                .id(state.step) // re-mount per step so transitions fire

            // Top bar — only the progress pill, anchored top-right and
            // vertically centred with the per-step title row in
            // `content()` (which sits at `.padding(.top, 36)` and is
            // ~28pt tall thanks to the 28pt logo). Matching the pill's
            // top padding to the content's puts it on the same baseline
            // as the title.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if state.step != .done {
                    progressPill
                }
            }
            .padding(.top, 36)
            .padding(.horizontal, 32)
        }
        // Pinned to the same fixed dimensions the WindowGroup uses in
        // `TronMacApp.swift` — the window is non-resizable, so every
        // step gets exactly this much canvas. If a step needs more
        // breathing room, it's the step's job to abbreviate, not the
        // shell's job to grow.
        .frame(width: 480, height: 360)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: state.step)
    }

    // MARK: - Progress pill (top-right)

    @ViewBuilder
    private var progressPill: some View {
        let cases = WizardStep.allCases
        let current = (cases.firstIndex(of: state.step) ?? 0) + 1
        let total = cases.count
        let fraction = Double(current) / Double(total)

        HStack(spacing: 8) {
            Text("\(current) / \(total)")
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(Color.tronEmerald.opacity(0.85))
                .monospacedDigit()
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.tronEmerald.opacity(0.18))
                    .frame(width: 80, height: 4)
                Capsule(style: .continuous)
                    .fill(LinearGradient.tronEmeraldGradient)
                    .frame(width: max(4, 80 * fraction), height: 4)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: fraction)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.tronEmerald.opacity(0.18), lineWidth: 0.5)
                )
        )
    }
}
