import Foundation
import Testing
@testable import TronMobile

@Suite("Agent Management UI Contract Tests")
struct AgentManagementUIContractTests {
    @Test("Manage Session places Agents between context and background activity")
    func manageSessionInformationArchitecture() throws {
        let source = try read("Sources/UI/SessionContext/SessionContextSections.swift")
        let context = try #require(source.range(of: "agentContextSection"))
        let agents = try #require(source.range(of: "agentsSection"))
        let background = try #require(source.range(of: "backgroundActivitySection"))

        #expect(context.lowerBound < agents.lowerBound)
        #expect(agents.lowerBound < background.lowerBound)
        #expect(source.contains(#"title: "Agents""#))
        #expect(source.contains("No child agents or agent conversations"))
    }

    @Test("Agent sheets share existing hierarchy, audit, and result components")
    func sheetsRemainCohesiveWithExistingSurfaces() throws {
        let list = try read("Sources/UI/SessionContext/SessionAgentsSheet.swift")
        let detail = try read("Sources/UI/SessionContext/AgentDetailSheet.swift")
        let activity = try read("Sources/UI/SessionContext/AgentActivitySheets.swift")
        let workerDetail = try read("Sources/UI/WorkerConsole/Detail/WorkerConsoleDetailSheets.swift")

        #expect(list.contains("WorkerConsoleGroup"))
        #expect(list.contains("Child agents"))
        #expect(list.contains("Other agents"))
        #expect(detail.contains("AuditSessionSheet"))
        #expect(activity.contains("WorkerResultInspectorSheet"))
        #expect(activity.contains("AgentPagedResultInspectorSheet"))
        #expect(activity.contains("repository.agentResult("))
        #expect(workerDetail.contains("typealias WorkerAuditSessionSheet = AuditSessionSheet"))
        #expect(detail.contains("server-authored"))
        #expect(!detail.contains("EngineClient"))
        #expect(!list.contains("EngineClient"))
    }

    @Test("Older servers retain a calm read-only Agents destination")
    func unsupportedServersKeepAgentsMounted() throws {
        let sections = try read("Sources/UI/SessionContext/SessionContextSections.swift")
        let sheet = try read("Sources/UI/SessionContext/SessionAgentsSheet.swift")
        let client = try read("Sources/Engine/Transport/Clients/AgentClient.swift")

        #expect(sections.contains("isEnabled: true"))
        #expect(sections.contains("Requires a server with reusable agent management"))
        #expect(sheet.contains("Reusable agent management requires a newer Tron server"))
        #expect(client.contains(#"contains("agent_coordination.v1")"#))
    }

    @Test("All destructive or ownership-changing actions consume server authorization")
    func actionGatingIsCanonical() throws {
        let detail = try read("Sources/UI/SessionContext/AgentDetailSheet.swift")
        let activity = try read("Sources/UI/SessionContext/AgentActivitySheets.swift")
        for action in [
            "operator_message", "cancel", "configure", "grant_management",
            "upgrade_role", "promote", "close",
        ] {
            #expect(detail.contains("\"\(action)\""))
        }
        #expect(detail.contains("SessionAgentsPresentation.action(action, in: actions)"))
        #expect(detail.contains("authorization.disabledReason"))
        #expect(detail.contains("managementAuthorizations.contains(where: \\.enabled)"))
        #expect(detail.contains("allowedActions: actions"))
        #expect(activity.contains("selectedAuthorization?.enabled == true"))
        #expect(activity.contains("selectedAuthorization?.disabledReason"))
        #expect(detail.contains("confirmationDialog"))
    }

    @Test("Agent invalidations are coalesced before authoritative refresh")
    func invalidationPolicyIsBounded() throws {
        let engineClient = try read("Sources/Engine/Transport/WebSocket/EngineClient.swift")
        let detail = try read("Sources/UI/SessionContext/AgentDetailSheet.swift")
        let loading = try read("Sources/UI/SessionContext/SessionContextLoading.swift")

        #expect(engineClient.contains("scheduleAgentCoordinationInvalidation"))
        #expect(engineClient.contains("Task.sleep(for: .milliseconds(200))"))
        #expect(detail.contains("Task.sleep(for: .seconds(2))"))
        #expect(detail.contains("let isActive: Bool"))
        #expect(loading.contains("refreshCoordinator.request(.agents)"))
        #expect(loading.contains("hasLoadedAgentRelationsSnapshot = true"))
    }

    @Test("Covered agent actions own visible busy and failure feedback")
    func nestedMutationFeedbackRemainsVisible() throws {
        let detail = try read("Sources/UI/SessionContext/AgentDetailSheet.swift")
        let activity = try read("Sources/UI/SessionContext/AgentActivitySheets.swift")
        let model = try read("Sources/UI/SessionContext/AgentDetailViewModel.swift")

        #expect(model.contains("struct AgentMutationOutcome"))
        #expect(model.contains("errorMessage: message"))
        #expect(detail.contains("return outcome"))
        #expect(activity.components(separatedBy: "@State private var mutationError").count == 5)
        #expect(activity.components(separatedBy: "WorkerConsoleErrorBanner(message: mutationError)").count == 5)
        #expect(activity.contains("retryingAssignmentId"))
        #expect(activity.contains("isBusy: isSending || isBusy"))
        #expect(activity.contains("isBusy: isSaving || isBusy"))
    }

    private func read(_ path: String) throws -> String {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
