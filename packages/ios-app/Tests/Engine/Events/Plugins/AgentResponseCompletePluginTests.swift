import Foundation
import XCTest
@testable import TronMobile

final class AgentResponseCompletePluginTests: XCTestCase {
    func testTransformsNoCapabilityResponseAsFinalityEvidence() throws {
        let event = try AgentResponseCompletePlugin.parse(from: data("""
        {
            "type": "agent.response_complete",
            "sessionId": "session-123",
            "timestamp": "2026-07-13T00:00:00Z",
            "data": {
                "turn": 4,
                "hasCapabilityInvocations": false,
                "capabilityInvocationCount": 0
            }
        }
        """))

        let result = AgentResponseCompletePlugin.transform(event)
            as? AgentResponseCompletePlugin.Result

        XCTAssertEqual(result?.turnNumber, 4)
        XCTAssertEqual(result?.hasCapabilityInvocations, false)
        XCTAssertEqual(result?.capabilityInvocationCount, 0)
    }

    func testTransformsCapabilityBearingResponseAsIneligible() throws {
        let event = try AgentResponseCompletePlugin.parse(from: data("""
        {
            "type": "agent.response_complete",
            "sessionId": "session-123",
            "data": {
                "turn": 5,
                "hasCapabilityInvocations": true,
                "capabilityInvocationCount": 3
            }
        }
        """))

        let result = AgentResponseCompletePlugin.transform(event)
            as? AgentResponseCompletePlugin.Result

        XCTAssertEqual(result?.turnNumber, 5)
        XCTAssertEqual(result?.hasCapabilityInvocations, true)
        XCTAssertEqual(result?.capabilityInvocationCount, 3)
    }

    func testRejectsInconsistentCapabilityEvidence() throws {
        let event = try AgentResponseCompletePlugin.parse(from: data("""
        {
            "type": "agent.response_complete",
            "sessionId": "session-123",
            "data": {
                "turn": 5,
                "hasCapabilityInvocations": false,
                "capabilityInvocationCount": 1
            }
        }
        """))

        XCTAssertNil(AgentResponseCompletePlugin.transform(event))
    }

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }
}
