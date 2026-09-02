import Foundation
import Testing
@testable import TronMobile

@Suite("Automation protocol")
struct AutomationProtocolTests {
    @Test("bounded automation page decodes without action content")
    func pageDecodes() throws {
        let data = Data(#"""
        {
          "catalogRevision":4,
          "items":[{
            "id":"10000000-0000-4000-8000-000000000001",
            "revision":2,
            "stateRevision":7,
            "name":"Daily review",
            "activation":"enabled",
            "actionKind":"sessionPrompt",
            "targetSessionId":"10000000-0000-4000-8000-000000000002",
            "trigger":{"kind":"calendar","timezone":"America/New_York","localTime":"09:30","weekdays":[1,2,3,4,5]},
            "nextOccurrenceAt":"2026-01-02T14:30:00.000Z",
            "currentRun":null,
            "lastRun":{"runId":"10000000-0000-4000-8000-000000000003","state":"succeeded","scheduledFor":"2026-01-01T14:30:00.000Z","terminalAt":"2026-01-01T14:31:00.000Z"},
            "consecutiveFailureCount":0,
            "createdAt":"2026-01-01T00:00:00.000Z",
            "updatedAt":"2026-01-01T14:31:00.000Z"
          }]
        }
        """#.utf8)

        let page = try JSONDecoder.gateway.decode(GatewayAutomationPage.self, from: data)
        #expect(page.catalogRevision == 4)
        #expect(page.items.first?.activation == .enabled)
        #expect(page.items.first?.trigger.weekdays == [1, 2, 3, 4, 5])
        #expect(page.items.first?.lastRun?.state == .succeeded)
    }

    @Test("malformed trigger fails closed")
    func invalidTriggerFails() throws {
        let data = Data(#"""
        {
          "catalogRevision":4,
          "items":[{
            "id":"10000000-0000-4000-8000-000000000001","revision":1,"stateRevision":1,
            "name":"Bad","activation":"enabled","actionKind":"sessionPrompt",
            "targetSessionId":"10000000-0000-4000-8000-000000000002",
            "trigger":{"kind":"calendar","timezone":"UTC","localTime":"25:00","weekdays":[1]},
            "consecutiveFailureCount":0,
            "createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"
          }]
        }
        """#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.gateway.decode(GatewayAutomationPage.self, from: data)
        }
    }

    @Test("automation invalidation is prepared and bounded")
    func invalidationPreparation() throws {
        let data = Data(#"""
        {"type":"event","topic":"automation.changed","payload":{"catalogRevision":9,"automationId":"10000000-0000-4000-8000-000000000001"}}
        """#.utf8)
        let event = try JSONDecoder.gateway.decode(GatewayEvent.self, from: data)
        guard case .automationChanged(let changed) = event.preparation else {
            Issue.record("Expected typed automation invalidation")
            return
        }
        #expect(changed.catalogRevision == 9)
        #expect(changed.automationId == "10000000-0000-4000-8000-000000000001")
    }
}
