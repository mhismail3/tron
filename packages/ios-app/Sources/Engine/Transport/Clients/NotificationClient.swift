import Foundation

/// Closed authenticated client for native notification registration, inbox
/// synchronization, fixed responses, and sanitized delivery evidence.
final class NotificationClient: EngineDomainClient {
    func upsertDevice(
        _ registration: NotificationDeviceUpsertDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationDeviceRegistrationDTO {
        try await invokeWrite(
            "worker_kernel::notification_device_upsert",
            registration,
            idempotencyKey: idempotencyKey
        )
    }

    func disableDevice(
        installationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationDeviceDisableDTO {
        try await invokeWrite(
            "worker_kernel::notification_device_disable",
            ["installationId": installationId],
            idempotencyKey: idempotencyKey
        )
    }

    func deliveries(
        cursor: String? = nil,
        limit: Int = 100,
        unreadOnly: Bool = false
    ) async throws -> NotificationDeliveriesPageDTO {
        try await invokeRead(
            "worker_kernel::notification_deliveries",
            NotificationDeliveriesRequestDTO(
                cursor: cursor,
                limit: min(max(limit, 1), 200),
                unreadOnly: unreadOnly
            )
        )
    }

    func acknowledge(
        _ response: NotificationAcknowledgeDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationAcknowledgementResultDTO {
        try await invokeWrite(
            "worker_kernel::notification_delivery_acknowledge",
            response,
            idempotencyKey: idempotencyKey
        )
    }

    func status(deliveryId: String) async throws -> NotificationDeliveryStatusDTO {
        try await invokeRead(
            "worker_kernel::notification_delivery_status",
            NotificationDeliveryStatusRequestDTO(deliveryId: deliveryId)
        )
    }
}
