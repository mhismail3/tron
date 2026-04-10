import XCTest
import SQLite3
@testable import TronMobile

/// Tests for SyncRepository — SQLite CRUD for sync_state table
final class SyncRepositoryTests: XCTestCase {

    var database: EventDatabase!

    @MainActor
    override func setUp() async throws {
        database = EventDatabase()
        try await database.initialize()
        try database.clearAll()
    }

    @MainActor
    override func tearDown() async throws {
        try? database.clearAll()
        database.close()
    }

    // MARK: - Round Trip

    @MainActor
    func testUpdateAndGetStateRoundTrip() throws {
        let state = SyncState(
            key: "session-1",
            lastSyncedEventId: "evt-42",
            lastSyncTimestamp: "2026-04-01T12:00:00Z",
            pendingEventIds: ["evt-43", "evt-44"]
        )

        try database.sync.update(state)
        let retrieved = try database.sync.getState("session-1")

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.key, "session-1")
        XCTAssertEqual(retrieved?.lastSyncedEventId, "evt-42")
        XCTAssertEqual(retrieved?.lastSyncTimestamp, "2026-04-01T12:00:00Z")
        XCTAssertEqual(retrieved?.pendingEventIds, ["evt-43", "evt-44"])
    }

    // MARK: - Non-Existent Key

    @MainActor
    func testGetStateReturnsNilForNonExistent() throws {
        let result = try database.sync.getState("non-existent")
        XCTAssertNil(result)
    }

    // MARK: - Nil Optional Fields

    @MainActor
    func testNilOptionalFieldsRoundTrip() throws {
        let state = SyncState(
            key: "session-1",
            lastSyncedEventId: nil,
            lastSyncTimestamp: nil,
            pendingEventIds: []
        )

        try database.sync.update(state)
        let retrieved = try database.sync.getState("session-1")

        XCTAssertNotNil(retrieved)
        XCTAssertNil(retrieved?.lastSyncedEventId)
        XCTAssertNil(retrieved?.lastSyncTimestamp)
        XCTAssertEqual(retrieved?.pendingEventIds, [])
    }

    // MARK: - Empty Pending IDs

    @MainActor
    func testEmptyPendingEventIdsRoundTrip() throws {
        let state = SyncState(
            key: "session-1",
            lastSyncedEventId: "evt-1",
            lastSyncTimestamp: "2026-04-01T00:00:00Z",
            pendingEventIds: []
        )

        try database.sync.update(state)
        let retrieved = try database.sync.getState("session-1")

        XCTAssertEqual(retrieved?.pendingEventIds, [])
    }

    // MARK: - Large Pending ID Arrays

    @MainActor
    func testLargePendingEventIdsArray() throws {
        let largeIds = (0..<200).map { "evt-\($0)" }
        let state = SyncState(
            key: "session-1",
            lastSyncedEventId: nil,
            lastSyncTimestamp: nil,
            pendingEventIds: largeIds
        )

        try database.sync.update(state)
        let retrieved = try database.sync.getState("session-1")

        XCTAssertEqual(retrieved?.pendingEventIds.count, 200)
        XCTAssertEqual(retrieved?.pendingEventIds.first, "evt-0")
        XCTAssertEqual(retrieved?.pendingEventIds.last, "evt-199")
    }

    // MARK: - Upsert Behavior

    @MainActor
    func testUpsertReplacesExistingState() throws {
        let original = SyncState(
            key: "session-1",
            lastSyncedEventId: "evt-1",
            lastSyncTimestamp: "2026-04-01T00:00:00Z",
            pendingEventIds: ["evt-2"]
        )
        try database.sync.update(original)

        let updated = SyncState(
            key: "session-1",
            lastSyncedEventId: "evt-50",
            lastSyncTimestamp: "2026-04-02T00:00:00Z",
            pendingEventIds: ["evt-51", "evt-52"]
        )
        try database.sync.update(updated)

        let retrieved = try database.sync.getState("session-1")
        XCTAssertEqual(retrieved?.lastSyncedEventId, "evt-50")
        XCTAssertEqual(retrieved?.lastSyncTimestamp, "2026-04-02T00:00:00Z")
        XCTAssertEqual(retrieved?.pendingEventIds, ["evt-51", "evt-52"])
    }

    // MARK: - Multiple Sessions

    @MainActor
    func testMultipleSessionsIndependent() throws {
        let state1 = SyncState(key: "session-1", lastSyncedEventId: "evt-a", lastSyncTimestamp: nil, pendingEventIds: [])
        let state2 = SyncState(key: "session-2", lastSyncedEventId: "evt-b", lastSyncTimestamp: nil, pendingEventIds: ["evt-c"])

        try database.sync.update(state1)
        try database.sync.update(state2)

        let r1 = try database.sync.getState("session-1")
        let r2 = try database.sync.getState("session-2")

        XCTAssertEqual(r1?.lastSyncedEventId, "evt-a")
        XCTAssertEqual(r1?.pendingEventIds, [])
        XCTAssertEqual(r2?.lastSyncedEventId, "evt-b")
        XCTAssertEqual(r2?.pendingEventIds, ["evt-c"])
    }

    // MARK: - Special Characters in Pending IDs

    @MainActor
    func testSpecialCharactersInPendingIds() throws {
        let specialIds = ["evt-日本語", "evt-with spaces", "evt-\"quotes\""]
        let state = SyncState(key: "session-1", lastSyncedEventId: nil, lastSyncTimestamp: nil, pendingEventIds: specialIds)

        try database.sync.update(state)
        let retrieved = try database.sync.getState("session-1")

        XCTAssertEqual(retrieved?.pendingEventIds, specialIds)
    }
}
