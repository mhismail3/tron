import Foundation
@testable import TronMobileCore
import XCTest

/// Kernel contract at GatewaySocketConnection: real handshake/decoder, receive
/// loop, event admission, epoch retirement and AsyncSequence; only the byte peer
/// is synthetic. No GatewayEventHub instance or private queue fields are read.
@MainActor
final class GatewayEventDeliveryContractTests: XCTestCase {
    private func profile(port: Int = 9847) -> GatewayProfile {
        GatewayProfile(id: "event-lock-\(port)", label: "Event contract", host: "127.0.0.1", port: port,
                       machineId: "fixture-machine", deviceId: "fixture-device")
    }

    private func frame(_ topic: String, value: String = "marker") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "event", "topic": topic,
                                                    "payload": ["value": value]], options: [.sortedKeys])
    }

    private func connect(_ client: GatewayClient, port: Int = 9847) async throws -> Int {
        let identity = try await client.connectForLifecycle(profile: profile(port: port), token: "fixture-token")
        try await client.activateEvents(connectionID: identity.id)
        return identity.id
    }

    private func next(_ stream: GatewayEventStream) async -> GatewayEventDelivery? {
        let completed = expectation(description: "socket delivery completes")
        let read = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            let value = await iterator.next()
            completed.fulfill()
            return value
        }
        await fulfillment(of: [completed], timeout: 3)
        read.cancel()
        return await read.value
    }

    private func fence(_ client: GatewayClient, peer: EventLockPeer, frames: [Data]) async throws {
        await peer.enqueue(frames)
        // This response follows the frames on the same receive port. Its
        // completion proves admission ran, without sleeps or private counters.
        _ = try await client.requestValue("fixture.fence", EmptyParams())
    }

    private func withClient(policy: GatewayEventBufferPolicy,
                            body: (GatewayClient, EventLockPeer) async throws -> Void) async throws {
        let peer = EventLockPeer()
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in peer }, eventBufferPolicy: policy)
        do {
            _ = try await connect(client)
            try await body(client, peer)
            await client.close()
        } catch {
            await client.close()
            throw error
        }
    }

    func testCountPressureRetiresConnectionAndDeliversDisconnect() async throws {
        try await withClient(policy: .init(maximumEvents: 3, maximumBytes: 4096)) { client, peer in
            try await self.fence(client, peer: peer, frames: try (0..<3).map { try self.frame("lock.\($0)") })
            let closed = expectation(description: "overflow closes byte peer")
            await peer.observeClose { closed.fulfill() }
            await peer.enqueue([try self.frame("lock.excess")])
            await fulfillment(of: [closed], timeout: 3)
            let diagnostics = await client.diagnostics()
            let rejection = try XCTUnwrap(diagnostics.first { $0.overflowReason != nil })
            XCTAssertEqual(rejection.overflowReason, .countLimit)
            XCTAssertEqual(rejection.overflowCount, 3)
            let active = await client.activeConnectionID()
            XCTAssertNil(active)
            var disconnect: GatewayEventDelivery?
            for _ in 0...3 {
                let delivery = await self.next(client.events)
                if delivery?.event.topic == "transport.disconnected" { disconnect = delivery; break }
            }
            XCTAssertEqual(disconnect?.event.payload.objectValue?["reason"]?.stringValue, "event_overflow")
        }
    }

    func testOrdinaryFrameCrossingCombinedByteCeilingRetiresConnection() async throws {
        let first = try frame("lock.first", value: String(repeating: "a", count: 80))
        let second = try frame("lock.second", value: String(repeating: "b", count: 80))
        try await withClient(policy: .init(maximumEvents: 8, maximumBytes: first.count + second.count - 1)) { client, peer in
            try await self.fence(client, peer: peer, frames: [first])
            let closed = expectation(description: "combined bytes close peer")
            await peer.observeClose { closed.fulfill() }
            await peer.enqueue([second])
            await fulfillment(of: [closed], timeout: 3)
            let diagnostics = await client.diagnostics()
            let rejection = try XCTUnwrap(diagnostics.first { $0.overflowReason != nil })
            XCTAssertEqual(rejection.overflowReason, .byteLimit)
            XCTAssertEqual(rejection.queueBytes, first.count)
        }
    }

    func testIndividuallyOversizedEventIsRejectedBeforeDelivery() async throws {
        let event = try frame("lock.large", value: String(repeating: "x", count: 300))
        try await withClient(policy: .init(maximumEvents: 8, maximumBytes: event.count - 1)) { client, peer in
            let closed = expectation(description: "oversized bytes close peer")
            await peer.observeClose { closed.fulfill() }
            await peer.enqueue([event])
            await fulfillment(of: [closed], timeout: 3)
            let diagnostics = await client.diagnostics()
            let rejection = try XCTUnwrap(diagnostics.first { $0.overflowReason != nil })
            XCTAssertEqual(rejection.overflowReason, .oversizedEvent)
            XCTAssertEqual(rejection.overflowCount, 0)
        }
    }

    func testCoalescedReplacementPreflightsTotalBytes() async throws {
        let first = try frame("session.listChanged", value: "first")
        let other = try frame("lock.other", value: "other")
        // Its own frame fits the ceiling; replacing the first while retaining
        // the other frame crosses it. Size the input from actual encoded bytes.
        let replacement = try frame("session.listChanged", value: String(repeating: "x", count: other.count))
        let ceiling = first.count + other.count + 10
        try await withClient(policy: .init(maximumEvents: 8, maximumBytes: ceiling)) { client, peer in
            try await self.fence(client, peer: peer, frames: [first, other])
            let closed = expectation(description: "replacement crossing byte ceiling closes peer")
            await peer.observeClose { closed.fulfill() }
            await peer.enqueue([replacement])
            await fulfillment(of: [closed], timeout: 3)
            let diagnostics = await client.diagnostics()
            let rejection = try XCTUnwrap(diagnostics.first { $0.overflowReason != nil })
            XCTAssertEqual(rejection.overflowReason, .byteLimit)
            XCTAssertEqual(rejection.queueBytes, first.count + other.count)
        }
    }

    func testCoalescingKeepsLatestPayloadWithoutTakingAnotherSlot() async throws {
        try await withClient(policy: .init(maximumEvents: 2, maximumBytes: 4096)) { client, peer in
            try await self.fence(client, peer: peer, frames: [
                try self.frame("session.listChanged", value: "old"),
                try self.frame("lock.other"),
                try self.frame("session.listChanged", value: "latest")])
            let first = await self.next(client.events)
            let second = await self.next(client.events)
            XCTAssertEqual(first?.event.topic, "session.listChanged")
            XCTAssertEqual(first?.event.payload.objectValue?["value"]?.stringValue, "latest")
            XCTAssertEqual(second?.event.topic, "lock.other")
            let diagnostics = await client.diagnostics()
            XCTAssertFalse(diagnostics.contains { $0.overflowReason != nil })
        }
    }

    func testSuccessorAdmissionAndLatePredecessorRetirementKeepOnlySuccessor() async throws {
        let predecessor = EventLockPeer(holdsClose: true)
        let successor = EventLockPeer()
        let client = GatewayClient(socketFactory: GatewaySocketFactory { request in
            request.url?.port == 9846 ? successor : predecessor
        }, eventBufferPolicy: .init(maximumEvents: 2, maximumBytes: 4096))
        var retirement: Task<Void, Never>?
        do {
            let oldID = try await connect(client)
            try await fence(client, peer: predecessor, frames: [try frame("lock.predecessor")])
            let closing = expectation(description: "old socket close is suspended")
            await predecessor.observeClose { closing.fulfill() }
            retirement = Task { await client.closeIfCurrent(connectionID: oldID) }
            await fulfillment(of: [closing], timeout: 3)
            let newID = try await connect(client, port: 9846)
            try await fence(client, peer: successor, frames: [try frame("lock.successor")])
            // Observe before releasing close: admission, not old reset, must
            // already have removed the predecessor's queued delivery.
            let delivery = await next(client.events)
            XCTAssertEqual(delivery?.connectionID, newID)
            XCTAssertEqual(delivery?.event.topic, "lock.successor")
            await predecessor.enqueue([try frame("lock.late-predecessor")])
            try await fence(client, peer: successor, frames: [try frame("lock.after-retirement")])
            await predecessor.releaseClose()
            await retirement?.value
            let after = await next(client.events)
            XCTAssertEqual(after?.connectionID, newID)
            XCTAssertEqual(after?.event.topic, "lock.after-retirement")
            await client.close()
        } catch {
            await predecessor.releaseClose()
            await retirement?.value
            await client.close()
            throw error
        }
    }

    func testDelayedPredecessorAdmissionCannotEnterSuccessorStream() async throws {
        let predecessor = EventLockPeer()
        let successor = EventLockPeer()
        let client = GatewayClient(socketFactory: GatewaySocketFactory { request in
            request.url?.port == 9846 ? successor : predecessor
        }, eventBufferPolicy: .init(maximumEvents: 4, maximumBytes: 4096))
        let entered = expectation(description: "predecessor decoded frame reaches actor hop")
        let admitted = expectation(description: "delayed admission attempt completes")
        let gate = EventLockGate { entered.fulfill() }
        do {
            let oldID = try await GatewayClient.$hostedEventAdmissionGate.withValue({
                await gate.wait()
                return { _ in admitted.fulfill() }
            }) { try await self.connect(client) }
            await predecessor.enqueue([try frame("lock.delayed-old")])
            await fulfillment(of: [entered], timeout: 3)
            await client.closeIfCurrent(connectionID: oldID)
            let newID = try await connect(client, port: 9846)
            try await fence(client, peer: successor, frames: [try frame("lock.new-first"), try frame("lock.new-second")])
            await gate.release()
            await fulfillment(of: [admitted], timeout: 3)
            let first = await next(client.events)
            let second = await next(client.events)
            XCTAssertEqual(first?.connectionID, newID)
            XCTAssertEqual(second?.connectionID, newID)
            let unexpected = expectation(description: "no queued predecessor after completed admission")
            unexpected.isInverted = true
            let stream = client.events
            let tail = Task {
                var iterator = stream.makeAsyncIterator()
                let delivery = await iterator.next()
                if delivery != nil { unexpected.fulfill() }
                return delivery
            }
            // The admission acknowledgement above fixes the producer boundary;
            // this bounded absence check does not infer producer completion.
            await fulfillment(of: [unexpected], timeout: 1)
            tail.cancel()
            let extra = await tail.value
            XCTAssertNil(extra)
            await client.close()
        } catch {
            await gate.release()
            await client.close()
            throw error
        }
    }

    func testCancellationDoesNotLeaveAWaiterThatStealsTheNextFrame() async throws {
        let peer = EventLockPeer()
        var client: GatewayClient? = GatewayClient(socketFactory: GatewaySocketFactory { _ in peer })
        _ = try await connect(client!)
        let stream = client!.events
        let entered = expectation(description: "consumer starts")
        let ended = expectation(description: "cancelled consumer ends")
        let consumer = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            entered.fulfill()
            let value = await iterator.next()
            ended.fulfill()
            return value
        }
        var following: Task<GatewayEventDelivery?, Never>?
        do {
            await fulfillment(of: [entered], timeout: 3)
            // A real RPC round trip gives the consumer's queued next() operation a
            // causal receive-loop boundary before cancellation, not an arbitrary delay.
            try await fence(client!, peer: peer, frames: [])
            consumer.cancel()
            await fulfillment(of: [ended], timeout: 3)
            try await fence(client!, peer: peer, frames: [try frame("lock.after-cancel")])
            let delivered = expectation(description: "next consumer receives the unclaimed frame")
            following = Task {
                var iterator = stream.makeAsyncIterator()
                let value = await iterator.next()
                if value != nil { delivered.fulfill() }
                return value
            }
            await fulfillment(of: [delivered], timeout: 3)
            // Finish before joining: even a broken cancellation control must
            // leave neither this case's waiter nor its follow-up consumer alive.
            await client!.close()
            client = nil
            let cancelled = await consumer.value
            let next = await following!.value
            XCTAssertNil(cancelled)
            XCTAssertEqual(next?.event.topic, "lock.after-cancel")
        } catch {
            consumer.cancel()
            following?.cancel()
            await client!.close()
            client = nil
            _ = await consumer.value
            _ = await following?.value
            throw error
        }
    }

    func testClientLifetimeFinishesWaitingStream() async throws {
        let peer = EventLockPeer()
        var client: GatewayClient? = GatewayClient(socketFactory: GatewaySocketFactory { _ in peer })
        _ = try await connect(client!)
        let stream = client!.events
        let entered = expectation(description: "stream consumer starts")
        let ended = expectation(description: "client lifetime finishes stream")
        let consumer = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            entered.fulfill()
            let value = await iterator.next()
            ended.fulfill()
            return value
        }
        do {
            await fulfillment(of: [entered], timeout: 3)
            try await fence(client!, peer: peer, frames: [])
            await client!.close()
            client = nil
            await fulfillment(of: [ended], timeout: 3)
            consumer.cancel() // also settles a known-bad missing-finish control
            let terminal = await consumer.value
            XCTAssertNil(terminal)
        } catch {
            consumer.cancel()
            await client?.close()
            client = nil
            _ = await consumer.value
            throw error
        }
    }
}

