import Foundation

/// Probes Tailscale availability + signed-in-and-connected state on the
/// host.
///
/// Detection rule:
/// 1. `/Applications/Tailscale.app` exists OR a CLI binary lives at one
///    of the known Homebrew paths (gives us something to invoke).
/// 2. `tailscale status --peers=false --json` exits 0 AND the parsed
///    `BackendState` is `"Running"` AND `Self.TailscaleIPs` contains at
///    least one IPv4 in the 100.64.0.0/10 CGNAT range.
///
/// The node is ready only while `BackendState` is `Running`; an assigned
/// address retained while disconnected is not sufficient.
///
/// `BackendState` values we treat as NOT-ready (i.e.
/// `.installedNotSignedIn`):
///   - `"Stopped"` — user hit Disconnect.
///   - `"NeedsLogin"` — not signed in.
///   - `"NeedsMachineAuth"` — pending admin approval.
///   - `"NoState"` — daemon just started, not yet configured.
///   - `"Starting"` — daemon is coming up; the next poll will settle.
///   - `"InUseOtherUser"` — another macOS user has the daemon bound.
///
/// The probe is async because running the subprocess spawns a child
/// process. Both the file-existence check and the subprocess are fast
/// enough to run on `.main` (typically <100ms total) but the wizard
/// awaits it on a background `Task` regardless.
enum TailscaleProbe {
    /// Default probe used by `GatewayDependencies.live`. Tests inject a
    /// fake instead of mocking Process directly.
    static func probe() async -> TailscaleStatus {
        await probe(
            tailscaleAppExists: { FileManager.default.fileExists(atPath: $0.path) },
            cliPaths: defaultCLIPaths,
            runProcess: { url in
                await Subprocess.run(
                    executable: url,
                    arguments: ["status", "--peers=false", "--json"]
                )
            }
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
        // Try every executable candidate and accept the first one that
        // proves the Mac is actively connected. This avoids a stale or
        // GUI-flavoured binary masking a healthy Homebrew CLI.
        var sawExecutableCLI = false
        for candidate in cliPaths where FileManager.default.isExecutableFile(atPath: candidate.path) {
            sawExecutableCLI = true
            let result = await runProcess(candidate)

            // Non-zero exit covers: daemon not running, transient
            // startup errors, permission errors. All of these are
            // "not ready from this executable right now" — try any
            // other known CLI before reporting not-ready.
            guard result.exitCode == 0 else { continue }

            guard let data = result.stdout.data(using: .utf8),
                  let status = try? JSONDecoder().decode(TailscaleStatusJSON.self, from: data) else {
                // Malformed / unparseable JSON — do not trust this
                // executable, but keep looking for a healthier CLI.
                continue
            }

            guard status.BackendState == "Running" else {
                continue
            }

            // Only the live local node's address is valid for health and
            // pairing. Aggregate or peer addresses are never accepted.
            let candidateIPs = status.`Self`?.TailscaleIPs ?? []
            if let ip = candidateIPs.first(where: { isTailscaleIPv4($0) }) {
                return .signedIn(ipv4: ip)
            }

            // BackendState==Running but no IPv4 in the response — this
            // shouldn't happen in a healthy tailnet. Try another CLI
            // before giving up.
        }

        return appPresent || sawExecutableCLI ? .installedNotSignedIn : .notInstalled
    }

    static let defaultCLIPaths: [URL] = [
        URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
        URL(fileURLWithPath: "/usr/local/bin/tailscale"),
        URL(fileURLWithPath: "/opt/homebrew/bin/tailscale"),
    ]

    static func isTailscaleIPv4(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".")
        guard parts.count == 4,
              let first = Int(parts[0]),
              let second = Int(parts[1]),
              first == 100,
              (64...127).contains(second) else { return false }
        for part in parts {
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
        }
        return true
    }
}

/// Subset of `tailscale status --peers=false --json` we need. Field
/// names mirror the Go source's PascalCase keys verbatim so the default
/// `JSONDecoder` picks them up without a custom key strategy. Everything
/// is optional so a future Tailscale version that drops or renames a
/// field degrades gracefully to `.installedNotSignedIn` instead of
/// throwing a decoding error that strands the wizard.
private struct TailscaleStatusJSON: Decodable {
    let BackendState: String?
    let `Self`: SelfStatus?

    struct SelfStatus: Decodable {
        let TailscaleIPs: [String]?
    }
}
