import Foundation

/// Reads launchd-owned process metadata for menu-bar diagnostics.
enum ServerProcessProbe {
    /// Returns every PID with a listening TCP socket on the exact port. An
    /// admission requires this set to contain exactly the expected owner PID.
    static func listenerPIDs(port: Int) async -> Set<Int> {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        )
        guard result.exitCode == 0 else { return [] }
        return Set(result.stdout.split(whereSeparator: \.isNewline).compactMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    static func processCommand(pid: Int) async -> String? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ww", "-p", "\(pid)", "-o", "command="]
        )
        guard result.exitCode == 0 else { return nil }
        let command = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    static func processStartIdentity(pid: Int) async -> String? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-o", "lstart="]
        )
        guard result.exitCode == 0 else { return nil }
        let identity = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return identity.isEmpty ? nil : identity
    }

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
