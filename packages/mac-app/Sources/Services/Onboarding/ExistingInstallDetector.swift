import Foundation

/// Decides whether a CLI-installed Tron is already present on the host.
/// The wizard uses this to skip the Install step on second runs and to
/// avoid clobbering a contributor's local setup.
///
/// Detection rule (mirrors plan §A step 3):
/// - `~/.tron/system/Tron.app/Contents/MacOS/tron` exists (binary), OR
/// - `~/Library/LaunchAgents/com.tron.server.plist` exists without that
///   binary, which is a stale/partial launch artifact.
///
/// Auth/settings/database files are user data, not install artifacts.
/// They are deliberately ignored here so the cleanup action can preserve
/// them while still returning the installer to a clean retry state.
enum ExistingInstallDetector {
    static func detect(
        binaryPath: URL = TronPaths.installedBinary,
        authJSONPath _: URL = TronPaths.systemDir.appendingPathComponent("auth.json", isDirectory: false),
        plistPath: URL = TronPaths.launchAgentPlistPath,
        bundleVersionResolver: (URL) -> String? = ExistingInstallDetector.readMarketingVersion,
        bundleSignatureProblemResolver: (URL) -> String? = ExistingInstallDetector.bundleSignatureProblem
    ) -> ExistingInstallStatus {
        let fm = FileManager.default
        let hasBinary = fm.fileExists(atPath: binaryPath.path)
        let hasPlist = fm.fileExists(atPath: plistPath.path)

        switch (hasBinary, hasPlist) {
        case (true, _):
            let bundle = binaryPath.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if let problem = bundleSignatureProblemResolver(bundle) {
                return .partial(reason: problem)
            }
            let version = bundleVersionResolver(bundle)
            return .installed(version: version)
        case (false, true):
            return .partial(reason: "LaunchAgent plist present but Tron.app missing")
        case (false, false):
            return .none
        }
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

    /// Returns nil when the bundle's code signature is suitable for TCC.
    /// Accessibility grants are code-identity sensitive; an unsigned app
    /// bundle whose executable keeps Cargo's linker-generated ad-hoc
    /// identity can show up in System Settings, accept a toggle, then have
    /// macOS immediately flip the toggle back off after restart.
    static func bundleSignatureProblem(of bundle: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", bundle.path]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Tron.app is present but its code signature could not be checked"
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            return "Tron.app is present but its code signature is invalid"
        }
        guard text.contains("Identifier=\(TronPaths.bundleID)") else {
            return "Tron.app is present but its code signature is not bound to \(TronPaths.bundleID)"
        }
        guard !text.contains("Info.plist=not bound") else {
            return "Tron.app is present but its Info.plist is not sealed into the code signature"
        }
        guard !text.contains("Sealed Resources=none") else {
            return "Tron.app is present but its bundle resources are not sealed into the code signature"
        }
        return nil
    }
}
