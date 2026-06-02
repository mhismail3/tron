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

    func testUnknownContextLimitDoesNotRenderFakeDenominator() {
        XCTAssertEqual(AgentControlCardMetricText.contextPercent(0, contextLimit: 0), "--")
        XCTAssertEqual(
            AgentControlCardMetricText.contextSummary(currentTokens: 0, contextLimit: 0),
            "Limit unknown"
        )
        XCTAssertEqual(
            AgentControlCardMetricText.contextSummary(currentTokens: 12_300, contextLimit: 0),
            "12.3k used (limit unknown)"
        )
    }

    func testKnownContextLimitRendersRemainingAndClampsAtZero() {
        XCTAssertEqual(AgentControlCardMetricText.contextPercent(0.247, contextLimit: 100_000), "25%")
        XCTAssertEqual(
            AgentControlCardMetricText.contextSummary(currentTokens: 12_300, contextLimit: 100_000),
            "87.7k left (12.3k / 100.0k)"
        )
        XCTAssertEqual(
            AgentControlCardMetricText.contextSummary(currentTokens: 120_000, contextLimit: 100_000),
            "0 left (120.0k / 100.0k)"
        )
    }
}
