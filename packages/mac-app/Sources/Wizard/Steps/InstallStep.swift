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

    @State private var stages: [InstallPipelineStage: StageState] = [:]
    @State private var installStatusText: String?

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
        .task {
            // Detection is observational only. Even an enabled Login
            // Item registration is not considered ready until the user
            // explicitly starts the pipeline and `system.ping` answers.
            prepareTerminalInstallStateIfNeeded()
        }
        .task(id: state.installRequestID) {
            guard state.installRequestID > 0 else { return }
            guard state.hasUnhandledInstallRequest else {
                prepareTerminalInstallStateIfNeeded()
                return
            }
            await runPipeline(requestID: state.installRequestID)
        }
        .task(id: state.installOutcome) {
            guard installIsComplete else {
                installStatusText = nil
                return
            }
            await refreshInstallStatus()
        }
    }

    private var installIsComplete: Bool {
        if state.installOutcome == .success {
            return true
        }
        return currentInstallRunSucceeded
    }

    private var currentInstallRunSucceeded: Bool {
        guard !stages.isEmpty else { return false }
        return InstallPipelineStage.allCases.allSatisfy { stage in
            stages[stage] == .succeeded
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

    private func resetStagesToPending() {
        for stage in InstallPipelineStage.allCases {
            stages[stage] = .pending
        }
    }

    private func markAlreadyInstalledStagesSucceeded() {
        for stage in InstallPipelineStage.allCases {
            stages[stage] = .succeeded
        }
    }

    private func prepareTerminalInstallStateIfNeeded() {
        switch state.installOutcome {
        case .success:
            markAlreadyInstalledStagesSucceeded()
        case nil:
            if stages.isEmpty {
                resetStagesToPending()
            }
        default:
            break
        }
    }

    private func stageState(for stage: InstallPipelineStage) -> StageState {
        if let explicitState = stages[stage] {
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

    private func runPipeline(requestID: Int) async {
        guard !state.installIsRunning else { return }
        guard state.hasUnhandledInstallRequest else {
            prepareTerminalInstallStateIfNeeded()
            return
        }
        state.markInstallRequestHandled(requestID)

        state.installIsRunning = true
        defer { state.installIsRunning = false }
        // Reset state.
        resetStagesToPending()
        stages[.validateApplication] = .running
        state.installOutcome = nil

        // 1. The release app must be running from /Applications/Tron.app.
        await paceStage()
        if let locationProblem = setup.validateApplicationLocation() {
            state.installOutcome = .invalidApplicationLocation(locationProblem)
            stages[.validateApplication] = .failed(locationProblem)
            return
        }
        stages[.validateApplication] = .succeeded

        // 2. Validate the bundled helper app, LaunchAgent plist, and signature.
        stages[.validateHelper] = .running
        await paceStage()
        if let helperProblem = setup.validateBundledHelper() {
            state.installOutcome = .helperValidationFailed(helperProblem)
            stages[.validateHelper] = .failed(helperProblem)
            return
        }
        guard ExistingInstallDetector.launchAgentPlistIsCurrent(
            plistPath: setup.launchAgentPlistPath,
            label: setup.launchAgentLabel,
            port: setup.serverPort
        ) else {
            let message = "The bundled LaunchAgent plist is invalid. Reinstall Tron.app."
            state.installOutcome = .helperValidationFailed(message)
            stages[.validateHelper] = .failed(message)
            return
        }
        stages[.validateHelper] = .succeeded

        let plan: InstallPlan
        let plannerResult = InstallPlanner.plan(
            paths: InstallPlanner.TargetPaths(
                helperBundle: setup.serverHelperBundle,
                helperBinary: setup.serverHelperBinary,
                plistPath: setup.launchAgentPlistPath,
                label: setup.launchAgentLabel,
                port: setup.serverPort
            )
        )
        switch plannerResult {
        case .failure(.helperMissing(let url)):
            let message = "Missing helper executable at \(url.path). Reinstall Tron.app."
            state.installOutcome = .helperValidationFailed(message)
            stages[.validateHelper] = .failed(message)
            return
        case .failure(.plistMissing(let url)):
            let message = "Missing LaunchAgent plist at \(url.path). Reinstall Tron.app."
            state.installOutcome = .helperValidationFailed(message)
            stages[.validateHelper] = .failed(message)
            return
        case .success(let value):
            plan = value
        }

        guard setup.canManageLaunchAgent else {
            let message = "This Xcode Debug wrapper is in companion mode. Use /Applications/Tron.app for the production install, or run the isolated install-testing scheme."
            stages[.registerAgent] = .failed(message)
            state.installOutcome = .serviceRegistrationFailed(message)
            return
        }

        // 3. Sync bundled managed skills into the user's mutable skill tree.
        stages[.syncSkills] = .running
        await paceStage()
        switch await setup.syncManagedSkills() {
        case .synced:
            stages[.syncSkills] = .succeeded
        case .failed(let message):
            stages[.syncSkills] = .failed(message)
            state.installOutcome = .managedSkillsSyncFailed(message)
            return
        }

        // 4. Register the bundled Login Item through SMAppService.
        stages[.registerAgent] = .running
        await paceStage()
        let outcome = await InstallLaunchAgentRunner.ensureLoaded(
            manager: setup.launchAgentManager,
            plistPath: plan.plistPath,
            label: setup.launchAgentLabel
        )
        switch outcome {
        case .ok, .alreadyLoaded:
            stages[.registerAgent] = .succeeded
        case .requiresApproval(let message):
            stages[.registerAgent] = .failed(message)
            state.installOutcome = .serviceRequiresApproval
            LoginItemsSettingsOpener.open()
            return
        case .launchdRefused(let message), .unknown(let message):
            stages[.registerAgent] = .failed(message)
            state.installOutcome = .serviceRegistrationFailed(message)
            return
        case .binaryMissing(let path):
            stages[.registerAgent] = .failed("Missing: \(path)")
            state.installOutcome = .helperValidationFailed("Missing: \(path)")
            return
        }

        // 5. Await ping.
        stages[.awaitPing] = .running
        await paceStage()
        let pingOK = await waitForPing()
        if pingOK {
            withAnimation(WizardLayout.transitionAnimation) {
                stages[.awaitPing] = .succeeded
                state.installOutcome = .success
            }
            state.existingInstallStatus = setup.detectExistingInstall()
        } else {
            stages[.awaitPing] = .failed("Server did not respond within 30 seconds")
            state.installOutcome = .awaitPingTimedOut
        }
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
    private func stageIcon(_ stateForStage: StageState) -> some View {
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

    private func paceStage() async {
        try? await Task.sleep(nanoseconds: InstallStepContent.stagePaceDelayNanoseconds)
    }

    enum StageState: Equatable {
        case pending, running, succeeded, failed(String)
    }

    private func label(for stage: InstallPipelineStage) -> String {
        InstallStepContent.label(for: stage)
    }

    private func outcomeDescription(_ outcome: InstallOutcome) -> String {
        switch outcome {
        case .success: return ""
        case .invalidApplicationLocation(let message): return message
        case .helperValidationFailed(let message): return message
        case .managedSkillsSyncFailed(let message): return "Could not sync bundled skills: \(message)"
        case .serviceRequiresApproval: return "Approve Tron Server in System Settings > Login Items, then return here."
        case .serviceRegistrationFailed(let message): return "Could not register Tron Server: \(message)"
        case .awaitPingTimedOut: return "The server did not respond in time. Open the logs window from the Tron menu bar after approving the Login Item."
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
                Text("Tron Server is registered")
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

    /// Polls `system.ping` for up to 30 s on a 1 s cadence. Returns true
    /// the moment the server responds. Treats `.unauthorized` as a
    /// success signal too — the server is alive; the wizard moves on
    /// and the pairing step will surface the token.
    private func waitForPing() async -> Bool {
        for _ in 0..<30 {
            let token = setup.readBearerToken()
            switch await setup.pingServer(token) {
            case .success, .unauthorized:
                return true
            case .unreachable, .timeout, .malformedResponse:
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    @ViewBuilder
    private var serverReadyBanner: some View {
        HStack(alignment: .center, spacing: WizardCardLayout.iconTextSpacing) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.tronSuccess)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: WizardCardLayout.iconColumnWidth, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tron Server is ready")
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

    private func refreshInstallStatus() async {
        installStatusText = "Checking..."
        let token = setup.readBearerToken()
        switch await setup.pingServer(token) {
        case .success(let info):
            installStatusText = "Running on port \(info.port)"
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
    static let intro = "Install Tron Server on this Mac. It runs quietly in the background so your iPhone can connect."
    static let notStartedPlaceholder = "Installation not started"
    static let stagePaceDelayNanoseconds: UInt64 = 350_000_000

    static func label(for stage: InstallPipelineStage) -> String {
        switch stage {
        case .validateApplication: return "Confirm app location"
        case .validateHelper: return "Verify server helper"
        case .syncSkills: return "Sync managed skills"
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

/// Applies the service registration step. An already-enabled label may
/// still be running an older helper image after app replacement, so
/// `.alreadyLoaded` is followed by `kickstart -k`.
enum InstallLaunchAgentRunner {
    static func ensureLoaded(
        manager: LaunchAgentManaging,
        plistPath: URL,
        label: String
    ) async -> LaunchAgentOutcome {
        let loadOutcome = await manager.load(plistPath: plistPath, label: label)
        guard case .alreadyLoaded = loadOutcome else {
            return loadOutcome
        }
        return await manager.restart(label: label)
    }
}
