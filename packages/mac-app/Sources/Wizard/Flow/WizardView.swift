import SwiftUI
import AppKit

@MainActor
func commitWizardCompletion(
    touchSentinel: @Sendable () throws -> Void,
    notificationCenter: NotificationCenter = .default
) throws {
    try touchSentinel()
    notificationCenter.post(name: .tronWizardDidComplete, object: nil)
}

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
            case .install:
                InstallStep(state: state)
            case .permissions:
                PermissionsStep(state: state)
            case .iosBeta:
                IOSBetaStep()
            case .pairingInfo:
                PairingInfoStep(state: state)
            case .done:
                DoneStep()
            }
        }
        .environment(state)
        .task(id: state.needsInstallDetection) {
            await state.refreshExistingInstall(using: setup.detectExistingInstall)
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

struct WizardShell<Content: View>: View {
    @Environment(\.environmentSetup) private var setup
    @Bindable var state: WizardState
    @ViewBuilder var content: (WizardStep) -> Content

    @State private var displayStep: WizardStep

    @State private var displayDirection: WizardSlideDirection

    init(state: WizardState, @ViewBuilder content: @escaping (WizardStep) -> Content) {
        self.state = state
        self.content = content
        _displayStep = State(wrappedValue: state.step)
        _displayDirection = State(wrappedValue: state.slideDirection)
    }

    var body: some View {
        ZStack(alignment: .top) {
            content(displayStep)
                .padding(.top, WizardLayout.topPadding + WizardLayout.headerHeight + WizardLayout.headerBodySpacing)
                .padding(.horizontal, WizardLayout.horizontalPadding)
                .padding(.bottom, WizardLayout.bottomPadding + WizardLayout.bottomBarHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(displayStep)
                .transition(slideTransition)
                .animation(WizardLayout.transitionAnimation, value: displayStep)

            bottomBar
                .frame(height: WizardLayout.bottomBarHeight, alignment: .center)
                .padding(.horizontal, WizardLayout.horizontalPadding)
                .padding(.bottom, WizardLayout.bottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            headerBar
                .padding(.top, WizardLayout.topPadding)
                .padding(.horizontal, WizardLayout.horizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: WizardLayout.width, height: WizardLayout.height)
        .configureHostingWindow { window in
            window.isMovableByWindowBackground = true
        }
        .onChange(of: state.step) { _, newStep in
            displayDirection = state.slideDirection
            DispatchQueue.main.async {
                displayStep = newStep
            }
        }
    }

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
            Button {
                state.skipToPairing()
            } label: {
                Text("I already have Tron running")
            }
            .buttonStyle(.wizardLink)
        case .done:
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
                if state.tailscaleStatus?.isReady == true {
                    state.advance()
                } else {
                    Task { @MainActor in
                        let status = await setup.probeTailscale()
                        state.tailscaleStatus = status
                        if status.isReady {
                            state.advance()
                        }
                    }
                }
            } label: {
                Text(state.tailscaleStatus?.isReady == true ? "Continue" : "I have Tailscale")
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
        case .permissions:
            Button {
                Task { @MainActor in
                    guard permissionsCanContinue else { return }
                    if !state.permissionsServerRestarted {
                        state.permissionsRestartInProgress = true
                        _ = await setup.launchAgentManager.restart(label: setup.launchAgentLabel)
                        state.permissionsServerRestarted = true
                        state.permissionsRestartInProgress = false
                    }
                    state.advance()
                }
            } label: {
                Text(state.permissionsRestartInProgress ? "Finalizing…" : "Continue")
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!permissionsCanContinue || state.permissionsRestartInProgress)
        case .install:
            Button {
                if installCanContinue {
                    state.advance()
                } else {
                    state.requestInstall(using: setup)
                }
            } label: {
                Text(installPrimaryLabel)
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(state.installIsRunning)
        case .iosBeta:
            Button {
                state.advance()
            } label: {
                Text("I installed Tron")
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
        case .pairingInfo:
            Button {
                state.advance()
            } label: {
                Text("I'm paired")
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(state.pairingPayload == nil)
        case .done:
            Button(action: completeOnboarding) {
                Text("Open menu bar")
            }
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func completeOnboarding() {
        do {
            try commitWizardCompletion(touchSentinel: setup.touchOnboardedSentinel)
        } catch {
            TronLog.shared.record(.error, event: "wizard.completion", source: "wizard", message: "Could not write onboarded sentinel: \(error.localizedDescription)", outcome: "failed")
        }
    }

    private var permissionsCanContinue: Bool {
        Permission.coreSetupSatisfied(by: state.permissionStatuses)
    }

    private var installCanContinue: Bool {
        guard let outcome = state.installOutcome else { return false }
        return outcome == .success
    }

    private var installPrimaryLabel: String {
        if installCanContinue { return "Continue" }
        if state.installIsRunning { return "Installing..." }
        if let outcome = state.installOutcome, outcome != .success {
            return "Retry install"
        }
        if case .registered = state.existingInstallStatus {
            return "Start Tron"
        }
        return "Install"
    }

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
