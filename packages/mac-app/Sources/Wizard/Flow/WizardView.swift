import AppKit
import SwiftUI

struct WizardView: View {
    @State private var model: GatewayOnboardingModel

    init(context: GatewayAppContext) {
        _model = State(initialValue: GatewayOnboardingModel(
            dependencies: context.dependencies,
            coordinator: context.coordinator,
            initialError: context.onboardingError,
            completion: { await context.completeOnboarding() }
        ))
    }

    var body: some View {
        WizardShell(model: model) { step in
            switch step {
            case .welcome:
                WelcomeStep()
            case .tailscale:
                TailscaleStep(state: model)
            case .install:
                InstallStep(state: model)
            case .permissions:
                PermissionsStep(state: model)
            case .connectIPhone:
                PairingInfoStep(state: model)
            case .done:
                DoneStep()
            }
        }
        .environment(model)
        .task { model.resumeFromObservedState() }
        .onDisappear { model.cancelAll() }
    }
}

private struct WizardProgressTrack: View, @MainActor Animatable {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.4, dy: 0.4)
            let track = Path(roundedRect: rect, cornerRadius: rect.height / 2)
            let width = min(rect.width, max(WizardLayout.progressBarMinFillWidth, rect.width * min(1, max(0, fraction))))
            let fillRect = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
            let fill = Path(roundedRect: fillRect, cornerRadius: fillRect.height / 2)
            context.fill(track, with: .color(Color.tronEmerald.opacity(0.11)))
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [Color.tronMint, Color.tronEmeraldDeep]),
                startPoint: CGPoint(x: fillRect.midX, y: fillRect.minY),
                endPoint: CGPoint(x: fillRect.midX, y: fillRect.maxY)
            ))
            context.stroke(track, with: .color(Color.tronEmerald.opacity(0.20)), lineWidth: 0.8)
        }
    }
}

struct WizardShell<Content: View>: View {
    @Bindable var model: GatewayOnboardingModel
    @ViewBuilder var content: (WizardStep) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headerFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            content(model.step)
                .padding(.top, WizardLayout.topPadding + WizardLayout.headerHeight + WizardLayout.headerBodySpacing)
                .padding(.horizontal, WizardLayout.horizontalPadding)
                .padding(.bottom, WizardLayout.bottomPadding + WizardLayout.bottomBarHeight + 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(model.step)
                .transition(stepTransition)

            bottomBar
                .padding(.horizontal, WizardLayout.horizontalPadding)
                .padding(.bottom, WizardLayout.bottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            headerBar
                .padding(.top, WizardLayout.topPadding)
                .padding(.horizontal, WizardLayout.horizontalPadding)
        }
        .frame(width: WizardLayout.width, height: WizardLayout.height)
        .animation(reduceMotion ? nil : WizardLayout.transitionAnimation, value: model.step)
        .configureHostingWindow { $0.isMovableByWindowBackground = true }
        .onAppear { headerFocused = true }
        .onChange(of: model.step) { _, _ in headerFocused = true }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            stepIcon
            Text(model.step.displayTitle)
                .font(TronTypography.wizardTitle)
                .foregroundStyle(Color.tronEmerald)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headerFocused)
            Spacer(minLength: 12)
            progressPill
        }
        .frame(height: WizardLayout.headerHeight)
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch model.step.headerIcon {
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: WizardLayout.headerHeight)
                .foregroundStyle(Color.tronEmerald)
                .accessibilityHidden(true)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.tronEmerald)
                .frame(width: 28, height: WizardLayout.headerHeight)
                .accessibilityHidden(true)
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.error {
                Label(error.userMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(TronTypography.wizardCaption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityElement(children: .combine)
            }
            HStack(spacing: 12) {
                secondaryButton
                Spacer(minLength: 0)
                primaryButton
            }
            .frame(height: WizardLayout.bottomBarHeight)
        }
    }

    @ViewBuilder
    private var secondaryButton: some View {
        if model.canGoBack {
            Button("Back") { model.goBack() }
                .buttonStyle(.wizardSecondary)
                .help("Back to previous step")
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.step {
        case .welcome:
            primary("Get started") { model.advanceFromWelcome() }
        case .tailscale:
            primary(model.tailscaleStatus?.isReady == true ? "Continue" : "Check Tailscale") {
                model.verifyTailscaleAndContinue()
            }
        case .install:
            primary(installLabel, disabled: model.isMutating) {
                model.installIsReady ? model.continueAfterInstall() : model.install()
            }
        case .permissions:
            primary(model.isMutating ? "Finalizing…" : "Continue", disabled: !model.permissionsAreReady || model.isMutating) {
                model.restartAfterPermissions()
            }
        case .connectIPhone:
            primary("I'm connected", disabled: model.pairingPayload == nil) {
                model.continueAfterPairing()
            }
        case .done:
            primary("Open menu bar", disabled: model.isMutating) {
                model.completeOnboarding()
            }
        }
    }

    private func primary(
        _ title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.wizardPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(disabled)
    }

    private var installLabel: String {
        if model.installIsReady { return "Continue" }
        if model.isMutating { return "Installing…" }
        if model.installOutcome != nil { return "Retry install" }
        return "Install"
    }

    private var progressPill: some View {
        let steps = WizardStep.allCases
        let current = (steps.firstIndex(of: model.step) ?? 0) + 1
        let fraction = Double(current) / Double(steps.count)
        return HStack(spacing: 8) {
            Text("\(current) / \(steps.count)")
                .font(TronTypography.wizardProgress)
                .monospacedDigit()
            WizardProgressTrack(fraction: fraction)
                .frame(width: WizardLayout.progressBarWidth, height: WizardLayout.progressBarHeight)
        }
        .foregroundStyle(Color.tronEmerald)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Capsule().fill(Color.tronEmerald.opacity(0.06)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup step \(current) of \(steps.count)")
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let insertion: Edge = model.slideDirection == .forward ? .trailing : .leading
        let removal: Edge = model.slideDirection == .forward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: insertion), removal: .move(edge: removal))
            .combined(with: .opacity)
    }
}
