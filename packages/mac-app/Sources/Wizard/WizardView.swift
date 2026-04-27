import SwiftUI
import AppKit

/// Top-level wizard. Reads the current `WizardStep` from `WizardState`
/// and dispatches to a per-step view. The shell (top-bar with progress,
/// fixed action bar, glass canvas, animated step transitions) is shared
/// by `WizardShell`.
///
/// Pass `initialStep` to override the persisted last-visited step for
/// wizard-owned recovery paths. The menu-bar pairing action uses its
/// dedicated pairing-only window instead of remounting this wizard.
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
                WelcomeStep()
            case .tailscale:
                TailscaleStep(state: state)
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

private struct WizardProgressTrack: View, @MainActor Animatable {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    private var clampedFraction: Double {
        min(1, max(0, fraction))
    }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.4, dy: 0.4)
            let radius = rect.height / 2
            let track = Path(roundedRect: rect, cornerRadius: radius)
            let fillWidth = max(WizardLayout.progressBarMinFillWidth, rect.width * clampedFraction)
            let fillRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: min(rect.width, fillWidth),
                height: rect.height
            )
            let fill = Path(roundedRect: fillRect, cornerRadius: radius)

            context.fill(track, with: .color(Color.tronEmerald.opacity(0.11)))
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [Color.tronMint, Color.tronEmeraldDeep]),
                startPoint: CGPoint(x: fillRect.midX, y: fillRect.minY),
                endPoint: CGPoint(x: fillRect.midX, y: fillRect.maxY)
            ))
            context.stroke(fill, with: .linearGradient(
                Gradient(colors: [
                    Color.white.opacity(0.52),
                    Color.black.opacity(0.22),
                ]),
                startPoint: CGPoint(x: fillRect.midX, y: fillRect.minY),
                endPoint: CGPoint(x: fillRect.midX, y: fillRect.maxY)
            ), lineWidth: 0.6)
            context.stroke(track, with: .linearGradient(
                Gradient(colors: [
                    Color.black.opacity(0.16),
                    Color.white.opacity(0.32),
                ]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            ), lineWidth: 0.8)
        }
        .shadow(color: Color.white.opacity(0.55), radius: 1, x: 0, y: -1)
        .shadow(color: Color.black.opacity(0.12), radius: 1.5, x: 0, y: 1)
        .drawingGroup()
    }
}

