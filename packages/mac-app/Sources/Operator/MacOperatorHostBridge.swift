import Darwin
import Foundation
import os

enum MacOperatorHostBridgeError: Error, Equatable {
    case invalidSocketPath
    case unsafeSocketPath
    case alreadyRunning
    case socketCreationFailed
    case socketBindFailed
    case socketListenFailed
}

private final class MacOperatorOperationStartGate: @unchecked Sendable {
    private struct State {
        var isOpen = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen {
                    return true
                }
                state.waiter = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.isOpen = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

/// Signed-wrapper-owned Unix socket bridge for the ordinary Mac Operator
/// worker. One serial queue owns the listener and every accepted connection,
/// so two worker attempts cannot actuate the Mac concurrently.
final class MacOperatorHostBridge: @unchecked Sendable {
    private struct State {
        var listener: Int32?
        var activeClient: Int32?
        var activeClientGeneration: UInt64?
        var activeOperation: Task<Void, Never>?
        var activeOperationCompletion: DispatchGroup?
        var cancellationGeneration: UInt64 = 0
        var stopping = false
    }

    private let socketURL: URL
    private let safety: MacOperatorSafetyState
    private let responseHandler: @Sendable (MacOperatorRequest) async -> Data
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(
        label: "com.tron.mac.operator-host",
        qos: .userInitiated
    )
    private let lifecycle = DispatchGroup()

    init(socketURL: URL, safety: MacOperatorSafetyState) {
        let actuator = MacOperatorActuator(safety: safety)
        self.socketURL = socketURL
        self.safety = safety
        self.responseHandler = { request in
            await actuator.responseData(for: request)
        }
    }

    /// Test-only seam for proving host lifecycle ownership without asking for
    /// Accessibility or Screen Recording permission.
    init(
        socketURL: URL,
        safety: MacOperatorSafetyState,
        responseHandler: @escaping @Sendable (MacOperatorRequest) async -> Data
    ) {
        self.socketURL = socketURL
        self.safety = safety
        self.responseHandler = responseHandler
    }

    func start() throws {
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
        try removeStaleSocket()

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
        } catch {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: socketURL)
            throw error
        }

        let started = state.withLock { state -> Bool in
            guard state.listener == nil else { return false }
            state.listener = descriptor
            state.stopping = false
            return true
        }
        guard started else {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: socketURL)
            throw MacOperatorHostBridgeError.alreadyRunning
        }

