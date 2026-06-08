import Foundation

/// Pure-value planner for the bundled `SMAppService` agent. Has no side
/// effects; the View validates the bundled files and registers the
/// LaunchAgent through `LaunchAgentManaging`.
///
/// Tests in `Tests/Support/Onboarding/InstallPlannerTests.swift` cover:
/// - happy path produces correct paths and plist contents
/// - registered services still produce a plan that the view must start
///   and ping before continuing
/// - plist rendering uses `BundleProgram`
enum InstallPlanner {
    enum Failure: Error, Equatable, Sendable {
        case helperMissing(URL)
        case plistMissing(URL)
    }

    /// Produces a fully-formed `InstallPlan` ready to be applied.
    static func plan(paths: TargetPaths) -> Result<InstallPlan, Failure> {
        guard FileManager.default.fileExists(atPath: paths.helperBinary.path) else {
            return .failure(.helperMissing(paths.helperBinary))
        }
        guard FileManager.default.fileExists(atPath: paths.plistPath.path) else {
            return .failure(.plistMissing(paths.plistPath))
        }

        return .success(InstallPlan(
            plistPath: paths.plistPath,
            helperBundle: paths.helperBundle,
            helperBinary: paths.helperBinary
        ))
    }

    struct TargetPaths: Equatable, Sendable {
        var helperBundle: URL
        var helperBinary: URL
        var plistPath: URL
        var label: String
        var port: Int
        var environmentVariables: [String: String] = TronPaths.launchAgentEnvironmentVariables
        var associatedBundleIDs: [String] = TronPaths.associatedWrapperBundleIDs
    }

    /// Renders the LaunchAgent plist body. Mirrors
    /// `SMAppService.agent(plistName:)` requirements: the plist is
    /// bundled under `Contents/Library/LaunchAgents`, `BundleProgram`
    /// is relative to the outer app bundle, and `ProgramArguments`
    /// contains only argv items.
    static func renderPlist(paths: TargetPaths) -> String {
        let bundleProgram = "Contents/Library/LoginItems/\(paths.helperBundle.lastPathComponent)/Contents/MacOS/tron"
        let environment = paths.environmentVariables.keys.sorted().map { key in
            """
                    <key>\(key.xmlEscaped)</key>
                    <string>\(paths.environmentVariables[key, default: ""].xmlEscaped)</string>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(paths.label.xmlEscaped)</string>

            <key>ProgramArguments</key>
            <array>
                <string>tron</string>
                <string>--port</string>
                <string>\(paths.port)</string>
                <string>--quiet</string>
            </array>

            <key>BundleProgram</key>
            <string>\(bundleProgram.xmlEscaped)</string>

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
        \(environment)
            </dict>

            <key>SoftResourceLimits</key>
            <dict>
                <key>NumberOfFiles</key>
                <integer>4096</integer>
            </dict>

            <key>AssociatedBundleIdentifiers</key>
            <array>
        \(paths.associatedBundleIDs.map { "        <string>\($0.xmlEscaped)</string>" }.joined(separator: "\n"))
            </array>
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
