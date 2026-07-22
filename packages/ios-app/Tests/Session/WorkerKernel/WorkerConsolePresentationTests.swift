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

        let provenance = WorkerConsolePresentation.provenance(from: AnyCodable([
            ["source": "field:agent-runner-scenario", "revision": "2-authenticated-model"],
        ]))
        #expect(provenance.count == 1)
        #expect(provenance.first?.source == "Field:agent Runner Scenario")
        #expect(provenance.first?.revision == "2-authenticated-model")
    }

    @Test("Engine primitive groups and projection reasons use stable operator language")
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
        #expect(
            EngineDashboardPresentation.selectionReason("session_promotion")
                == "Promoted for this session"
        )
        #expect(
            EngineDashboardPresentation.selectionReason("relevance")
                == "Relevant to the current task"
        )
        #expect(EngineDashboardPresentation.selectionReason(nil) == "Available")
        #expect(
            EngineDashboardPresentation.routingEvidence(
                AvailableWorkerToolDTO(
                    workerId: "research",
                    modelName: "worker_research",
                    functionId: "worker_kernel::dynamic_research",
                    functionRevision: 2,
                    workerVersion: "version",
                    promoted: false,
                    projected: true,
                    selectionReason: "relevance",
                    relevanceScore: 7,
                    completedRuns: 3
                )
            ) == "Relevant to the current task · score 7 · 3 completed runs"
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
