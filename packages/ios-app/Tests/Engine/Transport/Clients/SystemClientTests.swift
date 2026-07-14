import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("SystemClient Tests")
struct SystemClientTests {

    @Test("getSystemInfo throws when engineConnection is nil")
    func getSystemInfoNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SystemClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.getSystemInfo()
        }
    }

    @Test("ping invokes system ping")
    func pingInvokesSystemPing() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        let client = SystemClient(transport: transport)

        transport.readHandler = { functionId, payload, _ in
            #expect(functionId.rawValue == "system::ping")
            #expect((payload as? SystemPingParams)?.protocolVersion == 1)
            return SystemPingResult(pong: true)
        }

        try await client.ping()
        #expect(transport.lastReadFunctionId?.rawValue == "system::ping")
    }

    @Test("device token registration uses trusted internal function and redacts response")
    func deviceTokenRegistrationUsesTrustedFunction() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:9847/engine")!
        )
        let client = SystemClient(transport: transport)

        transport.writeHandler = { functionId, payload, idempotencyKey, _ in
            #expect(functionId.rawValue == "device::register")
            let registration = try #require(payload as? DeviceRegistrationParams)
            #expect(registration.platform == "ios")
            #expect(registration.apnsToken == "0011aabb")
            #expect(registration.pushOptIn)
            #expect(registration.pushEnabled)
            #expect(idempotencyKey.rawValue.hasPrefix("ios:device-register:v4:"))
            #expect(!idempotencyKey.rawValue.contains("0011aabb"))
            return DeviceRegistrationResult(
                status: "active",
                idempotentReplay: false,
                apnsTokenRedacted: true,
                liveApnsEnabled: true
            )
        }

        let result = try await client.registerDeviceToken("0011aabb")
        #expect(result.apnsTokenRedacted)
        #expect(result.liveApnsEnabled)
        #expect(transport.lastWriteFunctionId?.rawValue == "device::register")
    }

    @Test("device installation identity is stable and isolated by defaults store")
    func deviceInstallationIdentityIsStableAndIsolated() {
        IsolatedTestState.withDefaults(label: "system-client-first") { firstDefaults in
            IsolatedTestState.withDefaults(label: "system-client-second") { secondDefaults in
                let first = DeviceInstallationIdentity.current(defaults: firstDefaults)
                #expect(DeviceInstallationIdentity.current(defaults: firstDefaults) == first)
                #expect(DeviceInstallationIdentity.current(defaults: secondDefaults) != first)
            }
        }
    }

    @Test("device registration idempotency is stable and installation-specific")
    func deviceRegistrationIdempotencyIsInstallationSpecific() {
        let first = DeviceRegistrationIdempotency.key(
            bundleId: "com.example.app",
            environment: "development",
            deviceId: "installation-a",
            token: "token"
        )
        let replay = DeviceRegistrationIdempotency.key(
            bundleId: "com.example.app",
            environment: "development",
            deviceId: "installation-a",
            token: "token"
        )
        let second = DeviceRegistrationIdempotency.key(
            bundleId: "com.example.app",
            environment: "development",
            deviceId: "installation-b",
            token: "token"
        )

        #expect(first == replay)
        #expect(first != second)
        #expect(!first.rawValue.contains("installation-a"))
        #expect(!first.rawValue.contains("token"))
    }

}
