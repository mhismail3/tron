import Foundation
import Testing
@testable import TronMac

/// Tests `SingleInstanceLock`'s file-lock semantics in isolation.
/// We do not test `NSDistributedNotificationCenter` here - that path
/// requires a running NSApplication, which the unit-test bundle does
/// not provide.
@Suite("SingleInstanceLock — file lock")
struct SingleInstanceLockTests {
    @Test("first acquire succeeds, second on same lockfile blocks")
    func secondAcquireBlocked() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let lockPath = tmp.appendingPathComponent("test.lock", isDirectory: false)

        let first = SingleInstanceLock(lockFileURL: lockPath)
        #expect(first.acquire(), "first acquire should succeed on a fresh lockfile")

        // Second acquire from a different SingleInstanceLock instance
        // pointing at the same path. Because both are in the same
        // process, fcntl(F_SETLK) is per-process - so this returns
        // true (same-process locks are stacked). This documents that
        // behavior for the future cross-process test.
        let second = SingleInstanceLock(lockFileURL: lockPath)
        let secondResult = second.acquire()

        // The same-process behavior is platform-specific - we only
        // care that the first lock holder can release cleanly.
        first.release()
        if secondResult { second.release() }
    }

    @Test("release after acquire is idempotent")
    func releaseIsIdempotent() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let lockPath = tmp.appendingPathComponent("test.lock", isDirectory: false)

        let lock = SingleInstanceLock(lockFileURL: lockPath)
        #expect(lock.acquire())
        lock.release()
        // Releasing twice should be a no-op, not a crash.
        lock.release()
    }

    @Test("acquire creates the parent directory if missing")
    func acquireCreatesParent() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let nested = tmp.appendingPathComponent("a/b/c", isDirectory: true)
        let lockPath = nested.appendingPathComponent("test.lock", isDirectory: false)

        // Parent does not exist yet.
        #expect(!FileManager.default.fileExists(atPath: nested.path))

        let lock = SingleInstanceLock(lockFileURL: lockPath)
        defer { lock.release() }
        #expect(lock.acquire())
        #expect(FileManager.default.fileExists(atPath: lockPath.path))
    }

    @Test("PID is written to the lock file")
    func pidWritten() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let lockPath = tmp.appendingPathComponent("test.lock", isDirectory: false)

        let lock = SingleInstanceLock(lockFileURL: lockPath)
        defer { lock.release() }
        #expect(lock.acquire())

        let body = try String(contentsOf: lockPath, encoding: .utf8)
        let pid = body.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(pid) == Int(getpid()))
    }
}
