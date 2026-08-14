import Foundation

enum GatewayBundleValidationError: Equatable, Sendable {
    case applicationLocation
    case helperMissing
    case executableMissing
    case serviceDefinitionMissing
    case serviceDefinitionInvalid
    case signatureInvalid

    var userMessage: String {
        switch self {
        case .applicationLocation:
            "Move Tron.app to /Applications before installing Tron."
        case .helperMissing:
            "The bundled Tron Gateway Login Item is missing. Reinstall Tron."
        case .executableMissing:
            "The bundled Tron Gateway executable is missing. Reinstall Tron."
        case .serviceDefinitionMissing, .serviceDefinitionInvalid:
            "The bundled Tron Gateway service definition is invalid. Reinstall Tron."
        case .signatureInvalid:
            "The bundled Tron Gateway signature is invalid. Reinstall Tron."
        }
    }
}

/// Validates the one current helper and service definition before registration.
enum GatewayBundleValidator {
    static func validate(
        configuration: GatewayServiceConfiguration,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        signatureProblem: (URL, String) -> Bool = hasSignatureProblem
    ) -> GatewayBundleValidationError? {
        if configuration.applicationLocationProblem != nil {
            return .applicationLocation
        }
        guard fileExists(configuration.helperBundle.path) else { return .helperMissing }
        guard fileExists(configuration.helperBinary.path) else { return .executableMissing }
        guard fileExists(configuration.servicePlistPath.path) else { return .serviceDefinitionMissing }
        guard serviceDefinitionIsCurrent(configuration: configuration) else {
            return .serviceDefinitionInvalid
        }
        guard !signatureProblem(configuration.helperBundle, configuration.serviceLabel) else {
            return .signatureInvalid
        }
        return nil
    }

    static func serviceDefinitionIsCurrent(
        configuration: GatewayServiceConfiguration,
        data: Data? = nil
    ) -> Bool {
        guard let source = data ?? (try? Data(contentsOf: configuration.servicePlistPath)),
              let plist = try? PropertyListSerialization.propertyList(
                from: source,
                options: [],
                format: nil
              ) as? [String: Any],
              let label = plist["Label"] as? String,
              let bundleProgram = plist["BundleProgram"] as? String,
              let arguments = plist["ProgramArguments"] as? [String],
              let environment = plist["EnvironmentVariables"] as? [String: String],
              let associatedIDs = plist["AssociatedBundleIdentifiers"] as? [String],
              let runAtLoad = plist["RunAtLoad"] as? Bool,
              let keepAlive = plist["KeepAlive"] as? [String: Bool],
              let throttle = plist["ThrottleInterval"] as? Int else {
            return false
        }

        return label == configuration.serviceLabel
            && bundleProgram == configuration.helperBundleProgram
            && arguments == ["tron", "--host", "tailscale", "--port", "\(configuration.gatewayPort)"]
            && environment == configuration.serviceEnvironment
            && associatedIDs == configuration.associatedWrapperBundleIdentifiers
            && runAtLoad
            && keepAlive == ["SuccessfulExit": false, "Crashed": true]
            && throttle == 10
    }

    static func hasSignatureProblem(bundle: URL, expectedIdentifier: String) -> Bool {
        let verify = runCodesign(["--verify", "--deep", "--strict", "--verbose=2", bundle.path])
        guard verify.exitCode == 0 else { return true }
        let identity = runCodesign(["-dv", "--verbose=4", bundle.path])
        guard identity.exitCode == 0 else { return true }
        let details = identity.stderr + identity.stdout
        return !details.contains("Identifier=\(expectedIdentifier)")
            || details.contains("Signature=adhoc")
            || details.contains("TeamIdentifier=not set")
    }

    private static func runCodesign(_ arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "")
        }
        return ProcessResult(
            exitCode: Int(process.terminationStatus),
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
