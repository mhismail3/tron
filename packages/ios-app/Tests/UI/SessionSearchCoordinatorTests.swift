import XCTest
@testable import TronMobile

@MainActor
final class SessionSearchCoordinatorTests: XCTestCase {
    func testProfileQualifiedResultIDsDoNotCollapseEqualSessionIDs() {
        let revision = SessionSearchAnchorRevision(indexRevision: "i", fileIdentity: "f", branchDigest: "b", leafEntryId: nil, entryOrdinal: 1, forkBoundary: nil)
        let first = SessionSearchResult(sessionId: "same", gatewayProfileID: "one", title: "One", cwd: "/one", updatedAt: "1", entryId: "entry", parentEntryId: nil, ordinal: 1, passageKind: "user", snippet: "one", lexicalScore: 1, semanticScore: nil, jevScore: nil, anchorRevision: revision)
        let second = SessionSearchResult(sessionId: "same", gatewayProfileID: "two", title: "Two", cwd: "/two", updatedAt: "1", entryId: "entry", parentEntryId: nil, ordinal: 1, passageKind: "user", snippet: "two", lexicalScore: 1, semanticScore: nil, jevScore: nil, anchorRevision: revision)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testLocalAndRemoteMatchesMergeIntoOneNestedProfileSessionGroup() {
        let local = SessionSearchSessionGroup(profileID: "one", profileLabel: "One", sessionId: "same", title: "Local title", cwd: "/one", updatedAt: "2", passages: [], isLocalMatch: true)
        let revision = SessionSearchAnchorRevision(indexRevision: "i", fileIdentity: "f", branchDigest: "b", leafEntryId: nil, entryOrdinal: 1, forkBoundary: nil)
        let passage = SessionSearchResult(sessionId: "same", gatewayProfileID: "one", title: "Remote title", cwd: "/one", updatedAt: "2", entryId: "entry", parentEntryId: nil, ordinal: 1, passageKind: "assistant", snippet: "content", lexicalScore: 1, semanticScore: nil, jevScore: nil, anchorRevision: revision)
        let remote = SessionSearchSessionGroup(profileID: "one", profileLabel: "One", sessionId: "same", title: "Remote title", cwd: "/one", updatedAt: "2", passages: [passage], isLocalMatch: false)
        let merged = SessionSearchGrouping.merge(local: [local], remote: [remote])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].passages.map(\.id), [passage.id])
        XCTAssertTrue(merged[0].isLocalMatch)
    }

    func testNavigationAdmissionRejectsStaleRuntimeLeafAndProfile() {
        let revision = SessionSearchAnchorRevision(indexRevision: "i", fileIdentity: "f", branchDigest: "b", leafEntryId: "leaf", entryOrdinal: 1, forkBoundary: nil)
        let result = SessionSearchResult(sessionId: "session", gatewayProfileID: "one", title: "", cwd: "", updatedAt: "", entryId: "entry", parentEntryId: nil, ordinal: 1, passageKind: "user", snippet: "", lexicalScore: 1, semanticScore: nil, jevScore: nil, anchorRevision: revision)
        let item = TranscriptItem.label(LabelTranscriptItem(id: "entry", parentId: nil, timestamp: "", kind: .label, targetId: "entry", label: nil))
        let anchor = SessionSearchAnchorResponse(sessionId: "session", entryId: "entry", start: 0, end: 1, total: 1, items: [item], runtimeGeneration: "runtime", leafEntryId: "leaf")
        XCTAssertTrue(SessionSearchNavigationAdmission.admits(result: result, anchor: anchor, expectedProfileID: "one", currentProfileID: "one", expectedGeneration: 4, currentGeneration: 4, expectedRuntimeGeneration: "runtime", currentRuntimeGeneration: "runtime", expectedLeafEntryID: "leaf"))
        XCTAssertFalse(SessionSearchNavigationAdmission.admits(result: result, anchor: anchor, expectedProfileID: "two", currentProfileID: "two", expectedGeneration: 4, currentGeneration: 4, expectedRuntimeGeneration: "runtime", currentRuntimeGeneration: "runtime", expectedLeafEntryID: "leaf"))
        XCTAssertFalse(SessionSearchNavigationAdmission.admits(result: result, anchor: anchor, expectedProfileID: "one", currentProfileID: "one", expectedGeneration: 3, currentGeneration: 4, expectedRuntimeGeneration: "runtime", currentRuntimeGeneration: "runtime", expectedLeafEntryID: "leaf"))
        XCTAssertFalse(SessionSearchNavigationAdmission.admits(result: result, anchor: anchor, expectedProfileID: "one", currentProfileID: "one", expectedGeneration: 4, currentGeneration: 4, expectedRuntimeGeneration: "stale", currentRuntimeGeneration: "stale", expectedLeafEntryID: "leaf"))
    }

    func testUnsupportedCapabilityIsReportedWithoutAnRPC() async {
        let pool = DashboardGatewayConnectionPool()
        let coordinator = SessionSearchCoordinator()
        let aggregate = await coordinator.searchAll(
            query: "needle",
            targets: [SessionSearchProfileTarget(profileID: "one", label: "One", capabilities: ["sessions.v1"], isSelected: false)],
            connections: pool
        )
        XCTAssertEqual(aggregate.profiles.first?.state, "unsupported")
        XCTAssertTrue(aggregate.groups.isEmpty)
    }

    func testSearchAllPreservesOfflineStatusPerProfileWithoutCollapsingFanout() async {
        let pool = DashboardGatewayConnectionPool()
        let coordinator = SessionSearchCoordinator()
        let aggregate = await coordinator.searchAll(
            query: "needle",
            targets: [
                SessionSearchProfileTarget(profileID: "one", label: "One"),
                SessionSearchProfileTarget(profileID: "two", label: "Two"),
            ],
            connections: pool
        )
        XCTAssertEqual(Set(aggregate.profiles.map(\.profileID)), Set(["one", "two"]))
        XCTAssertTrue(aggregate.profiles.allSatisfy { $0.state == "offline" })
        XCTAssertTrue(aggregate.groups.isEmpty)
    }

    func testDismissInvalidatesCoordinatorRequests() async {
        let pool = DashboardGatewayConnectionPool()
        let coordinator = SessionSearchCoordinator()
        coordinator.dismiss()
        let aggregate = await coordinator.searchAll(query: "needle", targets: [], connections: pool)
        XCTAssertTrue(aggregate.groups.isEmpty)
        XCTAssertTrue(aggregate.profiles.isEmpty)
    }
}
