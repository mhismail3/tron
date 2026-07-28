import Darwin
import Foundation
import os

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

extension MacOperatorHostBridge {
    func handleClient(_ descriptor: Int32) {
        guard MacOperatorSocketTransport.isCurrentUserPeer(descriptor) else {
            MacOperatorSocketTransport.write(
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
            data = try MacOperatorSocketTransport.readRequest(from: descriptor)
        } catch let error as MacOperatorProtocolError {
            MacOperatorSocketTransport.write(
                MacOperatorProtocol.failureData(requestID: "unknown", code: error.code),
                to: descriptor
            )
            return
        } catch {
            MacOperatorSocketTransport.write(
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
            MacOperatorSocketTransport.write(
                MacOperatorProtocol.failureData(requestID: "unknown", code: error.code),
                to: descriptor
            )
            return
        } catch {
            MacOperatorSocketTransport.write(
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
            if MacOperatorSocketTransport.peerDisconnected(descriptor) {
                operation.cancel()
                completion.wait()
                return
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                operation.cancel()
                completion.wait()
                MacOperatorSocketTransport.write(
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
            MacOperatorSocketTransport.write(
                MacOperatorProtocol.failureData(
                    requestID: request.requestID,
                    code: "native_action_cancelled"
                ),
                to: descriptor
            )
            return
        }
        MacOperatorSocketTransport.write(data, to: descriptor)
    }
}
