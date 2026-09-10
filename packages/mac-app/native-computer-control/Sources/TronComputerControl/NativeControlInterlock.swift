import Foundation
import Darwin
import os

// This is deliberately internal. The future trusted native lifetime owner is the
// only caller that may admit or recover a native-control lease.
internal enum NativeControlInterlockError: Error, Equatable, CustomStringConvertible {
    case invalidRoot(String)
    case invalidLock(String)
    case lockBusy
    case quarantinePresent
    case quarantineAbsent
    case unsafeQuarantine(String)
    case malformedQuarantine
    case wrongQuarantineIdentity
    case alreadyArmed
    case alreadyClosed
    case notArmed
    case markerPersistenceFailed(String)
    case markerRemovalFailed(String)
    case io(String, Int32)
    case descriptorCleanup(primary: String?, failures: [String])

    var description: String {
        switch self {
        case let .invalidRoot(reason): "invalid native-control root: \(reason)"
        case let .invalidLock(reason): "invalid native-control lock: \(reason)"
        case .lockBusy: "native-control root is busy"
        case .quarantinePresent: "native-control quarantine marker is present"
        case .quarantineAbsent: "native-control quarantine marker is absent"
        case let .unsafeQuarantine(reason): "unsafe native-control quarantine marker: \(reason)"
        case .malformedQuarantine: "malformed native-control quarantine marker"
        case .wrongQuarantineIdentity: "native-control quarantine identity does not match"
        case .alreadyArmed: "native-control lease is already armed"
        case .alreadyClosed: "native-control lease is closed"
        case .notArmed: "native-control lease is not armed"
        case let .markerPersistenceFailed(reason): "could not durably persist quarantine marker: \(reason)"
        case let .markerRemovalFailed(reason): "could not durably remove quarantine marker: \(reason)"
        case let .io(operation, code): "\(operation) failed (errno \(code))"
        case let .descriptorCleanup(primary, failures):
            ([primary].compactMap { $0 } + failures).joined(separator: "; ")
        }
    }
}

internal struct NativeControlQuarantineIdentity: Equatable, Sendable {
    let rawValue: String

    init(random: Void = ()) {
        rawValue = UUID().uuidString.lowercased()
    }

    init(rawValue: String) throws {
        guard rawValue.count == 36, UUID(uuidString: rawValue) != nil,
              rawValue == rawValue.lowercased() else {
            throw NativeControlInterlockError.malformedQuarantine
        }
        self.rawValue = rawValue
    }
}

/// A host-owned directory descriptor and its fixed, relative interlock names.
/// There is no native-home default: trusted host code supplies the root URL.
internal final class NativeControlInterlockRoot: @unchecked Sendable {
    static let lockName = "native-control.lock"
    static let markerName = "native-control.quarantine"
    static let markerPrefix = "tron-native-control-quarantine/v1/"
    static let maximumMarkerBytes = 128

    enum DescriptorKind: String, Sendable { case root, lock, marker }
    typealias DescriptorClose = @Sendable (Int32, DescriptorKind) -> Int32
    private static let logger = Logger(subsystem: "com.tron.computer-control", category: "interlock")
    private let descriptor: Int32
    private let descriptorClose: DescriptorClose

