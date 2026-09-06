import SwiftUI

/// Progress belongs to the accepted wizard operation, not a mounted step view.
enum InstallStageState: Equatable, Sendable {
    case pending, running, succeeded, failed(String)
}

extension WizardState {
    /// Called only by the task admitted in requestInstall. Every failure stops
    /// later stages; no view cancellation or remount creates another operation.
    func performInstall(setup: EnvironmentSetup) async {
        await paceInstallStage()
        if let locationProblem = setup.validateApplicationLocation() {
            installOutcome = .invalidApplicationLocation(locationProblem)
            installStages[.validateApplication] = .failed(locationProblem)
            return
        }
        installStages[.validateApplication] = .succeeded

        installStages[.validateHelper] = .running
        await paceInstallStage()
        if let helperProblem = await setup.validateBundledHelper() {
            installOutcome = .helperValidationFailed(helperProblem)
            installStages[.validateHelper] = .failed(helperProblem)
            return
        }
        if let gatewayProblem = setup.validateGatewayPayload() {
            installOutcome = .helperValidationFailed(gatewayProblem)
            installStages[.validateHelper] = .failed(gatewayProblem)
            return
        }
        guard ExistingInstallDetector.launchAgentPlistIsCurrent(
            plistPath: setup.launchAgentPlistPath,
            label: setup.launchAgentLabel,
            port: setup.serverPort
        ) else {
            let message = "The bundled LaunchAgent plist is invalid. Reinstall Tron.app."
            installOutcome = .helperValidationFailed(message)
            installStages[.validateHelper] = .failed(message)
            return
        }
        installStages[.validateHelper] = .succeeded

        guard setup.canManageLaunchAgent else {
            let message = "This Xcode Debug wrapper is a read-only companion. Use /Applications/Tron.app to install or manage Stable."
            installStages[.registerAgent] = .failed(message)
            installOutcome = .serviceRegistrationFailed(message)
            return
        }
        installStages[.registerAgent] = .running
        await paceInstallStage()
        let outcome = await LaunchAgentLoader.ensureLoaded(
            manager: setup.launchAgentManager,
            plistPath: setup.launchAgentPlistPath,
            label: setup.launchAgentLabel
        )
        switch outcome {
        case .ok, .alreadyLoaded:
            installStages[.registerAgent] = .succeeded
        case .requiresApproval(let message):
            installStages[.registerAgent] = .failed(message)
            installOutcome = .serviceRequiresApproval
            LoginItemsSettingsOpener.open()
            return
        case .launchdRefused(let message), .unknown(let message):
            installStages[.registerAgent] = .failed(message)
            installOutcome = .serviceRegistrationFailed(message)
            return
        case .binaryMissing(let path):
            installStages[.registerAgent] = .failed("Missing: \(path)")
            installOutcome = .helperValidationFailed("Missing: \(path)")
            return
        }

        installStages[.awaitPing] = .running
        await paceInstallStage()
        if await waitForInstallPing(setup: setup) {
            withAnimation(WizardLayout.transitionAnimation) {
                installStages[.awaitPing] = .succeeded
                installOutcome = .success
            }
        } else {
            installStages[.awaitPing] = .failed("Tron did not respond within 30 seconds")
            installOutcome = .awaitPingTimedOut
        }
    }

    private func paceInstallStage() async {
        try? await Task.sleep(nanoseconds: InstallStepContent.stagePaceDelayNanoseconds)
    }

    /// Preserve the wizard's existing readiness policy: token rejection proves
    /// liveness, while pairing owns token recovery; a wrong channel is not ready.
    private func waitForInstallPing(setup: EnvironmentSetup) async -> Bool {
        for _ in 0..<30 {
            let token = setup.readBearerToken()
            switch await setup.pingServer(token) {
            case .success(let info) where info.gatewayChannel == setup.profile.channel:
                return true
            case .success:
                break
            case .unauthorized:
                return true
            case .unreachable, .timeout, .malformedResponse:
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }
}
