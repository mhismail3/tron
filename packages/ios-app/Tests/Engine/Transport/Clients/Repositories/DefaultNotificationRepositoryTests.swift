import Foundation
import XCTest

@testable import TronMobile

@MainActor
final class DefaultNotificationRepositoryTests: XCTestCase {
    func testDeliveriesForwardsClosedReadContract() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:9847/engine")!
        )
        let expected = NotificationDeliveriesPageDTO(
            deliveries: [],
            unreadCount: 0,
            nextCursor: nil
        )
        transport.readHandler = { functionId, payload, options in
            XCTAssertEqual(
                functionId.rawValue,
                "worker_kernel::notification_deliveries"
            )
            XCTAssertEqual(
                payload as? NotificationDeliveriesRequestDTO,
                NotificationDeliveriesRequestDTO(
                    cursor: "cursor_1",
                    limit: 25,
                    unreadOnly: true
                )
            )
            XCTAssertEqual(options.timeout, NotificationClient.requestTimeout)
            return expected
        }
        let repository = DefaultNotificationRepository(
            client: NotificationClient(transport: transport)
        )

        let result = try await repository.deliveries(
            cursor: "cursor_1",
            limit: 25,
            unreadOnly: true
        )

        XCTAssertEqual(result, expected)
    }

    func testDeviceUpsertForwardsIdempotentWriteContract() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:9847/engine")!
        )
        let input = NotificationDeviceUpsertDTO(
            installationId: "installation_1",
            clientServerId: "server_1",
            topic: "com.example.app",
            environment: .sandbox,
            authorizationStatus: .authorized,
            token: "token"
        )
        let key = EngineIdempotencyKey.userAction(
            "notification.repository.upsert"
        )
        let expected = NotificationDeviceRegistrationDTO(
            installationId: input.installationId,
            authorizationStatus: input.authorizationStatus,
            environment: input.environment,
            topic: input.topic,
            enabled: true,
            ready: true,
            registeredAt: "2026-07-27T00:00:00Z",
            transport: NotificationTransportReadinessDTO(
                mode: .relay,
                configured: true,
                problemCode: nil
            )
        )
        transport.writeHandler = {
            functionId,
            payload,
            idempotencyKey,
            options in
            XCTAssertEqual(
                functionId.rawValue,
                "worker_kernel::notification_device_upsert"
            )
            XCTAssertEqual(payload as? NotificationDeviceUpsertDTO, input)
            XCTAssertEqual(idempotencyKey, key)
            XCTAssertEqual(options.timeout, NotificationClient.requestTimeout)
            return expected
        }
        let repository = DefaultNotificationRepository(
            client: NotificationClient(transport: transport)
        )

        let result = try await repository.upsertDevice(
            input,
            idempotencyKey: key
        )

        XCTAssertEqual(result, expected)
    }
}
