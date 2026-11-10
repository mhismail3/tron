import Foundation

enum LaunchAgentOutcome: Equatable, Sendable {
    case ok
    case alreadyLoaded
    case requiresApproval(message: String)
    case launchdRefused(message: String)
    case binaryMissing(path: String)
    case unknown(message: String)
}

enum LaunchAgentRegistrationPlan: Equatable, Sendable {
    enum Step: Equatable, Sendable { case bootout, unregister, register }
    case keep
    case refuse(message: String)
    case change(steps: [Step])

    var steps: [Step] {
        switch self {
        case .keep, .refuse: return []
        case .change(let steps): return steps
        }
    }
}

protocol LaunchAgentManaging: Sendable {
    func load(plistPath: URL, label: String) async -> LaunchAgentOutcome

    func unload(label: String) async -> LaunchAgentOutcome

    func restart(label: String) async -> LaunchAgentOutcome

    func isLoaded(label: String) async -> Bool?

    func runtimeInfo(label: String) async -> LaunchAgentRuntimeInfo?
}

enum LaunchAgentLoader {
    static func ensureLoaded(
        manager: LaunchAgentManaging,
        plistPath: URL,
        label: String
    ) async -> LaunchAgentOutcome {
        let loadOutcome = await manager.load(plistPath: plistPath, label: label)
        guard case .alreadyLoaded = loadOutcome else {
            return loadOutcome
        }
        return await manager.restart(label: label)
    }
}