/// Controlled byte peer, using the production socket port and serialized wire
/// envelopes. It knows no event-buffer policy and makes no admission decision.
private actor EventLockPeer: GatewaySocketConnection {
    private var hello = false
    private var frames: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false
    private var holdsClose: Bool
    private var closing = false
    private var closeRelease: CheckedContinuation<Void, Never>?
    private var onClose: (@Sendable () -> Void)?

    init(holdsClose: Bool = false) { self.holdsClose = holdsClose }

    func observeClose(_ action: @escaping @Sendable () -> Void) { onClose = action }

    func send(_ data: Data) async throws {
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = value?["id"] as? String else { return }
        let response = try JSONSerialization.data(withJSONObject: ["type": "response", "id": id,
                                                                  "ok": true, "result": [:] as [String: String]])
        enqueue([response])
    }

    func enqueue(_ values: [Data]) {
        for value in values {
            if let receiver {
                self.receiver = nil
                receiver.resume(returning: value)
            } else { frames.append(value) }
        }
    }

    func receive() async throws -> Data {
        if !hello {
            hello = true
            return Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":8,"minProtocolVersion":8,"machineId":"fixture-machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":[]}"#.utf8)
        }
        if !frames.isEmpty { return frames.removeFirst() }
        if closed || Task.isCancelled { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { receiver = $0 }
        } onCancel: {
            Task { await self.cancelReceive() }
        }
    }

    private func cancelReceive() {
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }

    func ping() async throws { if closed { throw CancellationError() } }

    func close() async {
        guard !closing else { return }
        closing = true
        onClose?()
        if holdsClose { await withCheckedContinuation { closeRelease = $0 } }
        closed = true
        frames.removeAll()
        cancelReceive()
    }

    func releaseClose() {
        holdsClose = false
        closeRelease?.resume()
        closeRelease = nil
    }
}

/// Cancellation deliberately does not release this run-local admission gate:
/// it represents already-decoded predecessor work suspended at the actor hop.
private actor EventLockGate {
    private let onWait: @Sendable () -> Void
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(onWait: @escaping @Sendable () -> Void) { self.onWait = onWait }
    func wait() async {
        onWait()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
