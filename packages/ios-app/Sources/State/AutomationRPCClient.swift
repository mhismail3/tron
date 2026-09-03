import Foundation

/// Narrow typed client for Gateway-owned Automations. It never stores response
/// content; callers own the lifetime of definitions and run details.
@MainActor
final class AutomationRPCClient {
    typealias Request = @MainActor @Sendable (String, JSONValue, Duration) async throws -> JSONValue
    private let requestValue: Request
    private let mutationExecutor: ConfirmedMutationExecutor?

    init(request: @escaping Request, mutationExecutor: ConfirmedMutationExecutor? = nil) {
        self.requestValue = request
        self.mutationExecutor = mutationExecutor
    }

    func request<Response: Decodable>(_ method: String, _ params: some Encodable = EmptyParams(), timeout: Duration = .seconds(15)) async throws -> Response {
        let value = try JSONValue.encode(params)
        let response = try await requestValue(method, value, timeout)
        return try response.decode(Response.self)
    }

    func status() async throws -> GatewayAutomationStatus {
        let value: GatewayAutomationStatus = try await request("automation.status")
        guard value.automationCount >= 0,
              value.automationCount <= AutomationAdmissionPolicy.maximumRetainedCount,
              value.aggregateBytes >= 0,
              value.malformedRecordCount >= 0,
              value.catalogRevision >= 0 else {
            throw GatewayFailure(code: "invalid_response", message: "The Automation status is invalid.", retryable: false, details: nil)
        }
        return value
    }
    func list(cursor: String? = nil, limit: Int = 100) async throws -> GatewayAutomationPage {
        struct Params: Encodable { let cursor: String?; let limit: Int }
        return try await request("automation.list", Params(cursor: cursor, limit: min(100, max(1, limit))))
    }
    func get(id: String) async throws -> GatewayAutomationRecord {
        struct Params: Encodable { let automationId: String }
        let value: GatewayAutomationRecord = try await request("automation.get", Params(automationId: id))
        guard AutomationAdmissionPolicy.admits(value) else {
            throw GatewayFailure(code: "invalid_response", message: "The Automation definition is invalid.", retryable: false, details: nil)
        }
        return value
    }
    func runs(id: String) async throws -> GatewayAutomationRuns {
        struct Params: Encodable { let automationId: String }
        let value: GatewayAutomationRuns = try await request("automation.run.list", Params(automationId: id))
        guard value.runs.count <= 65, value.runs.allSatisfy(AutomationAdmissionPolicy.admits) else {
            throw GatewayFailure(code: "invalid_response", message: "The Automation run history is invalid.", retryable: false, details: nil)
        }
        return value
    }
    func run(id: String, runId: String, target: GatewayAutomationTarget) async throws -> GatewayAutomationRun {
        struct Params: Encodable { let automationId: String; let runId: String }
        let value: GatewayAutomationRun = try await request("automation.run.get", Params(automationId: id, runId: runId))
        guard AutomationAdmissionPolicy.admits(value),
              value.runId == runId,
              value.targetSnapshot == target else {
            throw GatewayFailure(code: "invalid_response", message: "The Automation run is invalid.", retryable: false, details: nil)
        }
        return value
    }
    func timeline(from: Date, through: Date, timezone: String, cursor: String? = nil, limit: Int = 200) async throws -> GatewayAutomationTimelinePage {
        struct Params: Encodable { let from, through, displayTimezone: String; let cursor: String?; let limit: Int }
        return try await request("automation.timeline.list", Params(from: from.gatewayISO8601, through: through.gatewayISO8601, displayTimezone: timezone, cursor: cursor, limit: min(200, max(1, limit))))
    }
    func preview(trigger: GatewayAutomationTrigger, after: Date? = nil, limit: Int = 10) async throws -> GatewayAutomationPreview {
        struct Params: Encodable { let trigger: GatewayAutomationTrigger; let after: String?; let limit: Int }
        return try await request("automation.schedule.preview", Params(trigger: trigger, after: after?.gatewayISO8601, limit: min(20, max(1, limit))))
    }

    func mutate(method: String, parameters: Encodable) async throws -> JSONValue {
        let commandID = UUID().uuidString.lowercased()
        let encoded = try JSONValue.encode(parameters)
        var object = encoded.objectValue ?? [:]
        object["commandId"] = .string(commandID)
        let send = { [requestValue] in try await requestValue(method, .object(object), .seconds(30)) }
        guard let mutationExecutor else {
            throw GatewayFailure(
                code: "needs_server",
                message: "Select this Gateway before changing an Automation.",
                retryable: false,
                details: nil
            )
        }
        return try await mutationExecutor.performValue(method: method, commandID: commandID, send: send)
    }

