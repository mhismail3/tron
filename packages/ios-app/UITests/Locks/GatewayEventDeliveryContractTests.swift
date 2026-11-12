import Foundation
@testable import TronMobileCore
import XCTest

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

    private func expectNoDelivery(_ stream: GatewayEventStream) async {
        let unexpected = expectation(description: "no queued predecessor after completed admission")
        unexpected.isInverted = true
        let tail = Task {
            var iterator = stream.makeAsyncIterator()
            let delivery = await iterator.next()
            if delivery != nil { unexpected.fulfill() }
            return delivery
        }
        await fulfillment(of: [unexpected], timeout: 1)
        tail.cancel()
        let extra = await tail.value
        XCTAssertNil(extra)
    }

    private func fence(_ client: GatewayClient, peer: EventLockPeer, frames: [Data]) async throws {
        await peer.enqueue(frames)
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

    func testProcessActivityIntegerProjectionPreservesInvalidResponseFailure() async throws {
        try await withClient(policy: .init(maximumEvents: 3, maximumBytes: 4096)) { client, peer in
            let method = "fixture.processActivity"
            let activity: [String: Any] = [
                "version": 1, "processId": "worker", "kind": "subagent", "executionMode": "asynchronous",
                "source": "delegatedAgent", "visibility": "active", "title": "Worker",
                "lifecycle": ["version": 1, "state": "running", "sequence": 1, "observedAt": "2026-01-01T00:00:00Z", "attention": "none"],
                "outputTruncated": false, "durationMs": 42, "toolCount": 2, "turnCount": 1, "childCount": 0,
                "toolCallId": "launch", "runId": "run-worker", "childSessionRef": "child-worker"
            ]
            await peer.respond(to: method, with: try JSONSerialization.data(withJSONObject: activity))
            let decoded: PresentedProcessActivity = try await client.request(method, EmptyParams())
            XCTAssertEqual(decoded.durationMs, 42)
            XCTAssertEqual(decoded.toolCount, 2)
            XCTAssertEqual(decoded.turnCount, 1)
            XCTAssertEqual(decoded.childCount, 0)
            for field in ["durationMs", "toolCount", "turnCount", "childCount"] {
                for invalid in [0.5, 1e30] {
                    var malformed = activity
                    malformed[field] = invalid
                    await peer.respond(to: method, with: try JSONSerialization.data(withJSONObject: malformed))
                    do {
                        let _: PresentedProcessActivity = try await client.request(method, EmptyParams())
                        XCTFail("Accepted invalid integer for \(field): \(invalid)")
                    } catch let failure as GatewayFailure {
                        XCTAssertEqual(failure.code, "invalid_response")
                        XCTAssertEqual(failure.details?.objectValue?["method"]?.stringValue, method)
                        XCTAssertEqual(failure.details?.objectValue?["category"]?.stringValue, "invalid_data")
                        XCTAssertFalse(failure.retryable)
                    }
                }
            }
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
        let original = try frame("session.listChanged", value: String(repeating: "o", count: 100))
        let other = try frame("lock.other")
        let latest = try frame("session.listChanged", value: "latest")
        try await withClient(policy: .init(maximumEvents: 2, maximumBytes: original.count + other.count)) { client, peer in
            try await self.fence(client, peer: peer, frames: [original, other, latest])
            let first = await self.next(client.events)
            XCTAssertEqual(first?.event.topic, "session.listChanged")
            XCTAssertEqual(first?.event.payload.objectValue?["value"]?.stringValue, "latest")
            try await self.fence(client, peer: peer, frames: [try self.frame("lock.after-replacement")])
            let second = await self.next(client.events)
            let third = await self.next(client.events)
            XCTAssertEqual(second?.event.topic, "lock.other")
            XCTAssertEqual(third?.event.topic, "lock.after-replacement")
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
        let entered = expectation(description: "second predecessor frame reaches actor hop")
        let admitted = expectation(description: "predecessor admission after successor completes")
        let gate = EventLockGate(skipping: 1) { entered.fulfill() }
        do {
            let oldID = try await GatewayClient.$hostedEventAdmissionGate.withValue({
                let paused = await gate.wait()
                return { _ in if paused { admitted.fulfill() } }
            }) { try await self.connect(client) }
            try await fence(client, peer: predecessor, frames: [try frame("lock.predecessor")])
            await predecessor.enqueue([try frame("lock.delayed-predecessor")])
            await fulfillment(of: [entered], timeout: 3)
            let closing = expectation(description: "old socket close is suspended")
            await predecessor.observeClose { closing.fulfill() }
            retirement = Task { await client.closeIfCurrent(connectionID: oldID) }
            await fulfillment(of: [closing], timeout: 3)
            let newID = try await connect(client, port: 9846)
            try await fence(client, peer: successor, frames: [try frame("lock.successor")])
            await gate.release()
            await fulfillment(of: [admitted], timeout: 3)
            let delivery = await next(client.events)
            XCTAssertEqual(delivery?.connectionID, newID)
            XCTAssertEqual(delivery?.event.topic, "lock.successor")
            await expectNoDelivery(client.events)
            await predecessor.enqueue([try frame("lock.late-predecessor")])
            try await fence(client, peer: successor, frames: [try frame("lock.after-retirement")])
            await predecessor.releaseClose()
            await retirement?.value
            let after = await next(client.events)
            XCTAssertEqual(after?.connectionID, newID)
            XCTAssertEqual(after?.event.topic, "lock.after-retirement")
            await client.close()
        } catch {
            await gate.release()
            await predecessor.releaseClose()
            await retirement?.value
            await client.close()
            throw error
        }
    }

    func testDelayedPredecessorAdmissionCannotReopenRetiredStream() async throws {
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
                _ = await gate.wait()
                return { _ in admitted.fulfill() }
            }) { try await self.connect(client) }
            await predecessor.enqueue([try frame("lock.delayed-old")])
            await fulfillment(of: [entered], timeout: 3)
            await client.closeIfCurrent(connectionID: oldID)
            await gate.release()
            await fulfillment(of: [admitted], timeout: 3)
            await expectNoDelivery(client.events)
            let newID = try await connect(client, port: 9846)
            try await fence(client, peer: successor, frames: [try frame("lock.new-first"), try frame("lock.new-second")])
            let first = await next(client.events)
            let second = await next(client.events)
            XCTAssertEqual(first?.connectionID, newID)
            XCTAssertEqual(second?.connectionID, newID)
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
            consumer.cancel()
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

private actor EventLockPeer: GatewaySocketConnection {
    private var hello = false
    private var frames: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false
    private var holdsClose: Bool
    private var closing = false
    private var closeRelease: CheckedContinuation<Void, Never>?
    private var onClose: (@Sendable () -> Void)?
    private var results: [String: Data] = [:]

    func respond(to method: String, with result: Data) { results[method] = result }

    init(holdsClose: Bool = false) { self.holdsClose = holdsClose }

    func observeClose(_ action: @escaping @Sendable () -> Void) { onClose = action }

    func send(_ data: Data) async throws {
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = value?["id"] as? String, let method = value?["method"] as? String else { return }
        let result = try results[method].map { try JSONSerialization.jsonObject(with: $0) } ?? [:] as [String: String]
        let response = try JSONSerialization.data(withJSONObject: ["type": "response", "id": id,
                                                                  "ok": true, "result": result])
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

private actor EventLockGate {
    private let onWait: @Sendable () -> Void
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var skipping: Int
    init(skipping: Int = 0, onWait: @escaping @Sendable () -> Void) {
        self.skipping = skipping
        self.onWait = onWait
    }
    func wait() async -> Bool {
        if skipping > 0 { skipping -= 1; return false }
        onWait()
        if !released { await withCheckedContinuation { continuation = $0 } }
        return true
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
