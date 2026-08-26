import Foundation
import Testing
@testable import TronMobile

@Suite("Extension activity models")
struct ExtensionActivityModelsTests {
    @Test("terminal lifecycle is admitted as recent but not current")
    func recentTerminalAdmission() {
        let lifecycle = ExtensionActivityLifecycle(
            state: .completed, sequence: 4,
            observedAt: "2026-01-01T00:00:02Z",
            terminalAt: "2026-01-01T00:00:02Z",
            recentUntil: "2026-01-01T00:15:02Z",
            visibility: .recent,
            remainingMs: 899_000
        )
        let activity = makeActivity(lifecycle: lifecycle)
        #expect(ExtensionActivityAdmissionPolicy.admits(activity))
        #expect(!activity.isLive)
    }

    @Test("active lifecycle omits terminal recency")
    func activeLifecycleAdmission() {
        let active = ExtensionActivityLifecycle(
            state: .running,
            sequence: 1,
            observedAt: "2026-01-01T00:00:01Z",
            visibility: .current
        )
        #expect(ExtensionActivityAdmissionPolicy.admits(makeActivity(lifecycle: active)))
        let malformed = ExtensionActivityLifecycle(
            state: .running,
            sequence: 1,
            observedAt: "2026-01-01T00:00:01Z",
            visibility: .current,
            remainingMs: 0
        )
        #expect(!ExtensionActivityAdmissionPolicy.admits(makeActivity(lifecycle: malformed)))
    }

    @Test("receipt timelines fail closed for Gateway and legacy rows")
    func receiptTimeline() {
        let malformedGateway = ExtensionActivityLifecycle(
            state: .completed, sequence: 4,
            observedAt: "2026-01-01T00:00:01Z",
            terminalAt: "2026-01-01T00:00:02Z"
        )
        #expect(!ExtensionActivityAdmissionPolicy.admits(makeActivity(lifecycle: malformedGateway)))
        #expect(!ExtensionActivityAdmissionPolicy.admits(makeActivity(completedAt: "2026-01-01T00:00:02Z")))
    }

    @Test("negative sequence and duration are rejected")
    func bounds() {
        let lifecycle = ExtensionActivityLifecycle(state: .running, sequence: -1, observedAt: "2026-01-01T00:00:00Z")
        let activity = makeActivity(lifecycle: lifecycle, durationMs: -1)
        #expect(!ExtensionActivityAdmissionPolicy.admits(activity))
    }

    @Test("descendant budget is global across siblings")
    func globalDescendantBudget() {
        let grandchildren = (0..<32).map { index in
            ExtensionRunChild(id: "grandchild-\(index)", label: "Child", status: .running)
        }
        let children = (0..<32).map { index in
            ExtensionRunChild(id: "child-\(index)", label: "Child", status: .running,
                              children: [grandchildren[index]])
        }
        #expect(ExtensionActivityAdmissionPolicy.admits(makeActivity(children: children)))
        let overBudget = children.enumerated().map { index, child in
            index == 0 ? ExtensionRunChild(id: child.id, label: child.label, status: child.status,
                                            children: [child.children![0], ExtensionRunChild(id: "extra", label: "Extra", status: .running)]) : child
        }
        #expect(!ExtensionActivityAdmissionPolicy.admits(makeActivity(children: overBudget)))
    }

    @Test("malformed identity and output are rejected")
    func strictActivityFields() {
        #expect(!ExtensionActivityAdmissionPolicy.admits(makeActivity(id: "", output: "ok")))
        #expect(!ExtensionActivityAdmissionPolicy.admits(makeActivity(runId: String(repeating: "x", count: 513), output: String(repeating: "x", count: 33 * 1_024))))
    }

    @Test("history page omits malformed rows while admitting the page")
    func pageAdmission() throws {
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder.gateway.encode(makeActivity()))
        let payload: [String: Any] = [
            "activities": [valid, ["id": "bad"]],
            "historyRevision": "revision-1",
            "nextCursor": NSNull(),
            "omissions": ["count": 1, "bytes": 12, "reason": "bytes"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let page = try JSONDecoder.gateway.decode(ExtensionActivityHistoryPage.self, from: data)
        #expect(page.activities.count == 1)
        #expect(page.omissions?.bytes == 12)
    }

    private func makeActivity(
        lifecycle: ExtensionActivityLifecycle? = nil,
        completedAt: String? = nil,
        durationMs: Int? = nil,
        id: String = "activity-1", runId: String? = "run-1", output: String? = nil,
        children: [ExtensionRunChild] = []
    ) -> ExtensionRunActivity {
        ExtensionRunActivity(
            id: id, runId: runId, toolCallId: "tool-1",
            source: ExtensionToolOrigin(source: "shared"), title: "Extension",
            mode: "delegated", status: lifecycle.map { lifecycle in
                switch lifecycle.state {
                case .failed: .failed
                case .completed, .stopped, .rejected: .completed
                default: .running
                }
            } ?? .running,
            startedAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            completedAt: completedAt ?? lifecycle?.terminalAt, lastActivityAt: nil,
            currentTool: nil, currentToolStartedAt: nil, currentPath: nil,
            toolCount: 1, turnCount: 1, durationMs: durationMs, output: output,
            children: children, lifecycle: lifecycle
        )
    }
}
