import Foundation

/// One `ps` read of a live process for a runtime fence.
struct ProcessFenceRead: Equatable, Sendable {
    /// Exact `ps -o lstart=` value: the process's start identity.
    let startIdentity: String
    /// `ps -o etime=` value from the same read. The menu's uptime must come
    /// from the current cycle, never from a cached earlier probe.
    let elapsedTime: String
}

/// Reads launchd-owned process metadata for menu-bar diagnostics.
enum ServerProcessProbe {
    /// Returns every PID with a listening TCP socket on the exact port. An
    /// admission requires this set to contain exactly the expected owner PID.
    static func listenerPIDs(port: Int) async -> Set<Int> {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"],
            policy: .observation
        )
        guard result.exitCode == 0 else { return [] }
        return Set(result.stdout.split(whereSeparator: \.isNewline).compactMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    static func processCommand(pid: Int) async -> String? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ww", "-p", "\(pid)", "-o", "command="],
            policy: .observation
        )
        guard result.exitCode == 0 else { return nil }
        let command = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    static func processStartIdentity(pid: Int) async -> String? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-o", "lstart="],
            policy: .observation
        )
        guard result.exitCode == 0 else { return nil }
        let identity = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return identity.isEmpty ? nil : identity
    }

    /// One `ps` read for both runtime-fence values. The fence runs every poll
    /// cycle, so start identity and elapsed time share one bounded spawn;
    /// `etime` never contains a space, so the first token is elapsed time and
    /// the remainder is `lstart`. Returns `nil` when either is missing, so no
    /// caller treats an unproven runtime as stable.
    static func processFenceRead(pid: Int) async -> ProcessFenceRead? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-o", "etime=,lstart="],
            policy: .observation
        )
        guard result.exitCode == 0 else { return nil }
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let elapsedTime = String(line[line.startIndex..<separator])
        let startIdentity = line[separator...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !elapsedTime.isEmpty, !startIdentity.isEmpty else { return nil }
        return ProcessFenceRead(startIdentity: startIdentity, elapsedTime: elapsedTime)
    }

    static func processElapsedTime(pid: Int) async -> String? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-o", "etime="],
            policy: .observation
        )
        guard result.exitCode == 0 else { return nil }
        let uptime = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return uptime.isEmpty ? nil : uptime
    }
}
