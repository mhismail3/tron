import Foundation
import Testing
@testable import TronMobile

@Suite("Paired device catalog admission")
struct PairedDeviceCatalogPolicyTests {
    @Test("admits exact unique bounded records")
    func admitsBoundedRecords() throws {
        let devices = [
            PairedDevice(id: "one", name: "Phone", createdAt: "2026-08-16T10:00:00Z"),
            PairedDevice(id: "two", name: "Tablet", createdAt: "2026-08-16T10:01:00.123Z"),
        ]
        #expect(try PairedDeviceCatalogPolicy.admit(devices) == devices)
    }

    @Test("rejects duplicate, malformed, and oversized catalogs atomically")
    func rejectsInvalidCatalogs() {
        let valid = PairedDevice(id: "one", name: "Phone", createdAt: "2026-08-16T10:00:00Z")
        #expect(throws: GatewayFailure.self) {
            _ = try PairedDeviceCatalogPolicy.admit([valid, valid])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try PairedDeviceCatalogPolicy.admit([
                PairedDevice(id: "one", name: "Phone", createdAt: "not-a-date"),
            ])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try PairedDeviceCatalogPolicy.admit(Array(
                repeating: valid,
                count: PairedDeviceCatalogPolicy.maximumDevices + 1
            ))
        }
    }

    @Test("admits optional custom labels and rejects unsafe labels")
    func customLabelAdmission() throws {
        let labeled = PairedDevice(id: "one", name: "Work phone", customLabel: "Work phone", createdAt: "2026-08-16T10:00:00Z")
        #expect(try PairedDeviceCatalogPolicy.admit([labeled]) == [labeled])
        #expect(throws: GatewayFailure.self) {
            _ = try PairedDeviceCatalogPolicy.admit([
                PairedDevice(id: "one", name: "Phone", customLabel: "\u{0}", createdAt: "2026-08-16T10:00:00Z"),
            ])
        }
    }

    @Test("device name changes preserve row identity and duplicate display names remain distinct")
    func labelProjectionIdentity() throws {
        let original = PairedDevice(id: "one", name: "iPhone", createdAt: "2026-08-16T10:00:00Z")
        let renamed = PairedDevice(id: "one", name: "Work phone", customLabel: "Work phone", createdAt: original.createdAt)
        let other = PairedDevice(id: "two", name: "Work phone", createdAt: original.createdAt)
        #expect(try PairedDeviceCatalogPolicy.admit([renamed, other]).count == 2)
        let before = GatewayAuthorizedDevice(profileID: "server", profileLabel: "Mac", device: original)
        let after = GatewayAuthorizedDevice(profileID: "server", profileLabel: "Mac", device: renamed)
        #expect(before.id == after.id)
        #expect(try JSONDecoder.gateway.decode(PairedDevice.self, from: JSONEncoder.gateway.encode(renamed)) == renamed)
        let fallback = Data(#"{"id":"one","name":"iPhone","createdAt":"2026-08-16T10:00:00Z"}"#.utf8)
        #expect(try JSONDecoder.gateway.decode(PairedDevice.self, from: fallback).customLabel == nil)
    }

    @Test("iOS install projections are bounded and omit host CoreDevice identity")
    func iosInstallProjectionAdmission() throws {
        let configData = Data(#"{"schema":1,"kind":"tron-ios-device-install-config","deviceId":"device-one","gatewayChannel":"stable","sourceRoot":"/Users/example/tron","target":{"name":"Development iPhone","deviceType":"iPhone","connectionState":"connected","developerModeEnabled":true},"updatedAt":"2026-08-31T00:00:00.000Z"}"#.utf8)
        let config = try JSONDecoder().decode(IosDeviceInstallConfig.self, from: configData)
        #expect(config.target?.name == "Development iPhone")
        #expect(String(decoding: configData, as: UTF8.self).contains("identifier") == false)

        let statusData = Data(#"{"schema":2,"kind":"tron-ios-device-install-status","deviceId":"device-one","buildMode":"fast-debug","state":"running","commandId":"command-install-1","targetName":"Development iPhone","startedAt":"2026-08-31T00:00:00.000Z","updatedAt":"2026-08-31T00:00:01.000Z"}"#.utf8)
        let status = try JSONDecoder().decode(IosDeviceInstallStatus.self, from: statusData)
        #expect(status.state.isActive)
    }
}