/// Shared chrome — single liquid-glass canvas with the system traffic
/// lights floating in the top-left, a pinned header row (step icon +
/// title + progress), a transitioning body, and a pinned
/// secondary/primary action bar.
///
/// Layout invariants:
/// ```
/// ┌────────────────────────────────────────┐
/// │ ●●●                                    │
/// │ [icon] Title                    [pill] │
/// │                                        │
/// │   [step body fills here]               │
/// │                                        │
/// │ [secondary]            [primary CTA]   │
/// └────────────────────────────────────────┘
/// ```
///
/// - The header row is pinned, so the icon, title, and progress pill
///   share one vertical center on every step. The title/icon group
///   transitions inside that row; the progress fill animates inside
///   one stable Canvas-backed track.
/// - Body content owns a single `.id(displayStep)` so it re-mounts and
///   slides as one cohesive unit. The shell keeps one fixed-height
///   viewport, so every page slides across the same clipping geometry.
/// - The bottom action bar is an overlay pinned to
///   `WizardLayout.bottomPadding` + `WizardLayout.horizontalPadding`.
///   Step bodies cannot push it around during measurement.
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
///   actions (Refresh, Re-check) live inline within the body
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
    @State private var hostingWindow: NSWindow?

    init(state: WizardState, @ViewBuilder content: @escaping (WizardStep) -> Content) {
        self.state = state
        self.content = content
        _displayStep = State(wrappedValue: state.step)
        _displayDirection = State(wrappedValue: state.slideDirection)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Layer 1 (content plane): body content re-mounts on every
            // `displayStep` change and slides as one cohesive group.
            // The top inset reserves permanent space for Layer 3's
            // pinned header row, and the bottom inset reserves Layer
            // 2's pinned action bar. Dynamic body measurement cannot
            // move the Back/Continue buttons or the progress pill even
            // for a single frame.
            content(displayStep)
                .padding(.top, WizardLayout.topPadding + WizardLayout.headerHeight + WizardLayout.headerBodySpacing)
                .padding(.horizontal, WizardLayout.horizontalPadding)
                .padding(.bottom, WizardLayout.bottomPadding + WizardLayout.bottomBarHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(displayStep)
                .transition(slideTransition)
                .animation(WizardLayout.transitionAnimation, value: displayStep)

            // Layer 2 (pinned): bottom bar has an explicit height and
            // absolute bottom alignment inside the 480×H canvas. Only
            // its labels/styles switch with `displayStep`; the bar's
            // frame never gets remeasured by the sliding content.
            bottomBar
                .frame(height: WizardLayout.bottomBarHeight, alignment: .center)
                .padding(.horizontal, WizardLayout.horizontalPadding)
                .padding(.bottom, WizardLayout.bottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            // Layer 3 (pinned): one real header row owns icon, title,
            // and progress. Keeping the pill in this row prevents the
            // progress track from drifting away from the title chrome
            // during page transitions.
            headerBar
                .padding(.top, WizardLayout.topPadding)
                .padding(.horizontal, WizardLayout.horizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Fixed wizard canvas: width stays 480 and height stays at the
        // tallest step's requirement. Lower-density pages get breathing
        // room, and every horizontal page slide runs inside identical
        // clipping geometry.
        .frame(width: WizardLayout.width, height: WizardLayout.height)
        .configureHostingWindow { window in
            hostingWindow = window
            applyWindowBackgroundDragPolicy(for: displayStep, window: window)
        }
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
                applyWindowBackgroundDragPolicy(for: newStep)
            }
        }
        .onChange(of: displayStep) { _, newStep in
            applyWindowBackgroundDragPolicy(for: newStep)
        }
        .onDisappear {
            hostingWindow?.isMovableByWindowBackground = true
        }
    }

    /// The glass window normally allows background dragging so the
    /// titlebar-less canvas still feels movable. Permissions is the
    /// exception: its Screen Recording row contains a real app-bundle
    /// drag source, and AppKit can otherwise interpret click-hold as a
    /// window move before the shortcut starts its file drag.
    private func applyWindowBackgroundDragPolicy(for step: WizardStep, window: NSWindow? = nil) {
        guard let window = window ?? hostingWindow else { return }
        window.isMovableByWindowBackground = step != .permissions
    }

    // MARK: - Header (icon + title + progress)

    @ViewBuilder
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack(alignment: .leading) {
                stepTitleGroup
                    .id(displayStep)
                    .transition(slideTransition)
                    .animation(WizardLayout.transitionAnimation, value: displayStep)
            }
            .frame(maxWidth: .infinity, maxHeight: WizardLayout.headerHeight, alignment: .leading)
            .clipped()

            progressPill
        }
        .frame(height: WizardLayout.headerHeight, alignment: .center)
    }

    @ViewBuilder
    private var stepTitleGroup: some View {
        HStack(spacing: 12) {
            stepIcon
            Text(displayStep.displayTitle)
                .font(TronTypography.wizardTitle)
                .foregroundStyle(Color.tronEmerald)
            Spacer(minLength: 12)
        }
        .frame(height: WizardLayout.headerHeight, alignment: .center)
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch displayStep.headerIcon {
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: WizardLayout.headerHeight, alignment: .center)
                .foregroundStyle(Color.tronEmerald)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.tronEmerald)
                .frame(width: 28, height: WizardLayout.headerHeight, alignment: .center)
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
                if installCanContinue {
                    state.advance()
                } else {
                    state.requestInstall()
                }
            } label: {
                Text(installPrimaryLabel)
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(state.installIsRunning)
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

    /// Gate for the Permissions step's Continue button. All three
    /// categories (FDA, Screen Recording, Accessibility) must be
    /// granted — the Rust agent's Computer-Use tool refuses to run
    /// without every one of them (see
    /// `packages/agent/src/tools/ui/computer_use/permissions.rs`),
    /// so we'd rather hold the wizard here than let the user land
    /// on a half-working install.
    private var permissionsCanContinue: Bool {
        Permission.allCases.allSatisfy { permission in
            state.permissionStatuses[permission] == .granted
        }
    }

    /// Mirrors the gate previously implemented privately by
    /// `InstallStep`: the primary CTA advances only after the install
    /// pipeline has finished cleanly. Before then, the same CTA starts
    /// or retries the pipeline via `state.requestInstall()`.
    private var installCanContinue: Bool {
        guard let outcome = state.installOutcome else { return false }
        return outcome == .success || outcome == .alreadyInstalled
    }

    private var installPrimaryLabel: String {
        if installCanContinue { return "Continue" }
        if state.installIsRunning { return "Installing..." }
        if let outcome = state.installOutcome, outcome != .success, outcome != .alreadyInstalled {
            return "Retry install"
        }
        return "Install"
    }

    // MARK: - Pinned progress pill

    @ViewBuilder
    private var progressPill: some View {
        let cases = WizardStep.allCases
        let current = (cases.firstIndex(of: displayStep) ?? 0) + 1
        let total = cases.count
        let fraction = Double(current) / Double(total)

        HStack(spacing: 8) {
            progressCount(current: current, total: total)
            progressTrack(fraction: fraction)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.tronEmerald.opacity(0.06))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.tronEmerald.opacity(0.14), lineWidth: 0.6)
                )
        )
    }

    @ViewBuilder
    private func progressCount(current: Int, total: Int) -> some View {
        Text("\(current) / \(total)")
            .font(TronTypography.wizardProgress)
            .foregroundStyle(Color.tronEmerald.opacity(0.90))
            .monospacedDigit()
            .shadow(color: Color.white.opacity(0.42), radius: 0.5, x: 0, y: -0.5)
            .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 0.5)
    }

    @ViewBuilder
    private func progressTrack(fraction: Double) -> some View {
        WizardProgressTrack(fraction: fraction)
            .frame(
                width: WizardLayout.progressBarWidth,
                height: WizardLayout.progressBarHeight,
                alignment: .leading
            )
            .animation(WizardLayout.progressAnimation, value: fraction)
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
