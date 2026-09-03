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

    @Test("timeline occurrences group by the device timezone day")
    @MainActor
    func timelineGrouping() {
        let first = GatewayAutomationOccurrence(kind: "occurrence", automationId: "a", automationRevision: 1, occurrenceId: "o1", scheduledFor: "2026-01-02T01:00:00Z", dayStart: nil, firstAt: nil, lastAt: nil, count: nil)
        let second = GatewayAutomationOccurrence(kind: "occurrence", automationId: "a", automationRevision: 1, occurrenceId: "o2", scheduledFor: "2026-01-03T23:00:00Z", dayStart: nil, firstAt: nil, lastAt: nil, count: nil)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: -5)!
        let days = AutomationTimelineCoordinator.group([
            AutomationTimelineItem(profileID: "profile", occurrence: second),
            AutomationTimelineItem(profileID: "profile", occurrence: first)
        ], calendar: calendar, timezone: calendar.timeZone)
        #expect(days.count == 2)
        #expect(days.first?.items.first?.occurrence.occurrenceId == "o1")
    }

    @Test("automation drafts encode exact trigger and action keys")
    func draftWireShape() throws {
        let draft = AutomationDefinitionDraft(
            name: "Review", description: nil, targetSessionId: "session",
            trigger: GatewayAutomationTrigger(kind: "once", at: "2026-01-01T00:00:00Z"),
            misfirePolicy: "latest", overlapPolicy: "skip", executionDeadlineSeconds: 3600,
            action: GatewayAutomationAction(kind: "notification", message: "Done")
        )
        let value = try JSONValue.encode(draft)
        #expect(value.objectValue?["trigger"]?.objectValue?.keys.sorted() == ["at", "kind"])
        #expect(value.objectValue?["action"]?.objectValue?.keys.sorted() == ["kind", "message"])
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
