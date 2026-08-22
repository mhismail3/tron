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

    @Test("rejects symlinks, directories, oversized files, and unknown keys")
    func rejectsUnsafeShapes() throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let target = root.appendingPathComponent("target.json")
        let valid = #"{"version":1,"code":"ABCD-EFGH","expiresAt":"2030-01-01T00:00:00Z","machineId":"machine"}"#
        try Data(valid.utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(EnrollmentCodeReader.read(at: link) == nil)
        let directory = root.appendingPathComponent("directory.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(EnrollmentCodeReader.read(at: directory) == nil)
        let unknown = root.appendingPathComponent("unknown.json")
        try Data(#"{"version":1,"code":"ABCD-EFGH","expiresAt":"2030-01-01T00:00:00Z","machineId":"machine","extra":true}"#.utf8).write(to: unknown)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unknown.path)
        #expect(EnrollmentCodeReader.read(at: unknown) == nil)
        let oversized = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: 65 * 1024).write(to: oversized)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oversized.path)
        #expect(EnrollmentCodeReader.read(at: oversized) == nil)
    }

}
