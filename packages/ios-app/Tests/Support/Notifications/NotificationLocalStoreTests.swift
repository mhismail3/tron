import Foundation
import Testing

@testable import TronMobile

@Suite("Native notification local durability")
@MainActor
struct NotificationLocalStoreTests {
    @Test("legacy defaults migrate once to the actor-owned durable file")
    func legacyMigrationRoundTrip() async throws {
        try await IsolatedTestState.withState(
            label: "notification-local-store"
        ) { state in
            let fileURL = state.rootURL.appendingPathComponent(
                "Notifications/state-v2.json"
            )
            let item = Self.item(deliveryId: "notification_1")
            let mutation = Self.mutation(
                id: "mutation_1",
                deliveryId: item.delivery.deliveryId,
                acknowledgement: .snooze
            )
            let readiness = Self.readiness
            state.defaults.set(
                try JSONEncoder().encode([item]),
                forKey: "nativeNotifications.inbox.v1"
            )
            state.defaults.set(
                try JSONEncoder().encode([mutation]),
                forKey: "nativeNotifications.outbox.v1"
            )
            state.defaults.set(
                try JSONEncoder().encode([readiness]),
                forKey: "nativeNotifications.readiness.v1"
            )

            let store = NotificationLocalStore(
                defaults: NotificationDefaultsHandle(value: state.defaults),
                fileURL: fileURL
            )
            let installationId = store.installationId
            let migrated = try await store.load()

            #expect(migrated.inbox == [item])
            #expect(migrated.outbox == [mutation])
            #expect(migrated.readiness == [readiness])
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
            #expect(
                state.defaults.object(
                    forKey: "nativeNotifications.inbox.v1"
                ) == nil
            )
            #expect(
                state.defaults.object(
                    forKey: "nativeNotifications.outbox.v1"
                ) == nil
            )

