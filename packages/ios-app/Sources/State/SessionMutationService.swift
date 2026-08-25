import Foundation

struct SessionForkOutcome: Equatable {
    let sessionID: String
    let selectedText: String?
}

struct ExtensionEditorUpdateResult: Codable, Equatable, Sendable {
    let revision: Int
    let text: String
    let applied: Bool
    var operationID: String? = nil
}

/// Owns explicit session command construction. Canonical session state remains
/// Gateway-owned; projection and navigation effects stay with their domain owners.
@MainActor
final class SessionMutationService {
    private struct SessionIDResponse: Codable { let sessionId: String }
    private struct MutationResponse: Codable {
        let updated: Bool
    }

    private let client: GatewayClient
    private let executor: ConfirmedMutationExecutor
    private let uuidSource: UUIDSource

    init(
        client: GatewayClient,
        executor: ConfirmedMutationExecutor,
        uuidSource: UUIDSource
    ) {
        self.client = client
        self.executor = executor
        self.uuidSource = uuidSource
    }

    func importSession(uploadID: String, cwd: String) async throws -> String {
        struct Params: Codable { let uploadId, cwd, commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(uploadId: uploadID, cwd: cwd, commandId: commandID)
        let response: SessionIDResponse = try await executor.perform(
            method: "session.import",
            commandID: commandID
        ) {
            try await client.request("session.import", params, timeout: .seconds(120))
        }
        return response.sessionId
    }

    func createSession(
        cwd: String,
        sourceControl: SessionSourceControlSelection? = nil
    ) async throws -> String {
        struct Params: Codable {
            let cwd: String
            let commandId: String
            let sourceControl: SessionSourceControlSelection?
        }
        let commandID = uuidSource.next().uuidString
        let params = Params(cwd: cwd, commandId: commandID, sourceControl: sourceControl)
        let response: SessionIDResponse = try await executor.perform(
            method: "session.create",
            commandID: commandID
        ) {
            try await client.request("session.create", params, timeout: .seconds(60))
        }
        return response.sessionId
    }

    func prompt(
        _ text: String,
        sessionID: String,
        uploadIDs: [String],
        behavior: String?,
        skillName: String? = nil
    ) async throws -> String {
        struct Params: Codable {
            let sessionId: String
            let text: String
            let uploadIds: [String]
            let behavior: String?
            let skillName: String?
            let commandId: String
        }
        struct Response: Codable { let operationId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            sessionId: sessionID,
            text: text,
            uploadIds: uploadIDs,
            behavior: behavior,
            skillName: skillName,
            commandId: commandID
        )
        let response: Response = try await executor.perform(method: "session.prompt", commandID: commandID) {
            try await client.request("session.prompt", params, as: Response.self, timeout: .seconds(15))
        }
        return response.operationId
    }

    func setAttention(
        sessionID: String,
        unread: Bool,
        throughCompletionRevision: Int
    ) async throws {
        struct Params: Codable {
            let sessionId: String
            let unread: Bool
            let throughCompletionRevision: Int
            let commandId: String
        }
        struct Response: Codable { let isUnread: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            sessionId: sessionID,
            unread: unread,
            throughCompletionRevision: throughCompletionRevision,
            commandId: commandID
        )
        let _: Response = try await executor.perform(method: "session.attention.set", commandID: commandID) {
            try await client.request("session.attention.set", params, timeout: .seconds(15))
        }
    }

    func abort(sessionID: String, kind: String) async throws {
        struct Params: Codable { let sessionId, kind, commandId: String }
        struct Response: Codable { let aborted: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, kind: kind, commandId: commandID)
        let _: Response = try await executor.perform(method: "session.abort", commandID: commandID) {
            try await client.request("session.abort", params, timeout: .seconds(30))
        }
    }

    func clearQueue(sessionID: String) async throws -> SessionSnapshot.QueuedMessages {
        struct Params: Codable { let sessionId, commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, commandId: commandID)
        return try await executor.perform(method: "session.clearQueue", commandID: commandID) {
            try await client.request("session.clearQueue", params)
        }
    }

    func replaceQueue(
        sessionID: String,
        expectedRevision: Int,
        items: [SessionSnapshot.QueuedMessage]
    ) async throws {
        struct Item: Codable {
            let id: String
            let behavior: SessionSnapshot.QueuedMessage.Behavior
            let text: String
        }
        struct Params: Codable {
            let sessionId: String
            let expectedRevision: Int
            let items: [Item]
            let commandId: String
        }
        struct Response: Codable {
            let queueRevision: Int
            let items: [SessionSnapshot.QueuedMessage]
        }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            sessionId: sessionID,
            expectedRevision: expectedRevision,
            items: items.map { Item(id: $0.id, behavior: $0.behavior, text: $0.text) },
            commandId: commandID
        )
        let _: Response = try await executor.perform(
            method: "session.queue.replace",
            commandID: commandID
        ) {
            try await client.request("session.queue.replace", params)
        }
    }

