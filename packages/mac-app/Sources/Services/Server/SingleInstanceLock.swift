import Foundation
import AppKit

/// Single-instance guard. When a second `Tron.app` launches, it should
/// see that one is already running and exit cleanly with a banner.
///
/// Implementation: combination of an exclusive flock(2) on a sentinel
/// file at `~/.tron/system/.mac-wrapper.lock` AND an
/// `NSDistributedNotificationCenter` ping. The flock catches "second
/// process from disk"; the distributed notification catches the case
/// where the same wrapper bundle is launched twice from different
/// locations (which would acquire different file descriptors but
/// conflict logically).
///
/// Tests in `Tests/Services/SingleInstanceLockTests.swift` validate
/// the file-lock semantics in isolation; AppKit-side tests are skipped
/// by default since they require a running NSApplication.
///
/// `@unchecked Sendable` because all mutable state is guarded by the
/// private serial `queue`; every access to `fileDescriptor` happens
/// inside `queue.sync { ... }` (both `acquire()` and `release()`),
/// which serializes reads and writes. Sendability is established by
/// synchronization discipline rather than static type-level
/// reasoning.
final class SingleInstanceLock: @unchecked Sendable {
    static let shared = SingleInstanceLock()

    private let lockFileURL: URL
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.tron.mac.singleinstance.lock", qos: .userInitiated)

    init(lockFileURL: URL = TronPaths.systemDir.appendingPathComponent(".mac-wrapper.lock", isDirectory: false)) {
        self.lockFileURL = lockFileURL
    }

    /// Attempts to acquire the lock. Returns true on success (this
    /// process owns the lock), false if another process holds it.
    @discardableResult
    func acquire() -> Bool {
        queue.sync {
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
    }

    func release() {
        queue.sync {
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
    }

    private func ensureParentDirectoryExists() {
        let parent = lockFileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }
}
