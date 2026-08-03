import Darwin
import Foundation

/// Owner-only Unix-socket framing and peer validation for the signed Mac
/// Operator host. It has no action semantics and owns no long-lived descriptor.
enum MacOperatorSocketTransport {
    static func createListener(at socketURL: URL) throws -> Int32 {
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw MacOperatorHostBridgeError.invalidSocketPath
        }
        let parent = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(parent.path, 0o700) == 0 else {
            throw MacOperatorHostBridgeError.unsafeSocketPath
        }
        try removeStaleSocket(at: socketURL)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw MacOperatorHostBridgeError.socketCreationFailed
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        do {
            try bindSocket(descriptor, path: path)
            guard Darwin.listen(descriptor, 4) == 0 else {
                throw MacOperatorHostBridgeError.socketListenFailed
            }
            guard chmod(path, 0o600) == 0 else {
                throw MacOperatorHostBridgeError.unsafeSocketPath
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: socketURL)
            throw error
        }
    }

    static func readRequest(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw MacOperatorProtocolError.invalidJSON
            }
            data.append(buffer, count: count)
            if data.count > MacOperatorProtocol.maximumRequestBytes {
                throw MacOperatorProtocolError.oversized
            }
        }
        guard !data.isEmpty else {
            throw MacOperatorProtocolError.invalidJSON
        }
        return data
    }

    static func write(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.send(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset,
                    MSG_NOSIGNAL
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
        Darwin.shutdown(descriptor, SHUT_WR)
    }

    static func isCurrentUserPeer(_ descriptor: Int32) -> Bool {
        var user = uid_t()
        var group = gid_t()
        return getpeereid(descriptor, &user, &group) == 0 && user == geteuid()
    }

    static func peerDisconnected(_ descriptor: Int32) -> Bool {
        var state = pollfd(
            fd: descriptor,
            events: Int16(POLLHUP | POLLERR | POLLNVAL),
            revents: 0
        )
        return Darwin.poll(&state, 1, 0) > 0
            && state.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
    }

    private static func removeStaleSocket(at socketURL: URL) throws {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return }
        var status = stat()
        guard lstat(socketURL.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFSOCK
        else {
            throw MacOperatorHostBridgeError.unsafeSocketPath
        }
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else {
            throw MacOperatorHostBridgeError.socketCreationFailed
        }
        defer { Darwin.close(probe) }
        let connected = withSocketAddress(path: socketURL.path) { address, length in
            Darwin.connect(probe, address, length) == 0
        }
        guard !connected else {
            throw MacOperatorHostBridgeError.alreadyRunning
        }
        try FileManager.default.removeItem(at: socketURL)
    }

    private static func bindSocket(_ descriptor: Int32, path: String) throws {
        let result = withSocketAddress(path: path) { address, length in
            Darwin.bind(descriptor, address, length)
        }
        guard result == 0 else {
            throw MacOperatorHostBridgeError.socketBindFailed
        }
    }

    private static func withSocketAddress<T>(
        path: String,
        operation: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let length = MemoryLayout<sa_family_t>.size + path.utf8.count + 1
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        address.sun_len = UInt8(length)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: pathCapacity
            ) { destination in
                path.withCString { source in
                    _ = strlcpy(destination, source, pathCapacity)
                }
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                operation($0, socklen_t(length))
            }
        }
    }
}
