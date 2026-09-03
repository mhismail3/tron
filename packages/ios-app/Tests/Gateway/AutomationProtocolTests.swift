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
            "target":{"kind":"existingSession","sessionId":"10000000-0000-4000-8000-000000000002"},
            "trigger":{"kind":"calendar","timezone":"America/New_York","localTime":"09:30","weekdays":[1,2,3,4,5]},
            "nextOccurrenceAt":"2026-01-02T14:30:00.000Z",
            "currentRun":null,
            "lastRun":{"runId":"10000000-0000-4000-8000-000000000003","state":"succeeded","scheduledFor":"2026-01-01T14:30:00.000Z","terminalAt":"2026-01-01T14:31:00.000Z","targetSnapshot":{"kind":"existingSession","sessionId":"10000000-0000-4000-8000-000000000002"},"executionSessionId":"10000000-0000-4000-8000-000000000002"},
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

    @Test("target union is exact, bounded, and action-compatible")
    func targetAdmission() throws {
        let decoder = JSONDecoder.gateway
        let workspace = try decoder.decode(
            GatewayAutomationTarget.self,
            from: Data(#"{"kind":"workspace","cwd":"/workspace/project","sessionPolicy":"newPerRun"}"#.utf8)
        )
        #expect(workspace.isWorkspace)
        #expect(AutomationAdmissionPolicy.admitsActionTarget(actionKind: .sessionPrompt, target: workspace))
        #expect(!AutomationAdmissionPolicy.admitsActionTarget(actionKind: .notification, target: workspace))
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(GatewayAutomationTarget.self, from: Data(#"{"kind":"workspace","cwd":"/workspace/project","sessionPolicy":"newPerRun","extra":true}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(GatewayAutomationTarget.self, from: Data(#"{"kind":"existingSession","sessionId":""}"#.utf8))
        }
        #expect(!AutomationAdmissionPolicy.validWorkspacePath(String(repeating: "/", count: 4_097)))
    }

    @Test("new-session intervals require one full day")
    func newSessionIntervalMinimum() {
        let target = GatewayAutomationTarget.workspace(cwd: "/workspace/project", sessionPolicy: .newPerRun)
        #expect(!AutomationAdmissionPolicy.admitsActionTarget(actionKind: .notification, target: target))
        #expect(!AutomationAdmissionPolicy.admitsNewSessionInterval(GatewayAutomationTrigger(kind: "interval", everySeconds: 86_399, anchorAt: "2026-01-01T00:00:00Z")))
        #expect(AutomationAdmissionPolicy.admitsNewSessionInterval(GatewayAutomationTrigger(kind: "interval", everySeconds: 86_400, anchorAt: "2026-01-01T00:00:00Z")))
    }

    @Test("malformed trigger fails closed")
    func invalidTriggerFails() throws {
        let data = Data(#"""
        {
          "catalogRevision":4,
          "items":[{
            "id":"10000000-0000-4000-8000-000000000001","revision":1,"stateRevision":1,
            "name":"Bad","activation":"enabled","actionKind":"sessionPrompt",
            "target":{"kind":"existingSession","sessionId":"10000000-0000-4000-8000-000000000002"},
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

    @Test("timeline decodes dense series without fabricating occurrence identity")
    func timelineSeriesDecodes() throws {
        let data = Data(#"""
        {"catalogRevision":7,"items":[{
          "kind":"series",
          "automationId":"10000000-0000-4000-8000-000000000001",
          "automationRevision":3,
          "dayStart":"2026-01-02T05:00:00.000Z",
          "firstAt":"2026-01-02T05:00:00.000Z",
          "lastAt":"2026-01-03T04:55:00.000Z",
          "count":288
        }],"nextCursor":"10000000-0000-4000-8000-000000000099"}
        """#.utf8)
        let page = try JSONDecoder.gateway.decode(GatewayAutomationTimelinePage.self, from: data)
        let item = try #require(page.items.first)
        #expect(item.kind == .series)
        #expect(item.occurrenceId == nil)
        #expect(item.presentationTimestamp == "2026-01-02T05:00:00.000Z")
        #expect(item.count == 288)
    }

    @Test("timeline rejects mixed occurrence and series fields")
    func timelineMixedShapeFails() {
        let data = Data(#"""
        {"catalogRevision":7,"items":[{
          "kind":"series","automationId":"automation-one","automationRevision":1,
          "occurrenceId":"occurrence-one","scheduledFor":"2026-01-02T05:00:00.000Z",
          "dayStart":"2026-01-02T05:00:00.000Z","firstAt":"2026-01-02T05:00:00.000Z",
          "lastAt":"2026-01-03T04:55:00.000Z","count":288
        }]}
        """#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.gateway.decode(GatewayAutomationTimelinePage.self, from: data)
        }
    }

    @Test("timeline occurrences group by the device timezone day")
    @MainActor
    func timelineGrouping() {
        let first = GatewayAutomationOccurrence(kind: .occurrence, automationId: "a", automationRevision: 1, occurrenceId: "o1", scheduledFor: "2026-01-02T01:00:00Z")
        let second = GatewayAutomationOccurrence(kind: .occurrence, automationId: "a", automationRevision: 1, occurrenceId: "o2", scheduledFor: "2026-01-03T23:00:00Z")
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
            name: "Review", description: nil, activation: "enabled", target: .existingSession(sessionID: "session"),
            trigger: GatewayAutomationTrigger(kind: "once", at: "2026-01-01T00:00:00Z"),
            misfirePolicy: "latest", overlapPolicy: "skip", executionDeadlineSeconds: 3600,
            action: GatewayAutomationAction(kind: "notification", message: "Done")
        )
        let value = try JSONValue.encode(draft)
        #expect(value.objectValue?["target"]?.objectValue?.keys.sorted() == ["kind", "sessionId"])
        #expect(value.objectValue?["trigger"]?.objectValue?.keys.sorted() == ["at", "kind"])
        #expect(value.objectValue?["action"]?.objectValue?.keys.sorted() == ["kind", "message"])
        #expect(value.objectValue?["activation"] == .string("enabled"))
    }

    @Test("automation admission bounds resource arguments and provenance")
    func detailAdmissionBoundsSensitiveFields() {
        let oversized = String(repeating: "x", count: ComposerResourceInvocation.maximumArgumentBytes + 1)
        let action = GatewayAutomationAction(
            kind: "sessionPrompt",
            text: oversized,
            resourceInvocation: ComposerResourceInvocation(source: .skill, name: "review", arguments: oversized)
        )
        #expect(!AutomationAdmissionPolicy.admits(action))
        #expect(AutomationAdmissionPolicy.admits(GatewayAutomationProvenance(kind: "mobile", sessionId: nil, sourceId: nil)))
        #expect(!AutomationAdmissionPolicy.admits(GatewayAutomationProvenance(kind: "mobile", sessionId: "unexpected", sourceId: nil)))
        #expect(!AutomationAdmissionPolicy.admits(GatewayAutomationProvenance(
            kind: "assistant",
            sessionId: "session",
            sourceId: String(repeating: "x", count: 257)
        )))
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

    @Test("automation invalidation rejects unbounded opaque identity")
    func invalidationRejectsBadIdentity() {
        let data = Data("""
        {"type":"event","topic":"automation.changed","payload":{"catalogRevision":9,"automationId":"bad id"}}
        """.utf8)
        let event = try? JSONDecoder.gateway.decode(GatewayEvent.self, from: data)
        #expect(event != nil)
        #expect(event?.preparation != nil)
        if let event { #expect(event.preparation == GatewayEventPreparation.none) }
    }
}
