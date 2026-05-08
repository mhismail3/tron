import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("MiscClient Tests")
struct MiscClientTests {

    @Test("getSystemInfo throws when engineConnection is nil")
    func getSystemInfoNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MiscClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.getSystemInfo()
        }
    }

    // MARK: - Device token registration (bundle_id flow)

    @Test("DeviceTokenRegisterParams encodes bundleId on the wire")
    func paramsEncodeBundleId() throws {
        // *** Regression guard for the 2026-04-16 DeviceTokenNotForTopic bug ***
        // If this test fails, the iOS app stopped sending the bundle ID
        // to the server and the relay will revert to its single-bundle
        // default — breaking the Beta scheme.
        let params = DeviceTokenRegisterParams(
            deviceToken: String(repeating: "a", count: 64),
            sessionId: nil,
            workspaceId: nil,
            environment: "sandbox",
            bundleId: "com.tron.mobile.beta"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["bundleId"] as? String == "com.tron.mobile.beta")
        #expect(json?["environment"] as? String == "sandbox")
        #expect(json?["deviceToken"] as? String == String(repeating: "a", count: 64))
    }

    @Test("DeviceTokenRegisterParams preserves optional session/workspace")
    func paramsEncodeOptionalFields() throws {
        let params = DeviceTokenRegisterParams(
            deviceToken: "xyz",
            sessionId: "sess_1",
            workspaceId: "ws_1",
            environment: "production",
            bundleId: "com.tron.mobile"
        )
        let data = try JSONEncoder().encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["sessionId"] as? String == "sess_1")
        #expect(json?["workspaceId"] as? String == "ws_1")
        #expect(json?["bundleId"] as? String == "com.tron.mobile")
    }

    @Test("registerDeviceToken throws when not connected")
    func registerDeviceTokenNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MiscClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            try await client.registerDeviceToken(
                String(repeating: "a", count: 64),
                idempotencyKey: .userAction("device.register.test")
            )
        }
    }
}
