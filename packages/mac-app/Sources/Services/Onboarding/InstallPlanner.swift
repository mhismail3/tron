import Foundation

/// Pure-value planner that converts a "where is the bundled binary, where
/// should it land, what's the LaunchAgent label" into an `InstallPlan`.
/// Has no side effects; the View applies the plan via
/// `LaunchAgentManaging`.
///
/// Tests in `Tests/Services/InstallPlannerTests.swift` cover:
/// - happy path produces correct paths and plist contents
/// - existing-binary case yields `requiresLoad = false` (idempotency)
/// - missing source binary surfaces a clear error to the caller
enum InstallPlanner {
    enum Failure: Error, Equatable, Sendable {
        case sourceBinaryMissing(URL)
        case targetParentNotWritable(URL)
    }

    /// Produces a fully-formed `InstallPlan` ready to be applied.
    /// - Parameters:
    ///   - sourceBinary: path to the bundled `tron-agent` (typically
    ///     inside `Tron.app/Contents/Resources/`).
    ///   - paths: filesystem layout (target bundle, plist path, port).
    ///   - existingInstall: result of `ExistingInstallDetector.detect()`.
    ///     Used to flip `requiresLoad` when an agent is already running.
    static func plan(
        sourceBinary: URL,
        paths: TargetPaths,
        existingInstall: ExistingInstallStatus
    ) -> Result<InstallPlan, Failure> {
        guard FileManager.default.fileExists(atPath: sourceBinary.path) else {
            return .failure(.sourceBinaryMissing(sourceBinary))
        }

        let plistContents = renderPlist(paths: paths)

        // If an existing install reported "installed" with the same
        // binary path, we treat the load as a no-op (kickstart only).
        let requiresLoad: Bool
        switch existingInstall {
        case .none, .partial:
            requiresLoad = true
        case .installed:
            requiresLoad = !FileManager.default.fileExists(atPath: paths.plistPath.path)
        }

        return .success(InstallPlan(
            sourceBinary: sourceBinary,
            targetBundle: paths.targetBundle,
            targetBinary: paths.targetBinary,
            plistPath: paths.plistPath,
            plistContents: plistContents,
            requiresLoad: requiresLoad
        ))
    }

    struct TargetPaths: Equatable, Sendable {
        var targetBundle: URL
        var targetBinary: URL
        var plistPath: URL
        var label: String
        var port: Int
        var tronHome: URL
        var homeDir: URL
        var repoRoot: URL?
    }

    /// Renders the LaunchAgent plist body. Mirrors
    /// `scripts/tron::create_launchd_plist()` so a wizard install lays
    /// down byte-identical contents to a CLI install.
    static func renderPlist(paths: TargetPaths) -> String {
        let repoRoot = paths.repoRoot?.path ?? ""
        let repoEntry: String
        if repoRoot.isEmpty {
            repoEntry = ""
        } else {
            repoEntry = """

                    <key>TRON_REPO_ROOT</key>
                    <string>\(repoRoot.xmlEscaped)</string>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(paths.label.xmlEscaped)</string>

            <key>ProgramArguments</key>
            <array>
                <string>\(paths.targetBinary.path.xmlEscaped)</string>
                <string>--port</string>
                <string>\(paths.port)</string>
                <string>--quiet</string>
            </array>

            <key>RunAtLoad</key>
            <true/>

            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
                <key>Crashed</key>
                <true/>
            </dict>

            <key>ThrottleInterval</key>
            <integer>10</integer>

            <key>EnvironmentVariables</key>
            <dict>
                <key>HOME</key>
                <string>\(paths.homeDir.path.xmlEscaped)</string>
                <key>TRON_DATA_DIR</key>
                <string>\(paths.tronHome.path.xmlEscaped)</string>\(repoEntry)
                <key>RUST_LOG</key>
                <string>info</string>
            </dict>

            <key>SoftResourceLimits</key>
            <dict>
                <key>NumberOfFiles</key>
                <integer>4096</integer>
            </dict>

            <key>AssociatedBundleIdentifiers</key>
            <string>\(TronPaths.bundleID.xmlEscaped)</string>
        </dict>
        </plist>
        """
    }
}

private extension String {
    /// Minimal XML escape for the four characters that can appear in
    /// our paths and label.
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
