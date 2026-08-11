import Foundation
import Testing
import UIKit
@testable import TronMobile

@Suite("Session Agents Presentation Tests")
struct SessionAgentsPresentationTests {
    @Test("Active lifecycle states remain visible to bounded observation")
    func activeLifecyclePolicy() {
        for status in ["provisioning", "offered", "queued", "active", "running", "waiting"] {
            #expect(SessionAgentsPresentation.isActive(status: status))
        }
        for status in ["idle", "completed", "failed", "cancelled", "closed", "future_state"] {
            #expect(!SessionAgentsPresentation.isActive(status: status))
        }
    }

    @Test("Child hierarchy is parent-first while active roots sort first")
    func childHierarchyIsParentFirst() throws {
        let idleRoot = try relation(id: "idle-root", parent: nil, depth: 1, status: "idle")
        let activeRoot = try relation(id: "active-root", parent: nil, depth: 1, status: "running")
        let child = try relation(id: "child", parent: "active-root", depth: 2, status: "running")
        let grandchild = try relation(id: "grandchild", parent: "child", depth: 3, status: "idle")

        let ordered = SessionAgentsPresentation.orderedChildren([
            grandchild, idleRoot, child, activeRoot,
        ])

        #expect(ordered.map(\.agentId) == [
            "active-root", "child", "grandchild", "idle-root",
        ])
    }

    @Test("Contacts never duplicate nested children")
    func contactsExcludeChildren() throws {
        let child = try relation(id: "child", relationship: "child")
        let peer = try relation(id: "peer", relationship: "peer")
        let promoted = try relation(id: "promoted", relationship: "promoted_child")

        #expect(SessionAgentsPresentation.orderedContacts([child, peer, promoted]).map(\.agentId) == [
            "peer", "promoted",
        ])
    }

    @Test("Management availability requires both server authorization and connection")
    func managementAvailabilityIsServerAuthored() {
        let actions = [
            AgentAllowedActionDTO(
                action: "cancel",
                enabled: false,
                disabledReason: "Not owner",
                affectedCount: 4
            ),
            AgentAllowedActionDTO(action: "promote", enabled: true, disabledReason: nil),
        ]
        #expect(!SessionAgentsPresentation.actionIsEnabled("cancel", in: actions, isConnected: true))
        #expect(SessionAgentsPresentation.actionIsEnabled("promote", in: actions, isConnected: true))
        #expect(!SessionAgentsPresentation.actionIsEnabled("promote", in: actions, isConnected: false))
        #expect(SessionAgentsPresentation.actionReason("cancel", in: actions, isConnected: true) == "Not owner")
        #expect(actions[0].affectedCount == 4)
        #expect(SessionAgentsPresentation.actionReason("promote", in: actions, isConnected: false) == "Available after reconnection")
    }

    @Test("Every agent-management SF Symbol is available")
    func symbolsExist() {
        let symbols = [
            "archivebox", "arrow.backward", "arrow.clockwise", "arrow.down.left.circle",
            "arrow.right.circle", "arrow.up.circle", "arrow.up.right.circle",
            "bubble.left.and.bubble.right", "checklist", "checklist.unchecked",
            "checkmark.circle.fill", "checkmark.shield", "circle.dotted", "circle.fill", "clock",
            "clock.arrow.circlepath", "doc.text.magnifyingglass",
            "exclamationmark.triangle", "exclamationmark.triangle.fill", "hourglass",
            "pause.circle", "person.3.sequence", "person.3.sequence.fill",
            "person.badge.key", "person.badge.key.fill",
            "person.crop.circle.badge.checkmark", "person.crop.circle.badge.minus",
            "person.crop.circle.badge.xmark", "rectangle.stack.badge.plus", "sparkles",
            "stop.circle", "text.bubble", "tray.and.arrow.down", "xmark.circle",
        ]

        for symbol in symbols {
            #expect(UIImage(systemName: symbol) != nil, "Missing SF Symbol: \(symbol)")
        }
    }

    private func relation(
        id: String,
        relationship: String = "child",
        parent: String? = nil,
        depth: UInt64 = 1,
        status: String = "idle"
    ) throws -> AgentRelationDTO {
        var object: [String: Any] = [
            "agentId": id,
            "relationship": relationship,
            "depth": depth,
            "status": status,
            "name": id,
            "lastActivityAt": "2026-08-11T00:00:00Z",
            "allowedActions": [],
        ]
        object["parentAgentId"] = parent
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(AgentRelationDTO.self, from: data)
    }
}
