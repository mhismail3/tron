import SwiftUI
import AppKit

/// Install step. The shell owns the icon, title, progress pill, and
/// the bottom action bar. Its primary CTA starts as "Install" and
/// only advances as "Continue" after `installOutcome == .success`.
/// This view contributes the description, the per-stage progress list,
/// and an error summary on failure.
struct InstallStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    @State private var installStatusText: String?
    @State private var statusRefreshFence = WizardPresentationRequestFence()

    var body: some View {
        VStack(alignment: .leading, spacing: InstallStepLayout.sectionSpacing) {
            Text(InstallStepContent.intro)
                .font(TronTypography.wizardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shouldShowRegisteredServiceLayout {
                registeredServiceSummary
            } else {
                stageProgressArea

                if let outcome = state.installOutcome, outcome != .success {
                    WizardInfoCard {
                        Text(outcomeDescription(outcome))
                            .font(TronTypography.wizardBodySmall)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if installIsComplete {
                    readySummary
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(WizardLayout.transitionAnimation, value: installIsComplete)
        .task(id: state.installOutcome) {
            let request = statusRefreshFence.begin()
            guard installIsComplete else {
                if statusRefreshFence.accepts(request) {
                    installStatusText = nil
                }
                return
            }
            await refreshInstallStatus(request: request)
        }
        .onDisappear {
            // Status is disposable presentation work. Retire its lease so a
            // late ping cannot publish into a remounted or replaced step.
            statusRefreshFence.retire()
        }
    }

    private var installIsComplete: Bool {
        if state.installOutcome == .success {
            return true
        }
        return currentInstallRunSucceeded
    }

    private var currentInstallRunSucceeded: Bool {
        guard !state.installStages.isEmpty else { return false }
        return InstallPipelineStage.allCases.allSatisfy { stage in
            state.installStages[stage] == .succeeded
        }
    }

    private var shouldShowRegisteredServiceLayout: Bool {
        guard state.installOutcome == nil, !state.installIsRunning else {
            return false
        }
        if case .registered = state.existingInstallStatus {
            return true
        }
        return false
    }

    private func stageState(for stage: InstallPipelineStage) -> InstallStageState {
        if let explicitState = state.installStages[stage] {
            return explicitState
        }
        switch state.installOutcome {
        case .success:
            // Re-entering this page after a successful install should
            // render completed rows on the first body pass. Updating
            // them later from `.task` makes the icons pop separately
            // from the page transition.
            return .succeeded
        default:
            return .pending
        }
    }

    private var visibleStages: [InstallPipelineStage] {
        if state.installOutcome == .success {
            return InstallPipelineStage.allCases
        }
        return InstallPipelineStage.allCases.filter { stage in
            stageState(for: stage) != .pending
        }
    }

    private var stageProgressArea: some View {
        Group {
            if visibleStages.isEmpty {
                Text(InstallStepContent.notStartedPlaceholder)
                    .font(TronTypography.wizardSubheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            } else {
                VStack(spacing: installIsComplete ? InstallStepLayout.completedStageSpacing : InstallStepLayout.runningStageSpacing) {
                    ForEach(visibleStages, id: \.self) { stage in
                        stageRow(stage)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .animation(WizardLayout.transitionAnimation, value: visibleStages)
    }

    @ViewBuilder
    private func stageRow(_ stage: InstallPipelineStage) -> some View {
        let stateForStage = stageState(for: stage)
        HStack(alignment: .center, spacing: 12) {
            stageIcon(stateForStage)
                .frame(
                    width: InstallStepLayout.stageIconColumnWidth,
                    height: InstallStepLayout.stageRowMinHeight,
                    alignment: .center
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: stage))
                    .font(TronTypography.wizardBody)
                if case .failed(let message) = stateForStage {
                    Text(message).font(TronTypography.wizardCaption).foregroundStyle(.red)
                }
            }
            .frame(minHeight: InstallStepLayout.stageRowMinHeight, alignment: .center)
            Spacer()
        }
    }

    @ViewBuilder
    private func stageIcon(_ stateForStage: InstallStageState) -> some View {
        switch stateForStage {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: InstallStepLayout.stageIconGlyphSize, weight: .regular))
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: InstallStepLayout.stageIconGlyphSize, weight: .semibold))
                .foregroundStyle(.green)
        case .failed(let message):
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: InstallStepLayout.stageIconGlyphSize, weight: .semibold))
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private func label(for stage: InstallPipelineStage) -> String {
        InstallStepContent.label(for: stage)
    }

    private func outcomeDescription(_ outcome: InstallOutcome) -> String {
        switch outcome {
        case .success: return ""
        case .invalidApplicationLocation(let message): return message
        case .helperValidationFailed(let message): return message
        case .serviceRequiresApproval: return "Approve Tron Agent in System Settings > Login Items, then return here."
        case .serviceRegistrationFailed(let message): return "Could not register Tron Agent: \(message)"
        case .awaitPingTimedOut: return "Tron did not respond in time. Open the logs window from the Tron menu bar after approving the Login Item."
        }
    }

    @ViewBuilder
    private var registeredServiceSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            registeredServiceCard
                .padding(.top, InstallStepLayout.detectedSummaryTopPadding)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var readySummary: some View {
        readySummaryCards
            .padding(.top, InstallStepLayout.readySummaryTopPadding)
            .transition(InstallStepLayout.readySummaryTransition)
    }

    @ViewBuilder
    private var readySummaryCards: some View {
        VStack(alignment: .leading, spacing: InstallStepLayout.readySummarySpacing) {
            serverReadyBanner
        }
    }

    @ViewBuilder
    private var registeredServiceCard: some View {
        HStack(alignment: .center, spacing: WizardCardLayout.iconTextSpacing) {
            Image(systemName: "power.circle.fill")
                .foregroundStyle(Color.tronEmerald)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: WizardCardLayout.iconColumnWidth, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tron Agent is registered")
                    .font(TronTypography.wizardSubheadline)
                    .foregroundStyle(Color.tronEmerald)
                Text("Start it to confirm this Mac is reachable.")
                    .font(TronTypography.wizardCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, InstallStepLayout.summaryCardVerticalPadding)
        .padding(.horizontal, WizardCardLayout.horizontalInset)
        .wizardGlassCard()
    }

    @ViewBuilder
    private var serverReadyBanner: some View {
        HStack(alignment: .center, spacing: WizardCardLayout.iconTextSpacing) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.tronSuccess)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: WizardCardLayout.iconColumnWidth, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tron Agent is ready")
                    .font(TronTypography.wizardSubheadline)
                    .foregroundStyle(Color.tronEmerald)
                Text("Current status: \(installStatusText ?? "Checking...")")
                    .font(TronTypography.wizardCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, InstallStepLayout.summaryCardVerticalPadding)
        .padding(.horizontal, WizardCardLayout.horizontalInset)
        .wizardGlassCard()
    }

    private func refreshInstallStatus(request: UInt64) async {
        guard statusRefreshFence.accepts(request), !Task.isCancelled else { return }
        installStatusText = "Checking..."
        let token = setup.readBearerToken()
        let result = await setup.pingServer(token)
        guard statusRefreshFence.accepts(request), !Task.isCancelled else { return }
        switch result {
        case .success(let info) where info.gatewayChannel == setup.profile.channel:
            installStatusText = "Running on port \(setup.serverPort)"
        case .success:
            installStatusText = "Unexpected Gateway channel"
        case .unauthorized:
            installStatusText = "Running; token needs refresh"
        case .unreachable:
            installStatusText = "Not reachable"
        case .timeout:
            installStatusText = "Timed out"
        case .malformedResponse:
            installStatusText = "Unexpected response"
        }
    }
}

enum LoginItemsSettingsOpener {
    static func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum InstallStepContent {
    static let intro = "Install Tron on this Mac. It runs quietly in the background so your iPhone can connect."
    static let notStartedPlaceholder = "Installation not started"
    static let stagePaceDelayNanoseconds: UInt64 = 350_000_000

    static func label(for stage: InstallPipelineStage) -> String {
        switch stage {
        case .validateApplication: return "Confirm app location"
        case .validateHelper: return "Verify bundled Gateway runtime"
        case .registerAgent: return "Register Login Item"
        case .awaitPing: return "Confirm it's running"
        }
    }
}

enum InstallStepLayout {
    static let sectionSpacing: CGFloat = 16
    static let runningStageSpacing: CGFloat = 6
    static let completedStageSpacing: CGFloat = 4
    static let readySummarySpacing: CGFloat = 11
    static let readySummaryTopPadding: CGFloat = 0
    static let detectedSummaryTopPadding: CGFloat = 72
    static let summaryCardVerticalPadding: CGFloat = 14
    static let stageIconColumnWidth: CGFloat = 24
    static let stageRowMinHeight: CGFloat = 24
    static let stageIconGlyphSize: CGFloat = 13

    static var readySummaryTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .move(edge: .bottom))
                .combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .opacity
        )
    }
}
