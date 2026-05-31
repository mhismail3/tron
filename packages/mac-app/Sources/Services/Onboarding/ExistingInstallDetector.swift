import Foundation
import ServiceManagement

/// Decides whether the bundled `SMAppService` agent is registered and
/// the embedded helper is intact. Auth/settings/database files are user
/// data and are deliberately ignored.
enum ExistingInstallDetector {
    static func detect(
        helperBundle: URL = TronPaths.serverHelperBundle,
        helperBinary: URL = TronPaths.serverHelperBinary,
        plistPath: URL = TronPaths.launchAgentPlistPath,
        bundleVersionResolver: (URL) -> String? = ExistingInstallDetector.readMarketingVersion,
        bundleSignatureProblemResolver: (URL) -> String? = ExistingInstallDetector.bundleSignatureProblem,
        serviceStatusResolver: () -> ServiceRegistrationStatus = { ExistingInstallDetector.serviceStatus() }
    ) -> ExistingInstallStatus {
        let fm = FileManager.default
        let hasHelper = fm.fileExists(atPath: helperBundle.path)
        let hasBinary = fm.fileExists(atPath: helperBinary.path)
        let hasPlist = fm.fileExists(atPath: plistPath.path)
        let helperName = helperBundle.lastPathComponent

        guard hasHelper else {
            return hasPlist ? .partial(reason: "\(helperName) is missing from the application bundle") : .none
        }
        guard hasBinary else {
            return .partial(reason: "\(helperName) is missing its tron executable")
        }
        guard hasPlist else {
            return .partial(reason: "Bundled LaunchAgent plist is missing")
        }
        if let problem = bundleSignatureProblemResolver(helperBundle) {
            return .partial(reason: problem)
        }

        switch serviceStatusResolver() {
        case .enabled:
            return .registered(version: bundleVersionResolver(helperBundle))
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .none
        case .notFound:
            return .partial(reason: "macOS cannot find the bundled Tron Server Login Item")
        case .unknown(let message):
            return .partial(reason: message)
        }
    }

    enum ServiceRegistrationStatus: Equatable, Sendable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unknown(String)
    }

    static func serviceStatus(label: String = TronPaths.launchAgentLabel) -> ServiceRegistrationStatus {
        let service = SMAppService.agent(plistName: "\(label).plist")
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown("Tron Server registration is in an unknown state")
        }
    }

    static func validateBundledHelper(
        helperBundle: URL = TronPaths.serverHelperBundle,
        helperBinary: URL = TronPaths.serverHelperBinary,
        plistPath: URL = TronPaths.launchAgentPlistPath,
        signatureProblemResolver: (URL) -> String? = ExistingInstallDetector.bundleSignatureProblem
    ) -> String? {
        let fm = FileManager.default
        let helperName = helperBundle.lastPathComponent
        guard fm.fileExists(atPath: helperBundle.path) else {
            return "\(helperName) is missing from the application bundle."
        }
        guard fm.fileExists(atPath: helperBinary.path) else {
            return "\(helperName) is missing its tron executable."
        }
        guard fm.fileExists(atPath: plistPath.path) else {
            return "The bundled LaunchAgent plist is missing."
        }
        return signatureProblemResolver(helperBundle)
    }

    static func validateApplicationLocation(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String? {
        MacRuntimeVariant.detect(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier
        ).locationProblem
    }

    static func launchAgentPlistIsCurrent(
        plistPath: URL = TronPaths.launchAgentPlistPath,
        label: String = TronPaths.launchAgentLabel,
        port: Int = TronPaths.defaultServerPort,
        bundleProgram expectedBundleProgram: String = TronPaths.serverHelperBundleProgram,
        environmentVariables expectedEnvironmentVariables: [String: String] = TronPaths.launchAgentEnvironmentVariables,
        associatedBundleIDs expectedAssociatedBundleIDs: [String] = TronPaths.associatedWrapperBundleIDs
    ) -> Bool {
        guard let data = try? Data(contentsOf: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let plistLabel = plist["Label"] as? String,
              let bundleProgram = plist["BundleProgram"] as? String,
              let args = plist["ProgramArguments"] as? [String],
              let environmentVariables = plist["EnvironmentVariables"] as? [String: String],
              let associatedBundleIDs = plist["AssociatedBundleIdentifiers"] as? [String] else {
            return false
        }
        return plistLabel == label
            && bundleProgram == expectedBundleProgram
            && args == ["tron", "--port", "\(port)", "--quiet"]
            && environmentVariables == expectedEnvironmentVariables
            && associatedBundleIDs == expectedAssociatedBundleIDs
    }

    /// Reads `CFBundleShortVersionString` from `<Bundle>/Contents/Info.plist`.
    /// Returns nil if the file doesn't exist or can't be parsed.
    static func readMarketingVersion(of bundle: URL) -> String? {
        let infoPlistURL = bundle.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// Returns nil when the helper app's code signature is suitable for TCC.
    static func bundleSignatureProblem(of bundle: URL) -> String? {
        let helperName = bundle.lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", "--verbose=2", bundle.path]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "\(helperName) is present but its code signature could not be checked"
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            return "\(helperName) is present but its code signature is invalid"
        }

        let identity = Process()
        identity.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        identity.arguments = ["-dv", "--verbose=4", bundle.path]
        let identityOutput = Pipe()
        identity.standardOutput = identityOutput
        identity.standardError = identityOutput
        do {
            try identity.run()
            identity.waitUntilExit()
        } catch {
            return "\(helperName) is present but its code signature identity could not be checked"
        }
        let identityText = String(data: identityOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard identity.terminationStatus == 0 else {
            return "\(helperName) is present but its code signature identity is invalid"
        }
        if let problem = codeSignatureIdentityProblem(identityText) {
            return problem
        }
        _ = text
        return nil
    }

    static func codeSignatureIdentityProblem(
        _ identityText: String,
        expectedBundleIdentifier: String = TronPaths.bundleID,
        helperName: String = "\(TronPaths.agentBundleName).app"
    ) -> String? {
        guard identityText.contains("Identifier=\(expectedBundleIdentifier)") else {
            return "\(helperName) is present but its code signature is not bound to \(expectedBundleIdentifier)"
        }
        if identityText.contains("Signature=adhoc")
            || identityText.contains("TeamIdentifier=not set") {
            return "\(helperName) is ad-hoc signed. Build Debug with Apple Development signing so macOS can launch the Login Item."
        }
        return nil
    }
}
