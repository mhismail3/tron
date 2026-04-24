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
        WizardShell(state: state) { step in
            switch step {
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
/// lights floating in the top-left, a pinned progress pill in the top-
/// right, and a transitioning content stack (icon + title, body,
/// secondary/primary action bar) that slides on every step change.
///
/// Layout invariants:
/// ```
/// ┌────────────────────────────────────────┐
/// │ ●●●                            [pill]  │
/// │ [icon] Title                           │
/// │                                        │
/// │   [step body fills here]               │
/// │                                        │
/// │ [secondary]            [primary CTA]   │
/// └────────────────────────────────────────┘
/// ```
///
/// - The pill is pinned in the top-right and never participates in the
///   slide transition; only its capsule fill animates as the step
///   ordinal changes.
/// - Header (icon + title), body content, and the bottom action bar
///   share a single `.id(displayStep)` so they re-mount and slide
///   together as one cohesive unit.
/// - Slide direction is read from `displayDirection`, a local `@State`
///   mirror of `WizardState.slideDirection`. `WizardState`'s navigation
///   methods set the new direction BEFORE mutating `step`; this view
///   then performs a two-phase update (see `onChange` below) so the
///   outgoing chrome is re-rendered with the fresh direction attached
///   to its `.transition(...)` modifier BEFORE its identity changes
///   and SwiftUI unmounts it. Without that deferral, SwiftUI reuses
///   whatever direction was baked into the outgoing view's transition
///   during the PREVIOUS body eval (i.e. the prior navigation's
///   direction), producing reversed animations on every nav after the
///   first.
/// - The shell owns the secondary + primary CTAs for every step. Step
///   bodies provide ONLY their description / body content; tertiary
///   actions (Refresh, Re-check, Retry) live inline within the body
///   so they slide with it.
struct WizardShell<Content: View>: View {
    @Bindable var state: WizardState
    @ViewBuilder var content: (WizardStep) -> Content

    /// The step actually rendered in the chrome. Lags `state.step` by
    /// exactly one runloop tick after a navigation. See the struct-
    /// level doc + the `.onChange` handler in `body` for the rationale.
    @State private var displayStep: WizardStep

    /// Direction consumed by `slideTransition`. Updated SYNCHRONOUSLY
    /// inside `.onChange(of: state.step)` (Phase 1) so the outgoing
    /// chrome re-renders with the fresh direction attached before
    /// `displayStep` changes identity (Phase 2).
    @State private var displayDirection: WizardSlideDirection

    init(state: WizardState, @ViewBuilder content: @escaping (WizardStep) -> Content) {
        self.state = state
        self.content = content
        _displayStep = State(wrappedValue: state.step)
        _displayDirection = State(wrappedValue: state.slideDirection)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Layer 1 (transitioning): header + body + bottom bar
            // re-mount on every `displayStep` change and slide as one
            // cohesive group. The `.id(displayStep)` is what triggers
            // the slide; without it SwiftUI would diff in place and
            // we'd lose the animation.
            VStack(spacing: 0) {
                stepHeader

                content(displayStep)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                bottomBar
            }
            // Tightened from 36 → 18 so the header tucks just below
            // the traffic-lights row instead of floating in dead space.
            // The traffic lights are ~20pt tall starting from the top
            // edge; 18pt of padding leaves a small visual gap without
            // the wizard feeling cavernous at the top.
            .padding(.top, 18)
            .padding(.bottom, 24)
            .padding(.horizontal, 32)
            .id(displayStep)
            .transition(slideTransition)

            // Layer 2 (pinned): the pill stays fixed in the top-right
            // corner. Only its progress fill width animates as the
            // step ordinal moves; the pill itself never re-mounts, so
            // it doesn't slide.
            //
            // The `.frame(height: 28)` matches the icon-row height in
            // `stepHeader` so the pill capsule (which is intrinsically
            // ~24pt tall) vertically center-aligns with the icon and
            // title within a 28pt-high optical row. Both this layer
            // and the chrome above use `.padding(.top, 18)`, so the
            // 28pt frame sits at the same Y as the icon row and their
            // optical centers land at the same pixel.
            progressPill
                .frame(height: 28)
                .padding(.top, 18)
                .padding(.trailing, 32)
        }
        // Pinned to the same fixed dimensions the WindowGroup uses in
        // `TronMacApp.swift` — the window is non-resizable, so every
        // step gets exactly this much canvas. Trimmed from 400 → 360
        // to remove the dead bottom space that empty steps (Welcome,
        // Done) made obvious. The densest steps (Permissions,
        // PairingInfo) compensate via internal scrolling / a smaller
        // QR so the layout still fits.
        .frame(width: 480, height: 360)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: displayStep)
        // Two-phase direction+step update (see struct doc). Phase 1
        // runs synchronously: write the new direction, which re-renders
        // the CURRENTLY-mounted chrome so its `.transition(slideTransition)`
        // modifier now holds the fresh direction. Phase 2 runs one
        // runloop tick later via `DispatchQueue.main.async`: flip
        // `displayStep`, which changes the chrome's `.id(...)` and
        // triggers SwiftUI to unmount the outgoing view (using the
        // direction Phase 1 just baked in) and mount the incoming
        // view. If we set both synchronously, both sides of the
        // transition use the direction from the PREVIOUS navigation
        // (because that's what was baked into the outgoing view's
        // transition during the prior body eval), and the animation
        // reverses on every step after the first.
        .onChange(of: state.step) { _, newStep in
            displayDirection = state.slideDirection
            DispatchQueue.main.async {
                displayStep = newStep
            }
        }
    }

    // MARK: - Header (icon + title)

    @ViewBuilder
    private var stepHeader: some View {
        HStack(spacing: 12) {
            stepIcon
            Text(displayStep.displayTitle)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.tronEmerald)
            Spacer(minLength: 12)
        }
        // Reserve trailing space so a long title (e.g. "Pair your
        // iPhone") doesn't collide with the pinned pill in Layer 2.
        // The pill is ~120pt wide + 32pt padding from the right edge
        // = ~152pt; 140pt of reserved space leaves a small visible
        // gap between title and pill on the longest-title step.
        .padding(.trailing, 140)
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch displayStep.headerIcon {
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.tronEmerald)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.tronEmerald)
                .frame(width: 28, height: 28)
        }
    }

    // MARK: - Bottom action bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 12) {
            secondaryButton
            Spacer(minLength: 0)
            primaryButton
        }
    }

    @ViewBuilder
    private var secondaryButton: some View {
        switch displayStep {
        case .welcome:
            // Power-user shortcut — not a back button. The Welcome
            // step is the entry point so there's nothing to go back
            // to anyway.
            Button {
                state.skipToPairing()
            } label: {
                Text("I already have Tron running")
            }
            .buttonStyle(.wizardLink)
        case .done:
            // Done is terminal; no secondary action.
            EmptyView()
        default:
            Button {
                state.goBack()
            } label: {
                Text("Back")
            }
            .buttonStyle(.wizardSecondary)
            .help("Back to previous step")
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch displayStep {
        case .welcome:
            Button {
                state.advance()
            } label: {
                Text("Get started")
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
        case .tailscale:
            Button {
                state.advance()
            } label: {
                Text(state.tailscaleStatus?.isReady == true ? "Continue" : "I have Tailscale")
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
        case .existingInstall:
            Button {
                state.advance()
            } label: {
                Text(existingInstallContinueLabel)
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
        case .permissions:
            Button {
                state.advance()
            } label: {
                Text("Continue")
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!permissionsCanContinue)
        case .install:
            Button {
                state.advance()
            } label: {
                Text("Continue")
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!installCanContinue)
        case .pairingInfo:
            Button {
                state.complete()
            } label: {
                Text("I'm paired")
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(state.pairingPayload == nil)
        case .done:
            Button {
                NotificationCenter.default.post(name: .tronWizardDidComplete, object: nil)
            } label: {
                Text("Open menu bar")
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var existingInstallContinueLabel: String {
        if case .installed = state.existingInstallStatus { return "Skip install" }
        return "Continue"
    }

    /// Mirrors the gate previously implemented privately by
    /// `PermissionsStep`: FDA + Notifications must both be granted;
    /// Accessibility is skippable.
    private var permissionsCanContinue: Bool {
        let fda = state.permissionStatuses[.fullDiskAccess] ?? .notDetermined
        let notif = state.permissionStatuses[.notifications] ?? .notDetermined
        return fda == .granted && notif == .granted
    }

    /// Mirrors the gate previously implemented privately by
    /// `InstallStep`: Continue is enabled only after the install
    /// pipeline has finished cleanly. The step body's Retry button
    /// resets `installOutcome` to `nil` while running, so this
    /// implicitly disables Continue during a retry too — we don't
    /// need to plumb a separate `running` flag through state.
    private var installCanContinue: Bool {
        guard let outcome = state.installOutcome else { return false }
        return outcome == .success || outcome == .alreadyInstalled
    }

    // MARK: - Pinned progress pill

    @ViewBuilder
    private var progressPill: some View {
        let cases = WizardStep.allCases
        let current = (cases.firstIndex(of: displayStep) ?? 0) + 1
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

    // MARK: - Direction-aware slide transition

    /// Reads `displayDirection` (a local mirror of `state.slideDirection`
    /// updated in Phase 1 of the two-phase `onChange` handler above).
    /// Forward navigations slide the outgoing view off-left and the
    /// incoming view in from the right; back navigations reverse both
    /// edges. The whole shell mimics a horizontal pager: forward =
    /// swipe left, back = swipe right.
    private var slideTransition: AnyTransition {
        switch displayDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }
}
