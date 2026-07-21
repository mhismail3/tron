import Foundation
import XCTest
@testable import TronMobile

final class AgentResponseCompletePluginTests: XCTestCase {
    func testTransformsNoToolResponseAsFinalityEvidence() throws {
        let event = try AgentResponseCompletePlugin.parse(from: data("""
        {
            "type": "agent.response_complete",
            "sessionId": "session-123",
            "timestamp": "2026-07-13T00:00:00Z",
            "data": {
                "turn": 4,
                "hasToolInvocations": false,
                "toolInvocationCount": 0
            }
        }
        """))

        let result = AgentResponseCompletePlugin.transform(event)
            as? AgentResponseCompletePlugin.Result

        XCTAssertEqual(result?.turnNumber, 4)
        XCTAssertEqual(result?.hasToolInvocations, false)
        XCTAssertEqual(result?.toolInvocationCount, 0)
    }

    func testTransformsToolBearingResponseAsIneligible() throws {
        let event = try AgentResponseCompletePlugin.parse(from: data("""
        {
            "type": "agent.response_complete",
            "sessionId": "session-123",
            "data": {
                "turn": 5,
                "hasToolInvocations": true,
                "toolInvocationCount": 3
            }
        }
        """))

        let result = AgentResponseCompletePlugin.transform(event)
            as? AgentResponseCompletePlugin.Result

        XCTAssertEqual(result?.turnNumber, 5)
        XCTAssertEqual(result?.hasToolInvocations, true)
        XCTAssertEqual(result?.toolInvocationCount, 3)
    }

    func testRejectsInconsistentToolEvidence() throws {
        let event = try AgentResponseCompletePlugin.parse(from: data("""
        {
            "type": "agent.response_complete",
            "sessionId": "session-123",
            "data": {
                "turn": 5,
                "hasToolInvocations": false,
                "toolInvocationCount": 1
            }
        }
        """))

        XCTAssertNil(AgentResponseCompletePlugin.transform(event))
    }

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }
}
