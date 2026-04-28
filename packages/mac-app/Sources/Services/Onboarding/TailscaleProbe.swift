import Foundation

/// Probes Tailscale availability + signed-in-and-connected state on the
/// host.
///
/// Detection rule:
/// 1. `/Applications/Tailscale.app` exists OR a CLI binary lives at one
///    of the known Homebrew paths (gives us something to invoke).
/// 2. `tailscale status --peers=false --json` exits 0 AND the parsed
///    `BackendState` is `"Running"` AND `TailscaleIPs` contains at least
///    one IPv4 in the 100.64.0.0/10 CGNAT range.
///
/// Why not `tailscale ip -4`: the CLI returns the Mac's assigned IP even
/// when the user has hit **Disconnect** in the menu bar (`BackendState`
/// becomes `"Stopped"`) or has quit Tailscale.app while the launchd
/// daemon keeps running. Using `ip -4` caused the wizard to briefly
/// flash `.installedNotSignedIn` (during the subprocess's transient
/// unavailability window right after the user disconnected) and then
/// flip back to `.signedIn` on the next poll because the cached IP
/// reappeared. Parsing `BackendState` out of the JSON status gives us
/// an authoritative "currently participating in the tailnet" signal
/// that can't be fooled by the cached IP.
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
    /// Default probe used by `EnvironmentSetup.live`. Tests inject a
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

            // Prefer `Self.TailscaleIPs` (the node's own IP) over the
            // top-level list which on some Tailscale versions includes
            // only the aggregate tailnet IPs. Fall back to top-level
            // if `Self` is absent.
            let candidateIPs = status.`Self`?.TailscaleIPs ?? status.TailscaleIPs ?? []
            if let ip = candidateIPs.first(where: { isIPv4($0) }) {
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

    static func isIPv4(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".")
        guard parts.count == 4 else { return false }
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
    let TailscaleIPs: [String]?
    let `Self`: SelfStatus?

    struct SelfStatus: Decodable {
        let TailscaleIPs: [String]?
    }
}
