import XCTest
@testable import TronMobile

@MainActor
final class SessionListPageLoaderTests: XCTestCase {
    func testLoadsGenerousSessionSnapshotAcrossManyProjects() async throws {
        let expected = (0..<525).map { index in
            makeSessionInfo(index: index, project: index % 35)
        }
        var requestedCursors: [String?] = []

        let snapshot = try await SessionListPageLoader().load { limit, cursor in
            requestedCursors.append(cursor)
            XCTAssertLessThanOrEqual(limit, SessionListPageLoader.pageSize)

            let start = cursor.flatMap(Int.init) ?? 0
            let end = min(start + limit, expected.count)
            let hasMore = end < expected.count
            return SessionListResult(
                sessions: Array(expected[start..<end]),
                totalCount: expected.count,
                hasMore: hasMore,
                nextCursor: hasMore ? String(end) : nil,
                snapshotAsOf: "2026-07-01T13:00:00Z",
                snapshotCanReconcile: true
            )
        }

        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(snapshot.sessions.map(\.sessionId), expected.map(\.sessionId))
        XCTAssertEqual(Set(snapshot.sessions.compactMap(\.workingDirectory)).count, 35)
        XCTAssertEqual(requestedCursors.count, 3)
        XCTAssertNil(requestedCursors[0])
        XCTAssertEqual(requestedCursors[1], "200")
        XCTAssertEqual(requestedCursors[2], "400")
    }

    func testDeduplicatesRefreshRaceRowsWithoutChangingFirstSeenOrder() async throws {
        let firstPage = [
            makeSessionInfo(index: 0, project: 0),
            makeSessionInfo(index: 1, project: 0),
        ]
        let secondPage = [
            makeSessionInfo(index: 1, project: 0),
            makeSessionInfo(index: 2, project: 1),
        ]

        let snapshot = try await SessionListPageLoader().load { _, cursor in
            if cursor == nil {
                return SessionListResult(
                    sessions: firstPage,
                    totalCount: 3,
                    hasMore: true,
                    nextCursor: "next",
                    snapshotAsOf: "2026-07-01T13:00:00Z",
                    snapshotCanReconcile: true
                )
            }
            return SessionListResult(
                sessions: secondPage,
                totalCount: 3,
                hasMore: false,
                nextCursor: nil,
                snapshotAsOf: "2026-07-01T13:00:00Z",
                snapshotCanReconcile: true
            )
        }

        XCTAssertEqual(snapshot.sessions.map(\.sessionId), ["session-0000", "session-0001", "session-0002"])
        XCTAssertEqual(Set(snapshot.sessions.map(\.sessionId)).count, snapshot.sessions.count)
    }

    func testSafetyCapMarksSnapshotPartial() async throws {
        let expected = (0..<2_100).map { index in
            makeSessionInfo(index: index, project: index % 50)
        }

        let snapshot = try await SessionListPageLoader().load { limit, cursor in
            let start = cursor.flatMap(Int.init) ?? 0
            let end = min(start + limit, expected.count)
            return SessionListResult(
                sessions: Array(expected[start..<end]),
                totalCount: expected.count,
                hasMore: end < expected.count,
                nextCursor: String(end),
                snapshotAsOf: "2026-07-01T13:00:00Z",
                snapshotCanReconcile: true
            )
        }

        XCTAssertFalse(snapshot.isComplete)
        XCTAssertEqual(snapshot.sessions.count, SessionListPageLoader.maximumSessionCount)
        XCTAssertEqual(Set(snapshot.sessions.map(\.sessionId)).count, snapshot.sessions.count)
    }

    func testRejectsMoreFlagWithoutCursor() async {
        do {
            _ = try await SessionListPageLoader().load { _, _ in
                SessionListResult(
                    sessions: [],
                    totalCount: 1,
                    hasMore: true,
                    nextCursor: nil,
                    snapshotAsOf: "2026-07-01T13:00:00Z",
                    snapshotCanReconcile: true
                )
            }
            XCTFail("Expected missing cursor error")
        } catch {
            XCTAssertEqual(error as? SessionListPageLoadingError, .missingCursor)
        }
    }

