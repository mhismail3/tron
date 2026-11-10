import Foundation
import AppKit

final class SingleInstanceLock: @unchecked Sendable {
    private let lockFileURL: URL
    private var fileDescriptor: Int32 = -1
    private let mutex = NSLock()

    init(lockFileURL: URL = TronPaths.macWrapperLockPath) {
        self.lockFileURL = lockFileURL
    }

    @discardableResult
    func acquire() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }

        if fileDescriptor >= 0 {
            return true
        }

        ensureParentDirectoryExists()
        let fd = open(lockFileURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return false }

        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 0

        if fcntl(fd, F_SETLK, &fl) != 0 {
            close(fd)
            return false
        }

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