    // The internal FFI seam permits exercising late close errors without manipulating
    // unrelated descriptors. A closer consumes its descriptor once; it must not retry.
    internal init(rootURL: URL,
                  descriptorClose: @escaping DescriptorClose = { descriptor, _ in Darwin.close(descriptor) }) throws {
        guard rootURL.isFileURL else {
            throw NativeControlInterlockError.invalidRoot("not a file URL")
        }
        let descriptor: Int32 = rootURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw NativeControlInterlockError.io("open native-control root", errno)
        }
        do {
            try Self.validateRoot(descriptor)
            self.descriptor = descriptor
            self.descriptorClose = descriptorClose
        } catch {
            throw Self.combining(error, cleanup: Self.closeOwned(descriptor, kind: .root, using: descriptorClose))
        }
    }

    deinit { Self.reportDeinitCleanup(Self.closeOwned(descriptor, kind: .root, using: descriptorClose)) }

    /// Ordinary admission never interprets or repairs an existing marker.
    internal func acquire() throws -> NativeControlInterlockLease {
        let lock = try openAndValidateLock()
        do {
            try Self.takeExclusiveLock(lock)
            guard try inspectMarker() == nil else {
                throw NativeControlInterlockError.quarantinePresent
            }
            return NativeControlInterlockLease(root: self, lockDescriptor: lock)
        } catch {
            throw Self.combining(error, cleanup: closeOwnedLock(lock))
        }
    }

    /// Explicit recovery is an internal primitive for a later trusted owner. It
    /// never starts input and refuses every marker except the exact admitted one.
    internal func recoverExpectedMarker(_ expected: NativeControlQuarantineIdentity) throws {
        let lock = try openAndValidateLock()
        try withClosedDescriptor(lock, kind: .lock) {
            try Self.takeExclusiveLock(lock)
            try clearExpectedMarker(expected)
        }
    }

    /// The caller must already hold this root's flock. Keeping the check and
    /// unlink in the same helper makes clean retirement and crash recovery use
    /// exactly the same fail-closed marker proof.
    fileprivate func clearExpectedMarker(_ expected: NativeControlQuarantineIdentity, createdFile: stat? = nil) throws {
        guard let marker = try inspectMarker() else {
            throw NativeControlInterlockError.quarantineAbsent
        }
        guard marker.identity == expected else {
            throw NativeControlInterlockError.wrongQuarantineIdentity
        }
        if let createdFile, !Self.sameFile(createdFile, marker.status) {
            throw NativeControlInterlockError.unsafeQuarantine("armed marker was replaced")
        }
        let currentStatus = try markerStatusAtPath()
        try Self.validateMarkerStatus(currentStatus)
        guard Self.sameFile(marker.status, currentStatus) else {
            throw NativeControlInterlockError.unsafeQuarantine("marker changed during inspection")
        }
        guard unlinkat(descriptor, Self.markerName, 0) == 0 else {
            throw NativeControlInterlockError.markerRemovalFailed(Self.errnoDescription("unlink marker"))
        }
        // Removal must be observable as a failed recovery if the directory flush
        // cannot complete; a later process must not be told recovery succeeded.
        guard fsync(descriptor) == 0 else {
            throw NativeControlInterlockError.markerRemovalFailed(Self.errnoDescription("flush root"))
        }
        do {
            guard try inspectMarker() == nil else {
                throw NativeControlInterlockError.markerRemovalFailed("marker remains or was replaced")
            }
        } catch let error as NativeControlInterlockError {
            if case .markerRemovalFailed = error { throw error }
            throw NativeControlInterlockError.markerRemovalFailed(error.description)
        } catch {
            throw NativeControlInterlockError.markerRemovalFailed(String(describing: error))
        }
    }

    private func openAndValidateLock() throws -> Int32 {
        let lock = openat(descriptor, Self.lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard lock >= 0 else {
            throw NativeControlInterlockError.io("open native-control lock", errno)
        }
        do {
            try Self.validateLock(lock)
            return lock
        } catch {
            throw Self.combining(error, cleanup: closeOwnedLock(lock))
        }
    }

    private static func takeExclusiveLock(_ lock: Int32) throws {
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw NativeControlInterlockError.lockBusy
            }
            throw NativeControlInterlockError.io("flock native-control lock", errno)
        }
    }

    private static func validateRoot(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw NativeControlInterlockError.io("stat native-control root", errno)
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw NativeControlInterlockError.invalidRoot("not a directory")
        }
        guard status.st_uid == geteuid() else {
            throw NativeControlInterlockError.invalidRoot("owner mismatch")
        }
        guard status.st_nlink >= 2 else {
            throw NativeControlInterlockError.invalidRoot("unexpected hard-link count")
        }
        guard status.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw NativeControlInterlockError.invalidRoot("mode is not owner-only 0700")
        }
    }

    private static func validateLock(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw NativeControlInterlockError.io("stat native-control lock", errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw NativeControlInterlockError.invalidLock("not a regular file")
        }
        guard status.st_uid == geteuid() else {
            throw NativeControlInterlockError.invalidLock("owner mismatch")
        }
        guard status.st_nlink == 1 else {
            throw NativeControlInterlockError.invalidLock("unexpected hard-link count")
        }
        guard status.st_mode & mode_t(0o7777) == mode_t(0o600) else {
            throw NativeControlInterlockError.invalidLock("mode is not owner-only 0600")
        }
        guard status.st_size == 0 else {
            throw NativeControlInterlockError.invalidLock("lock file is not empty")
        }
    }

    private struct MarkerInspection {
        let identity: NativeControlQuarantineIdentity
        let status: stat
    }

    private func markerStatusAtPath() throws -> stat {
        var status = stat()
        guard fstatat(descriptor, Self.markerName, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw NativeControlInterlockError.io("stat quarantine marker", errno)
        }
        return status
    }

    /// nil means absent. Any present but unsafe or malformed marker throws and
    /// therefore remains fail-closed for both ordinary and recovery admission.
    private func inspectMarker() throws -> MarkerInspection? {
        var pathStatus = stat()
        guard fstatat(descriptor, Self.markerName, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw NativeControlInterlockError.unsafeQuarantine(Self.errnoDescription("stat marker"))
        }
        try Self.validateMarkerStatus(pathStatus)

        let marker = openat(descriptor, Self.markerName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard marker >= 0 else {
            throw NativeControlInterlockError.unsafeQuarantine(Self.errnoDescription("open marker"))
        }
        return try withClosedDescriptor(marker, kind: .marker) {
        var openedStatus = stat()
        guard fstat(marker, &openedStatus) == 0 else {
            throw NativeControlInterlockError.io("stat opened marker", errno)
        }
        try Self.validateMarkerStatus(openedStatus)
        guard Self.sameFile(pathStatus, openedStatus), pathStatus.st_size == openedStatus.st_size else {
            throw NativeControlInterlockError.unsafeQuarantine("marker changed during inspection")
        }

        let length = Int(openedStatus.st_size)
        var bytes = [UInt8](repeating: 0, count: length)
        var offset = 0
        while offset < length {
            let count = bytes.withUnsafeMutableBytes { storage in
                read(marker, storage.baseAddress!.advanced(by: offset), length - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw NativeControlInterlockError.malformedQuarantine
            }
            offset += count
        }
        var extra: UInt8 = 0
        guard read(marker, &extra, 1) == 0 else {
            throw NativeControlInterlockError.unsafeQuarantine("marker grew during inspection")
        }
        var finalStatus = stat()
        guard fstat(marker, &finalStatus) == 0 else {
            throw NativeControlInterlockError.io("restat opened marker", errno)
        }
        try Self.validateMarkerStatus(finalStatus)
        guard Self.sameFile(openedStatus, finalStatus), finalStatus.st_size == openedStatus.st_size else {
            throw NativeControlInterlockError.unsafeQuarantine("marker changed during read")
        }
        guard let text = String(bytes: bytes, encoding: .utf8),
              text.hasPrefix(Self.markerPrefix) else {
            throw NativeControlInterlockError.malformedQuarantine
        }
        let rawIdentity = String(text.dropFirst(Self.markerPrefix.count))
        let identity = try NativeControlQuarantineIdentity(rawValue: rawIdentity)
        return MarkerInspection(identity: identity, status: openedStatus)
        }
    }

    private static func validateMarkerStatus(_ status: stat) throws {
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_nlink == 1,
              status.st_mode & mode_t(0o7777) == mode_t(0o600) else {
            throw NativeControlInterlockError.unsafeQuarantine("shape, owner, mode, or hard-link count")
        }
        guard status.st_size >= 0, status.st_size <= off_t(maximumMarkerBytes) else {
            throw NativeControlInterlockError.unsafeQuarantine("marker exceeds bounded size")
        }
    }

    fileprivate func writeMarker(_ identity: NativeControlQuarantineIdentity) throws -> stat {
        let payload = Data((Self.markerPrefix + identity.rawValue).utf8)
        let marker = openat(descriptor, Self.markerName,
                            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard marker >= 0 else {
            throw NativeControlInterlockError.markerPersistenceFailed(Self.errnoDescription("create marker"))
        }
        // Any failure leaves the uncertain marker in place; never silently repair it.
        return try withClosedDescriptor(marker, kind: .marker) {
            try payload.withUnsafeBytes { storage in
                var offset = 0
                while offset < storage.count {
                    let count = write(marker, storage.baseAddress!.advanced(by: offset), storage.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw NativeControlInterlockError.markerPersistenceFailed(Self.errnoDescription("write marker"))
                    }
                    offset += count
                }
            }
            guard fsync(marker) == 0 else {
                throw NativeControlInterlockError.markerPersistenceFailed(Self.errnoDescription("flush marker"))
            }
            guard fsync(descriptor) == 0 else {
                throw NativeControlInterlockError.markerPersistenceFailed(Self.errnoDescription("flush root"))
            }
            var status = stat()
            guard fstat(marker, &status) == 0 else {
                throw NativeControlInterlockError.io("stat armed marker", errno)
            }
            try Self.validateMarkerStatus(status)
            guard status.st_size == payload.count else {
                throw NativeControlInterlockError.markerPersistenceFailed("unexpected marker size")
            }
            return status
        }
    }

    fileprivate func closeOwnedLock(_ descriptor: Int32) -> NativeControlInterlockError? {
        Self.closeOwned(descriptor, kind: .lock, using: descriptorClose)
    }

    private func withClosedDescriptor<T>(_ descriptor: Int32, kind: DescriptorKind,
                                         body: () throws -> T) throws -> T {
        let result = Result { try body() }
        let cleanup = Self.closeOwned(descriptor, kind: kind, using: descriptorClose)
        switch result {
        case let .success(value):
            if let cleanup { throw cleanup }
            return value
        case let .failure(error): throw Self.combining(error, cleanup: cleanup)
        }
    }

    // Unlock the owned file description explicitly, then close exactly once. Retrying
    // close after an error can close a recycled descriptor. These are unguarded POSIX
    // descriptors; Swift Task cancellation is not pthread cancellation of a syscall.
    private static func closeOwned(_ descriptor: Int32, kind: DescriptorKind,
                                   using closeDescriptor: DescriptorClose) -> NativeControlInterlockError? {
        var failures: [String] = []
        if kind == .lock, flock(descriptor, LOCK_UN) != 0 {
            failures.append("unlock owned lock failed (errno \(errno))")
        }
        if closeDescriptor(descriptor, kind) != 0 {
            failures.append("close owned \(kind.rawValue) failed (errno \(errno))")
        }
        return failures.isEmpty ? nil : .descriptorCleanup(primary: nil, failures: failures)
    }

    fileprivate static func combining(_ primary: any Error,
                                      cleanup: NativeControlInterlockError?) -> any Error {
        guard let cleanup else { return primary }
        return NativeControlInterlockError.descriptorCleanup(
            primary: String(describing: primary), failures: [cleanup.description])
    }

    fileprivate static func reportDeinitCleanup(_ error: NativeControlInterlockError?) {
        if let error { logger.error("Owned descriptor cleanup failed: \(error.description, privacy: .public)") }
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func errnoDescription(_ operation: String) -> String {
        "\(operation) failed (errno \(errno))"
    }
}

/// One synchronous physical-resource lease. It only gates a future native
/// owner; it does not post events, verify quiescence, or represent authorization.
// Every mutable field and descriptor close is serialized by stateLock. The root
// descriptor is immutable and marker operations run under this lease's flock.
internal final class NativeControlInterlockLease: @unchecked Sendable {
    private enum State {
        case unarmed
        case armed(NativeControlQuarantineIdentity, stat)
        case closed(clean: Bool, error: (any Error)?)
    }

    private let stateLock = NSLock()
    private let root: NativeControlInterlockRoot
    private var lockDescriptor: Int32?
    private var state: State = .unarmed

    fileprivate init(root: NativeControlInterlockRoot, lockDescriptor: Int32) {
        self.root = root
        self.lockDescriptor = lockDescriptor
    }

    internal func arm() throws -> NativeControlQuarantineIdentity {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .unarmed = state else {
            if case .closed = state { throw NativeControlInterlockError.alreadyClosed }
            throw NativeControlInterlockError.alreadyArmed
        }
        let identity = NativeControlQuarantineIdentity()
        do {
            let createdFile = try root.writeMarker(identity)
            state = .armed(identity, createdFile)
            return identity
        } catch {
            throw closeAfterFailure(error)
        }
    }

    /// Repeated retirement is an idempotent join: the state lock is held across
    /// every descriptor close, so no caller returns while another close is live.
    internal func retire() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if case let .closed(_, error) = state {
            if let error { throw error }
            return
        }
        let closeError = closeDescriptorsLocked()
        state = .closed(clean: false, error: closeError)
        if let closeError { throw closeError }
    }

    /// Only the later trusted native owner may call this after it has verified
    /// actual native release. The identity is checked against durable bytes
    /// while this lease still owns the flock; this method itself is not release
    /// evidence and is intentionally internal rather than model-callable.
    internal func retireAfterTrustedNativeRelease() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if case let .closed(clean, error) = state {
            if let error { throw error }
            guard clean else { throw NativeControlInterlockError.alreadyClosed }
            return
        }
        guard case let .armed(identity, createdFile) = state else {
            throw NativeControlInterlockError.notArmed
        }
        guard lockDescriptor != nil else {
            state = .closed(clean: false, error: NativeControlInterlockError.alreadyClosed)
            throw NativeControlInterlockError.alreadyClosed
        }
        do {
            try root.clearExpectedMarker(identity, createdFile: createdFile)
        } catch {
            throw closeAfterFailure(error)
        }
        let closeError = closeDescriptorsLocked()
        state = .closed(clean: true, error: closeError)
        if let closeError { throw closeError }
    }

    deinit {
        stateLock.lock()
        let cleanup = closeDescriptorsLocked()
        state = .closed(clean: false, error: cleanup)
        stateLock.unlock()
        NativeControlInterlockRoot.reportDeinitCleanup(cleanup)
    }

    private func closeAfterFailure(_ error: any Error) -> any Error {
        let combined = NativeControlInterlockRoot.combining(error, cleanup: closeDescriptorsLocked())
        state = .closed(clean: false, error: combined)
        return combined
    }

    @discardableResult
    private func closeDescriptorsLocked() -> NativeControlInterlockError? {
        guard let descriptor = lockDescriptor else { return nil }
        lockDescriptor = nil
        return root.closeOwnedLock(descriptor)
    }
}
