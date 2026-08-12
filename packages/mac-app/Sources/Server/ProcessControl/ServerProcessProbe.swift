import Foundation

/// Reads launchd-owned process metadata for menu-bar diagnostics.
enum ServerProcessProbe {
    static func processElapsedTime(pid: Int) async -> String? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-o", "etime="]
        )
        guard result.exitCode == 0 else { return nil }
        let uptime = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return uptime.isEmpty ? nil : uptime
    }
}
