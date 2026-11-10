import Foundation

struct ProcessFenceRead: Equatable, Sendable {
    let startIdentity: String
    let elapsedTime: String
}

enum ServerProcessProbe {
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
