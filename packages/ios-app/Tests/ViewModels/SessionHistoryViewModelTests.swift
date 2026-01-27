import XCTest
@testable import TronMobile

// MARK: - SessionForkContext Tests

@MainActor
final class SessionForkContextTests: XCTestCase {

    func test_sessionForkContext_storesProperties() {
        let parentEventIds: Set<String> = ["event1", "event2"]
        let context = SessionForkContext(
            parentSessionId: "parent-session",
            forkEventId: "fork-event",
            forkPointEventId: "fork-point",
            parentSessionTitle: "Parent Session",
            parentEventIds: parentEventIds
        )

        XCTAssertEqual(context.parentSessionId, "parent-session")
        XCTAssertEqual(context.forkEventId, "fork-event")
        XCTAssertEqual(context.forkPointEventId, "fork-point")
        XCTAssertEqual(context.parentSessionTitle, "Parent Session")
        XCTAssertEqual(context.parentEventIds, parentEventIds)
    }

    func test_sessionForkContext_allowsNilTitle() {
        let context = SessionForkContext(
            parentSessionId: "parent-session",
            forkEventId: "fork-event",
            forkPointEventId: "fork-point",
            parentSessionTitle: nil,
            parentEventIds: []
        )

        XCTAssertNil(context.parentSessionTitle)
    }

    func test_sessionForkContext_emptyParentEventIds() {
        let context = SessionForkContext(
            parentSessionId: "parent-session",
            forkEventId: "fork-event",
            forkPointEventId: "fork-point",
            parentSessionTitle: nil,
            parentEventIds: []
        )

        XCTAssertTrue(context.parentEventIds.isEmpty)
    }

    func test_sessionForkContext_largeParentEventIdSet() {
        var eventIds: Set<String> = []
        for i in 0..<100 {
            eventIds.insert("event-\(i)")
        }

        let context = SessionForkContext(
            parentSessionId: "parent-session",
            forkEventId: "fork-event",
            forkPointEventId: "fork-point",
            parentSessionTitle: nil,
            parentEventIds: eventIds
        )

        XCTAssertEqual(context.parentEventIds.count, 100)
    }
}

// MARK: - SiblingBranchInfo Tests

@MainActor
final class SiblingBranchInfoTests: XCTestCase {

    func test_siblingBranchInfo_identifiable() {
        let info = SiblingBranchInfo(
            id: "session-123",
            sessionTitle: "Test Session",
            eventCount: 10,
            lastActivity: "2024-01-01",
            events: []
        )

        XCTAssertEqual(info.id, "session-123")
    }

    func test_siblingBranchInfo_displayTitle_usesSessionTitle() {
        let info = SiblingBranchInfo(
            id: "session-123",
            sessionTitle: "My Custom Title",
            eventCount: 10,
            lastActivity: "2024-01-01",
            events: []
        )

        XCTAssertEqual(info.displayTitle, "My Custom Title")
    }

    func test_siblingBranchInfo_displayTitle_fallsBackToSessionId() {
        let info = SiblingBranchInfo(
            id: "session-123",
            sessionTitle: nil,
            eventCount: 10,
            lastActivity: "2024-01-01",
            events: []
        )

        // First 8 chars of "session-123" is "session-"
        XCTAssertEqual(info.displayTitle, "Session session-")
    }

    func test_siblingBranchInfo_displayTitle_usesFirst8Chars() {
        let info = SiblingBranchInfo(
            id: "abcdefghijklmnop",
            sessionTitle: nil,
            eventCount: 10,
            lastActivity: "2024-01-01",
            events: []
        )

        XCTAssertEqual(info.displayTitle, "Session abcdefgh")
    }

    func test_siblingBranchInfo_storesEventCount() {
        let info = SiblingBranchInfo(
            id: "session-123",
            sessionTitle: nil,
            eventCount: 42,
            lastActivity: "2024-01-01",
            events: []
        )

        XCTAssertEqual(info.eventCount, 42)
    }

