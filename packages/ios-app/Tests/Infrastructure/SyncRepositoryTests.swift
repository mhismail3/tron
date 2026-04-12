import XCTest
import SQLite3
@testable import TronMobile

/// Tests for SyncRepository — SQLite CRUD for sync_state table
@MainActor
final class SyncRepositoryTests: XCTestCase {

    var database: EventDatabase!

    override func setUp() async throws {
        database = EventDatabase()
        try await database.initialize()
        try await database.clearAll()
    }

    override func tearDown() async throws {
        try? await database.clearAll()
        await database.close()
    }

    // MARK: - Round Trip

    func testUpdateAndGetStateRoundTrip() async throws {
        let state = SyncState(
            key: "session-1",
            lastSyncedEventId: "evt-42",
            lastSyncTimestamp: "2026-04-01T12:00:00Z",
            pendingEventIds: ["evt-43", "evt-44"]
        )

        try await database.sync.update(state)
        let retrieved = try await database.sync.getState("session-1")

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.key, "session-1")
        XCTAssertEqual(retrieved?.lastSyncedEventId, "evt-42")
        XCTAssertEqual(retrieved?.lastSyncTimestamp, "2026-04-01T12:00:00Z")
        XCTAssertEqual(retrieved?.pendingEventIds, ["evt-43", "evt-44"])
    }

    // MARK: - Non-Existent Key

    func testGetStateReturnsNilForNonExistent() async throws {
        let result = try await database.sync.getState("non-existent")
        XCTAssertNil(result)
    }

    // MARK: - Nil Optional Fields

    func testNilOptionalFieldsRoundTrip() async throws {
        let state = SyncState(
            key: "session-1",
            lastSyncedEventId: nil,
            lastSyncTimestamp: nil,
            pendingEventIds: []
        )

        try await database.sync.update(state)
        let retrieved = try await database.sync.getState("session-1")

        XCTAssertNotNil(retrieved)
        XCTAssertNil(retrieved?.lastSyncedEventId)
        XCTAssertNil(retrieved?.lastSyncTimestamp)
        XCTAssertEqual(retrieved?.pendingEventIds, [])
    }

    // MARK: - Empty Pending IDs

    func testEmptyPendingEventIdsRoundTrip() async throws {
        let state = SyncState(
            key: "session-1",
            lastSyncedEventId: "evt-1",
            lastSyncTimestamp: "2026-04-01T00:00:00Z",
            pendingEventIds: []
        )

        try await database.sync.update(state)
        let retrieved = try await database.sync.getState("session-1")

        XCTAssertEqual(retrieved?.pendingEventIds, [])
    }

    // MARK: - Large Pending ID Arrays

    func testLargePendingEventIdsArray() async throws {
        let largeIds = (0..<200).map { "evt-\($0)" }
        let state = SyncState(
            key: "session-1",
            lastSyncedEventId: nil,
            lastSyncTimestamp: nil,
            pendingEventIds: largeIds
        )

        try await database.sync.update(state)
        let retrieved = try await database.sync.getState("session-1")

        XCTAssertEqual(retrieved?.pendingEventIds.count, 200)
        XCTAssertEqual(retrieved?.pendingEventIds.first, "evt-0")
        XCTAssertEqual(retrieved?.pendingEventIds.last, "evt-199")
    }

    // MARK: - Upsert Behavior

    func testUpsertReplacesExistingState() async throws {
        let original = SyncState(
            key: "session-1",
            lastSyncedEventId: "evt-1",
            lastSyncTimestamp: "2026-04-01T00:00:00Z",
            pendingEventIds: ["evt-2"]
        )
        try await database.sync.update(original)

        let updated = SyncState(
            key: "session-1",
            lastSyncedEventId: "evt-50",
            lastSyncTimestamp: "2026-04-02T00:00:00Z",
            pendingEventIds: ["evt-51", "evt-52"]
        )
        try await database.sync.update(updated)

        let retrieved = try await database.sync.getState("session-1")
        XCTAssertEqual(retrieved?.lastSyncedEventId, "evt-50")
        XCTAssertEqual(retrieved?.lastSyncTimestamp, "2026-04-02T00:00:00Z")
        XCTAssertEqual(retrieved?.pendingEventIds, ["evt-51", "evt-52"])
    }

    // MARK: - Multiple Sessions

    func testMultipleSessionsIndependent() async throws {
        let state1 = SyncState(key: "session-1", lastSyncedEventId: "evt-a", lastSyncTimestamp: nil, pendingEventIds: [])
        let state2 = SyncState(key: "session-2", lastSyncedEventId: "evt-b", lastSyncTimestamp: nil, pendingEventIds: ["evt-c"])

        try await database.sync.update(state1)
        try await database.sync.update(state2)

        let r1 = try await database.sync.getState("session-1")
        let r2 = try await database.sync.getState("session-2")

        XCTAssertEqual(r1?.lastSyncedEventId, "evt-a")
        XCTAssertEqual(r1?.pendingEventIds, [])
        XCTAssertEqual(r2?.lastSyncedEventId, "evt-b")
        XCTAssertEqual(r2?.pendingEventIds, ["evt-c"])
    }

    // MARK: - Special Characters in Pending IDs

    func testSpecialCharactersInPendingIds() async throws {
        let specialIds = ["evt-日本語", "evt-with spaces", "evt-\"quotes\""]
        let state = SyncState(key: "session-1", lastSyncedEventId: nil, lastSyncTimestamp: nil, pendingEventIds: specialIds)

        try await database.sync.update(state)
        let retrieved = try await database.sync.getState("session-1")

        XCTAssertEqual(retrieved?.pendingEventIds, specialIds)
    }
}
