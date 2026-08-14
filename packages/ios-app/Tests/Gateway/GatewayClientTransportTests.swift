import Foundation
import Testing
@testable import TronMobile

private final class WeakGatewayClient {
    weak var value: GatewayClient?
}

@Suite("Gateway client byte transport")
struct GatewayClientTransportTests {
    private let profile = GatewayProfile(
        id: "machine",
        label: "Mac",
        host: "gateway.test",
        port: 9_847,
        machineId: "machine",
        deviceId: "device"
    )

    @Test("hello and request frames use injected IDs without changing their byte protocol")
    func deterministicHelloAndRequestIDs() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let factory = ScriptedGatewaySocketFactory(socket: socket)
            let ids = SequenceUUIDSource([
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            ])
            let signposts = RecordingPerformanceSignposts()
            let client = GatewayClient(
                socketFactory: factory.factory,
                uuidSource: ids.source,
                performanceSignposts: signposts
            )
            await socket.enqueue(helloFrame())

            let info = try await client.connect(profile: profile, token: "token")
            #expect(info.machineId == "machine")
            #expect(factory.requests.count == 1)
            #expect(factory.requests[0].url == profile.socketURL)
            #expect(factory.requests[0].timeoutInterval == 15)
            #expect(factory.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer token")

            let sentHello = try await decodedValue(in: socket, index: 0)
            #expect(sentHello == .object([
                "type": .string("hello"),
                "protocolVersion": .number(2),
                "clientId": .string("00000000-0000-0000-0000-000000000001"),
            ]))

            let request = Task {
                try await client.requestValue("test.echo", EmptyParams(), timeout: .seconds(30))
            }
            defer { request.cancel() }
            try await socket.waitUntilSent(count: 2)
            let sentRequest = try await decodedValue(in: socket, index: 1)
            #expect(sentRequest == .object([
                "type": .string("request"),
                "id": .string("00000000-0000-0000-0000-000000000002"),
                "method": .string("test.echo"),
                "params": .object([:]),
            ]))
            await socket.enqueue(responseFrame(
                id: "00000000-0000-0000-0000-000000000002",
                result: .object(["answer": .string("ok")])
            ))
            #expect(try await valueOfOwnedTask(request).objectValue?["answer"]?.stringValue == "ok")
            #expect(signposts.events() == [
                .begin(.gatewayConnect),
                .end(.gatewayConnect, .success, .none),
            ])
            await client.close()
        }
    }

    @Test("response and event bytes are admitted by GatewayClient")
    func responseAndEventAdmission() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            let request = Task { try await client.requestValue("test.value", EmptyParams()) }
            defer { request.cancel() }
            try await socket.waitUntilSent(count: 2)
            await socket.enqueue(responseFrame(id: "00000000-0000-0000-0000-000000000012", result: .number(7)))
            #expect(try await valueOfOwnedTask(request).intValue == 7)

            var iterator = client.events.makeAsyncIterator()
            await socket.enqueue(eventFrame(topic: "test.changed", payload: .object(["revision": .number(3)])))
            let event = await iterator.next()
            #expect(event?.topic == "test.changed")
            #expect(event?.payload.objectValue?["revision"]?.intValue == 3)
            await client.close()
        }
    }

    @Test("handshake timeout advances on the injected monotonic clock")
    func virtualHandshakeTimeout() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket()
            let signposts = RecordingPerformanceSignposts()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
                ]).source,
                performanceSignposts: signposts
            )

            let connection = Task { try await client.connect(profile: profile, token: "token") }
            defer { connection.cancel() }
            try await socket.waitUntilSent(count: 1)
            try await clock.waitUntilSleeping(count: 1)
            clock.advance(by: .seconds(15))

            do {
                _ = try await valueOfOwnedTask(connection)
                Issue.record("handshake unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "timeout")
            } catch {
                Issue.record("unexpected handshake error: \(error)")
            }
            #expect(signposts.events() == [
                .begin(.gatewayConnect),
                .end(.gatewayConnect, .failure, .none),
            ])
            await client.close()
        }
    }

    @Test("cancelled handshake closes its signpost as cancelled")
    func cancelledHandshakeSignpost() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let signposts = RecordingPerformanceSignposts()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
                ]).source,
                performanceSignposts: signposts
            )

            let connection = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            connection.cancel()
            do {
                _ = try await valueOfOwnedTask(connection)
                Issue.record("cancelled handshake unexpectedly succeeded")
            } catch is CancellationError {}
            #expect(signposts.events() == [
                .begin(.gatewayConnect),
                .end(.gatewayConnect, .cancelled, .none),
            ])
            await client.close()
        }
    }

    @Test("request timeout advances on the injected monotonic clock")
    func virtualRequestTimeout() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            let request = Task { try await client.requestValue("test.timeout", EmptyParams(), timeout: .seconds(5)) }
            defer { request.cancel() }
            try await socket.waitUntilSent(count: 2)
            try await clock.waitUntilSleeping(count: 2) // liveness plus request deadline
            clock.advance(by: .seconds(5))

            do {
                _ = try await valueOfOwnedTask(request)
                Issue.record("request unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "timeout")
            }
            await client.close()
        }
    }

    @Test("liveness checks at 20 seconds and enforces the 8-second system info deadline")
    func deterministicLivenessTiming() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000025")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000026")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")
            try await clock.waitUntilSleeping(count: 1)

            clock.advance(by: .seconds(20))
            try await clock.waitUntilSleeping(count: 1)
            #expect(await socket.sentFrames().count == 1)

            clock.advance(by: .seconds(20))
            try await socket.waitUntilSent(count: 2)
            #expect(try await decodedValue(in: socket, index: 1) == .object([
                "type": .string("request"),
                "id": .string("00000000-0000-0000-0000-000000000026"),
                "method": .string("system.info"),
                "params": .object([:]),
            ]))
            try await clock.waitUntilSleeping(count: 1)

            clock.advance(by: .seconds(7))
            #expect(await socket.closeInvocationCount() == 0)
            #expect(await client.info?.machineId == "machine")

            var eventIterator = client.events.makeAsyncIterator()
            clock.advance(by: .seconds(1))
            try await socket.waitUntilClosed()
            let event = await eventIterator.next()
            #expect(event?.topic == "transport.disconnected")
            #expect(await socket.closeInvocationCount() == 1)
            #expect(await socket.closeTransitionCount() == 1)
            #expect(await client.info == nil)
        }
    }

    @Test("a current receiver cancellation is a transport disconnect")
    func currentReceiverCancellationDisconnects() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000027")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            var iterator = client.events.makeAsyncIterator()
            await socket.failPendingReceivers(CancellationError())
            let event = await iterator.next()
            #expect(event?.topic == "transport.disconnected")
            #expect(await client.info == nil)
            #expect(await socket.closed())
        }
    }

    @Test("an idle connected client releases its socket when ownership ends")
    func connectedClientDeinitializes() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let weakClient = try await makeConnectedClientReleasedImmediately(socket: socket)
            try await socket.waitUntilClosed()
            #expect(weakClient.value == nil)
            #expect(await socket.closeTransitionCount() == 1)
        }
    }

    @Test("disconnect invokes close once and closes the factory-created socket")
    func disconnectClosesExactSocket() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            await client.close()
            #expect(await socket.closeInvocationCount() == 1)
            #expect(await socket.closeTransitionCount() == 1)
            #expect(await socket.closed())

            await socket.close()
            #expect(await socket.closeInvocationCount() == 2)
            #expect(await socket.closeTransitionCount() == 1)
            #expect(await socket.closed())
        }
    }

    @Test("a suspended old socket close cannot clear a replacement connection")
    func suspendedCloseDoesNotClearReplacement() async throws {
        try await withTestWatchdog {
            let oldSocket = ScriptedGatewaySocket(suspendsClose: true)
            let replacementSocket = ScriptedGatewaySocket()
            let factory = ScriptedGatewaySocketFactory(sockets: [oldSocket, replacementSocket])
            let client = GatewayClient(
                socketFactory: factory.factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000051")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000052")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000053")!,
                ]).source
            )
            await oldSocket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "old-token")

            let oldClose = Task { await client.close() }
            defer { oldClose.cancel() }
            try await oldSocket.waitUntilCloseInvoked()
            #expect(await oldSocket.closeTransitionCount() == 0)

            await replacementSocket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "new-token")
            #expect(await client.info?.machineId == "machine")

            await oldSocket.releaseClose()
            _ = try await valueOfOwnedTask(oldClose)
            #expect(await oldSocket.closeInvocationCount() == 1)
            #expect(await oldSocket.closeTransitionCount() == 1)
            #expect(await client.info?.machineId == "machine")

            let request = Task { try await client.requestValue("test.replacement", EmptyParams()) }
            defer { request.cancel() }
            try await replacementSocket.waitUntilSent(count: 2)
            await replacementSocket.enqueue(responseFrame(
                id: "00000000-0000-0000-0000-000000000053",
                result: .string("alive")
            ))
            #expect(try await valueOfOwnedTask(request) == .string("alive"))
            await client.close()
        }
    }

    @Test("late hello from a replaced connection cannot install or clear the replacement")
    func staleHelloIsDiscarded() async throws {
        try await withTestWatchdog {
            let oldSocket = ScriptedGatewaySocket(deliversCallbacksAfterClose: true)
            let replacementSocket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(sockets: [oldSocket, replacementSocket]).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000061")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000062")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000063")!,
                ]).source
            )

            let staleConnection = Task { try await client.connect(profile: profile, token: "old") }
            defer { staleConnection.cancel() }
            try await oldSocket.waitUntilSent(count: 1)

            await replacementSocket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "new")
            await oldSocket.enqueue(helloFrame())
            await #expect(throws: CancellationError.self) {
                _ = try await valueOfOwnedTask(staleConnection)
            }

            let request = Task { try await client.requestValue("test.current", EmptyParams()) }
            defer { request.cancel() }
            try await replacementSocket.waitUntilSent(count: 2)
            await replacementSocket.enqueue(responseFrame(
                id: "00000000-0000-0000-0000-000000000063",
                result: .string("current")
            ))
            #expect(try await valueOfOwnedTask(request) == .string("current"))
            await client.close()
        }
    }

    @Test("late frame from a replaced receiver is discarded")
    func staleFrameIsDiscarded() async throws {
        try await withTestWatchdog {
            let oldSocket = ScriptedGatewaySocket(deliversCallbacksAfterClose: true)
            let replacementSocket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(sockets: [oldSocket, replacementSocket]).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000071")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000072")!,
                ]).source
            )
            await oldSocket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "old")
            await replacementSocket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "new")

            var iterator = client.events.makeAsyncIterator()
            await oldSocket.enqueue(eventFrame(topic: "stale.changed", payload: .number(1)))
            await replacementSocket.enqueue(eventFrame(topic: "current.changed", payload: .number(2)))
            let event = await iterator.next()
            #expect(event?.topic == "current.changed")
            #expect(await client.info?.machineId == "machine")
            await client.close()
        }
    }

    @Test("a suspended retired close cannot emit disconnect after replacement")
    func suspendedRetiredDisconnectIsDiscarded() async throws {
        try await withTestWatchdog {
            let oldSocket = ScriptedGatewaySocket(suspendsClose: true)
            let replacementSocket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(sockets: [oldSocket, replacementSocket]).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000075")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000076")!,
                ]).source
            )
            await oldSocket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "old")
            var iterator = client.events.makeAsyncIterator()
            await oldSocket.failPendingReceivers(GatewayFailure(
                code: "disconnected",
                message: "old failure",
                retryable: true,
                details: nil
            ))
            try await oldSocket.waitUntilCloseInvoked()

            await replacementSocket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "new")
            await oldSocket.releaseClose()
            await replacementSocket.enqueue(eventFrame(topic: "current.changed", payload: .number(2)))
            let event = await iterator.next()
            #expect(event?.topic == "current.changed")
            #expect(await client.info?.machineId == "machine")
            await client.close()
        }
    }

    @Test("late receive failure from a replaced receiver cannot disconnect the replacement")
    func staleDisconnectIsDiscarded() async throws {
        try await withTestWatchdog {
            let oldSocket = ScriptedGatewaySocket(deliversCallbacksAfterClose: true)
            let replacementSocket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(sockets: [oldSocket, replacementSocket]).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000081")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000082")!,
                ]).source
            )
            await oldSocket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "old")
            await replacementSocket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "new")

            await oldSocket.failPendingReceivers(GatewayFailure(
                code: "disconnected",
                message: "late old failure",
                retryable: true,
                details: nil
            ))
            #expect(await client.info?.machineId == "machine")
            await client.close()
        }
    }

    @Test("scripted waiters and close barriers observe cancellation")
    func supportWaitCancellation() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket(suspendsClose: true)
            let sentWait = Task { try await socket.waitUntilSent(count: 1) }
            defer { sentWait.cancel() }
            sentWait.cancel()
            await #expect(throws: CancellationError.self) { try await valueOfOwnedTask(sentWait) }

            let clock = ManualClock()
            let sleepWait = Task { try await clock.waitUntilSleeping(count: 1) }
            defer { sleepWait.cancel() }
            sleepWait.cancel()
            await #expect(throws: CancellationError.self) { try await valueOfOwnedTask(sleepWait) }

            let close = Task { await socket.close() }
            defer { close.cancel() }
            try await socket.waitUntilCloseInvoked()
            close.cancel()
            _ = try await valueOfOwnedTask(close)
            #expect(await socket.closeInvocationCount() == 1)
            #expect(await socket.closeTransitionCount() == 1)
        }
    }

    @Test("event-buffer overflow preserves one disconnect across the complete bounded sequence")
    func eventBufferOverflowSignalsOnce() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket(suspendsClose: true)
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            for revision in 0..<513 {
                await socket.enqueue(eventFrame(topic: "test.changed", payload: .number(Double(revision))))
            }
            try await socket.waitUntilCloseInvoked()
            #expect(await socket.closeTransitionCount() == 0)

            let (bufferDrained, bufferDrainedContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let consumer = Task { () -> [GatewayEvent] in
                var iterator = client.events.makeAsyncIterator()
                var events: [GatewayEvent] = []
                for index in 0..<513 {
                    guard let event = await iterator.next() else { break }
                    events.append(event)
                    if index == 511 {
                        bufferDrainedContinuation.yield(())
                        bufferDrainedContinuation.finish()
                    }
                }
                return events
            }
            defer { consumer.cancel() }

            var bufferDrainedIterator = bufferDrained.makeAsyncIterator()
            #expect(await bufferDrainedIterator.next() != nil)
            await socket.releaseClose()

            let events = try await valueOfOwnedTask(consumer)
            #expect(events.count == 513)
            #expect(events.dropLast().map(\.topic).allSatisfy { $0 == "test.changed" })
            #expect(events.dropLast().compactMap { $0.payload.intValue } == Array(1...512))
            #expect(events.last?.topic == "transport.disconnected")
            #expect(events.filter { $0.topic == "transport.disconnected" }.count == 1)
            #expect(await socket.closeInvocationCount() == 1)
            #expect(await socket.closeTransitionCount() == 1)
        }
    }

    private func makeConnectedClientReleasedImmediately(
        socket: ScriptedGatewaySocket
    ) async throws -> WeakGatewayClient {
        let weakClient = WeakGatewayClient()
        do {
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000028")!,
                ]).source
            )
            weakClient.value = client
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")
        }
        return weakClient
    }

    private func decodedValue(in socket: ScriptedGatewaySocket, index: Int) async throws -> JSONValue {
        let frames = await socket.sentFrames()
        return try JSONDecoder.gateway.decode(JSONValue.self, from: frames[index])
    }

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8)
    }

    private func responseFrame(id: String, result: JSONValue) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": result,
        ]))
    }

    private func eventFrame(topic: String, payload: JSONValue) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("event"),
            "topic": .string(topic),
            "sessionId": .null,
            "payload": payload,
        ]))
    }
}
