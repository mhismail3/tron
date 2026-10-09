import Foundation
import Observation
import TronMobileCore

struct HomeDesignationReceipt: Codable, Equatable, Sendable {
    let homeId: String
    let sessionId: String
    let generation: Int
}

/// One Home command authority, independent of disposable dashboard/chat reads.
@MainActor
@Observable
final class HomeMutationCoordinator {
    enum Command: Equatable {
        case designate, disable, configureMemory(ModelRef), pauseMemory, resumeMemory
        case stopTask(taskID: String, operationID: String, generation: Int)
        case steerTask(taskID: String, operationID: String, generation: Int, text: String)
        case revokeScope(String), revokeGrant(String)
        case decideGrant(requestID: String, approved: Bool, expiresAt: Int)
        case reconfirmPermissions
        case redeliver(taskID: String, homeID: String, routeGeneration: Int)

        var method: String {
            switch self {
            case .designate: "home.designate"
            case .disable: "home.disable"
            case .configureMemory: "home.configureMemory"
            case .pauseMemory: "home.pauseMemory"
            case .resumeMemory: "home.resumeMemory"
            case .stopTask: "home.stopTask"
            case .steerTask: "home.steerTask"
            case .revokeScope: "home.revokeTaskScope"
            case .revokeGrant: "home.revokeTaskGrant"
            case .decideGrant: "home.decideTaskGrant"
            case .reconfirmPermissions: "home.reconfirmPermissions"
            case .redeliver: "home.redeliverTaskResult"
            }
        }
    }

    struct Authority {
        fileprivate let profileID: String
        fileprivate let generation: Int
    }

    /// Capture synchronously at the user action, before creating an async task.
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
    private enum State {
        case idle, running(Invocation), unresolved(Invocation)
    }
    private var state: State = .idle
    var isRunning: Bool { if case .running = state { true } else { false } }
    var hasUnresolvedCommand: Bool { if case .unresolved = state { true } else { false } }
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

    func ownsUnresolvedCommand(profileID: String) -> Bool {
        if case .unresolved(let invocation) = state { return invocation.profileID == profileID }
        return false
    }

    func designate(authority: Authority) async throws -> HomeDesignationReceipt {
        let value: JSONValue
        if case .unresolved(let invocation) = state, invocation.command == .designate {
            value = try await checkCompletion(authority: authority)
        } else {
            value = try await perform(.designate, authority: authority)
        }
        return try value.decode(HomeDesignationReceipt.self)
    }

    func perform(_ command: Command, authority: Authority) async throws -> JSONValue {
        let profileID = authority.profileID
        guard case .idle = state else {
            throw GatewayFailure(code: "conflict", message: "A Home change is pending. Check its completion before starting another.", retryable: false, details: nil)
        }
        try requireAuthority(profileID: profileID, generation: authority.generation)
        let invocation = Invocation(profileID: profileID, generation: authority.generation,
                                    commandID: uuidSource.next().uuidString, command: command)
        var params: [String: JSONValue] = ["commandId": .string(invocation.commandID)]
        switch command {
        case .configureMemory(let model): params["model"] = try JSONValue.encode(model)
        case .stopTask(let task, let operation, let generation), .steerTask(let task, let operation, let generation, _):
            params["taskId"] = .string(task); params["operationId"] = .string(operation)
            params["controllerGeneration"] = .number(Double(generation))
            if case .steerTask(_, _, _, let text) = command { params["text"] = .string(text) }
        case .revokeScope(let id): params["scopeId"] = .string(id)
        case .revokeGrant(let id): params["grantId"] = .string(id)
        case .decideGrant(let request, let approved, let expires):
            params["requestId"] = .string(request); params["approved"] = .bool(approved); params["expiresAt"] = .number(Double(expires))
        case .redeliver(let task, let home, let route):
            params["taskId"] = .string(task); params["homeId"] = .string(home); params["routeGeneration"] = .number(Double(route))
        default: break
        }
        state = .running(invocation)
        do {
            let value = try await mutationExecutor.performValue(
                method: command.method, commandID: invocation.commandID, replayMissingReceipt: false
            ) { try await self.client.requestValue(command.method, JSONValue.object(params)) }
            state = .idle
            try requireAuthority(profileID: profileID, generation: invocation.generation)
            return value
        } catch let failure as GatewayFailure where failure.code == "outcome_unknown" {
            state = .unresolved(invocation)
            throw failure
        } catch {
            state = .idle
            if let notSent = error as? GatewayDefinitelyNotSentError { throw notSent.failure }
            throw error
        }
    }

    /// Checking an unresolved command never creates or re-sends a mutation.
    func checkCompletion(authority: Authority) async throws -> JSONValue {
        let profileID = authority.profileID
        guard case .unresolved(let invocation) = state, invocation.profileID == profileID else {
            throw GatewayFailure(code: "conflict", message: "Check the pending Home change on its original Gateway.", retryable: false, details: nil)
        }
        try requireAuthority(profileID: profileID, generation: authority.generation)
        let generation = authority.generation
        state = .running(invocation)
        do {
            let value = try await mutationExecutor.resolveValue(method: invocation.command.method, commandID: invocation.commandID)
            // A terminal receipt retires its invocation even if its UI is gone.
            state = .idle
            try requireAuthority(profileID: profileID, generation: generation)
            return value
        } catch {
            // Publication cancellation after terminal retirement must not restore
            // an already-completed receipt as a pending command.
            if case .running = state { state = .unresolved(invocation) }
            throw error
        }
    }

    private func requireAuthority(profileID: String, generation: Int? = nil) throws {
        guard lifecycle.selectedProfileID == profileID, lifecycle.generationAdmission != nil,
              generation == nil || lifecycle.currentLifecycleGeneration == generation,
              lifecycle.gatewayInfo?.capabilities.contains("home.v1") == true else { throw CancellationError() }
    }
}
