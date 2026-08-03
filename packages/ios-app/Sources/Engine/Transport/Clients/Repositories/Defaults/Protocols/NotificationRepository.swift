import Foundation

/// Closed notification operations available to native lifecycle coordination.
///
/// The repository intentionally omits connection, token, URL, and socket
/// controls. The composition root lends one repository for the duration of a
/// bounded server pass and remains the sole owner of transport lifetime.
@MainActor
protocol NotificationRepository: AnyObject {
    func upsertDevice(
        _ registration: NotificationDeviceUpsertDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationDeviceRegistrationDTO

    func disableDevice(
        installationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationDeviceDisableDTO

    func deliveries(
        cursor: String?,
        limit: Int,
        unreadOnly: Bool
    ) async throws -> NotificationDeliveriesPageDTO

    func acknowledge(
        _ response: NotificationAcknowledgeDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationAcknowledgementResultDTO

    func status(deliveryId: String) async throws -> NotificationDeliveryStatusDTO
}