        lifecycle.enter()
        queue.async { [weak self] in
            defer { self?.lifecycle.leave() }
            self?.acceptLoop(listener: descriptor)
        }
    }

    func stop() {
        safety.stop()
        let snapshot = state.withLock { state -> CancellationSnapshot in
            state.stopping = true
            state.cancellationGeneration &+= 1
            let snapshot = CancellationSnapshot(
                listener: state.listener,
                client: state.activeClient,
                operation: state.activeOperation,
                operationCompletion: state.activeOperationCompletion
            )
            state.listener = nil
            return snapshot
        }
        cancel(snapshot)
        if let listener = snapshot.listener {
            Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        // INVARIANT: stop does not return while an admitted native action can
        // still execute. The response handler owns bounded native timeouts and
        // cooperatively observes task cancellation.
        lifecycle.wait()
        try? FileManager.default.removeItem(at: socketURL)
    }

    /// The signed native menu owns the emergency stop. It invalidates semantic
    /// observations through `safety`, then cancels and drains the exact active
    /// client/action without stopping the listener. Future status requests can
    /// still report the stopped state, but no action can resume it.
    func emergencyStop() {
        safety.stop()
        let snapshot = state.withLock { state -> CancellationSnapshot in
            state.cancellationGeneration &+= 1
            return CancellationSnapshot(
                listener: nil,
                client: state.activeClient,
                operation: state.activeOperation,
                operationCompletion: state.activeOperationCompletion
            )
        }
        cancel(snapshot)
    }

    private func acceptLoop(listener: Int32) {
        while !state.withLock({ $0.stopping }) {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if state.withLock({ $0.stopping }) { return }
                if errno == EINTR { continue }
                return
            }
            let admitted = state.withLock { state -> Bool in
                guard !state.stopping, state.activeClient == nil else {
                    return false
                }
                state.activeClient = client
                state.activeClientGeneration = state.cancellationGeneration
                return true
            }
            guard admitted else {
                Darwin.shutdown(client, SHUT_RDWR)
                Darwin.close(client)
                return
            }
            autoreleasepool {
                handleClient(client)
            }
            state.withLock { state in
                guard state.activeClient == client else { return }
                state.activeClient = nil
                state.activeClientGeneration = nil
                state.activeOperation = nil
                state.activeOperationCompletion = nil
            }
            Darwin.close(client)
        }
    }

    private func handleClient(_ descriptor: Int32) {
        guard isCurrentUserPeer(descriptor) else {
            write(
                MacOperatorProtocol.failureData(
                    requestID: "unknown",
                    code: "unauthorized_local_peer"
                ),
                to: descriptor
            )
            return
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        let data: Data
        do {
            data = try readRequest(from: descriptor)
        } catch let error as MacOperatorProtocolError {
            write(
                MacOperatorProtocol.failureData(requestID: "unknown", code: error.code),
                to: descriptor
            )
            return
        } catch {
            write(
                MacOperatorProtocol.failureData(
                    requestID: "unknown",
                    code: "request_read_failed"
                ),
                to: descriptor
            )
            return
        }

        let request: MacOperatorRequest
        do {
            request = try MacOperatorProtocol.decodeRequest(data)
        } catch let error as MacOperatorProtocolError {
            write(
                MacOperatorProtocol.failureData(requestID: "unknown", code: error.code),
                to: descriptor
            )
            return
        } catch {
            write(
                MacOperatorProtocol.failureData(
                    requestID: "unknown",
                    code: "invalid_request"
                ),
                to: descriptor
            )
            return
        }

        let completion = DispatchGroup()
        completion.enter()
        let response = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let startGate = MacOperatorOperationStartGate()
        let operation = Task { [responseHandler] in
            defer { completion.leave() }
            await startGate.wait()
            guard !Task.isCancelled else {
                response.withLock {
                    $0 = MacOperatorProtocol.failureData(
                        requestID: request.requestID,
                        code: "native_action_cancelled"
                    )
                }
                return
            }
            let data = await responseHandler(request)
            response.withLock { $0 = data }
        }
        let operationAdmitted = state.withLock { state -> Bool in
            guard !state.stopping,
                  state.activeClient == descriptor,
                  state.activeClientGeneration == state.cancellationGeneration
            else {
                return false
            }
            state.activeOperation = operation
            state.activeOperationCompletion = completion
            return true
        }
        guard operationAdmitted else {
            operation.cancel()
            startGate.open()
            completion.wait()
            return
        }
        startGate.open()
        defer {
            state.withLock { state in
                guard state.activeClient == descriptor else { return }
                state.activeOperation = nil
                state.activeOperationCompletion = nil
            }
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(request.timeoutMilliseconds) * 1_000_000
        while completion.wait(timeout: .now() + .milliseconds(50)) != .success {
            if peerDisconnected(descriptor) {
                operation.cancel()
                completion.wait()
                return
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                operation.cancel()
                completion.wait()
                write(
                    MacOperatorProtocol.failureData(
                        requestID: request.requestID,
                        code: "native_action_timed_out"
                    ),
                    to: descriptor
                )
                return
            }
        }
        guard let data = response.withLock({ $0 }) else {
            write(
                MacOperatorProtocol.failureData(
                    requestID: request.requestID,
                    code: "native_action_cancelled"
                ),
                to: descriptor
            )
            return
        }
        write(data, to: descriptor)
    }

    private struct CancellationSnapshot {
        let listener: Int32?
        let client: Int32?
        let operation: Task<Void, Never>?
        let operationCompletion: DispatchGroup?
    }

    private func cancel(_ snapshot: CancellationSnapshot) {
        snapshot.operation?.cancel()
        if let client = snapshot.client {
            Darwin.shutdown(client, SHUT_RDWR)
        }
        snapshot.operationCompletion?.wait()
    }

    private func readRequest(from descriptor: Int32) throws -> Data {
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

    private func write(_ data: Data, to descriptor: Int32) {
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

    private func isCurrentUserPeer(_ descriptor: Int32) -> Bool {
        var user = uid_t()
        var group = gid_t()
        return getpeereid(descriptor, &user, &group) == 0 && user == geteuid()
    }

    private func peerDisconnected(_ descriptor: Int32) -> Bool {
        var state = pollfd(
            fd: descriptor,
            events: Int16(POLLHUP | POLLERR | POLLNVAL),
            revents: 0
        )
        return Darwin.poll(&state, 1, 0) > 0
            && state.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
    }

    private func removeStaleSocket() throws {
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

    private func bindSocket(_ descriptor: Int32, path: String) throws {
        let result = withSocketAddress(path: path) { address, length in
            Darwin.bind(descriptor, address, length)
        }
        guard result == 0 else {
            throw MacOperatorHostBridgeError.socketBindFailed
        }
    }

    private func withSocketAddress<T>(
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
                    _ = strlcpy(
                        destination,
                        source,
                        pathCapacity
                    )
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
