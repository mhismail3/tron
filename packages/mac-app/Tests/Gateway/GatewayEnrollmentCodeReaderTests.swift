import Foundation
import Testing
@testable import TronMac

@Suite("Gateway enrollment code reader")
struct GatewayEnrollmentCodeReaderTests {
    @Test("admits an owner-only unexpired one-time code")
    func readsCurrentCode() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let file = root.appendingPathComponent("enrollment.json")
        try #"{"version":1,"code":"ABCD-EFGH","expiresAt":"2030-01-01T00:00:00Z","machineId":"machine"}"#.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        #expect(GatewayEnrollmentCodeReader.read(at: file, now: Date(timeIntervalSince1970: 1_700_000_000)) == "ABCD-EFGH")
    }

    @Test("rejects expired or group-readable enrollment files")
    func rejectsUnsafeCode() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let file = root.appendingPathComponent("enrollment.json")
        try #"{"version":1,"code":"ABCD-EFGH","expiresAt":"2020-01-01T00:00:00Z","machineId":"machine"}"#.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        #expect(GatewayEnrollmentCodeReader.read(at: file) == nil)
    }
}
