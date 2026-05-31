import XCTest
@testable import TronMobile

final class AgentControlCardMetricTextTests: XCTestCase {
    func testLoadingStateDoesNotRenderMisleadingZeroMetrics() {
        XCTAssertEqual(AgentControlCardMetricText.analyticsTokens(0, isLoading: true), "...")
        XCTAssertEqual(AgentControlCardMetricText.analyticsCost(0, isLoading: true), "...")
        XCTAssertEqual(AgentControlCardMetricText.historyTurns(0, isLoading: true), "...")
        XCTAssertEqual(AgentControlCardMetricText.capabilityCalls(0, isLoading: true), "...")
    }

    func testLoadedStateRendersServerDerivedMetrics() {
        XCTAssertEqual(AgentControlCardMetricText.analyticsTokens(14_300, isLoading: false), "14.3k")
        XCTAssertEqual(AgentControlCardMetricText.analyticsCost(0.0098, isLoading: false), "$0.010")
        XCTAssertEqual(AgentControlCardMetricText.historyTurns(1, isLoading: false), "1 turn")
        XCTAssertEqual(AgentControlCardMetricText.capabilityCalls(2, isLoading: false), "2 capability calls")
    }

    func testEventSummaryRemainsPendingWhenContextArrivesBeforeEvents() {
        XCTAssertTrue(AgentControlCardMetricText.isEventSummaryPending(
            isLoadingEvents: false,
            sessionEventCount: 0,
            analyticsTurnCount: 0,
            turnGroupCount: 0,
            currentContextTokens: 14_700
        ))
    }

    func testEventSummaryPendingStopsForLoadedOrTrulyEmptySessions() {
        XCTAssertFalse(AgentControlCardMetricText.isEventSummaryPending(
            isLoadingEvents: false,
            sessionEventCount: 12,
            analyticsTurnCount: 1,
            turnGroupCount: 2,
            currentContextTokens: 14_700
        ))
        XCTAssertFalse(AgentControlCardMetricText.isEventSummaryPending(
            isLoadingEvents: false,
            sessionEventCount: 0,
            analyticsTurnCount: 0,
            turnGroupCount: 0,
            currentContextTokens: 0
        ))
    }

    func testEventSummaryStaysPendingWhileDerivedAnalyticsLoads() {
        XCTAssertTrue(AgentControlCardMetricText.isEventSummaryPending(
            isLoadingEvents: true,
            sessionEventCount: 12,
            analyticsTurnCount: 0,
            turnGroupCount: 0,
            currentContextTokens: 14_700
        ))
    }
}
