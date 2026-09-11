import Foundation

struct LaunchAgentRuntimeInfo: Equatable, Sendable {
    var pid: Int?
    var uptime: String?
    var parentBundleIdentifier: String?
    var parentBundleVersion: String?
    var executablePath: String?
    var bundleProgram: String?
    /// Exact `ps -ww` command for the launchd-owned PID. Relative
    /// BundleProgram metadata alone cannot prove which payload was exec'd.
    var processCommand: String?
    var gatewaySupervisionMarker: String?
    var gatewayChannelMarker: String?
    var needsLaunchConstraintRefresh: Bool

    init(
        pid: Int? = nil,
        uptime: String? = nil,
        parentBundleIdentifier: String? = nil,
        parentBundleVersion: String? = nil,
        executablePath: String? = nil,
        bundleProgram: String? = nil,
        processCommand: String? = nil,
        gatewaySupervisionMarker: String? = nil,
        gatewayChannelMarker: String? = nil,
        needsLaunchConstraintRefresh: Bool = false
    ) {
        self.pid = pid
        self.uptime = uptime
        self.parentBundleIdentifier = parentBundleIdentifier
        self.parentBundleVersion = parentBundleVersion
        self.executablePath = executablePath
        self.bundleProgram = bundleProgram
        self.processCommand = processCommand
        self.gatewaySupervisionMarker = gatewaySupervisionMarker
        self.gatewayChannelMarker = gatewayChannelMarker
        self.needsLaunchConstraintRefresh = needsLaunchConstraintRefresh
    }
}

/// Read-only launchd/ps observation shared with the native peer boundary.
enum LaunchAgentRuntimeReader {
    enum ObservationFailure: Error { case unavailable }
    static func read(label: String) async throws -> LaunchAgentRuntimeInfo? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "gui/\(getuid())/\(label)"],
            policy: .observation
        )
        guard result.exitCode >= 0 else { throw ObservationFailure.unavailable }
        guard result.exitCode == 0 else { return nil }
        let pid = parsePID(from: result.stdout)
        let uptime: String?
        let processCommand: String?
        if let pid {
            uptime = await ServerProcessProbe.processElapsedTime(pid: pid)
            processCommand = await ServerProcessProbe.processCommand(pid: pid)
        } else {
            uptime = nil
            processCommand = nil
        }
        return LaunchAgentRuntimeInfo(
            pid: pid,
            uptime: uptime,
            parentBundleIdentifier: parseLaunchctlValue(
                named: "parent bundle identifier",
                from: result.stdout
            ),
            parentBundleVersion: parseLaunchctlValue(named: "parent bundle version", from: result.stdout),
            executablePath: parseLaunchctlDictionaryValue(named: "Executable", from: result.stdout),
            bundleProgram: parseLaunchctlProgramIdentifier(from: result.stdout),
            processCommand: processCommand,
            gatewaySupervisionMarker: parseLaunchctlEnvironmentValue(
                named: "TRON_GATEWAY_SUPERVISED",
                from: result.stdout
            ),
            gatewayChannelMarker: parseLaunchctlEnvironmentValue(
                named: "TRON_GATEWAY_CHANNEL",
                from: result.stdout
            ),
            needsLaunchConstraintRefresh: result.stdout.contains("needs LWCR update")
        )
    }

    private static func parsePID(from launchctlOutput: String) -> Int? {
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid =") else { continue }
            let digits = trimmed.drop { !$0.isNumber }.prefix { $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    private static func parseLaunchctlValue(named key: String, from launchctlOutput: String) -> String? {
        let prefix = "\(key) ="
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func parseLaunchctlEnvironmentValue(named key: String, from launchctlOutput: String) -> String? {
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            for separator in [" => ", " = "] {
                let prefix = "\(key)\(separator)"
                guard text.hasPrefix(prefix) else { continue }
                let value = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func parseLaunchctlProgramIdentifier(from launchctlOutput: String) -> String? {
        guard let value = parseLaunchctlValue(named: "program identifier", from: launchctlOutput) else {
            return nil
        }
        let program = value.components(separatedBy: " (mode:").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return program?.isEmpty == false ? program : nil
    }

    private static func parseLaunchctlDictionaryValue(named key: String, from launchctlOutput: String) -> String? {
        let prefix = "\"\(key)\" => \""
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let range = text.range(of: prefix) else { continue }
            let remainder = text[range.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { continue }
            let value = String(remainder[..<end])
            return value.isEmpty ? nil : value
        }
        return nil
    }

}
