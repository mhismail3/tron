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
                nextCursor: hasMore ? String(end) : nil
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
                    nextCursor: "next"
                )
            }
            return SessionListResult(
                sessions: secondPage,
                totalCount: 3,
                hasMore: false,
                nextCursor: nil
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
                nextCursor: String(end)
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
                    nextCursor: nil
                )
            }
            XCTFail("Expected missing cursor error")
        } catch {
            XCTAssertEqual(error as? SessionListPageLoadingError, .missingCursor)
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
