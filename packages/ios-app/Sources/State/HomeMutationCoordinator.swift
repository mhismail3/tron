import Foundation
import Observation
import TronMobileCore

struct HomeDesignationReceipt: Codable, Equatable, Sendable {
    let homeId: String
    let sessionId: String
    let generation: Int
}

@MainActor
@Observable
final class HomeMutationCoordinator {
    enum Command: Equatable {
        case designate, disable, pauseMemory, resumeMemory
        case revokeScope(String), revokeGrant(String)
        case reconfirmPermissions
        case redeliver(taskID: String, homeID: String, routeGeneration: Int)
        case changeProfile([HomeProfileChange])
        case undoProfileChange(String)

        var method: String {
            switch self {
            case .designate: "home.designate"
            case .disable: "home.disable"
            case .pauseMemory: "home.pauseMemory"
            case .resumeMemory: "home.resumeMemory"
            case .revokeScope: "home.revokeTaskScope"
            case .revokeGrant: "home.revokeTaskGrant"
            case .reconfirmPermissions: "home.reconfirmPermissions"
            case .redeliver: "home.redeliverTaskResult"
            case .changeProfile: "home.profileChange"
            case .undoProfileChange: "settings.undo"
            }
        }
    }

    struct Authority {
        fileprivate let profileID: String
        fileprivate let generation: Int
    }

    func authority(profileID: String) throws -> Authority {
        try requireAuthority(profileID: profileID)
        return Authority(profileID: profileID, generation: lifecycle.currentLifecycleGeneration)
    }

    private struct Invocation {
        let profileID: String
        let generation: Int
        let commandID: String
        let command: Command
    }
    static let notAppliedCode = "home_change_not_found"

    private enum State {
        case idle, running(Invocation), unresolved(Invocation)
    }
    private var pending: [String: State] = [:]
    @ObservationIgnored private let client: GatewayClient
    @ObservationIgnored private let lifecycle: GatewayLifecycleCoordinator
    @ObservationIgnored private let mutationExecutor: ConfirmedMutationExecutor
    @ObservationIgnored private let uuidSource: UUIDSource

    init(client: GatewayClient, lifecycle: GatewayLifecycleCoordinator,
         mutationExecutor: ConfirmedMutationExecutor, uuidSource: UUIDSource) {
        self.client = client
        self.lifecycle = lifecycle
        self.mutationExecutor = mutationExecutor
        self.uuidSource = uuidSource
    }

    func isRunning(profileID: String) -> Bool {
        if case .running = state(for: profileID) { true } else { false }
    }

    func ownsUnresolvedCommand(profileID: String) -> Bool {
        if case .unresolved = state(for: profileID) { true } else { false }
    }

    func forgetProfile(_ profileID: String) {
        pending.removeValue(forKey: profileID)
    }

    private func state(for profileID: String) -> State {
        pending[profileID] ?? .idle
    }

    private func setState(_ newState: State, for profileID: String) {
        if case .idle = newState { pending.removeValue(forKey: profileID) } else { pending[profileID] = newState }
    }

    func designate(authority: Authority) async throws -> HomeDesignationReceipt {
        let value: JSONValue
        if case .unresolved(let invocation) = state(for: authority.profileID), invocation.command == .designate {
            value = try await checkCompletion(authority: authority)
        } else {
            value = try await perform(.designate, authority: authority)
        }
        return try value.decode(HomeDesignationReceipt.self)
    }

    func perform(_ command: Command, authority: Authority) async throws -> JSONValue {
        let profileID = authority.profileID
        guard case .idle = state(for: profileID) else {
            throw GatewayFailure(code: "conflict", message: "A Home change is pending. Check its completion before starting another.", retryable: false, details: nil)
        }
        try requireAuthority(profileID: profileID, generation: authority.generation)
        let invocation = Invocation(profileID: profileID, generation: authority.generation,
                                    commandID: uuidSource.next().uuidString, command: command)
        var params: [String: JSONValue] = ["commandId": .string(invocation.commandID)]
        switch command {
        case .revokeScope(let id): params["scopeId"] = .string(id)
        case .revokeGrant(let id): params["grantId"] = .string(id)
        case .changeProfile(let changes):
            params["changes"] = try JSONValue.encode(changes)
        case .undoProfileChange(let changeID):
            params["changeId"] = .string(changeID)
        case .redeliver(let task, let home, let route):
            params["taskId"] = .string(task); params["homeId"] = .string(home); params["routeGeneration"] = .number(Double(route))
        default: break
        }
        setState(.running(invocation), for: profileID)
        do {
            let value = try await mutationExecutor.performValue(
                method: command.method, commandID: invocation.commandID, replayMissingReceipt: false
            ) { try await self.client.requestValue(command.method, JSONValue.object(params)) }
            setState(.idle, for: profileID)
            try requireAuthority(profileID: profileID, generation: invocation.generation)
            return value
        } catch let failure as GatewayFailure where failure.code == "outcome_unknown" {
            setState(.unresolved(invocation), for: profileID)
            throw failure
        } catch {
            setState(.idle, for: profileID)
            if let notSent = error as? GatewayDefinitelyNotSentError { throw notSent.failure }
            throw error
        }
    }

    func checkCompletion(authority: Authority) async throws -> JSONValue {
        let profileID = authority.profileID
        guard case .unresolved(let invocation) = state(for: profileID) else {
            throw GatewayFailure(code: "conflict", message: "Check the pending Home change on its original Gateway.", retryable: false, details: nil)
        }
        try requireAuthority(profileID: profileID, generation: authority.generation)
        let generation = authority.generation
        setState(.running(invocation), for: profileID)
        do {
            let resolution = try await mutationExecutor.resolveReceipt(method: invocation.command.method, commandID: invocation.commandID)
            setState(.idle, for: profileID)
            try requireAuthority(profileID: profileID, generation: generation)
            switch resolution {
            case .completed(let value): return value
            case .missing:
                throw GatewayFailure(
                    code: Self.notAppliedCode,
                    message: "Tron has no record of that Home change, so nothing was replayed. Check the current Home status before trying again.",
                    retryable: false,
                    details: nil
                )
            }
        } catch {
            if case .running = state(for: profileID) { setState(.unresolved(invocation), for: profileID) }
            throw error
        }
    }

    private func requireAuthority(profileID: String, generation: Int? = nil) throws {
        guard lifecycle.selectedProfileID == profileID, lifecycle.generationAdmission != nil,
              generation == nil || lifecycle.currentLifecycleGeneration == generation,
              lifecycle.gatewayInfo?.capabilities.contains("home.v1") == true else { throw CancellationError() }
    }
}