    func executeBash(
        _ command: String,
        sessionID: String,
        excludeFromContext: Bool
    ) async throws {
        struct Params: Codable {
            let sessionId, command: String
            let excludeFromContext: Bool
            let commandId: String
        }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            sessionId: sessionID,
            command: command,
            excludeFromContext: excludeFromContext,
            commandId: commandID
        )
        _ = try await executor.performValue(method: "session.bash", commandID: commandID) {
            try await client.requestValue("session.bash", params, timeout: .seconds(300))
        }
    }

    func setModel(_ model: ModelRef, sessionID: String) async throws {
        struct Params: Codable { let sessionId, provider, modelId, commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            sessionId: sessionID,
            provider: model.provider,
            modelId: model.id,
            commandId: commandID
        )
        let _: MutationResponse = try await executor.perform(
            method: "session.setModel",
            commandID: commandID
        ) {
            try await client.request("session.setModel", params)
        }
    }

    func setThinking(_ level: String, sessionID: String) async throws {
        struct Params: Codable { let sessionId, level, commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, level: level, commandId: commandID)
        let _: MutationResponse = try await executor.perform(
            method: "session.setThinking",
            commandID: commandID
        ) {
            try await client.request("session.setThinking", params)
        }
    }

    func rename(_ sessionID: String, name: String) async throws {
        struct Params: Codable { let sessionId, name, commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, name: name, commandId: commandID)
        let _: MutationResponse = try await executor.perform(
            method: "session.rename",
            commandID: commandID
        ) {
            try await client.request("session.rename", params)
        }
    }

    func compact(sessionID: String, instructions: String?) async throws {
        struct Params: Codable {
            let sessionId: String
            let instructions: String?
            let commandId: String
        }
        struct Response: Codable { let compacted: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, instructions: instructions, commandId: commandID)
        let _: Response = try await executor.perform(method: "session.compact", commandID: commandID) {
            try await client.request("session.compact", params, timeout: .seconds(300))
        }
    }

    func setTools(_ tools: [String], sessionID: String) async throws {
        struct Params: Codable { let sessionId: String; let tools: [String]; let commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, tools: tools, commandId: commandID)
        let _: MutationResponse = try await executor.perform(
            method: "session.setTools",
            commandID: commandID
        ) {
            try await client.request("session.setTools", params)
        }
    }

    func fork(
        sessionID: String,
        entryID: String,
        position: String
    ) async throws -> SessionForkOutcome {
        struct Params: Codable { let sessionId, entryId, position, commandId: String }
        struct Response: Codable { let sessionId: String; let selectedText: String? }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            sessionId: sessionID,
            entryId: entryID,
            position: position,
            commandId: commandID
        )
        let response: Response = try await executor.perform(method: "session.fork", commandID: commandID) {
            try await client.request("session.fork", params, timeout: .seconds(120))
        }
        return SessionForkOutcome(sessionID: response.sessionId, selectedText: response.selectedText)
    }

    func navigate(
        sessionID: String,
        entryID: String,
        summarize: Bool,
        instructions: String?,
        replaceInstructions: Bool,
        label: String?
    ) async throws -> String? {
        struct Params: Codable {
            let sessionId, entryId: String
            let summarize: Bool
            let instructions: String?
            let replaceInstructions: Bool
            let label: String?
            let commandId: String
        }
        struct Response: Codable { let editorText: String? }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            sessionId: sessionID,
            entryId: entryID,
            summarize: summarize,
            instructions: instructions,
            replaceInstructions: replaceInstructions,
            label: label,
            commandId: commandID
        )
        let response: Response = try await executor.perform(
            method: "session.navigate",
            commandID: commandID
        ) {
            try await client.request("session.navigate", params, timeout: .seconds(300))
        }
        return response.editorText
    }

    func setLabel(sessionID: String, entryID: String, label: String?) async throws {
        struct Params: Codable {
            let sessionId, entryId: String
            let label: String?
            let commandId: String
        }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, entryId: entryID, label: label, commandId: commandID)
        let _: MutationResponse = try await executor.perform(
            method: "session.label",
            commandID: commandID
        ) {
            try await client.request("session.label", params)
        }
    }

    func delete(sessionID: String) async throws {
        struct Params: Codable { let sessionId, commandId: String }
        struct Response: Codable { let deleted: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, commandId: commandID)
        let _: Response = try await executor.perform(method: "session.delete", commandID: commandID) {
            try await client.request("session.delete", params, timeout: .seconds(60))
        }
    }

    func reloadResources(sessionID: String) async throws {
        struct Params: Codable { let sessionId, commandId: String }
        struct Response: Codable { let reloaded: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, commandId: commandID)
        let _: Response = try await executor.perform(
            method: "session.reloadResources",
            commandID: commandID
        ) {
            try await client.request("session.reloadResources", params, timeout: .seconds(120))
        }
    }

    func updateExtensionEditor(
        sessionID: String,
        hostEpoch: String,
        baseRevision: Int,
        operationID: String,
        text: String
    ) async throws -> ExtensionEditorUpdateResult {
        struct Params: Codable {
            let sessionId, hostEpoch, operationId, text, commandId: String
            let baseRevision: Int
        }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            sessionId: sessionID,
            hostEpoch: hostEpoch,
            operationId: operationID,
            text: text,
            commandId: commandID,
            baseRevision: baseRevision
        )
        let response: ExtensionEditorUpdateResult = try await executor.perform(method: "extension.editor.update", commandID: commandID) {
            try await client.request("extension.editor.update", params)
        }
        return ExtensionEditorUpdateResult(
            revision: response.revision,
            text: response.text,
            applied: response.applied,
            operationID: operationID
        )
    }

    func setExtensionToolsExpanded(
        sessionID: String,
        hostEpoch: String,
        presentationRevision: Int,
        expanded: Bool
    ) async throws {
        struct Params: Codable {
            let sessionId, hostEpoch, commandId: String
            let presentationRevision: Int
            let expanded: Bool
        }
        struct Response: Codable { let updated: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            sessionId: sessionID,
            hostEpoch: hostEpoch,
            commandId: commandID,
            presentationRevision: presentationRevision,
            expanded: expanded
        )
        let _: Response = try await executor.perform(method: "extension.toolsExpanded", commandID: commandID) {
            try await client.request("extension.toolsExpanded", params)
        }
    }

    func answerInteraction(
        interactionID: String,
        hostEpoch: String,
        presentationRevision: Int,
        sessionID: String,
        value: JSONValue?,
        cancelled: Bool
    ) async throws {
        struct Params: Codable {
            let sessionId, interactionId, hostEpoch: String
            let presentationRevision: Int
            let value: JSONValue?
            let cancelled: Bool
            let commandId: String
        }
        struct Response: Codable { let answered: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            sessionId: sessionID,
            interactionId: interactionID,
            hostEpoch: hostEpoch,
            presentationRevision: presentationRevision,
            value: value,
            cancelled: cancelled,
            commandId: commandID
        )
        let _: Response = try await executor.perform(method: "extension.respond", commandID: commandID) {
            try await client.request("extension.respond", params)
        }
    }
}
