import Foundation
import Testing

@testable import TronMobile

@Suite("Native notification local durability")
@MainActor
struct NotificationLocalStoreTests {
    @Test("installation identity, inbox, readiness, and response outbox survive reconstruction")
    func roundTrip() {
        IsolatedTestState.withDefaults(label: "notification-local-store") { defaults in
            let store = NotificationLocalStore(defaults: defaults)
            let installationId = store.installationId
            let delivery = NotificationDeliveryDTO(
                deliveryId: "notification_1",
                workerId: "automation-reminders",
                workerVersion: "version_1",
                sourceWorkerId: "automation-reminders",
                sourceWorkerVersion: "version_1",
                producerWorkerId: "notification-policy",
                producerWorkerVersion: "policy-version",
                sourceInvocationId: "source-run",
                sourceRecordId: "occurrence_1",
                title: "Reminder",
                body: "Persist this logical item.",
                threadKey: "reminders",
                expiresAt: "2026-07-26T00:00:00Z",
                notBefore: "2026-07-25T00:00:00Z",
                transportMode: .relay,
                actions: ["snooze", "complete"],
                onOpen: "complete",
                readAt: nil,
                terminalResponse: nil,
                terminalRespondedAt: nil,
                createdAt: "2026-07-25T00:00:00Z",
                updatedAt: "2026-07-25T00:00:00Z",
                targetSummary: NotificationDeliveryTargetSummaryDTO(
                    total: 1,
                    queued: 1,
                    retryWait: 0,
                    acceptedByAPNs: 0,
                    blocked: 0,
                    permanentFailure: 0,
                    expired: 0,
                    cancelled: 0
                )
            )
            let item = NotificationInboxItem(serverId: "server_1", delivery: delivery)
            let mutation = NotificationMutation(
                mutationId: "mutation_1",
                serverId: "server_1",
                deliveryId: delivery.deliveryId,
                acknowledgement: .snooze,
                occurredAt: "2026-07-25T00:01:00Z"
            )
            let readiness = NotificationServerReadiness(
                serverId: "server_1",
                ready: false,
                deviceReady: true,
                transportMode: .relay,
                transportConfigured: false,
                transportProblem: "relay_offline",
                authorizationStatus: .authorized,
                registeredAt: nil,
                problem: "Offline"
            )

            store.saveInbox([item])
            store.saveOutbox([mutation])
            store.saveReadiness([readiness])

            let restored = NotificationLocalStore(defaults: defaults)
            #expect(restored.installationId == installationId)
            #expect(restored.loadInbox() == [item])
            #expect(restored.loadOutbox() == [mutation])
            #expect(restored.loadReadiness() == [readiness])
            #expect(!defaults.dictionaryRepresentation().description.contains("device-token"))
        }
    }
}
