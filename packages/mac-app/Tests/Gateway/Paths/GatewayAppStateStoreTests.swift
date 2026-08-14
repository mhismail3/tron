import Foundation
import Testing
@testable import TronMac

@Suite("Gateway app state store")
struct GatewayAppStateStoreTests {
    @Test("state is atomically written owner-only and round-trips")
    func roundTrip() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let path = root.appendingPathComponent("gateway/mac-app-state.json")
        let store = FileGatewayStateStore(path: path)
        let state = GatewayAppState(
            onboardingCompleted: true,
            preparedVersion: GatewayTestDependencies.version
        )

        try store.write(state)

        #expect(store.read() == .valid(state))
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: path.deletingLastPathComponent().path
        )
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: path.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(siblings.map(\.lastPathComponent) == ["mac-app-state.json"])
    }

    @Test("missing and corrupt records are distinct")
    func missingAndCorrupt() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let path = root.appendingPathComponent("gateway/mac-app-state.json")
        let store = FileGatewayStateStore(path: path)
        #expect(store.read() == .missing)

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        #expect(store.read() == .corrupt)

        let unsupported = GatewayAppState(
            onboardingCompleted: true,
            preparedVersion: GatewayTestDependencies.version,
            schemaVersion: 99
        )
        try JSONEncoder().encode(unsupported).write(to: path)
        #expect(store.read() == .corrupt)
    }

    @Test("overly broad file permissions are rejected")
    func permissionsAreRequired() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let path = root.appendingPathComponent("gateway/mac-app-state.json")
        let store = FileGatewayStateStore(path: path)
        let state = GatewayAppState(
            onboardingCompleted: true,
            preparedVersion: GatewayTestDependencies.version
        )
        try store.write(state)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)

        #expect(store.read() == .corrupt)
    }

    @Test("removal is idempotent")
    func removalIsIdempotent() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let path = root.appendingPathComponent("gateway/mac-app-state.json")
        let store = FileGatewayStateStore(path: path)

        try store.remove()
        try store.write(GatewayAppState(
            onboardingCompleted: false,
            preparedVersion: GatewayTestDependencies.version
        ))
        try store.remove()
        try store.remove()

        #expect(store.read() == .missing)
    }
}
