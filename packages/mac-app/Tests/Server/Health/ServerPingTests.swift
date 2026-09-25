import Foundation
import Testing
@testable import TronMac

@Suite("GatewayWebSocketTransport")
struct GatewayWebSocketTransportTests {
    @Test("parent cancellation closes the socket")
    func cancellationClosesSocket() async throws {
        let task = TestWebSocketTask()
        let session = URLSession(configuration: .ephemeral)
        let connection = GatewayWebSocketTransport.Connection(
            task: task,
            session: session,
            capture: GatewayWebSocketTransport.StatusCapture()
        )
        let pending = Task {
            try await connection.receiveData(
                deadline: GatewayWebSocketTransport.Deadline(timeout: 2)
            )
        }
        await task.receiveEntered.wait()
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        #expect(task.cancelCount == 1)
    }

    @Test("a hanging operation closes and returns within one deadline")
    func timeoutClosesHangingOperationWithinDeadline() async throws {
        let task = TestWebSocketTask()
        let session = URLSession(configuration: .ephemeral)
        let connection = GatewayWebSocketTransport.Connection(
            task: task,
            session: session,
            capture: GatewayWebSocketTransport.StatusCapture()
        )
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await connection.receiveData(
                deadline: GatewayWebSocketTransport.Deadline(timeout: 0.05)
            )
            Issue.record("expected timeout")
        } catch GatewayWebSocketTransport.Failure.timeout {
            // Expected.
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        #expect(elapsed < 500_000_000)
        #expect(task.cancelCount == 1)
    }

    @Test("oversized data frames are rejected before decoding")
    func oversizedDataFrameRejectedAtTransportBoundary() async throws {
        let task = TestWebSocketTask(message: .data(Data(repeating: 0, count: GatewayWebSocketTransport.maximumFrameBytes + 1)))
        let session = URLSession(configuration: .ephemeral)
        let connection = GatewayWebSocketTransport.Connection(
            task: task,
            session: session,
            capture: GatewayWebSocketTransport.StatusCapture()
        )
        var rejected = false
        do {
            _ = try await connection.receiveData(
                deadline: GatewayWebSocketTransport.Deadline(timeout: 1)
            )
        } catch GatewayWebSocketTransport.Failure.invalidMessage {
            rejected = true
        }
        #expect(rejected)
        connection.close()
    }
}

private final class TestWebSocketTask: GatewayWebSocketTransport.WebSocketTask, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var cancelled = false
    private(set) var cancelCount = 0
    private let nextMessage: URLSessionWebSocketTask.Message?
    /// Signalled when `receive()` is entered, so cancellation targets a live
    /// socket observation without a real-time sleep.
    let receiveEntered = TestLatch()

    init(message: URLSessionWebSocketTask.Message? = nil) {
        nextMessage = message
    }

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let pending: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        lock.lock()
        cancelCount += 1
        cancelled = true
        pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if let nextMessage { return nextMessage }
        receiveEntered.signal()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// One-shot signal for a test task that must not poll or sleep.
private final class TestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let waiters = lock.withLock { ready = true; defer { self.waiters.removeAll() }; return self.waiters }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { if ready { return true }; waiters.append(continuation); return false }
            if immediate { continuation.resume() }
        }
    }
}

/// Network behavior is covered only at the closed-port boundary; the pure
/// frame decoder owns the cross-language gateway contract assertions.
@Suite("ServerPing.decodeFrame")
struct ServerPingDecodeTests {

    @Test("matching system.info response retains runtime provenance")
    func matchingResponseProjectsRuntimeIdentity() {
        let body = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","gatewayChannel":"dev","sourceRevision":"revision-1","buildFingerprint":"fingerprint-1","runtimeEpoch":"epoch-1"}}"#
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .result(ServerPingInfo(
            version: "0.1.0",
            gatewayChannel: "dev",
            sourceRevision: "revision-1",
            buildFingerprint: "fingerprint-1",
            runtimeEpoch: "epoch-1"
        )))
    }

    @Test("undeclared result fields are tolerated")
    func undeclaredResultFieldsAreTolerated() {
        let body = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","gatewayChannel":"stable","machineName":"Mac","piVersion":"fixture-version","capabilities":[]}}"#
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .result(ServerPingInfo(version: "0.1.0", gatewayChannel: "stable")))
    }

    @Test("gateway channel is bounded when present")
    func gatewayChannelIsBounded() {
        let oversized = String(repeating: "x", count: GatewayPayloadStore.channelComponentLimit + 1)
        let body = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","gatewayChannel":"\#(oversized)"}}"#
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .malformed)
    }

    @Test("missing required gateway identity is malformed")
    func missingCanonicalFieldsIsMalformed() {
        let body = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":5,"minProtocolVersion":5,"machineId":""}}"#
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .malformed)
    }

    @Test("protocol versions must exactly match the supported transport")
    func incompatibleProtocolIsMalformed() {
        let older = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine"}}"#
        let future = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":5,"minProtocolVersion":4,"machineId":"machine"}}"#
        let inverted = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":1,"minProtocolVersion":3,"machineId":"machine"}}"#
        #expect(ServerPing.decodeFrame(data: Data(older.utf8)) == .malformed)
        #expect(ServerPing.decodeFrame(data: Data(future.utf8)) == .malformed)
        #expect(ServerPing.decodeFrame(data: Data(inverted.utf8)) == .malformed)
    }

    @Test("server hello must be exact before system.info is sent")
    func serverHelloRequiresExactTransportVersions() {
        let valid = #"{"type":"hello","protocolVersion":5,"minProtocolVersion":5}"#
        let older = #"{"type":"hello","protocolVersion":3,"minProtocolVersion":3}"#
        let future = #"{"type":"hello","protocolVersion":5,"minProtocolVersion":4}"#
        #expect(GatewayWebSocketTransport.validHello(
            data: Data(valid.utf8),
            protocolVersion: ServerPing.supportedProtocolVersion,
            minimumProtocolVersion: ServerPing.minimumProtocolVersion
        ))
        #expect(!GatewayWebSocketTransport.validHello(
            data: Data(older.utf8),
            protocolVersion: ServerPing.supportedProtocolVersion,
            minimumProtocolVersion: ServerPing.minimumProtocolVersion
        ))
        #expect(!GatewayWebSocketTransport.validHello(
            data: Data(future.utf8),
            protocolVersion: ServerPing.supportedProtocolVersion,
            minimumProtocolVersion: ServerPing.minimumProtocolVersion
        ))
    }

    @Test("system.info responses are not accepted as the server hello")
    func responseCannotSatisfyHelloGate() {
        let body = #"{"type":"response","id":"mac-system-info","ok":true,"result":{"gatewayVersion":"0.1.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","gatewayChannel":"stable"}}"#
        #expect(!GatewayWebSocketTransport.validHello(
            data: Data(body.utf8),
            protocolVersion: ServerPing.supportedProtocolVersion,
            minimumProtocolVersion: ServerPing.minimumProtocolVersion
        ))
        #expect(ServerPing.decodeFrame(data: Data(body.utf8)) == .result(ServerPingInfo(version: "0.1.0", gatewayChannel: "stable")))
    }
}

@Suite("ServerPing — live network classification")
struct ServerPingLiveTests {
    @Test("closed port is never reported as authenticated")
    func closedPortIsUnreachable() async throws {
        let result = try await ServerPing.ping(host: "127.0.0.1", port: 1, token: "anything", timeout: 1)
        switch result {
        case .unreachable, .timeout: break
        case .success, .unauthorized, .malformedResponse:
            Issue.record("expected .unreachable/.timeout for closed port, got \(result)")
        }
    }
}
