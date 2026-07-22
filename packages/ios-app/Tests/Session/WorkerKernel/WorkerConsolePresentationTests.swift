import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Worker Console Presentation Tests")
struct WorkerConsolePresentationTests {
    @Test("Worker states preserve server facts while translating them into cockpit language")
    func workerStatusProjection() {
        #expect(WorkerConsolePresentation.status(for: worker()).kind == .healthy)
        #expect(WorkerConsolePresentation.status(for: worker(enabled: false)).title == "Disabled")
        #expect(WorkerConsolePresentation.status(for: worker(retired: true)).kind == .retired)
        #expect(
            WorkerConsolePresentation.status(for: worker(health: "dependency_failed")).kind
                == .needsAttention
        )
    }

    @Test("Input schemas become readable fields and a valid invocation template")
    func schemaProjection() throws {
        let schema = AnyCodable([
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Question to research"],
                "depth": ["type": "integer"],
            ],
            "required": ["query"],
        ])

        let fields = WorkerConsolePresentation.schemaFields(from: schema)
        #expect(fields.map(\.name) == ["depth", "query"])
        #expect(fields.first(where: { $0.name == "query" })?.isRequired == true)
        #expect(fields.first(where: { $0.name == "query" })?.detail == "Question to research")

        let template = WorkerConsolePresentation.invocationTemplate(from: schema)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(template.utf8)) as? [String: Any]
        )
        #expect(object["query"] as? String == "")
        #expect(object["depth"] as? Int == 0)
    }

    @Test("Hashes, timestamps, labels, and provenance stay compact")
    func compactMetadataProjection() {
        #expect(WorkerConsolePresentation.compactIdentifier("1234567890abcdef") == "1234567890")
        #expect(
            WorkerConsolePresentation.timestamp("2026-07-20T16:18:00.781070+00:00")
                == "2026-07-20 · 16:18"
        )
        #expect(WorkerConsolePresentation.displayLabel("resident_service") == "Resident Service")
        #expect(WorkerConsolePresentation.runnerLabel("agent") == "Agent runner")
        #expect(WorkerConsolePresentation.runnerLabel("command") == "Command runner")
        #expect(WorkerConsolePresentation.runnerLabel("service") == "Service runner")
        #expect(WorkerConsolePresentation.triggerLabel(1) == "1 trigger")
        #expect(WorkerConsolePresentation.triggerLabel(2) == "2 triggers")
        #expect(WorkerConsolePresentation.completedRunLabel(1) == "1 successful run")
        #expect(WorkerConsolePresentation.completedRunLabel(3) == "3 successful runs")

        let provenance = WorkerConsolePresentation.provenance(from: AnyCodable([
            ["source": "field:agent-runner-scenario", "revision": "2-authenticated-model"],
        ]))
        #expect(provenance.count == 1)
        #expect(provenance.first?.source == "Field:agent Runner Scenario")
        #expect(provenance.first?.revision == "2-authenticated-model")
        #expect(provenance.first?.compactLabel == "agent Runner Scen… · 2-authe…")
        #expect(provenance.first?.compactLabel.count ?? 0 <= 30)
        #expect(provenance.first?.fullLabel.contains("2-authenticated-model") == true)
    }

    @Test("Activity summaries prefer useful nested fields and remain bounded")
    func activitySummaryProjection() {
        let item = WorkerInboxItemDTO(
            inboxId: "inbox-1",
            invocationId: "run-1",
            workerId: "delegate",
            severity: "info",
            result: AnyCodable([
                "output": [
                    "summary": String(repeating: "useful result ", count: 20),
                ],
            ]),
            seen: false,
            createdAt: "2026-07-22T13:06:45Z"
        )
        #expect(WorkerConsolePresentation.inboxSummary(item).hasSuffix("…"))
        #expect(WorkerConsolePresentation.inboxSummary(item).count == 80)
    }

    @Test("Engine primitive groups use stable operator language")
    func engineDashboardProjection() {
        #expect(EngineDashboardPresentation.groupTitle("host") == "Host primitives")
        #expect(EngineDashboardPresentation.groupTitle("worker_control") == "Worker controls")
        #expect(EngineDashboardPresentation.groupTitle("core_change") == "Core changes")
        #expect(EngineDashboardPresentation.toolTitle("filesystem_read") == "Read File")
        #expect(EngineDashboardPresentation.toolTitle("worker_upsert") == "Create or Update Worker")
        #expect(EngineDashboardPresentation.toolTitle("core_proposal_apply") == "Apply Core Proposal")
        #expect(EngineDashboardPresentation.toolTitle("future_operation") == "Future Operation")
        #expect(
            EngineDashboardPresentation.groupDetail("host", count: 6)
                .hasPrefix("6 fixed tools")
        )
    }

    private func worker(
        enabled: Bool = true,
        retired: Bool = false,
        health: String = "healthy"
    ) -> WorkerSummaryDTO {
        WorkerSummaryDTO(
            workerId: "research",
            name: "Research",
            description: "Research worker",
            toolName: "worker_research",
            runnerKind: "command",
            activeVersion: "1234567890abcdef",
            enabled: enabled,
            retired: retired,
            health: health,
            triggerCount: 1,
            updatedAt: "2026-07-20T16:18:00Z",
            presentation: nil
        )
    }
}
