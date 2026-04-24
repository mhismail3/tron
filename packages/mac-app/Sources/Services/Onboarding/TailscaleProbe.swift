import Foundation

/// Probes Tailscale availability + signed-in state on the host.
///
/// Detection rule:
/// 1. `/Applications/Tailscale.app` exists (gives us a CLI at
///    `/Applications/Tailscale.app/Contents/MacOS/Tailscale`).
/// 2. `tailscale ip -4` exits 0 and prints at least one IPv4 address.
///
/// The probe is async because step 2 spawns a subprocess. Both checks
/// are fast enough to run on `.main` (typically <100ms total) but the
/// wizard awaits it on a background `Task` regardless.
enum TailscaleProbe {
    /// Default probe used by `EnvironmentSetup.live`. Tests inject a
    /// fake instead of mocking Process directly.
    static func probe() async -> TailscaleStatus {
        await probe(
            tailscaleAppExists: { FileManager.default.fileExists(atPath: $0.path) },
            cliPaths: defaultCLIPaths,
            runProcess: { url in await Subprocess.run(executable: url, arguments: ["ip", "-4"]) }
        )
    }

    /// Test-injection variant. All side-effects flow through the closures.
    static func probe(
        tailscaleAppExists: (URL) -> Bool,
        cliPaths: [URL],
        runProcess: (URL) async -> ProcessResult
    ) async -> TailscaleStatus {
        let appURL = URL(fileURLWithPath: "/Applications/Tailscale.app")
        let appPresent = tailscaleAppExists(appURL)

        // The CLI may be present even without the .app (Homebrew install).
        // Run through the candidate CLI paths in priority order.
        for candidate in cliPaths where FileManager.default.isExecutableFile(atPath: candidate.path) {
            let result = await runProcess(candidate)
            if result.exitCode == 0 {
                let firstIP = result.stdout
                    .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
                    .map(String.init)
                    .first(where: { isIPv4($0) })
                if let ip = firstIP, !ip.isEmpty {
                    return .signedIn(ipv4: ip)
                }
                // CLI exited 0 but printed nothing - signed out.
                return .installedNotSignedIn
            }
            // Non-zero exit - typically `not running` or `logged out`.
            return .installedNotSignedIn
        }

        return appPresent ? .installedNotSignedIn : .notInstalled
    }

    static let defaultCLIPaths: [URL] = [
        URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
        URL(fileURLWithPath: "/usr/local/bin/tailscale"),
        URL(fileURLWithPath: "/opt/homebrew/bin/tailscale"),
    ]

    static func isIPv4(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".")
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
        }
        return true
    }
}
