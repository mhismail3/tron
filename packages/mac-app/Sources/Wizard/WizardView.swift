import SwiftUI
import AppKit

/// Top-level wizard. Reads the current `WizardStep` from `WizardState`
/// and dispatches to a per-step view. The shell (top-bar with progress,
/// fixed action bar, glass canvas, animated step transitions) is shared
/// by `WizardShell`.
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
/// right, a transitioning content stack (icon + title, body), and a
/// pinned secondary/primary action bar.
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
/// - Header (icon + title) and body content share a single
///   `.id(displayStep)` so they re-mount and slide together as one
///   cohesive unit.
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

    init(state: WizardState, @ViewBuilder content: @escaping (WizardStep) -> Content) {
        self.state = state
        self.content = content
        _displayStep = State(wrappedValue: state.step)
        _displayDirection = State(wrappedValue: state.slideDirection)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Layer 1 (content plane): header + body re-mount on every
            // `displayStep` change and slide as one cohesive group. The
            // bottom inset reserves permanent space for Layer 2's pinned
            // action bar, so dynamic body measurement cannot move the
            // Back/Continue buttons even for a single frame.
            VStack(spacing: 0) {
                stepHeader
                content(displayStep)
                    .padding(.top, WizardLayout.headerBodySpacing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, WizardLayout.topPadding)
            .padding(.horizontal, WizardLayout.horizontalPadding)
            .padding(.bottom, WizardLayout.bottomPadding + WizardLayout.bottomBarHeight)
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

            // Layer 3 (pinned): the pill stays fixed in the top-right
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
                .frame(height: WizardLayout.headerHeight)
                .padding(.top, WizardLayout.topPadding)
                .padding(.trailing, WizardLayout.horizontalPadding)
        }
        // Per-step canvas: width stays 480 but height is driven by
        // `displayStep.preferredHeight` so dense steps (Permissions,
        // Install, PairingInfo) get enough room without scrolling and
        // sparse steps (ExistingInstall, Done) don't float in dead
        // space. `.windowResizability(.contentSize)` on the scene
        // propagates the new content size out to `NSWindow`. The
        // sliding content owns its own animation above; the manual
        // AppKit resize below only runs when the preferred content
        // height actually changes.
        .frame(width: WizardLayout.width, height: displayStep.preferredHeight)
        .onChange(of: displayStep) { oldStep, newStep in
            // SwiftUI's implicit window resize via `.contentSize`
            // doesn't always interpolate smoothly (AppKit can choose
            // to snap instead of animate). Manually driving
            // `NSWindow.setFrame(_:display:animate:)` guarantees the
            // window chrome tracks the content animation on every
            // step change. We keep the top edge pinned so the
            // wizard doesn't jitter upward as it grows.
            animateHostingWindow(from: oldStep, to: newStep)
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
        .padding(.trailing, WizardLayout.progressPillReservedWidth)
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
                if case .installed = state.existingInstallStatus {
                    state.skipInstall()
                } else {
                    state.advance()
                }
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

    private var existingInstallContinueLabel: String {
        if case .installed = state.existingInstallStatus { return "Skip install" }
        return "Continue"
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
            Text("\(current) / \(total)")
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(Color.tronEmerald.opacity(0.85))
                .monospacedDigit()
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.tronEmerald.opacity(0.18))
                    .frame(width: WizardLayout.progressBarWidth, height: WizardLayout.progressBarHeight)
                Capsule(style: .continuous)
                    .fill(LinearGradient.tronEmeraldGradient)
                    .frame(width: max(4, WizardLayout.progressBarWidth * fraction), height: WizardLayout.progressBarHeight)
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

    // MARK: - Animated window resize

    /// Drives `NSWindow.setFrame(_:display:animate:)` so the window
    /// chrome resizes in lockstep with the SwiftUI content transition.
    /// Pins the window's TOP edge (subtracts the height delta from
    /// the origin Y, since AppKit frames anchor at the bottom-left)
    /// so the wizard grows/shrinks downward instead of jumping
    /// upward. Width stays pinned by the SwiftUI content size.
    ///
    /// The delta is step-to-step CONTENT height, not
    /// `window.frame.height`. AppKit frame height includes titlebar /
    /// full-size-content-view accounting, so comparing that directly to
    /// `WizardStep.preferredHeight` made same-height transitions look
    /// like real resizes on the first click.
    private func animateHostingWindow(from oldStep: WizardStep, to newStep: WizardStep) {
        guard WizardLayout.shouldResizeWindow(from: oldStep, to: newStep) else { return }
        guard let window = Self.findHostingWindow() else { return }
        let delta = WizardLayout.contentHeightDelta(from: oldStep, to: newStep)
        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        NSAnimationContext.runAnimationGroup { context in
            // Match the SwiftUI transition animation above so the
            // window, header slide, and body transition
            // all finish within the same frame budget. AppKit doesn't
            // expose a spring curve directly; duration-matching the
            // spring's `response` parameter and using ease-in-ease-out
            // is the closest visual match, and keeps the window chrome
            // from lagging the SwiftUI content by a frame or two at
            // the end of the animation.
            context.duration = WizardLayout.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
        }
    }

    /// Locates the wizard window among `NSApp.windows`. The wizard
    /// app has exactly one visible `WindowGroup` instance at a time
    /// (the menu-bar mode orders its own 1×1 window out), so
    /// picking the first key or visible non-panel window is enough.
    private static func findHostingWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, !(key is NSPanel) { return key }
        return NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
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
