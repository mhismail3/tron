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
}
