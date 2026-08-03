import Foundation

/// Closed authenticated client for native notification registration, inbox
/// synchronization, fixed responses, and sanitized delivery evidence.
final class NotificationClient: EngineDomainClient {
    /// Notification background work must never inherit the ordinary unbounded
    /// UI lifetime. Connection establishment has its own bounded open budget;
    /// every protocol operation owns this independent deadline.
    nonisolated static let requestTimeout: TimeInterval = 8

    func upsertDevice(
        _ registration: NotificationDeviceUpsertDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationDeviceRegistrationDTO {
        try await invokeWrite(
            "worker_kernel::notification_device_upsert",
            registration,
            idempotencyKey: idempotencyKey,
            timeout: Self.requestTimeout
        )
    }

    func disableDevice(
        installationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationDeviceDisableDTO {
        try await invokeWrite(
            "worker_kernel::notification_device_disable",
            ["installationId": installationId],
            idempotencyKey: idempotencyKey,
            timeout: Self.requestTimeout
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
            ),
            timeout: Self.requestTimeout
        )
    }

    func acknowledge(
        _ response: NotificationAcknowledgeDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationAcknowledgementResultDTO {
        try await invokeWrite(
            "worker_kernel::notification_delivery_acknowledge",
            response,
            idempotencyKey: idempotencyKey,
            timeout: Self.requestTimeout
        )
    }

    func status(deliveryId: String) async throws -> NotificationDeliveryStatusDTO {
        try await invokeRead(
            "worker_kernel::notification_delivery_status",
            NotificationDeliveryStatusRequestDTO(deliveryId: deliveryId),
            timeout: Self.requestTimeout
        )
    }
}
