import Foundation

struct MacAppVersionIdentity: Codable, Equatable, Sendable {
    var canonicalVersion: String
    var buildNumber: String

    static func current(bundle: Bundle = .main) -> MacAppVersionIdentity {
        let canonical = bundle.object(forInfoDictionaryKey: "TRONCanonicalVersion") as? String
        let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return MacAppVersionIdentity(
            canonicalVersion: canonical ?? marketing ?? "unknown",
            buildNumber: build ?? "unknown"
        )
    }
}

enum MacAppVersionMarkerStore {
    static func read(at path: URL) -> MacAppVersionIdentity? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(MacAppVersionIdentity.self, from: data)
    }

    static func write(_ version: MacAppVersionIdentity, at path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(version)
        let tmp = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: tmp, options: [.atomic])
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: path)
        }
    }
}

enum MacAppStartupContext: Equatable, Sendable {
    case existingOnboardedLaunch
    case wizardCompletion
}

enum MacAppStartupSkipReason: Equatable, Sendable {
    case notOnboarded
    case unmanagedWrapper
    case devServerActive
    case versionAlreadyRecorded
}

enum MacAppStartupMaintenanceResult: Equatable, Sendable {
    case restarted(LaunchAgentOutcome)
    case restartUnhealthy(LaunchAgentOutcome, ServerPingResult)
    case recordedCurrentVersion
    case skipped(MacAppStartupSkipReason)
}

enum MacAppStartupMaintenance {
    static func shouldRestartServerOnLaunch(
        context: MacAppStartupContext,
        currentVersion: MacAppVersionIdentity,
        recordedVersion: MacAppVersionIdentity?,
        canManageLaunchAgent: Bool,
        onboarded: Bool,
        devServerActive: Bool
    ) -> Bool {
        guard context == .existingOnboardedLaunch else { return false }
        guard onboarded else { return false }
        guard canManageLaunchAgent else { return false }
        guard !devServerActive else { return false }
        return recordedVersion != currentVersion
    }

    static func run(
        setup: EnvironmentSetup,
        controller: MenuBarController?,
        context: MacAppStartupContext
    ) async -> MacAppStartupMaintenanceResult {
        let currentVersion = setup.currentAppVersion()
        let recordedVersion = setup.readRecordedAppVersion()
        let onboarded = setup.onboardedSentinelExists()

        let devServerActive = await setup.probeServerProcess(setup.serverPort)?.isDevServer == true
        guard shouldRestartServerOnLaunch(
            context: context,
            currentVersion: currentVersion,
            recordedVersion: recordedVersion,
            canManageLaunchAgent: setup.canManageLaunchAgent,
            onboarded: onboarded,
            devServerActive: devServerActive
        ) else {
            let reason = skipReason(
                currentVersion: currentVersion,
                recordedVersion: recordedVersion,
                canManageLaunchAgent: setup.canManageLaunchAgent,
                onboarded: onboarded,
                devServerActive: devServerActive
            )
            if context == .wizardCompletion,
               setup.canManageLaunchAgent {
                recordCurrentVersion(currentVersion, setup: setup)
                return .recordedCurrentVersion
            }
            return .skipped(reason)
        }

        await MainActor.run {
            controller?.applySnapshot(ServerStatusSnapshot(
                state: .busy(.starting),
                port: setup.serverPort,
                tailscaleIP: setup.readTailscaleIPFromSettings(),
                bearerToken: setup.readBearerToken()
            ))
        }

        let outcome = await InstallLaunchAgentRunner.ensureLoaded(
            manager: setup.launchAgentManager,
            plistPath: setup.launchAgentPlistPath,
            label: setup.launchAgentLabel
        )
        let health: ServerPingResult?
        switch outcome {
        case .ok, .alreadyLoaded:
            health = await ServerHealthAwaiter.waitForHealthy(setup: setup)
        case .requiresApproval, .launchdRefused, .binaryMissing, .unknown:
            health = nil
        }
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        await MainActor.run {
            controller?.applySnapshot(snapshot)
        }
        switch outcome {
        case .ok, .alreadyLoaded:
            if let health, case .success = health {
                recordCurrentVersion(currentVersion, setup: setup)
            } else {
                return .restartUnhealthy(outcome, health ?? .unreachable)
            }
        case .requiresApproval, .launchdRefused, .binaryMissing, .unknown:
            break
        }
        return .restarted(outcome)
    }

    private static func skipReason(
        currentVersion: MacAppVersionIdentity,
        recordedVersion: MacAppVersionIdentity?,
        canManageLaunchAgent: Bool,
        onboarded: Bool,
        devServerActive: Bool
    ) -> MacAppStartupSkipReason {
        if !onboarded { return .notOnboarded }
        if !canManageLaunchAgent { return .unmanagedWrapper }
        if devServerActive { return .devServerActive }
        if recordedVersion == currentVersion { return .versionAlreadyRecorded }
        return .versionAlreadyRecorded
    }

    @discardableResult
    static func recordCurrentVersion(setup: EnvironmentSetup) -> Bool {
        recordCurrentVersion(setup.currentAppVersion(), setup: setup)
    }

    @discardableResult
    private static func recordCurrentVersion(_ version: MacAppVersionIdentity, setup: EnvironmentSetup) -> Bool {
        do {
            try setup.writeRecordedAppVersion(version)
            return true
        } catch {
            NSLog("[Tron] Failed to record Mac app version marker: %@", error.localizedDescription)
            return false
        }
    }
}
