import Foundation
import Testing

@testable import TronMobile

@Suite("Notification protocol types")
struct EngineProtocolTypesNotificationTests {
    @Test("logical inbox decodes without transport secrets")
    func decodesLogicalDelivery() throws {
        let json = """
        {
          "deliveries": [{
            "deliveryId": "notification_1",
            "workerId": "automation-reminders",
            "workerVersion": "version",
            "sourceWorkerId": "automation-reminders",
            "sourceWorkerVersion": "version",
            "producerWorkerId": "notification-policy",
            "producerWorkerVersion": "policy-version",
            "sourceInvocationId": "source-run",
            "sourceRecordId": "occurrence",
            "title": "Reminder",
            "body": "Do the thing.",
            "threadKey": "reminders",
            "expiresAt": "2026-07-26T00:00:00Z",
            "notBefore": "2026-07-25T01:00:00Z",
            "transportMode": "relay",
            "actions": ["snooze", "complete"],
            "onOpen": "complete",
            "readAt": null,
            "terminalResponse": null,
            "terminalRespondedAt": null,
            "createdAt": "2026-07-25T00:00:00Z",
            "updatedAt": "2026-07-25T00:00:00Z",
            "targetSummary": {
              "total": 2,
              "queued": 0,
              "retryWait": 0,
              "acceptedByAPNs": 1,
              "blocked": 1,
              "permanentFailure": 0,
              "expired": 0,
              "cancelled": 0
            }
          }],
          "unreadCount": 1,
          "nextCursor": null
        }
        """

        let page = try JSONDecoder().decode(
            NotificationDeliveriesPageDTO.self,
            from: Data(json.utf8)
        )
        #expect(page.unreadCount == 1)
        #expect(page.deliveries.first?.isUnread == true)
        #expect(page.deliveries.first?.actions == ["snooze", "complete"])
        #expect(page.deliveries.first?.targetSummary.acceptedByAPNs == 1)
        #expect(page.deliveries.first?.producerWorkerId == "notification-policy")
        #expect(page.deliveries.first?.notBefore == "2026-07-25T01:00:00Z")
        #expect(page.deliveries.first?.transportMode == .relay)
    }

    @Test("fixed acknowledgement names match the authenticated engine contract")
    func acknowledgementEncoding() throws {
        let response = NotificationAcknowledgeDTO(
            deliveryId: "notification_1",
            installationId: "installation_1",
            clientMutationId: "mutation_1",
            acknowledgement: .clearUnread,
            occurredAt: nil
        )
        let value = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(response)
        ) as? [String: Any]
        #expect(value?["acknowledgement"] as? String == "clear_unread")
    }
}