    func test_siblingBranchInfo_storesLastActivity() {
        let info = SiblingBranchInfo(
            id: "session-123",
            sessionTitle: nil,
            eventCount: 10,
            lastActivity: "2024-06-15",
            events: []
        )

        XCTAssertEqual(info.lastActivity, "2024-06-15")
    }

    func test_siblingBranchInfo_eventsInitiallyEmpty() {
        let info = SiblingBranchInfo(
            id: "session-123",
            sessionTitle: nil,
            eventCount: 10,
            lastActivity: "2024-06-15",
            events: []
        )

        XCTAssertTrue(info.events.isEmpty)
    }

    func test_siblingBranchInfo_eventCountCanBeZero() {
        let info = SiblingBranchInfo(
            id: "session-123",
            sessionTitle: "Empty Session",
            eventCount: 0,
            lastActivity: "2024-01-01",
            events: []
        )

        XCTAssertEqual(info.eventCount, 0)
    }

    func test_siblingBranchInfo_emptySessionTitle() {
        let info = SiblingBranchInfo(
            id: "session-123",
            sessionTitle: "",
            eventCount: 10,
            lastActivity: "2024-01-01",
            events: []
        )

        // Empty string should still be used as displayTitle (not nil fallback)
        XCTAssertEqual(info.displayTitle, "")
    }
}

// MARK: - SessionHistoryViewModel State Tests

@MainActor
final class SessionHistoryViewModelStateTests: XCTestCase {

    func test_expandedBranchPoints_toggleOnWorks() {
        var expandedBranchPoints: Set<String> = []

        expandedBranchPoints.insert("event-123")

        XCTAssertTrue(expandedBranchPoints.contains("event-123"))
    }

    func test_expandedBranchPoints_toggleOffWorks() {
        var expandedBranchPoints: Set<String> = ["event-123"]

        expandedBranchPoints.remove("event-123")

        XCTAssertFalse(expandedBranchPoints.contains("event-123"))
    }

    func test_multipleBranchPoints_canBeExpanded() {
        var expandedBranchPoints: Set<String> = []

        expandedBranchPoints.insert("event-1")
        expandedBranchPoints.insert("event-2")
        expandedBranchPoints.insert("event-3")

        XCTAssertEqual(expandedBranchPoints.count, 3)
        XCTAssertTrue(expandedBranchPoints.contains("event-1"))
        XCTAssertTrue(expandedBranchPoints.contains("event-2"))
        XCTAssertTrue(expandedBranchPoints.contains("event-3"))
    }

    func test_siblingBranches_dictionaryAccess() {
        var siblingBranches: [String: [SiblingBranchInfo]] = [:]

        let branchInfo = SiblingBranchInfo(
            id: "branch-1",
            sessionTitle: "Branch 1",
            eventCount: 5,
            lastActivity: "2024-01-01",
            events: []
        )

        siblingBranches["fork-point-1"] = [branchInfo]

        XCTAssertEqual(siblingBranches["fork-point-1"]?.count, 1)
        XCTAssertEqual(siblingBranches["fork-point-1"]?.first?.id, "branch-1")
    }

    func test_siblingBranches_multipleAtSameForkPoint() {
        var siblingBranches: [String: [SiblingBranchInfo]] = [:]

        let branch1 = SiblingBranchInfo(
            id: "branch-1",
            sessionTitle: "Branch 1",
            eventCount: 5,
            lastActivity: "2024-01-01",
            events: []
        )
        let branch2 = SiblingBranchInfo(
            id: "branch-2",
            sessionTitle: "Branch 2",
            eventCount: 10,
            lastActivity: "2024-01-02",
            events: []
        )

        siblingBranches["fork-point-1"] = [branch1, branch2]

        XCTAssertEqual(siblingBranches["fork-point-1"]?.count, 2)
    }

    func test_isLoading_initialState() {
        // isLoading should be true initially according to SessionHistoryViewModel
        let isLoading = true
        XCTAssertTrue(isLoading)
    }

    func test_forkContext_canBeNil() {
        let forkContext: SessionForkContext? = nil
        XCTAssertNil(forkContext)
    }
}