    func create(definition: AutomationDefinitionDraft) async throws -> GatewayAutomationRecord {
        struct Params: Encodable { let definition: AutomationDefinitionDraft }
        let value = try await mutate(method: "automation.create", parameters: Params(definition: definition))
        let record = try admittedRecord(value)
        guard record.revision == 1,
              record.name == definition.name,
              record.description == definition.description,
              record.activation.rawValue == (definition.activation ?? "draft"),
              record.target == definition.target,
              AutomationAdmissionPolicy.admitsActionTarget(actionKind: definition.action.typedKind, target: record.target),
              record.trigger == definition.trigger,
              record.misfirePolicy == definition.misfirePolicy,
              record.overlapPolicy == definition.overlapPolicy,
              record.executionDeadlineSeconds == definition.executionDeadlineSeconds,
              record.action == definition.action else {
            throw invalidMutationResponse()
        }
        return record
    }
    func update(id: String, revision: Int, definition: AutomationDefinitionDraft) async throws -> GatewayAutomationRecord {
        struct Params: Encodable { let automationId: String; let expectedRevision: Int; let definition: AutomationDefinitionDraft }
        let value = try await mutate(method: "automation.update", parameters: Params(automationId: id, expectedRevision: revision, definition: definition))
        let record = try admittedRecord(value, expectedID: id, expectedRevision: revision + 1)
        guard record.name == definition.name,
              record.description == definition.description,
              record.target == definition.target,
              AutomationAdmissionPolicy.admitsActionTarget(actionKind: definition.action.typedKind, target: record.target),
              record.trigger == definition.trigger,
              record.misfirePolicy == definition.misfirePolicy,
              record.overlapPolicy == definition.overlapPolicy,
              record.executionDeadlineSeconds == definition.executionDeadlineSeconds,
              record.action == definition.action else {
            throw invalidMutationResponse()
        }
        return record
    }
    func setActivation(id: String, revision: Int, enabled: Bool) async throws -> GatewayAutomationRecord {
        struct Params: Encodable { let automationId: String; let expectedRevision: Int }
        let value = try await mutate(method: enabled ? "automation.enable" : "automation.pause", parameters: Params(automationId: id, expectedRevision: revision))
        let record = try admittedRecord(value, expectedID: id, expectedRevision: revision + 1)
        guard record.activation == (enabled ? .enabled : .paused) else { throw invalidMutationResponse() }
        return record
    }
    func runNow(id: String, revision: Int, target: GatewayAutomationTarget) async throws -> GatewayAutomationRun {
        struct Params: Encodable { let automationId: String; let expectedRevision: Int }
        let value = try await mutate(method: "automation.runNow", parameters: Params(automationId: id, expectedRevision: revision))
        let run = try value.decode(GatewayAutomationRun.self)
        guard AutomationAdmissionPolicy.admits(run),
              run.automationRevision == revision,
              run.targetSnapshot == target,
              AutomationAdmissionPolicy.admitsActionTarget(actionKind: run.actionSnapshot.typedKind, target: run.targetSnapshot) else {
            throw invalidMutationResponse()
        }
        return run
    }
    func cancel(id: String, runId: String, target: GatewayAutomationTarget) async throws -> GatewayAutomationRun {
        struct Params: Encodable { let automationId: String; let runId: String }
        let value = try await mutate(method: "automation.run.cancel", parameters: Params(automationId: id, runId: runId))
        let run = try value.decode(GatewayAutomationRun.self)
        guard AutomationAdmissionPolicy.admits(run),
              run.runId == runId,
              run.targetSnapshot == target else {
            throw invalidMutationResponse()
        }
        return run
    }
    func delete(id: String, revision: Int) async throws {
        struct Params: Encodable { let automationId: String; let expectedRevision: Int }
        let value = try await mutate(method: "automation.delete", parameters: Params(automationId: id, expectedRevision: revision))
        let response = try value.decode(GatewayAutomationDeleteResponse.self)
        guard response.deleted else { throw invalidMutationResponse() }
    }
    func resolve(id: String, runId: String, revision: Int, outcome: String) async throws -> GatewayAutomationRecord {
        struct Params: Encodable { let automationId, runId: String; let expectedRevision: Int; let outcome: String }
        let value = try await mutate(method: "automation.run.resolve", parameters: Params(automationId: id, runId: runId, expectedRevision: revision, outcome: outcome))
        let record = try admittedRecord(value, expectedID: id, expectedRevision: revision + 1)
        let resolved = ([record.lastRun].compactMap { $0 } + record.history).first { $0.runId == runId }
        guard resolved?.state.rawValue == outcome, resolved?.resolution?.outcome == outcome else {
            throw invalidMutationResponse()
        }
        return record
    }

    private func admittedRecord(
        _ value: JSONValue,
        expectedID: String? = nil,
        expectedRevision: Int? = nil
    ) throws -> GatewayAutomationRecord {
        let record = try value.decode(GatewayAutomationRecord.self)
        guard AutomationAdmissionPolicy.admits(record),
              expectedID.map({ record.id == $0 }) ?? true,
              expectedRevision.map({ record.revision == $0 }) ?? true else {
            throw invalidMutationResponse()
        }
        return record
    }

    private func invalidMutationResponse() -> GatewayFailure {
        GatewayFailure(
            code: "invalid_response",
            message: "The Automation mutation response does not match the requested change.",
            retryable: false,
            details: nil
        )
    }
}

struct AutomationDefinitionDraft: Codable, Hashable, Sendable {
    var name: String
    var description: String?
    var activation: String? = nil
    var target: GatewayAutomationTarget
    var trigger: GatewayAutomationTrigger
    var misfirePolicy: String
    var overlapPolicy: String
    var executionDeadlineSeconds: Int
    var action: GatewayAutomationAction
}

private extension Date {
    var gatewayISO8601: String {
        ISO8601DateFormatter().string(from: self)
    }
}
