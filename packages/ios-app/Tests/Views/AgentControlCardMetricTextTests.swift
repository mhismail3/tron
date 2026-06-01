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

    func testValidZeroMetricsRenderAfterSummaryIsKnown() {
        XCTAssertEqual(AgentControlCardMetricText.analyticsTokens(0, isLoading: false), "0")
        XCTAssertEqual(AgentControlCardMetricText.analyticsCost(0, isLoading: false), "$0.00")
        XCTAssertEqual(AgentControlCardMetricText.historyTurns(0, isLoading: false), "0 turns")
        XCTAssertEqual(AgentControlCardMetricText.capabilityCalls(0, isLoading: false), "0 capability calls")
    }
}
