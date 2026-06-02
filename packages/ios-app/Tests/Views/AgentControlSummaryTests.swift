import XCTest
@testable import TronMobile

final class AgentControlSummaryTests: XCTestCase {
    func testCachedSessionZeroesAreKnownValues() {
        let session = makeSession(input: 0, output: 0, cacheRead: 0, cacheCreation: 0, cost: 0)

        let summary = AgentControlSummary.fromSession(session, freshness: .cached)

        XCTAssertTrue(summary.isKnown)
        XCTAssertEqual(summary.totalTokens, 0)
        XCTAssertEqual(summary.totalCost, 0)
        XCTAssertEqual(summary.freshness, .cached)
    }

    func testCachedSessionIncludesCacheCreationInTotalTokens() {
        let session = makeSession(input: 100, output: 25, cacheRead: 40, cacheCreation: 10, cost: 0.02)

        let summary = AgentControlSummary.fromSession(session, freshness: .fresh)

        XCTAssertEqual(summary.inputTokens, 100)
        XCTAssertEqual(summary.outputTokens, 25)
        XCTAssertEqual(summary.cacheReadTokens, 40)
        XCTAssertEqual(summary.cacheCreationTokens, 10)
        XCTAssertEqual(summary.totalTokens, 175)
        XCTAssertEqual(summary.totalCost, 0.02)
    }

    func testCachedSessionUsesServerTurnCountWithoutGuessingCapabilityCount() {
        let session = makeSession(
            input: 100,
            output: 25,
            cacheRead: 0,
            cacheCreation: 0,
            cost: 0,
            eventCount: 18,
            turnCount: 3
        )

        let summary = AgentControlSummary.fromSession(session, freshness: .cached)

        XCTAssertEqual(summary.eventCount, 18)
        XCTAssertEqual(summary.totalTurns, 3)
        XCTAssertEqual(summary.totalCapabilityInvocations, 0)
        XCTAssertFalse(summary.capabilityInvocationsKnown)
    }

    func testMergedSnapshotPreservesFreshPersistedTurnCountOverStaleMemory() {
        let staleMemory = makeSession(
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 0,
            cost: 0,
            eventCount: 2,
            turnCount: 0
        )
        let refreshedPersisted = makeSession(
            input: 5449,
            output: 78,
            cacheRead: 0,
            cacheCreation: 0,
            cost: 0,
            eventCount: 10,
            turnCount: 1
        )

        let merged = AgentControlSummary.mergedSessionSnapshot(
            inMemory: staleMemory,
            persisted: refreshedPersisted
        )

        XCTAssertEqual(merged?.eventCount, 10)
        XCTAssertEqual(merged?.turnCount, 1)
        XCTAssertEqual(merged?.inputTokens, 5449)
        XCTAssertEqual(merged?.outputTokens, 78)
    }

    func testMergedSnapshotPreservesLiveMemoryTurnCountOverStalePersistedSession() {
        let stalePersisted = makeSession(
            input: 5449,
            output: 78,
            cacheRead: 0,
            cacheCreation: 0,
            cost: 0,
            eventCount: 10,
            turnCount: 1
        )
        let liveMemory = makeSession(
            input: 10935,
            output: 86,
            cacheRead: 0,
            cacheCreation: 0,
            cost: 0,
            eventCount: 15,
            turnCount: 2
        )

        let merged = AgentControlSummary.mergedSessionSnapshot(
            inMemory: liveMemory,
            persisted: stalePersisted
        )

        XCTAssertEqual(merged?.eventCount, 15)
        XCTAssertEqual(merged?.turnCount, 2)
        XCTAssertEqual(merged?.inputTokens, 10935)
        XCTAssertEqual(merged?.outputTokens, 86)
    }

    func testCachedEmptySessionHasKnownZeroCapabilityCount() {
        let session = makeSession(
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 0,
            cost: 0,
            eventCount: 0,
            turnCount: 0
        )

        let summary = AgentControlSummary.fromSession(session, freshness: .cached)

        XCTAssertEqual(summary.totalTurns, 0)
        XCTAssertEqual(summary.totalCapabilityInvocations, 0)
        XCTAssertTrue(summary.capabilityInvocationsKnown)
    }

    func testLocalEventsPopulateTurnAndEventCountsWithoutTokenRecords() {
        let events = [
            makeEvent(type: PersistedEventType.sessionStart.rawValue, sequence: 0),
            makeEvent(type: PersistedEventType.rulesLoaded.rawValue, sequence: 1)
        ]
        let analytics = ConsolidatedAnalytics(from: events)
        let turnGroups = TurnGrouping.group(events: events, analytics: analytics, currentSessionId: "s")

        let summary = AgentControlSummary.fromEvents(
            events,
            analytics: analytics,
            turnGroups: turnGroups,
            sessionSnapshot: makeSession(input: 0, output: 0, cacheRead: 0, cacheCreation: 0, cost: 0),
            freshness: .cached
        )

        XCTAssertTrue(summary.isKnown)
        XCTAssertEqual(summary.eventCount, 2)
        XCTAssertEqual(summary.totalTurns, 1)
        XCTAssertEqual(summary.totalCapabilityInvocations, 0)
    }

