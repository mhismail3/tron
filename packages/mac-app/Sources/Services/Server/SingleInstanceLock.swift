import Foundation
import AppKit

/// Single-instance guard. When a second `Tron.app` launches, it should
/// see that one is already running and exit cleanly with a banner.
///
/// Implementation: exclusive `fcntl(F_SETLK, F_WRLCK)` advisory lock on
/// `~/.tron/system/run/.mac-wrapper.lock`. The kernel cleans up the lock on
/// process exit (including crash), so we don't have to worry about
/// stale lockfiles. The PID is written to the file body so `tron
/// status` can report "held by PID 12345".
///
/// Tests in `Tests/Services/SingleInstanceLockTests.swift` validate
/// the file-lock semantics in isolation; AppKit-side tests are skipped
/// by default since they require a running NSApplication.
///
/// `@unchecked Sendable` because the mutable state (`fileDescriptor`)
/// is guarded by an `NSLock`. Using a plain mutex (not GCD's
/// `queue.sync`) avoids blocking the main thread on a private serial
/// queue when `acquire`/`release` is called from MainActor — the
/// previous design did `DispatchQueue.sync` from main, which works but
/// imposes unnecessary GCD overhead for a single-shot file-lock op.
final class SingleInstanceLock: @unchecked Sendable {
    static let shared = SingleInstanceLock()

    private let lockFileURL: URL
    private var fileDescriptor: Int32 = -1
    private let mutex = NSLock()

    init(lockFileURL: URL = TronPaths.macWrapperLockPath) {
        self.lockFileURL = lockFileURL
    }

    /// Attempts to acquire the lock. Returns true on success (this
    /// process owns the lock), false if another process holds it.
    @discardableResult
    func acquire() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }

        // Idempotent — re-acquiring the lock from the same process is
        // a no-op success. Without this, AppDelegate restarts (rare,
        // but possible during XCUITest reruns) would falsely fail.
        if fileDescriptor >= 0 {
            return true
        }

        ensureParentDirectoryExists()
        let fd = open(lockFileURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return false }

        // F_SETLK with F_WRLCK is the POSIX-portable equivalent of
        // flock LOCK_EX | LOCK_NB. Fails immediately if another
        // process holds an incompatible lock.
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 0

        if fcntl(fd, F_SETLK, &fl) != 0 {
            close(fd)
            return false
        }

        // Stash our PID into the file so `tron status` can show "held by PID 12345".
        ftruncate(fd, 0)
        let pidString = "\(getpid())\n"
        _ = pidString.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }

        self.fileDescriptor = fd
        return true
    }

    func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard fileDescriptor >= 0 else { return }

        var fl = flock()
        fl.l_type = Int16(F_UNLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 0
        _ = fcntl(fileDescriptor, F_SETLK, &fl)

        close(fileDescriptor)
        fileDescriptor = -1
    }

    private func ensureParentDirectoryExists() {
        let parent = lockFileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }
}
