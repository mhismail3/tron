import Foundation
import Testing
@testable import TronMac

@Suite("TronUninstaller — local state removal")
struct UninstallLocalStateTests {
    /// A requested reset that leaves a file behind must be reported, while an
    /// already absent file is a completed removal (#1086).
    @Test func reportsOnlyPathsThatRemainOnDisk() throws {
        let root = TestTempDir.make()
        let protectedDirectory = root.appendingPathComponent("protected", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedDirectory.path)
            TestTempDir.cleanup(root)
        }
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: true)
        let removable = root.appendingPathComponent("onboarded", isDirectory: false)
        let absent = root.appendingPathComponent("auth.lock", isDirectory: false)
        let protectedToken = protectedDirectory.appendingPathComponent("token", isDirectory: false)
        try Data("marker".utf8).write(to: removable)
        try Data("secret".utf8).write(to: protectedToken)
        // A read-only parent makes unlink fail with EACCES, as a locked or
        // foreign-owned credential directory would.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protectedDirectory.path)

        let remaining = TronUninstaller.removeLocalState(at: [removable, absent, protectedToken])

        #expect(remaining == [protectedToken])
        #expect(!FileManager.default.fileExists(atPath: removable.path))
        #expect(FileManager.default.fileExists(atPath: protectedToken.path))
    }
}