            let restored = NotificationLocalStore(
                defaults: NotificationDefaultsHandle(value: state.defaults),
                fileURL: fileURL
            )
            #expect(restored.installationId == installationId)
            #expect(try await restored.load() == migrated)
            #expect(
                !state.defaults.dictionaryRepresentation().description
                    .contains("device-token")
            )
        }
    }

    @Test("one Mark All Read batch is durable and pending optimism survives sync")
    func batchedOutboxAndSynchronization() async throws {
        try await IsolatedTestState.withState(
            label: "notification-outbox-batch"
        ) { state in
            let fileURL = state.rootURL.appendingPathComponent(
                "Notifications/state-v2.json"
            )
            let first = Self.item(deliveryId: "delivery_1")
            let second = Self.item(deliveryId: "delivery_2")
            state.defaults.set(
                try JSONEncoder().encode([first, second]),
                forKey: "nativeNotifications.inbox.v1"
            )
            let store = NotificationLocalStore(
                defaults: NotificationDefaultsHandle(value: state.defaults),
                fileURL: fileURL
            )
            _ = try await store.load()

            let clear = Self.mutation(
                id: "clear_1",
                deliveryId: first.delivery.deliveryId,
                acknowledgement: .clearUnread
            )
            let complete = Self.mutation(
                id: "complete_2",
                deliveryId: second.delivery.deliveryId,
                acknowledgement: .complete
            )
            let appended = try await store.appendMutations([
                clear,
                complete,
            ])
            #expect(appended.outbox == [clear, complete])
            #expect(appended.inbox.allSatisfy { !$0.delivery.isUnread })

            var authoritativeFirst = first.delivery
            authoritativeFirst.readAt = "2026-07-25T00:02:00Z"
            let committed = try await store.commitSynchronization(
                acknowledgedMutationIds: [clear.mutationId],
                deliveriesByServer: [
                    first.serverId: [
                        authoritativeFirst,
                        second.delivery,
                    ],
                ]
            )

            #expect(committed.outbox == [complete])
            #expect(
                committed.inbox.first {
                    $0.delivery.deliveryId == second.delivery.deliveryId
                }?.delivery.terminalResponse == "complete"
            )

            let restored = NotificationLocalStore(
                defaults: NotificationDefaultsHandle(value: state.defaults),
                fileURL: fileURL
            )
            #expect(try await restored.load() == committed)
        }
    }

    @Test("concurrent response appends serialize without lost mutations")
    func concurrentAppendsSerialize() async throws {
        try await IsolatedTestState.withState(
            label: "notification-outbox-concurrency"
        ) { state in
            let store = NotificationLocalStore(
                defaults: NotificationDefaultsHandle(value: state.defaults),
                fileURL: state.rootURL.appendingPathComponent(
                    "Notifications/state-v2.json"
                )
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<40 {
                    group.addTask {
                        _ = try await store.appendMutations([
                            Self.mutation(
                                id: "mutation_\(index)",
                                deliveryId: "delivery_\(index)",
                                acknowledgement: .clearUnread
                            ),
                        ])
                    }
                }
                try await group.waitForAll()
            }

            let snapshot = try await store.load()
            #expect(snapshot.outbox.count == 40)
            #expect(Set(snapshot.outbox.map(\.mutationId)).count == 40)
        }
    }

    @Test("coordinator shutdown drains one batched Mark All Read outbox")
    func coordinatorShutdownDrainsMarkAllRead() async throws {
        try await IsolatedTestState.withState(
            label: "notification-coordinator-shutdown"
        ) { state in
            let fileURL = state.rootURL.appendingPathComponent(
                "Notifications/state-v2.json"
            )
            let items = [
                Self.item(deliveryId: "delivery_1"),
                Self.item(deliveryId: "delivery_2"),
                Self.item(deliveryId: "delivery_3"),
            ]
            state.defaults.set(
                try JSONEncoder().encode(items),
                forKey: "nativeNotifications.inbox.v1"
            )
            let coordinator = NativeNotificationCoordinator(
                defaults: state.defaults,
                storeURL: fileURL,
                runtimeMode: .hostedUnitTests,
                servers: { [] },
                notificationSession: { _, _ in
                    throw EngineClientError.connectionNotEstablished
                }
            )

            _ = await coordinator.handleQuietRefresh([
                "tron": ["serverId": "server_1"],
            ])
            #expect(coordinator.aggregateUnreadCount == 3)

            coordinator.clearAllUnread()
            #expect(coordinator.aggregateUnreadCount == 0)
            await coordinator.shutdown()

            let restored = NotificationLocalStore(
                defaults: NotificationDefaultsHandle(value: state.defaults),
                fileURL: fileURL
            )
            let snapshot = try await restored.load()
            #expect(snapshot.outbox.count == 3)
            #expect(
                snapshot.outbox.allSatisfy {
                    $0.acknowledgement == .clearUnread
                }
            )
            #expect(snapshot.inbox.allSatisfy { !$0.delivery.isUnread })
        }
    }

    @Test("system response is durable and synchronized before callback returns")
    func systemResponseCompletesAdmissionBeforeReturning() async throws {
        try await IsolatedTestState.withState(
            label: "notification-system-response"
        ) { state in
            let fileURL = state.rootURL.appendingPathComponent(
                "Notifications/state-v2.json"
            )
            let repository = RecordingNotificationRepository()
            let server = Self.server
            let coordinator = NativeNotificationCoordinator(
                defaults: state.defaults,
                storeURL: fileURL,
                runtimeMode: .hostedUnitTests,
                servers: { [server] },
                notificationSession: { _, operation in
                    try await operation(repository)
                }
            )

            await coordinator.handleNotificationResponse(
                serverId: server.id,
                deliveryId: "delivery-snooze",
                acknowledgement: .snooze
            )

            #expect(repository.acknowledgements.count == 1)
            #expect(
                repository.acknowledgements.first?.acknowledgement == .snooze
            )
            let restored = NotificationLocalStore(
                defaults: NotificationDefaultsHandle(value: state.defaults),
                fileURL: fileURL
            )
            let snapshot = try await restored.load()
            #expect(snapshot.outbox.isEmpty)
            await coordinator.shutdown()
        }
    }

    @Test("cold-launch response waits for coordinator attachment")
    func responseBeforeCoordinatorAttachmentIsNotDropped() async throws {
        await IsolatedTestState.withState(
            label: "notification-response-before-attach"
        ) { state in
            let repository = RecordingNotificationRepository()
            let server = Self.server
            let coordinator = NativeNotificationCoordinator(
                defaults: state.defaults,
                storeURL: state.rootURL.appendingPathComponent(
                    "Notifications/state-v2.json"
                ),
                runtimeMode: .hostedUnitTests,
                servers: { [server] },
                notificationSession: { _, operation in
                    try await operation(repository)
                }
            )
            let bridge = NotificationLifecycleBridge()
            let response = Task { @MainActor in
                await bridge.admitNotificationResponse(
                    serverId: server.id,
                    deliveryId: "delivery-cold-launch",
                    acknowledgement: .complete
                )
            }
            await Task.yield()

            bridge.attach(coordinator)
            await response.value

            #expect(repository.acknowledgements.count == 1)
            #expect(
                repository.acknowledgements.first?.acknowledgement == .complete
            )
            await coordinator.shutdown()
        }
    }

    nonisolated private static func item(
        deliveryId: String
    ) -> NotificationInboxItem {
        NotificationInboxItem(
            serverId: "server_1",
            delivery: NotificationDeliveryDTO(
                deliveryId: deliveryId,
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
        )
    }

    nonisolated private static func mutation(
        id: String,
        deliveryId: String,
        acknowledgement: NotificationAcknowledgement
    ) -> NotificationMutation {
        NotificationMutation(
            mutationId: id,
            serverId: "server_1",
            deliveryId: deliveryId,
            acknowledgement: acknowledgement,
            occurredAt: "2026-07-25T00:01:00Z"
        )
    }

    nonisolated private static let readiness = NotificationServerReadiness(
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

    private static let server = PairedServer(
        id: "server_1",
        label: "Test server",
        host: "127.0.0.1",
        port: 9847
    )
}

@MainActor
private final class RecordingNotificationRepository: NotificationRepository {
    private(set) var acknowledgements: [NotificationAcknowledgeDTO] = []

    func upsertDevice(
        _ registration: NotificationDeviceUpsertDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationDeviceRegistrationDTO {
        throw CancellationError()
    }

    func disableDevice(
        installationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationDeviceDisableDTO {
        throw CancellationError()
    }

    func deliveries(
        cursor: String?,
        limit: Int,
        unreadOnly: Bool
    ) async throws -> NotificationDeliveriesPageDTO {
        NotificationDeliveriesPageDTO(
            deliveries: [],
            unreadCount: 0,
            nextCursor: nil
        )
    }

    func acknowledge(
        _ response: NotificationAcknowledgeDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationAcknowledgementResultDTO {
        acknowledgements.append(response)
        return NotificationAcknowledgementResultDTO(
            deliveryId: response.deliveryId,
            clientMutationId: response.clientMutationId,
            acknowledgement: response.acknowledgement,
            accepted: true,
            currentTerminalResponse: response.acknowledgement.rawValue,
            read: true,
            eventRequired: true,
            workerId: "automation-reminders",
            sourceRecordId: "occurrence_1",
            traceId: "trace_1",
            occurredAt: response.occurredAt ?? "2026-07-30T00:00:00Z"
        )
    }

    func status(
        deliveryId: String
    ) async throws -> NotificationDeliveryStatusDTO {
        throw CancellationError()
    }
}
