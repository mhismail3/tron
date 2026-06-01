import XCTest
@testable import TronMobile

final class SessionUpdatedPluginTests: XCTestCase {
    func testSessionUpdatedDecodesEventAndTurnCounts() throws {
        let event = try SessionUpdatedPlugin.parse(from: Data("""
        {
          "type": "session.updated",
          "sessionId": "sess_1",
          "data": {
            "eventCount": 10,
            "turnCount": 1,
            "messageCount": 2,
            "inputTokens": 5449,
            "outputTokens": 78,
            "cost": 0.0
          }
        }
        """.utf8))

        let result = SessionUpdatedPlugin.transform(event) as? SessionUpdatedPlugin.Result

        XCTAssertEqual(result?.sessionId, "sess_1")
        XCTAssertEqual(result?.eventCount, 10)
        XCTAssertEqual(result?.turnCount, 1)
        XCTAssertEqual(result?.messageCount, 2)
        XCTAssertEqual(result?.inputTokens, 5449)
        XCTAssertEqual(result?.outputTokens, 78)
        XCTAssertEqual(result?.cost, 0)
    }
}
