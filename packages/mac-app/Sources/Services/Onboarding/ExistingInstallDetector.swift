import Foundation

/// Decides whether a CLI-installed Tron is already present on the host.
/// The wizard uses this to skip the Install step on second runs and to
/// avoid clobbering a contributor's local setup.
///
/// Detection rule (mirrors plan §A step 3):
/// - `~/.tron/system/Tron.app/Contents/MacOS/tron` exists (binary), OR
/// - `~/.tron/system/auth.json` exists and is non-empty (provider auth
///   present from prior CLI install).
///
/// "partial" is returned when only one half is present - the wizard
/// surfaces the discrepancy so the user knows they're not in a clean
/// state, but the install step still proceeds.
enum ExistingInstallDetector {
    static func detect(
        binaryPath: URL = TronPaths.installedBinary,
        authJSONPath: URL = TronPaths.systemDir.appendingPathComponent("auth.json", isDirectory: false),
        plistPath: URL = TronPaths.launchAgentPlistPath,
        bundleVersionResolver: (URL) -> String? = ExistingInstallDetector.readMarketingVersion
    ) -> ExistingInstallStatus {
        let fm = FileManager.default
        let hasBinary = fm.fileExists(atPath: binaryPath.path)
        let hasAuth = (try? Data(contentsOf: authJSONPath))?.isEmpty == false
        let hasPlist = fm.fileExists(atPath: plistPath.path)

        switch (hasBinary, hasAuth || hasPlist) {
        case (true, _):
            let version = bundleVersionResolver(binaryPath.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
            return .installed(version: version)
        case (false, true):
            // One or both sidecar files remain but the binary is gone —
            // probably a prior install that was partially uninstalled,
            // or a CLI-only install that never ran the wizard. List
            // every leftover so the user sees the full picture instead
            // of only the first one the old ternary happened to pick.
            var leftovers: [String] = []
            if hasAuth { leftovers.append("auth.json") }
            if hasPlist { leftovers.append("LaunchAgent plist") }
            let joined = ListFormatter.localizedString(byJoining: leftovers)
            return .partial(reason: "\(joined) present but Tron.app missing")
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
}
