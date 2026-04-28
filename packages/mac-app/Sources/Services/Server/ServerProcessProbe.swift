import Foundation

struct ServerProcessInfo: Equatable, Sendable {
    var pid: Int
    var uptime: String?
    var command: String?
    var isDevServer: Bool
}

enum ServerProcessProbe {
    static func probe(port: Int) async -> ServerProcessInfo? {
        let lsof = await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]
        )
        guard lsof.exitCode == 0, let pid = parseFirstPID(lsof.stdout) else {
            return nil
        }

        async let uptime = processElapsedTime(pid: pid)
        async let command = processCommand(pid: pid)
        let resolvedUptime = await uptime
        let resolvedCommand = await command
        return ServerProcessInfo(
            pid: pid,
            uptime: resolvedUptime,
            command: resolvedCommand,
            isDevServer: isDevServerCommand(resolvedCommand)
        )
    }

    static func parseFirstPID(_ stdout: String) -> Int? {
        for line in stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = Int(trimmed), pid > 0 else { continue }
            return pid
        }
        return nil
    }

    static func isDevServerCommand(_ command: String?) -> Bool {
        command?.contains("/Tron-Dev.app/Contents/MacOS/tron") == true
    }

    private static func processElapsedTime(pid: Int) async -> String? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-o", "etime="]
        )
        guard result.exitCode == 0 else { return nil }
        let uptime = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return uptime.isEmpty ? nil : uptime
    }

    private static func processCommand(pid: Int) async -> String? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-ww", "-o", "command="]
        )
        guard result.exitCode == 0 else { return nil }
        let command = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}
