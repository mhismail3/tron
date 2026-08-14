import Darwin
import Foundation

enum SingleInstanceLockFailure: Equatable, Sendable {
    case createDirectory
    case openFile
    case invalidFile
    case securePermissions
    case acquireKernelLock
    case writeOwner
}

enum SingleInstanceLockAcquisition: Equatable, Sendable {
    case acquired
    case heldByAnotherProcess
    case failed(SingleInstanceLockFailure)
}

/// Process-scoped advisory lock for one wrapper bundle identity.
/// The stable lock file is never unlinked while its descriptor is held.
final class SingleInstanceLock: @unchecked Sendable {
    private let lockFileURL: URL
    private var fileDescriptor: Int32 = -1
    private let mutex = NSLock()

    init(lockFileURL: URL = GatewayPaths.liveConfiguration.wrapperLockPath) {
        self.lockFileURL = lockFileURL
    }

    @discardableResult
    func acquire() -> SingleInstanceLockAcquisition {
        mutex.lock()
        defer { mutex.unlock() }
        if fileDescriptor >= 0 { return .acquired }

        do {
            try FileManager.default.createDirectory(
                at: lockFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failed(.createDirectory)
        }

        let descriptor = open(lockFileURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return .failed(.openFile) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid() else {
            close(descriptor)
            return .failed(.invalidFile)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            return .failed(.securePermissions)
        }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        guard fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let lockError = errno
            close(descriptor)
            return lockError == EACCES || lockError == EAGAIN
                ? .heldByAnotherProcess
                : .failed(.acquireKernelLock)
        }

        let owner = Data("\(getpid())\n".utf8)
        guard ftruncate(descriptor, 0) == 0,
              writeAll(owner, descriptor: descriptor),
              fsync(descriptor) == 0 else {
            unlockAndClose(descriptor)
            return .failed(.writeOwner)
        }

        fileDescriptor = descriptor
        return .acquired
    }

    func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard fileDescriptor >= 0 else { return }
        unlockAndClose(fileDescriptor)
        fileDescriptor = -1
    }

    private func writeAll(_ data: Data, descriptor: Int32) -> Bool {
        var succeeded = true
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else {
                    succeeded = false
                    return
                }
                offset += count
            }
        }
        return succeeded
    }

    private func unlockAndClose(_ descriptor: Int32) {
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        _ = fcntl(descriptor, F_SETLK, &lock)
        close(descriptor)
    }
}
