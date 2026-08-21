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
        #expect(ExtensionActivityVisibilityPolicy.ambient(activity))
        #expect(!activity.isLive)
    }

    @Test("ambiguous source fallback fails closed")
    func ambiguousOwnerGrouping() {
        let activity = makeActivity()
        let first = ExtensionOwner(id: "one", title: "One", source: "shared")
        let second = ExtensionOwner(id: "two", title: "Two", source: "shared")
        #expect(ExtensionActivityGroupProjection.owner(for: activity, inventory: [first, second]) == nil)
        #expect(ExtensionActivityGroupProjection.ambientGroups([activity], inventory: [first, second]).isEmpty)
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

    @Test("duration anchor is monotonic and never falls below Gateway observation")
    func durationAnchorMonotonic() {
        let anchor = ExtensionActivityDurationAnchor(
            startedAt: "2026-01-01T00:00:00Z",
            observedDurationMs: 1_000,
            anchor: .now
        )
        #expect(anchor.durationMs(at: anchor.anchor) == 1_000)
        #expect(anchor.durationMs(at: anchor.anchor.advanced(by: .milliseconds(250))) >= 1_000)
    }

    @Test("visual deadline cannot promote an expired historical bucket")
    func visualDeadlineExpiry() {
        let deadline = ExtensionActivityVisualDeadline(bucket: .recent, remainingMs: 10, now: .now)
        #expect(!deadline.expired(at: .now))
        #expect(deadline.expired(at: .now.advanced(by: .milliseconds(11))))
    }

    @Test("composer pill groups admit one exact owner identity")
    func composerOwnerGrouping() {
        let owner = ExtensionOwner(id: "owner-a", title: "Owner A", source: "source-a")
        let group = ExtensionWidgetGroup(id: "owner:\(owner.id)", label: owner.title, items: [], statuses: [], services: [], activities: [])
        let duplicate = ExtensionWidgetGroup(id: group.id, label: owner.title, items: [], statuses: [], services: [], activities: [])
        #expect(ExtensionActivityPillPolicy.composerGroups([group, duplicate]).map(\.id) == ["owner:owner-a"])
    }

    @Test("hub sections have the explicit presentation order")
    func hubSectionOrder() {
        #expect(ExtensionActivityHubSection.allCases.map(\.title) == [
            "Overview", "Current Work", "Recently Finished", "Extension Updates",
            "Service Activity", "View All Activity"
        ])
    }

    @Test("pill composer geometry is typed for detached and pinned readers")
    func composerGeometryDisposition() {
        let old = ExtensionActivityPillComposerGeometry(ownerIDs: ["owner:a"], height: 32)
        let next = ExtensionActivityPillComposerGeometry(ownerIDs: ["owner:a"], height: 48)
        #expect(ExtensionActivityPillComposerGeometryPolicy.changed(previous: old, current: next))
        #expect(ExtensionActivityPillComposerGeometryPolicy.disposition(isDetached: true) == .noScrollWrites)
        #expect(ExtensionActivityPillComposerGeometryPolicy.disposition(isDetached: false) == .noSmoothFollow)
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
