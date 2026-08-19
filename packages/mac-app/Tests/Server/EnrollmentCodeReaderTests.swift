import Foundation
import Testing
@testable import TronMac

@Suite("Gateway enrollment code reader")
struct EnrollmentCodeReaderTests {
    @Test("admits an owner-only unexpired one-time code")
    func readsCurrentCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("enrollment.json")
        try #"{"version":1,"code":"ABCD-EFGH","expiresAt":"2030-01-01T00:00:00Z","machineId":"machine"}"#.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        #expect(EnrollmentCodeReader.read(at: file, now: Date(timeIntervalSince1970: 1_700_000_000)) == "ABCD-EFGH")
    }

    @Test("admits gateway timestamps with fractional seconds")
    func readsFractionalSecondTimestamp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("enrollment.json")
        try #"{"version":1,"code":"ABCD-EFGH","expiresAt":"2030-01-01T00:00:00.123Z","machineId":"machine"}"#.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        #expect(EnrollmentCodeReader.read(at: file, now: Date(timeIntervalSince1970: 1_700_000_000)) == "ABCD-EFGH")
    }

    @Test("rejects expired or group-readable enrollment files")
    func rejectsUnsafeCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("enrollment.json")
        try #"{"version":1,"code":"ABCD-EFGH","expiresAt":"2020-01-01T00:00:00Z","machineId":"machine"}"#.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        #expect(EnrollmentCodeReader.read(at: file) == nil)
    }
}
