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

    func status() async throws -> GatewayAutomationStatus { try await request("automation.status") }
    func list(cursor: String? = nil, limit: Int = 100) async throws -> GatewayAutomationPage {
        struct Params: Encodable { let cursor: String?; let limit: Int }
        return try await request("automation.list", Params(cursor: cursor, limit: min(100, max(1, limit))))
    }
    func get(id: String) async throws -> GatewayAutomationRecord {
        struct Params: Encodable { let automationId: String }
        return try await request("automation.get", Params(automationId: id))
    }
    func runs(id: String) async throws -> GatewayAutomationRuns {
        struct Params: Encodable { let automationId: String }
        return try await request("automation.run.list", Params(automationId: id))
    }
    func run(id: String, runId: String) async throws -> GatewayAutomationRun {
        struct Params: Encodable { let automationId: String; let runId: String }
        return try await request("automation.run.get", Params(automationId: id, runId: runId))
    }
    func timeline(from: Date, through: Date, timezone: String, cursor: String? = nil, limit: Int = 200) async throws -> GatewayAutomationTimelinePage {
        struct Params: Encodable { let from, through, displayTimezone: String; let cursor: String?; let limit: Int }
        return try await request("automation.timeline.list", Params(from: from.gatewayISO8601, through: through.gatewayISO8601, displayTimezone: timezone, cursor: cursor, limit: min(200, max(1, limit))))
    }
    func preview(trigger: GatewayAutomationTrigger, after: Date? = nil, limit: Int = 10) async throws -> GatewayAutomationPreview {
        struct Params: Encodable { let trigger: GatewayAutomationTrigger; let after: String?; let limit: Int }
        return try await request("automation.schedule.preview", Params(trigger: trigger, after: after?.gatewayISO8601, limit: min(10, max(1, limit))))
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
        let value = try await mutate(method: "automation.create", parameters: definition)
        return try value.decode(GatewayAutomationRecord.self)
    }
    func update(id: String, revision: Int, definition: AutomationDefinitionDraft) async throws -> GatewayAutomationRecord {
        struct Params: Encodable { let automationId: String; let expectedRevision: Int; let definition: AutomationDefinitionDraft }
        let value = try await mutate(method: "automation.update", parameters: Params(automationId: id, expectedRevision: revision, definition: definition))
        return try value.decode(GatewayAutomationRecord.self)
    }
    func setActivation(id: String, revision: Int, enabled: Bool) async throws -> GatewayAutomationRecord {
        struct Params: Encodable { let automationId: String; let expectedRevision: Int }
        let value = try await mutate(method: enabled ? "automation.enable" : "automation.pause", parameters: Params(automationId: id, expectedRevision: revision))
        return try value.decode(GatewayAutomationRecord.self)
    }
    func runNow(id: String, revision: Int) async throws -> GatewayAutomationRun {
        struct Params: Encodable { let automationId: String; let expectedRevision: Int }
        let value = try await mutate(method: "automation.runNow", parameters: Params(automationId: id, expectedRevision: revision))
        return try value.decode(GatewayAutomationRun.self)
    }
    func cancel(id: String, runId: String) async throws -> GatewayAutomationRun {
        struct Params: Encodable { let automationId: String; let runId: String }
        let value = try await mutate(method: "automation.run.cancel", parameters: Params(automationId: id, runId: runId))
        return try value.decode(GatewayAutomationRun.self)
    }
    func delete(id: String, revision: Int) async throws {
        struct Params: Encodable { let automationId: String; let expectedRevision: Int }
        _ = try await mutate(method: "automation.delete", parameters: Params(automationId: id, expectedRevision: revision))
    }
    func resolve(id: String, runId: String, revision: Int, outcome: String) async throws -> GatewayAutomationRecord {
        struct Params: Encodable { let automationId, runId: String; let expectedRevision: Int; let outcome: String }
        let value = try await mutate(method: "automation.run.resolve", parameters: Params(automationId: id, runId: runId, expectedRevision: revision, outcome: outcome))
        return try value.decode(GatewayAutomationRecord.self)
    }
}

struct AutomationDefinitionDraft: Codable, Hashable, Sendable {
    var name: String
    var description: String?
    var targetSessionId: String
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
