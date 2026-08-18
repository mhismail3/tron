import Foundation
import Testing
@testable import TronMobile

private final class WeakGatewayClient {
    weak var value: GatewayClient?
}

private final class CountingGatewayFrameDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var decoder: GatewayFrameDecoder {
        GatewayFrameDecoder { [self] data in
            lock.lock()
            count += 1
            lock.unlock()
            return try JSONDecoder().decode(GatewayInboundFrame.self, from: data)
        }
    }

    func invocationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
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

    @Test("invalid persisted endpoints fail before socket creation")
    func invalidEndpointFailsClosed() async {
        let factory = ScriptedGatewaySocketFactory(socket: ScriptedGatewaySocket())
        let client = GatewayClient(socketFactory: factory.factory)
        let invalid = GatewayProfile(
            id: "invalid", label: "Invalid", host: "bad/path", port: 70_000,
            machineId: "invalid", deviceId: nil
        )

        await #expect(throws: GatewayFailure.self) {
            try await client.connect(profile: invalid, token: "token")
        }
        #expect(factory.requests.isEmpty)
    }

    @Test("oversized hello fails before handshake JSON decoding")
    func oversizedHelloFailsClosed() async {
        let socket = ScriptedGatewaySocket()
        let factory = ScriptedGatewaySocketFactory(socket: socket)
        let client = GatewayClient(socketFactory: factory.factory)
        await socket.enqueue(Data(repeating: 0x20, count: GatewayFramePolicy.maximumInboundBytes + 1))

        await #expect(throws: GatewayFailure.self) {
            try await client.connect(profile: profile, token: "token")
        }
    }

    @Test("v2 hello is rejected before a session-open request")
    func rejectsV2BeforeSessionOpen() async throws {
        let socket = ScriptedGatewaySocket()
        let factory = ScriptedGatewaySocketFactory(socket: socket)
        let client = GatewayClient(socketFactory: factory.factory)
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"0.84.1","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":[]}"#.utf8))

        do {
            _ = try await client.connect(profile: profile, token: "token")
            Issue.record("v2 handshake unexpectedly succeeded")
        } catch let error as GatewayFailure {
            #expect(error.code == "protocol_mismatch")
        }
        #expect(await socket.sentFrames().count == 1)
        await client.close()
    }

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
                "protocolVersion": .number(3),
                "clientId": .string("00000000-0000-0000-0000-000000000001"),
                "clientRole": .string("mobile"),
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
            #expect(event?.event.topic == "test.changed")
            #expect(event?.event.payload.objectValue?["revision"]?.intValue == 3)
            await client.close()
        }
    }

    @Test("each inbound response or event frame is decoded once and prepared before delivery")
    func singleFrameDecodeAndPreparation() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let counter = CountingGatewayFrameDecoder()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
                ]).source,
                frameDecoder: counter.decoder
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            let request = Task { try await client.requestValue("test.value", EmptyParams()) }
            defer { request.cancel() }
            try await socket.waitUntilSent(count: 2)
            await socket.enqueue(responseFrame(
                id: "00000000-0000-0000-0000-000000000014",
                result: .number(9)
            ))
            #expect(try await valueOfOwnedTask(request).intValue == 9)

            var iterator = client.events.makeAsyncIterator()
            let snapshot = try SessionScenarioBuilder(seed: 17).openingTail(
                targetEncodedBytes: 64 * 1_024
            )
            await socket.enqueue(eventFrame(
                topic: "session.snapshot",
                payload: try JSONValue.encode(snapshot)
            ))
            let delivery = try #require(await iterator.next())
            guard case .sessionSnapshot(let prepared) = delivery.event.preparation else {
                Issue.record("large snapshot event was not prepared")
                await client.close()
                return
            }
            #expect(prepared.sessionId == snapshot.sessionId)
            #expect(prepared.transcript == snapshot.transcript)
            #expect(counter.invocationCount() == 2)
            await client.close()
        }
    }

    @Test("unknown and undiscriminated frame shapes remain forward-compatible")
    func unknownFramesAreIgnored() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000015")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            var iterator = client.events.makeAsyncIterator()
            await socket.enqueue(Data("42".utf8))
            await socket.enqueue(Data(#"{"future":"shape"}"#.utf8))
            await socket.enqueue(Data(#"{"type":7,"payload":"future"}"#.utf8))
            await socket.enqueue(Data(#"{"type":"future","responseFieldsAreNotRequired":true}"#.utf8))
            await socket.enqueue(eventFrame(topic: "future.changed", payload: .object([
                "preserved": .bool(true),
            ])))

            let delivery = try #require(await iterator.next())
            #expect(delivery.event.topic == "future.changed")
            #expect(delivery.event.payload.objectValue?["preserved"]?.boolValue == true)
            #expect(delivery.event.preparation == .none)
            #expect(await client.info?.machineId == "machine")
            #expect(await socket.closeInvocationCount() == 0)
            await client.close()
        }
    }

    @Test("malformed known frames retain strict transport failure")
    func malformedKnownFrameDisconnects() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000016")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            var iterator = client.events.makeAsyncIterator()
            await socket.enqueue(Data(#"{"type":"event","topic":"known.malformed"}"#.utf8))
            let delivery = try #require(await iterator.next())
            #expect(delivery.event.topic == "transport.disconnected")
            #expect(await client.info == nil)
            #expect(await socket.closeTransitionCount() == 1)
        }
    }

    @Test("lifecycle connection activates event delivery only under its returned identity")
    func lifecycleConnectionIdentity() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000091")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            let connection = try await client.connectForLifecycle(profile: profile, token: "token")
            var iterator = client.events.makeAsyncIterator()
            await socket.enqueue(eventFrame(topic: "identity.changed", payload: .number(1)))
            try await client.activateEvents(connectionID: connection.id)

            let delivery = await iterator.next()
            #expect(delivery?.connectionID == connection.id)
            #expect(delivery?.event.topic == "identity.changed")
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

    @Test("transmission state distinguishes definitely queued from possibly sent")
    func transmissionOutcomePolicy() {
        #expect(!GatewayRequestTransmissionState.queued.mayHaveBeenSent)
        #expect(GatewayRequestTransmissionState.sending.mayHaveBeenSent)
        #expect(GatewayRequestTransmissionState.sent.mayHaveBeenSent)
    }

    @Test("cancellation during suspended send reports uncertainty and prevents a late ghost frame")
    func suspendedSendCancellation() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000091")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000092")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")
            await socket.suspendSends()

            let request = Task { try await client.requestValue("session.prompt", EmptyParams()) }
            try await socket.waitUntilSendInvoked(count: 2)
            request.cancel()
            do {
                _ = try await valueOfOwnedTask(request)
                Issue.record("cancelled suspended send unexpectedly succeeded")
            } catch let failure as GatewayPossiblySentError {
                #expect(failure.failure.code == "possibly_sent")
            }
            await socket.releaseSend()
            #expect(await socket.sentFrames().count == 1)
            await client.close()
        }
    }

    @Test("cancellation-insensitive send cannot retain the client or transmit after teardown")
    func cancellationInsensitiveSendReleasesClient() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket(deliversSendsAfterCancellation: true)
            let weakClient = WeakGatewayClient()
            var client: GatewayClient? = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000093")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000094")!,
                ]).source
            )
            weakClient.value = client
            await socket.enqueue(helloFrame())
            _ = try await client?.connect(profile: profile, token: "token")
            await socket.suspendSends()

            var request: Task<JSONValue, Error>? = makePromptRequest(client: try #require(client))
            try await socket.waitUntilSendInvoked(count: 2)
            request?.cancel()
            do {
                _ = try await request?.value
                Issue.record("cancelled send unexpectedly succeeded")
            } catch is GatewayPossiblySentError {}
            request = nil
            client = nil

            try await socket.waitUntilClosed()
            #expect(weakClient.value == nil)
            await socket.releaseSend()
            #expect(await socket.sentFrames().count == 1)
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
            } catch let failure as GatewayPossiblySentError {
                #expect(failure.failure.code == "possibly_sent")
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
            #expect(event?.event.topic == "transport.disconnected")
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
            #expect(event?.event.topic == "transport.disconnected")
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

    @Test("background retirement discards queued events while preserving reconnect credentials")
    func backgroundRetirementResetsEventQueue() async throws {
        try await withTestWatchdog {
            let oldSocket = ScriptedGatewaySocket()
            let replacementSocket = ScriptedGatewaySocket()
            let factory = ScriptedGatewaySocketFactory(sockets: [oldSocket, replacementSocket])
            let client = GatewayClient(socketFactory: factory.factory)
            await oldSocket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")
            var iterator = client.events.makeAsyncIterator()

            await oldSocket.enqueue(eventFrame(topic: "stale.changed", payload: .number(1)))
            await Task.yield()
            await client.retireForBackground()
            #expect(await oldSocket.closed())

            await replacementSocket.enqueue(helloFrame())
            _ = try await client.reconnect()
            await replacementSocket.enqueue(eventFrame(topic: "current.changed", payload: .number(2)))
            let delivery = try #require(await iterator.next())
            #expect(delivery.event.topic == "current.changed")
            #expect(delivery.event.payload.intValue == 2)
            await client.close()
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
            var iterator = client.events.makeAsyncIterator()
            await replacementSocket.enqueue(eventFrame(topic: "replacement.changed", payload: .number(7)))
            await Task.yield()

            await oldSocket.releaseClose()
            _ = try await valueOfOwnedTask(oldClose)
            #expect(await oldSocket.closeInvocationCount() == 1)
            #expect(await oldSocket.closeTransitionCount() == 1)
            #expect(await client.info?.machineId == "machine")
            let delivery = try #require(await iterator.next())
            #expect(delivery.event.topic == "replacement.changed")
            #expect(delivery.event.payload.intValue == 7)

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
            #expect(event?.event.topic == "current.changed")
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
            #expect(event?.event.topic == "current.changed")
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
                    guard let delivery = await iterator.next() else { break }
                    events.append(delivery.event)
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

    private func makePromptRequest(client: GatewayClient) -> Task<JSONValue, Error> {
        Task { try await client.requestValue("session.prompt", EmptyParams()) }
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
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8)
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