    func testIncompleteLocalEventsPreserveServerTurnCountAndKeepCapabilityCountUnknown() {
        let events = [
            makeEvent(type: PersistedEventType.sessionStart.rawValue, sequence: 0),
            makeEvent(type: PersistedEventType.rulesLoaded.rawValue, sequence: 1)
        ]
        let analytics = ConsolidatedAnalytics(from: events)
        let turnGroups = TurnGrouping.group(events: events, analytics: analytics, currentSessionId: "s")

        let summary = AgentControlSummary.fromEvents(
            events,
            analytics: analytics,
            turnGroups: turnGroups,
            sessionSnapshot: makeSession(
                input: 17_885,
                output: 318,
                cacheRead: 0,
                cacheCreation: 0,
                cost: 0,
                eventCount: 18,
                turnCount: 3
            ),
            freshness: .refreshing
        )

        XCTAssertEqual(summary.eventCount, 18)
        XCTAssertEqual(summary.totalTurns, 3)
        XCTAssertEqual(summary.totalCapabilityInvocations, 0)
        XCTAssertFalse(summary.capabilityInvocationsKnown)
    }

    func testCompleteLocalEventsExposeCapabilityCount() {
        let events = [
            makeEvent(
                type: PersistedEventType.messageAssistant.rawValue,
                sequence: 0,
                payload: [
                    "turn": AnyCodable(1),
                    "model": AnyCodable("model"),
                    "tokenRecord": AnyCodable(tokenRecordPayload())
                ]
            ),
            makeEvent(
                type: PersistedEventType.capabilityInvocationStarted.rawValue,
                sequence: 1,
                payload: [
                    "turn": AnyCodable(1),
                    "modelPrimitiveName": AnyCodable("process::run")
                ]
            )
        ]
        let analytics = ConsolidatedAnalytics(from: events)
        let turnGroups = TurnGrouping.group(events: events, analytics: analytics, currentSessionId: "s")

        let summary = AgentControlSummary.fromEvents(
            events,
            analytics: analytics,
            turnGroups: turnGroups,
            sessionSnapshot: makeSession(
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheCreation: 0,
                cost: 0,
                eventCount: 2,
                turnCount: 1
            ),
            freshness: .fresh
        )

        XCTAssertEqual(summary.totalTurns, 1)
        XCTAssertEqual(summary.totalCapabilityInvocations, 1)
        XCTAssertTrue(summary.capabilityInvocationsKnown)
    }

    func testEventAnalyticsOverrideStaleSessionCostWhenTurnsAreLoaded() {
        let events = [
            makeEvent(
                type: PersistedEventType.messageAssistant.rawValue,
                sequence: 0,
                payload: [
                    "turn": AnyCodable(1),
                    "model": AnyCodable("model"),
                    "tokenRecord": AnyCodable(tokenRecordPayload())
                ]
            )
        ]
        let analytics = ConsolidatedAnalytics(from: events)

        let summary = AgentControlSummary.fromEvents(
            events,
            analytics: analytics,
            turnGroups: [],
            sessionSnapshot: makeSession(input: 999, output: 999, cacheRead: 0, cacheCreation: 0, cost: 0),
            freshness: .fresh
        )

        XCTAssertEqual(summary.totalTokens, 20)
        XCTAssertEqual(summary.totalCost, 0.04)
    }

    private func makeSession(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int,
        cost: Double,
        eventCount: Int = 0,
        turnCount: Int = 0
    ) -> CachedSession {
        CachedSession(
            id: "s",
            workspaceId: "/tmp/repo",
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            latestModel: "model",
            workingDirectory: "/tmp/repo",
            createdAt: "2026-01-01T00:00:00Z",
            lastActivityAt: "2026-01-01T00:00:00Z",
            eventCount: eventCount,
            turnCount: turnCount,
            messageCount: 0,
            inputTokens: input,
            outputTokens: output,
            lastTurnInputTokens: input,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            cost: cost
        )
    }

    private func makeEvent(
        type: String,
        sequence: Int,
        payload: [String: AnyCodable] = [:]
    ) -> SessionEvent {
        SessionEvent(
            id: "e\(sequence)",
            parentId: nil,
            sessionId: "s",
            workspaceId: "/tmp/repo",
            type: type,
            timestamp: "2026-01-01T00:00:00Z",
            sequence: sequence,
            payload: payload
        )
    }

    private func tokenRecordPayload() -> [String: Any] {
        [
            "source": [
                "provider": "anthropic",
                "timestamp": "2026-01-01T00:00:00Z",
                "rawInputTokens": 10,
                "rawOutputTokens": 5,
                "rawCacheReadTokens": 3,
                "rawCachedInputTokens": 3,
                "rawCacheCreationTokens": 2,
                "rawCacheCreation5mTokens": 0,
                "rawCacheCreation1hTokens": 0,
                "rawReasoningOutputTokens": 0,
                "rawThoughtTokens": 0,
                "rawToolUsePromptTokens": 0,
                "rawTotalTokens": 20
            ],
            "computed": [
                "contextWindowTokens": 10,
                "newInputTokens": 10,
                "previousContextBaseline": 0,
                "calculationMethod": "anthropic_cache_aware"
            ],
            "meta": [
                "turn": 1,
                "sessionId": "s",
                "model": "model",
                "contextSegmentId": "segment-1",
                "baselineResetReason": "none",
                "extractedAt": "2026-01-01T00:00:00Z",
                "normalizedAt": "2026-01-01T00:00:00Z"
            ],
            "pricing": [
                "available": true,
                "model": "model",
                "reason": NSNull(),
                "cost": [
                    "baseInputTokens": 10,
                    "outputTokens": 5,
                    "cacheReadTokens": 3,
                    "cacheWriteTokens": 2,
                    "cacheWrite5mTokens": 0,
                    "cacheWrite1hTokens": 0,
                    "baseInputCost": 0.01,
                    "outputCost": 0.02,
                    "cacheReadCost": 0.005,
                    "cacheWriteCost": 0.005,
                    "totalCost": 0.04,
                    "currency": "USD"
                ]
            ]
        ]
    }
}
