import Foundation
import Testing
@testable import TronMac

@Suite("Single-instance lock")
struct SingleInstanceLockTests {
    @Test("a second process cannot acquire the held lock")
    func crossProcessExclusivity() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let path = root.appendingPathComponent("gateway.lock")
        let owner = SingleInstanceLock(lockFileURL: path)
        #expect(owner.acquire() == .acquired)
        defer { owner.release() }

        let contender = Process()
        contender.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        contender.arguments = [
            "-c",
            "import fcntl,sys; f=open(sys.argv[1],'r+');\ntry: fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB); sys.exit(1)\nexcept BlockingIOError: sys.exit(0)",
            path.path,
        ]
        try contender.run()
        contender.waitUntilExit()

        #expect(contender.terminationStatus == 0)
    }

    @Test("the lock records its owner and keeps a stable file")
    func stableOwnerFile() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let path = root.appendingPathComponent("nested/gateway.lock")
        let lock = SingleInstanceLock(lockFileURL: path)

        #expect(lock.acquire() == .acquired)
        let body = try String(contentsOf: path, encoding: .utf8)
        #expect(Int(body.trimmingCharacters(in: .whitespacesAndNewlines)) == Int(getpid()))
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        lock.release()
        lock.release()

        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("directory and open failures are typed")
    func filesystemFailuresAreTyped() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let blockingFile = root.appendingPathComponent("blocking")
        try Data().write(to: blockingFile)

        let directoryFailure = SingleInstanceLock(
            lockFileURL: blockingFile.appendingPathComponent("gateway.lock")
        )
        #expect(directoryFailure.acquire() == .failed(.createDirectory))

        let openFailure = SingleInstanceLock(lockFileURL: root)
        #expect(openFailure.acquire() == .failed(.openFile))
    }

    @Test("a lock path never follows a symbolic link")
    func symbolicLinkIsRejected() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let target = root.appendingPathComponent("target")
        let path = root.appendingPathComponent("gateway.lock")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)

        let lock = SingleInstanceLock(lockFileURL: path)
        #expect(lock.acquire() == .failed(.openFile))
        #expect(try String(contentsOf: target, encoding: .utf8) == "preserve")
    }
}
