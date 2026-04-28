import Foundation

/// Installs the bundled transcription sidecar support files into the
/// mutable Tron data root. The Python venv and HuggingFace cache remain
/// in place across app updates; only the repo-owned worker/requirements
/// files are refreshed from the signed app bundle.
enum TranscriptionResourceInstaller {
    enum Failure: Error, LocalizedError, Equatable {
        case missingResourceDirectory(String)
        case missingResourceFile(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingResourceDirectory(let path):
                return "Missing bundled transcription resources at \(path). Reinstall Tron.app."
            case .missingResourceFile(let name):
                return "Missing bundled transcription file \(name). Reinstall Tron.app."
            case .installFailed(let reason):
                return reason
            }
        }
    }

    static let requiredFiles = ["worker.py", "requirements.txt"]

    static func install(from sourceDir: URL, to destinationDir: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceDir.path) else {
            throw Failure.missingResourceDirectory(sourceDir.path)
        }

        do {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            for file in requiredFiles {
                let source = sourceDir.appendingPathComponent(file, isDirectory: false)
                guard fm.fileExists(atPath: source.path) else {
                    throw Failure.missingResourceFile(file)
                }
                let destination = destinationDir.appendingPathComponent(file, isDirectory: false)
                let tmp = destinationDir.appendingPathComponent(".\(file).\(UUID().uuidString).tmp", isDirectory: false)
                try fm.copyItem(at: source, to: tmp)
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: destination)
                }
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.installFailed(error.localizedDescription)
        }
    }
}

/// Applies the first-run transcription preference from the Mac wizard.
enum TranscriptionSetupCoordinator {
    static func apply(
        enabled: Bool,
        sidecarSource: URL,
        sidecarDestination: URL,
        settingsPath: URL,
        bearerToken: String?,
        launchAgentManager: LaunchAgentManaging,
        label: String,
        pingServer: @Sendable (String?) async -> ServerPingResult
    ) async -> TranscriptionSetupResult {
        do {
            try TranscriptionResourceInstaller.install(from: sidecarSource, to: sidecarDestination)
            try ServerSettingsWriter.setTranscriptionEnabled(enabled, at: settingsPath)
        } catch {
            return .failed(error.localizedDescription)
        }

        guard enabled else {
            return .disabled
        }

        let restartOutcome = await launchAgentManager.restart(label: label)
        switch restartOutcome {
        case .ok, .alreadyLoaded:
            break
        case .requiresApproval(let message),
             .launchdRefused(let message),
             .unknown(let message):
            return .failed(message)
        case .binaryMissing(let path):
            return .failed("Missing Tron Server helper at \(path). Reinstall Tron.app.")
        }

        let reachable = await waitForPing(token: bearerToken, pingServer: pingServer)
        return reachable
            ? .enabled
            : .failed("Tron Server did not respond after enabling transcription. Restart it from the menu bar and try again.")
    }

    private static func waitForPing(
        token: String?,
        pingServer: @Sendable (String?) async -> ServerPingResult
    ) async -> Bool {
        for _ in 0..<20 {
            switch await pingServer(token) {
            case .success, .unauthorized:
                return true
            case .unreachable, .timeout, .malformedResponse:
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return false
    }
}