    func testRejectsCursorCycleAcrossNonAdjacentPages() async {
        var requestCount = 0
        do {
            _ = try await SessionListPageLoader().load { _, cursor in
                requestCount += 1
                let nextCursor: String
                switch cursor {
                case nil: nextCursor = "a"
                case "a": nextCursor = "b"
                default: nextCursor = "a"
                }
                return SessionListResult(
                    sessions: [makeSessionInfo(index: requestCount, project: 0)],
                    totalCount: nil,
                    hasMore: true,
                    nextCursor: nextCursor,
                    snapshotAsOf: "2026-07-01T13:00:00Z",
                    snapshotCanReconcile: true
                )
            }
            XCTFail("Expected repeated cursor error")
        } catch {
            XCTAssertEqual(error as? SessionListPageLoadingError, .repeatedCursor)
        }
    }

    func testChangingEmptyCursorsStopAsIncompleteAfterNoProgressBound() async throws {
        var requestCount = 0
        let snapshot = try await SessionListPageLoader().load { _, _ in
            requestCount += 1
            return SessionListResult(
                sessions: [],
                totalCount: nil,
                hasMore: true,
                nextCursor: "cursor-\(requestCount)",
                snapshotAsOf: "2026-07-01T13:00:00Z",
                snapshotCanReconcile: true
            )
        }

        XCTAssertFalse(snapshot.isComplete)
        XCTAssertEqual(requestCount, SessionListPageLoader.maximumNoProgressPageCount)
    }

    func testPageCountIsBoundedIndependentlyOfUniqueRows() async throws {
        var requestCount = 0
        let snapshot = try await SessionListPageLoader().load { _, _ in
            requestCount += 1
            return SessionListResult(
                sessions: [makeSessionInfo(index: requestCount, project: 0)],
                totalCount: nil,
                hasMore: true,
                nextCursor: "cursor-\(requestCount)",
                snapshotAsOf: "2026-07-01T13:00:00Z",
                snapshotCanReconcile: true
            )
        }

        XCTAssertFalse(snapshot.isComplete)
        XCTAssertEqual(requestCount, SessionListPageLoader.maximumPageCount)
    }

    func testUnverifiedSnapshotNeverAuthorizesReconciliation() async throws {
        let snapshot = try await SessionListPageLoader().load { _, _ in
            SessionListResult(
                sessions: [makeSessionInfo(index: 0, project: 0)],
                totalCount: 1,
                hasMore: false,
                nextCursor: nil
            )
        }

        XCTAssertFalse(snapshot.isComplete)
        XCTAssertNil(snapshot.snapshotAsOf)
    }

    func testRejectsSnapshotBoundaryChangeBetweenPages() async {
        do {
            _ = try await SessionListPageLoader().load { _, cursor in
                SessionListResult(
                    sessions: [makeSessionInfo(index: cursor == nil ? 0 : 1, project: 0)],
                    totalCount: 2,
                    hasMore: cursor == nil,
                    nextCursor: cursor == nil ? "next" : nil,
                    snapshotAsOf: cursor == nil
                        ? "2026-07-01T13:00:00Z"
                        : "2026-07-01T13:00:01Z",
                    snapshotCanReconcile: true
                )
            }
            XCTFail("Expected inconsistent snapshot error")
        } catch {
            XCTAssertEqual(error as? SessionListPageLoadingError, .inconsistentSnapshot)
        }
    }

    private func makeSessionInfo(index: Int, project: Int) -> SessionInfo {
        SessionInfo(
            sessionId: String(format: "session-%04d", index),
            model: "model",
            createdAt: "2026-07-01T12:00:00Z",
            eventCount: 1,
            turnCount: 1,
            messageCount: 1,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: 0,
            lastActivity: String(format: "2026-07-01T11:%02d:%02dZ", (index / 60) % 60, index % 60),
            isActive: false,
            isArchived: false,
            workingDirectory: "/tmp/tron-fixtures/project-\(project)",
            parentSessionId: nil,
            title: "Session \(index)",
            lastUserPrompt: nil,
            lastAssistantResponse: nil,
            source: nil,
            profile: nil,
            isRunning: false,
            activityLines: nil
        )
    }
}
