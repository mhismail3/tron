import Foundation
import ServiceManagement

/// Exact `SMAppService` adapter for the configured Gateway label.
/// It never inspects, migrates, or controls any other service identity.
struct LiveGatewayServiceManager: GatewayServiceManaging {
    func registrationStatus(
        configuration: GatewayServiceConfiguration
    ) async -> GatewayServiceRegistrationStatus {
        switch service(configuration).status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register(configuration: GatewayServiceConfiguration) async -> GatewayServiceOutcome {
        guard GatewayBundleValidator.validate(configuration: configuration) == nil else {
            return .invalidBundle
        }

        let status = await registrationStatus(configuration: configuration)
        if status == .requiresApproval {
            return .requiresApproval
        }

        if status == .enabled {
            let runtime = await runtimeInfo(configuration: configuration)
            if Self.runtimeMatches(runtime, configuration: configuration) {
                return .alreadyRegistered
            }
            guard await unregister(configuration: configuration) == .unregistered else {
                return .refused
            }
        } else if await isLoaded(configuration: configuration) {
            guard await unregister(configuration: configuration) == .unregistered else {
                return .refused
            }
        }

        if await Self.isPortBound(configuration.gatewayPort) {
            return .portInUse(configuration.gatewayPort)
        }

        do {
            try service(configuration).register()
        } catch {
            return .refused
        }

        return switch await registrationStatus(configuration: configuration) {
        case .enabled: .registered
        case .requiresApproval: .requiresApproval
        case .notRegistered, .unavailable: .failed
        }
    }

    func unregister(configuration: GatewayServiceConfiguration) async -> GatewayServiceOutcome {
        switch await registrationStatus(configuration: configuration) {
        case .notRegistered, .unavailable:
            guard await isLoaded(configuration: configuration) else {
                return .unregistered
            }
            let bootout = await Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["bootout", "gui/\(currentUID())/\(configuration.serviceLabel)"]
            )
            guard bootout.exitCode == 0 else { return .refused }
            return await isLoaded(configuration: configuration) ? .failed : .unregistered
        case .enabled, .requiresApproval:
            break
        }

        do {
            try await service(configuration).unregister()
        } catch {
            return .refused
        }

        switch await registrationStatus(configuration: configuration) {
        case .notRegistered, .unavailable:
            return await isLoaded(configuration: configuration) ? .failed : .unregistered
        case .enabled, .requiresApproval:
            return .failed
        }
    }

    func restart(configuration: GatewayServiceConfiguration) async -> GatewayServiceOutcome {
        guard await registrationStatus(configuration: configuration) == .enabled else {
            return .failed
        }
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["kickstart", "-k", "gui/\(currentUID())/\(configuration.serviceLabel)"]
        )
        return result.exitCode == 0 ? .registered : .refused
    }

    func isLoaded(configuration: GatewayServiceConfiguration) async -> Bool {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "gui/\(currentUID())/\(configuration.serviceLabel)"]
        )
        return result.exitCode == 0
    }

    func runtimeInfo(configuration: GatewayServiceConfiguration) async -> GatewayRuntimeInfo? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "gui/\(currentUID())/\(configuration.serviceLabel)"]
        )
        guard result.exitCode == 0 else { return nil }
        let pid = parsePID(result.stdout)
        let uptime: String? = if let pid {
            await GatewayProcessProbe.processElapsedTime(pid: pid)
        } else {
            nil
        }
        return GatewayRuntimeInfo(
            pid: pid,
            uptime: uptime,
            parentBundleIdentifier: parseValue("parent bundle identifier", result.stdout),
            parentBundleVersion: parseValue("parent bundle version", result.stdout),
            programIdentifier: Self.parseProgramIdentifier(result.stdout)
        )
    }

    static func runtimeMatches(
        _ runtime: GatewayRuntimeInfo?,
        configuration: GatewayServiceConfiguration,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard let runtime,
              runtime.parentBundleIdentifier == configuration.mode.bundleIdentifier,
              runtime.programIdentifier == configuration.helperBundleProgram else {
            return false
        }
        return fileExists(configuration.helperBinary.standardizedFileURL.path)
    }

    static func parseProgramIdentifier(_ output: String) -> String? {
        let prefix = "program identifier = "
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = String(trimmed.dropFirst(prefix.count))
            let identifier = value.components(separatedBy: " (mode:").first?
                .trimmingCharacters(in: .whitespaces)
            return identifier?.isEmpty == false ? identifier : nil
        }
        return nil
    }

    private func service(_ configuration: GatewayServiceConfiguration) -> SMAppService {
        SMAppService.agent(plistName: "\(configuration.serviceLabel).plist")
    }

    private func parsePID(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid =") else { continue }
            return Int(trimmed.drop { !$0.isNumber }.prefix { $0.isNumber })
        }
        return nil
    }

    private func parseValue(_ key: String, _ output: String) -> String? {
        let prefix = "\(key) ="
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func isPortBound(_ port: Int) async -> Bool {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        )
        return result.exitCode == 0 && !result.stdout.isEmpty
    }

    private func currentUID() -> Int { Int(getuid()) }
}
