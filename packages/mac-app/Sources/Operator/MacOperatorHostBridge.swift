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

/// Signed-wrapper-owned Unix socket bridge for the ordinary Mac Operator
/// worker. One serial queue owns the listener and every accepted connection,
/// so two worker attempts cannot actuate the Mac concurrently.
final class MacOperatorHostBridge: @unchecked Sendable {
    struct State {
        var listener: Int32?
        var activeClient: Int32?
        var activeClientGeneration: UInt64?
        var activeOperation: Task<Void, Never>?
        var activeOperationCompletion: DispatchGroup?
        var cancellationGeneration: UInt64 = 0
        var stopping = false
    }

    let socketURL: URL
    let safety: MacOperatorSafetyState
    let responseHandler: @Sendable (MacOperatorRequest) async -> Data
    let state = OSAllocatedUnfairLock(initialState: State())
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
        let descriptor = try MacOperatorSocketTransport.createListener(at: socketURL)

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

}
