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
        #expect(WorkerConsolePresentation.compactRunIdentifier("worker_run_019f897f") == "…019f897f")
        #expect(WorkerConsolePresentation.compactRunIdentifier("run-123") == "run-123")
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
            contextAttached: false,
            createdAt: "2026-07-22T13:06:45Z",
            triggerKind: "manual",
            hasInvocation: true,
            requiresAttention: false
        )
        #expect(WorkerConsolePresentation.inboxSummary(item).hasSuffix("…"))
        #expect(WorkerConsolePresentation.inboxSummary(item).count == 80)
    }

    @Test("Engine primitive groups use stable operator language")
    func engineDashboardProjection() {
        #expect(EngineDashboardPresentation.groupTitle("host") == "Host primitives")
        #expect(
            EngineDashboardPresentation.groupTitle("worker_interaction")
                == "Worker interaction"
        )
        #expect(
            EngineDashboardPresentation.groupTitle("worker_administration")
                == "Worker administration"
        )
        #expect(EngineDashboardPresentation.toolTitle("filesystem_read") == "Read File")
        #expect(EngineDashboardPresentation.toolTitle("worker_upsert") == "Create or Update Worker")
        #expect(EngineDashboardPresentation.toolTitle("future_operation") == "Future Operation")
        #expect(
            EngineDashboardPresentation.groupDetail("host", count: 6)
                .hasPrefix("6 fixed tools")
        )
    }

    @Test("Declarative worker presentation decodes the closed native section vocabulary")
    func declarativePresentationDecoding() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "experienceId": "generic-workflow",
            "contractVersion": 1,
            "primary": false,
            "sections": [
                ["sectionId": "summary", "kind": "text", "valuePointer": "/summary"],
                ["sectionId": "state", "kind": "status", "valuePointer": "/status"],
                ["sectionId": "completion", "kind": "progress", "valuePointer": "/progress"],
                [
                    "sectionId": "records",
                    "kind": "table",
                    "valuePointer": "/records",
                    "columns": [
                        ["label": "Name", "valuePointer": "/name"],
                        ["label": "State", "valuePointer": "/status"],
                    ],
                ],
                ["sectionId": "notes", "kind": "list", "valuePointer": "/notes"],
                [
                    "sectionId": "source",
                    "kind": "link",
                    "label": "Open source",
                    "url": "https://example.com/source",
                ],
                [
                    "sectionId": "artifact",
                    "kind": "artifact",
                    "label": "Inspect report",
                    "valuePointer": "/report",
                ],
                [
                    "sectionId": "approve",
                    "kind": "confirmation",
                    "title": "Approve",
                    "detail": "Run approval?",
                    "action": [
                        "actionId": "approve",
                        "label": "Approve",
                        "input": ["action": "approve"],
                    ],
                ],
                [
                    "sectionId": "refresh",
                    "kind": "worker_action",
                    "action": [
                        "actionId": "refresh",
                        "label": "Refresh",
                        "input": ["action": "refresh"],
                    ],
                ],
            ],
        ])
        let presentation = try JSONDecoder().decode(WorkerPresentationDTO.self, from: data)

        #expect(presentation.sections.count == 9)
        #expect(
            presentation.sections.compactMap {
                WorkerDeclarativePresentation.kind(of: $0)
            }.count == 9
        )
        #expect(
            WorkerDeclarativePresentation.resultPointers(in: presentation)
                == ["/notes", "/progress", "/records", "/report", "/status", "/summary"]
        )
        #expect(
            presentation.sections.last?.action?.input.dictionaryValue?["action"] as? String
                == "refresh"
        )
    }

    @Test("Legacy and future presentation contracts retain generic-console fallback")
    func declarativePresentationFallback() throws {
        let legacy = try JSONDecoder().decode(
            WorkerPresentationDTO.self,
            from: Data(
                """
                {"experienceId":"legacy","contractVersion":1,"primary":false}
                """.utf8
            )
        )
        #expect(legacy.sections.isEmpty)
        let future = WorkerPresentationSectionDTO(
            sectionId: "future",
            kind: "custom_swift_view"
        )
        #expect(WorkerDeclarativePresentation.kind(of: future) == nil)
    }

    @Test("Declarative values remain bounded and unsafe links are inert")
    func declarativeValueProjection() {
        #expect(
            WorkerDeclarativePresentation.safeURL("https://example.com/report")?.host
                == "example.com"
        )
        #expect(WorkerDeclarativePresentation.safeURL("http://example.com") == nil)
        #expect(WorkerDeclarativePresentation.safeURL("javascript:alert(1)") == nil)
        #expect(WorkerDeclarativePresentation.safeURL("https://user:secret@example.com") == nil)
        #expect(WorkerDeclarativePresentation.safeURL("https://localhost/private") == nil)
        #expect(WorkerDeclarativePresentation.safeURL("https://127.0.0.1/private") == nil)
        #expect(WorkerDeclarativePresentation.safeURL("https://192.168.1.2/private") == nil)
        #expect(WorkerDeclarativePresentation.progressValue(AnyCodable(1.4)) == 1)
        #expect(WorkerDeclarativePresentation.progressValue(AnyCodable(-0.2)) == 0)
        #expect(
            WorkerDeclarativePresentation.listItems(
                AnyCodable(Array(repeating: "item", count: 30))
            ).count == 20
        )

        let rows = WorkerDeclarativePresentation.tableRows(
            AnyCodable([
                ["name": "Alpha", "nested": ["state": "ready"]],
                ["name": "Beta", "nested": ["state": "blocked"]],
            ]),
            columns: [
                WorkerPresentationColumnDTO(label: "Name", valuePointer: "/name"),
                WorkerPresentationColumnDTO(label: "State", valuePointer: "/nested/state"),
            ]
        )
        #expect(rows == [["Alpha", "ready"], ["Beta", "blocked"]])
        #expect(
            WorkerDeclarativePresentation.value(
                at: "/escaped~1key/~0value",
                in: ["escaped/key": ["~value": "safe"]]
            ) as? String == "safe"
        )
        #expect(
            WorkerDeclarativePresentation.value(
                at: "/bad~2escape",
                in: ["bad~2escape": "unsafe"]
            ) == nil
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
