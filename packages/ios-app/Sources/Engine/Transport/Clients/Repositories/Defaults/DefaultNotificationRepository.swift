import Foundation

/// Transport adapter for the native notification repository contract.
///
/// Connection selection and lifetime are deliberately absent: the composition
/// root creates this adapter around either the active client or one bounded,
/// short-lived inactive-server client.
@MainActor
final class DefaultNotificationRepository: NotificationRepository {
    private let client: NotificationClient

    init(client: NotificationClient) {
        self.client = client
    }

    func upsertDevice(
        _ registration: NotificationDeviceUpsertDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationDeviceRegistrationDTO {
        try await client.upsertDevice(
            registration,
            idempotencyKey: idempotencyKey
        )
    }

    func disableDevice(
        installationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationDeviceDisableDTO {
        try await client.disableDevice(
            installationId: installationId,
            idempotencyKey: idempotencyKey
        )
    }

    func deliveries(
        cursor: String? = nil,
        limit: Int = 100,
        unreadOnly: Bool = false
    ) async throws -> NotificationDeliveriesPageDTO {
        try await client.deliveries(
            cursor: cursor,
            limit: limit,
            unreadOnly: unreadOnly
        )
    }

    func acknowledge(
        _ response: NotificationAcknowledgeDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationAcknowledgementResultDTO {
        try await client.acknowledge(
            response,
            idempotencyKey: idempotencyKey
        )
    }

    func status(deliveryId: String) async throws -> NotificationDeliveryStatusDTO {
        try await client.status(deliveryId: deliveryId)
    }
}
