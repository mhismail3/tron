import XCTest
@testable import TronMobile

final class TurnStartPluginTests: XCTestCase {
    func testTurnNumberAliasesRequireAtLeastOneExplicitTurnField() throws {
        let both = try TurnStartPlugin.parse(from: jsonData("""
        {"type": "agent.turn_start", "data": {"turn": 5, "turnNumber": 10}}
        """))
        XCTAssertEqual(both.data?.number, 5)

        let aliasOnly = try TurnStartPlugin.parse(from: jsonData("""
        {"type": "agent.turn_start", "data": {"turnNumber": 7}}
        """))
        XCTAssertEqual(aliasOnly.data?.number, 7)

        let missing = try TurnStartPlugin.parse(from: jsonData("""
        {"type": "agent.turn_start", "sessionId": "session-789"}
        """))
        XCTAssertNil(TurnStartPlugin.transform(missing))
    }

    func testTransformUsesExplicitTurnAndDefaultPhaseOnly() throws {
        let event = try TurnStartPlugin.parse(from: jsonData("""
        {"type": "agent.turn_start", "data": {"turn": 3}}
        """))

        let result = TurnStartPlugin.transform(event) as? TurnStartPlugin.Result
        XCTAssertEqual(result?.turnNumber, 3)
        XCTAssertEqual(result?.agentPhase, "processing")
    }

    private func jsonData(_ json: String) -> Data {
        Data(json.utf8)
    }
}
