import Foundation
import Testing
@testable import TronMobile
@testable import TronMobileCore

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
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"fixture-version","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":[]}"#.utf8))

        do {
            _ = try await client.connect(profile: profile, token: "token")
            Issue.record("v2 handshake unexpectedly succeeded")
        } catch let error as GatewayFailure {
            #expect(error.code == "protocol_mismatch")
        }
        #expect(await socket.sentFrames().count == 1)
        await client.close()
    }

    @Test("a typed protocol-mismatch close names the build that must update")
    func protocolMismatchCloseNamesTheStaleBuild() async throws {
        // The Gateway refuses a hello it cannot speak and closes with a typed
        // reason. Reading that close as the transport failure underneath it
        // retried a permanent build mismatch forever (F-3), so the classification
        // has to name the side the user can update. The fixture is the pair the
        // Gateway's own refusal sends: application close 4006 carrying this
        // Gateway's protocol range. A Gateway with an older range cannot send it
        // (it predates the typed close), which is why an older Mac stays
        // retryable and needs its own update (F-3, Option B).
        let socket = ScriptedGatewaySocket(metadata: GatewaySocketMetadata(
            closeCode: GatewayProtocolMismatchClose.closeCode,
            httpStatusCode: 101,
            closeReason: #"{"code":"protocol_mismatch","gatewayProtocol":6,"minProtocol":6}"#
        ))
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        await socket.failPendingReceivers(URLError(.networkConnectionLost))
        do {
            _ = try await client.connect(profile: profile, token: "token")
            Issue.record("a protocol mismatch unexpectedly connected")
        } catch let error as GatewayFailure {
            #expect(error.code == "protocol_mismatch")
            #expect(!error.retryable)
            #expect(error.message.contains("Update Tron on"))
        }
        await client.close()
    }

    @Test("a Gateway range above this app's protocol names this app")
    func protocolRangeNamesTheStaleSide() {
        // The range is the Gateway's own advertised range, and it is the only
        // fact that says which side can act: a range above this app's protocol
        // means this app is stale. This is the direction today's app can read:
        // a Gateway carrying this refusal covers the app only while the app is
        // inside the Gateway's range. The opposite ordering is what the next
        // app release reads from the same classifier.
        let failure = GatewayProtocolMismatchClose.failure(gatewayProtocol: 8, minProtocol: 8)
        #expect(failure.message.contains("Update Tron on this iPhone"))
        #expect(!failure.retryable)
    }

    @Test("hello requires a bounded channel matching the saved Stable or Debug profile")
    func channelIdentityFailsClosed() async {
        let debug = GatewayProfile(
            id: "debug", label: "Debug", host: "gateway.test", port: 9_848,
            machineId: "machine", deviceId: "device"
        )
        let fixtures: [(GatewayProfile, String)] = [
            (profile, #"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","capabilities":[]}"#),
            (profile, #"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"dev","capabilities":[]}"#),
            (debug, #"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":[]}"#),
            (profile, #"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"preview","capabilities":[]}"#),
        ]
        for (target, frame) in fixtures {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            await socket.enqueue(Data(frame.utf8))
            await #expect(throws: Error.self) {
                try await client.connect(profile: target, token: "token")
            }
            await client.close()
        }
    }

    @Test("hello replaces the LAN endpoints and pin the profile will hold")
    func helloCarriesLanAdvertisement() async throws {
        let pin = Data(repeating: 7, count: 32).base64EncodedString()
        let advertised = ScriptedGatewaySocket()
        let advertisedClient = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: advertised).factory)
        await advertised.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":[],"lanEndpoints":[{"host":"192.168.1.24","port":9847},{"host":"bad/entry","port":9847}],"lanPin":"\#(pin)"}"#.utf8))

        let identity = try await advertisedClient.connectForLifecycle(profile: profile, token: "token")
        // One entry this phone cannot dial is dropped; the leg stays usable.
        #expect(identity.info.lanEndpoints == [GatewayLanEndpoint(host: "192.168.1.24", port: 9_847)])
        #expect(identity.info.lanPin == pin)
        await advertisedClient.close()

        // A Gateway that advertises no lane leaves the profile with no LAN leg
        // rather than a stale one.
        let silent = ScriptedGatewaySocket()
        let silentClient = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: silent).factory)
        await silent.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":[]}"#.utf8))

        let silentIdentity = try await silentClient.connectForLifecycle(profile: profile, token: "token")
        #expect(silentIdentity.info.lanEndpoints.isEmpty)
        #expect(silentIdentity.info.lanPin == nil)
        await silentClient.close()
    }

    @Test("always-on AppLog records repeated RPC completions at debug level")
    func appLogRecordsRPCs() async throws {
        let socket = ScriptedGatewaySocket()
        let ids = SequenceUUIDSource([
            UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        ])
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
            uuidSource: ids.source
        )
        let appLog = AppLog(fileURL: FileManager.default.temporaryDirectory.appending(path: "rpc-app-log-\(UUID().uuidString).jsonl"))
        await client.installAppLog(appLog)
        await socket.enqueue(helloFrame())
        _ = try await client.connect(profile: profile, token: "token")

        for (index, expectedID) in ["00000000-0000-0000-0000-000000000012", "00000000-0000-0000-0000-000000000013"].enumerated() {
            let request = Task { try await client.requestValue("session.list", EmptyParams()) }
            try await socket.waitUntilSent(count: index + 2)
            await socket.enqueue(responseFrame(id: expectedID, result: .array([])))
            _ = try await valueOfOwnedTask(request)
        }
        await Task.yield()
        let records = await appLog.snapshot().filter { $0.event == "rpc.completed" && $0.message == "session.list" }
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.level == "debug" && ($0.profileID == nil || $0.profileID == "machine") })
        await client.close()
    }

    @Test("diagnostic export records only its own send boundary and bounded frame size")
    func diagnosticExportSendBoundary() async throws {
        let socket = ScriptedGatewaySocket()
        let appLogURL = FileManager.default.temporaryDirectory.appending(path: "logs-export-app-log-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: appLogURL)
            try? FileManager.default.removeItem(at: appLogURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: appLogURL)
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
            uuidSource: SequenceUUIDSource([
                UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            ]).source,
            appLog: appLog
        )
        await socket.enqueue(helloFrame())
        _ = try await client.connect(profile: profile, token: "do-not-record-token")

        let normal = Task { try await client.requestValue("system.info", EmptyParams()) }
        try await socket.waitUntilSent(count: 2)
        await socket.enqueue(responseFrame(id: "00000000-0000-0000-0000-000000000012", result: .object(["protocolVersion": .number(7)])))
        _ = try await valueOfOwnedTask(normal)

        let privatePayload = String(repeating: "synthetic-export-private", count: 8_192)
        let exported = Task {
            try await client.requestValue("system.logs.export", JSONValue.object([
                "commandId": .string("synthetic-command-id"), "content": .string(privatePayload),
            ]))
        }
        try await socket.waitUntilSent(count: 3)
        let sent = try #require(await socket.sentFrames().last)
        let object = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let requestID = try #require(object["id"] as? String)
        var heldRecords: [AppLogRecord] = []
        for _ in 0..<100 {
            heldRecords = await appLog.snapshot().filter { $0.event.hasPrefix("logs.export.") }
            if heldRecords.contains(where: { $0.event == "logs.export.requested" }) { break }
            await Task.yield()
        }
        #expect(heldRecords.map(\.event) == ["logs.export.requested"])
        await socket.enqueue(responseFrame(id: requestID, result: .object(["exportedAt": .string("fixture"), "path": .string("synthetic-path")])))
        _ = try await valueOfOwnedTask(exported)

        var records: [AppLogRecord] = []
        for _ in 0..<100 {
            records = await appLog.snapshot().filter { $0.event.hasPrefix("logs.export.") }
            if records.contains(where: { $0.event == "logs.export.terminal" }) { break }
            await Task.yield()
        }
        #expect(records.map(\.event).sorted() == ["logs.export.requested", "logs.export.terminal"])
        #expect(records.allSatisfy { $0.requestID == requestID && $0.connectionID != nil && $0.profileID == nil })
        #expect(records.first(where: { $0.event == "logs.export.requested" })?.message.contains("count=\(sent.count)") == true)
        #expect(records.first(where: { $0.event == "logs.export.terminal" })?.outcome == "success")
        let diagnosticText = String(decoding: try JSONEncoder().encode(await appLog.snapshot()), as: UTF8.self)
        #expect(!diagnosticText.contains(privatePayload))
        #expect(!diagnosticText.contains("do-not-record-token"))
        await client.close()
    }

    @Test("a diagnostic export socket-send failure records size without changing its result")
    func diagnosticExportSendFailure() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
            uuidSource: SequenceUUIDSource([
                UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            ]).source
        )
        let appLogURL = FileManager.default.temporaryDirectory.appending(path: "logs-export-fail-app-log-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: appLogURL)
            try? FileManager.default.removeItem(at: appLogURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: appLogURL)
        await client.installAppLog(appLog)
        await socket.enqueue(helloFrame())
        _ = try await client.connect(profile: profile, token: "token")
        await socket.failNextSend(URLError(.networkConnectionLost))
        do {
            _ = try await client.requestValue("system.logs.export", JSONValue.object(["content": .string("synthetic")] ))
            Issue.record("The failed socket send unexpectedly returned a diagnostic export")
        } catch is GatewayPossiblySentError { }

        var records: [AppLogRecord] = []
        for _ in 0..<100 {
            records = await appLog.snapshot().filter { $0.event.hasPrefix("logs.export.") }
            if records.contains(where: { $0.event == "logs.export.terminal" }) { break }
            await Task.yield()
        }
        #expect(records.map(\.event).sorted() == ["logs.export.requested", "logs.export.terminal"])
        #expect(records.allSatisfy { $0.requestID == "00000000-0000-0000-0000-000000000012" })
        #expect(records.first(where: { $0.event == "logs.export.requested" })?.message.contains("count=") == true)
        #expect(records.first(where: { $0.event == "logs.export.terminal" })?.outcome == "transportFailure")
        await client.close()
    }

    @Test("a cancelled held Logs Export records one terminal without cancelling or replaying it")
    func diagnosticExportCancellationObservesHeldResponse() async throws {
        let socket = ScriptedGatewaySocket()
        let appLog = AppLog(fileURL: FileManager.default.temporaryDirectory.appending(path: "logs-export-cancel-app-log-\(UUID().uuidString).jsonl"))
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
            uuidSource: SequenceUUIDSource([
                UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            ]).source,
            appLog: appLog
        )
        await socket.enqueue(helloFrame())
        _ = try await client.connect(profile: profile, token: "token")
        let export = Task {
            try await client.requestValue("system.logs.export", JSONValue.object(["content": .string("synthetic")]))
        }
        try await socket.waitUntilSent(count: 2)
        let request = try #require(await socket.sentFrames().last)
        let envelope = try #require(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        let requestID = try #require(envelope["id"] as? String)
        var beforeCancellation = await appLog.snapshot().filter { $0.event.hasPrefix("logs.export.") }
        for _ in 0..<100 where !beforeCancellation.contains(where: { $0.event == "logs.export.requested" }) {
            await Task.yield()
            beforeCancellation = await appLog.snapshot().filter { $0.event.hasPrefix("logs.export.") }
        }
        #expect(beforeCancellation.map(\.event) == ["logs.export.requested"])

        export.cancel()
        do {
            _ = try await valueOfOwnedTask(export)
            Issue.record("The cancelled Logs Export unexpectedly returned a response")
        } catch let failure as GatewayPossiblySentError {
            #expect(failure.failure.code == "possibly_sent")
        }
        #expect(await socket.sentFrames().count == 2)
        let heldResponse = responseFrame(id: requestID, result: .object(["path": .string("synthetic-path")]))
        await socket.enqueue(heldResponse)
        await Task.yield()
        let records = await appLog.snapshot().filter { $0.event.hasPrefix("logs.export.") }
        #expect(records.map(\.event).sorted() == ["logs.export.requested", "logs.export.terminal"])
        #expect(records.filter { $0.event == "logs.export.terminal" }.count == 1)
        #expect(records.first(where: { $0.event == "logs.export.terminal" })?.outcome == "cancelled")
        #expect(await socket.sentFrames().count == 2)
        await client.close()
    }

    @Test("attachment HTTP correlation is bounded and transport failure preserves its result")
    func attachmentHTTPDiagnosticCorrelation() async throws {
        let socket = ScriptedGatewaySocket()
        let appLogURL = FileManager.default.temporaryDirectory.appending(path: "upload-app-log-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: appLogURL)
            try? FileManager.default.removeItem(at: appLogURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: appLogURL)
        let requestIDs = HTTPRequestIDCapture()
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
            uuidSource: SequenceUUIDSource([
                UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            ]).source,
            boundedHTTPDataTransport: BoundedHTTPDataTransport { request, _, _ in
                await requestIDs.record(request)
                throw URLError(.networkConnectionLost)
            },
            appLog: appLog
        )
        await socket.enqueue(helloFrame())
        _ = try await client.connect(profile: profile, token: "do-not-record-token")
        let fileName = "private-upload-name.pdf"
        do {
            _ = try await client.upload(name: fileName, mimeType: "application/private", data: Data(repeating: 42, count: 128))
            Issue.record("The failed attachment upload unexpectedly returned a staged ID")
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost)
        }

        let requestID = try #require(await requestIDs.value())
        #expect(UUID(uuidString: requestID) != nil)
        var records: [AppLogRecord] = []
        for _ in 0..<100 {
            records = await appLog.snapshot().filter { $0.event.hasPrefix("http.upload.") }
            if records.contains(where: { $0.event == "http.upload.terminal" }) { break }
            await Task.yield()
        }
        #expect(records.map(\.event).sorted() == ["http.upload.requested", "http.upload.terminal"])
        #expect(records.allSatisfy { $0.requestID == requestID && $0.profileID == nil })
        #expect(records.first(where: { $0.event == "http.upload.requested" })?.message.contains("count=128") == true)
        #expect(records.allSatisfy { $0.message.contains("route=saved") })
        #expect(records.first(where: { $0.event == "http.upload.terminal" })?.outcome == "failure")
        let diagnosticText = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        #expect(!diagnosticText.contains(fileName))
        #expect(!diagnosticText.contains("application/private"))
        #expect(!diagnosticText.contains("do-not-record-token"))
        await client.close()
    }

    @Test("a timed-out disposable read sends a cancel frame, a mutation does not")
    func timedOutReadSendsCancelFrame() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
                ]).source
            )
            let appLog = AppLog(fileURL: FileManager.default.temporaryDirectory.appending(path: "cancel-app-log-\(UUID().uuidString).jsonl"))
            await client.installAppLog(appLog)
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            // The Gateway never answers, so the request times out and the phone
            // tells the Gateway to stop computing the read it abandoned.
            let read = Task { try await client.requestValue("session.open", EmptyParams(), timeout: .seconds(30)) }
            try await clock.expireRequest(on: socket, sentCount: 2, after: .seconds(30))
            do {
                _ = try await valueOfOwnedTask(read)
                Issue.record("the abandoned read unexpectedly answered")
            } catch let failure as GatewayPossiblySentError {
                #expect(failure.failure.code == "possibly_sent")
            }
            try await socket.waitUntilSent(count: 3)
            let cancelFrame = try #require(await socket.sentFrames().last)
            let cancel = try #require(try JSONSerialization.jsonObject(with: cancelFrame) as? [String: Any])
            #expect(cancel["type"] as? String == "cancel")
            #expect(cancel["id"] as? String == "00000000-0000-0000-0000-000000000012")

            // An admitted mutation keeps its owner: the phone never cancels it,
            // whatever it does with its own wait.
            let mutation = Task { try await client.requestValue("session.prompt", EmptyParams(), timeout: .seconds(30)) }
            try await clock.expireRequest(on: socket, sentCount: 4, after: .seconds(30))
            do {
                _ = try await valueOfOwnedTask(mutation)
                Issue.record("the abandoned mutation unexpectedly answered")
            } catch let failure as GatewayPossiblySentError {
                #expect(failure.failure.code == "possibly_sent")
            }
            await Task.yield()
            #expect(await socket.sentFrames().count == 4)

            let cancellations = await appLog.snapshot().filter { $0.event == "rpc.cancelled" }
            #expect(cancellations.count == 1)
            #expect(cancellations.first?.message == "session.open")
            #expect(cancellations.first?.outcome == "cancelled")
            #expect(cancellations.first?.level == "debug")
            await client.close()
        }
    }

    @Test("a shed disposable read is retried after the Gateway's hint, a mutation is not")
    func shedReadRetriesAfterHint() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                // The connection consumes the first identity, so the shed read is
                // the second, its retry the third and the mutation the fourth.
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000024")!,
                ]).source
            )
            let appLog = AppLog(fileURL: FileManager.default.temporaryDirectory.appending(path: "retry-after-app-log-\(UUID().uuidString).jsonl"))
            await client.installAppLog(appLog)
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            // The Gateway sheds the read with a hint; the phone waits it out and
            // asks again under a new identity.
            let read = Task { try await client.requestValue("session.list", EmptyParams()) }
            try await socket.waitUntilSent(count: 2)
            await socket.enqueue(shedResponseFrame(id: "00000000-0000-0000-0000-000000000022", retryAfterMs: 1))
            try await socket.waitUntilSent(count: 3)
            let retry = try #require(await socket.sentFrames().last)
            let frame = try #require(try JSONSerialization.jsonObject(with: retry) as? [String: Any])
            #expect(frame["method"] as? String == "session.list")
            #expect(frame["id"] as? String == "00000000-0000-0000-0000-000000000023")
            await socket.enqueue(responseFrame(id: "00000000-0000-0000-0000-000000000023", result: .array([])))
            _ = try await valueOfOwnedTask(read)

            // An admitted mutation is never retried, even with the same hint.
            let mutation = Task { try await client.requestValue("session.prompt", EmptyParams()) }
            try await socket.waitUntilSent(count: 4)
            await socket.enqueue(shedResponseFrame(id: "00000000-0000-0000-0000-000000000024", retryAfterMs: 1))
            do {
                _ = try await valueOfOwnedTask(mutation)
                Issue.record("the shed mutation unexpectedly answered")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "busy")
            }
            await Task.yield()
            #expect(await socket.sentFrames().count == 4)

            let retries = await appLog.snapshot().filter { $0.event == "rpc.retry-after" }
            #expect(retries.count == 1)
            #expect(retries.first?.message == "session.list")
            #expect(retries.first?.code == "busy")
            #expect(retries.first?.durationMs == 1)
            #expect(retries.first?.outcome == "retrying")
            await client.close()
        }
    }

    @Test("a cancel frame cannot overtake the request it cancels")
    func cancelFrameFollowsItsRequest() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket(deliversSendsAfterCancellation: true)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")
            // The request's own write is still in flight when its wait is abandoned.
            await socket.suspendSends()
            let read = Task { try await client.requestValue("session.open", EmptyParams()) }
            try await socket.waitUntilSendInvoked(count: 2)
            read.cancel()
            do {
                _ = try await valueOfOwnedTask(read)
                Issue.record("the abandoned read unexpectedly answered")
            } catch let failure as GatewayPossiblySentError {
                #expect(failure.failure.code == "possibly_sent")
            }
            // The cancel waits for that write: a frame that jumped ahead of it
            // would name a request the Gateway never admitted and do nothing.
            try await Task.sleep(for: .milliseconds(50))
            #expect(await socket.sendInvocationCount() == 2)
            await socket.releaseSend()
            try await socket.waitUntilSent(count: 3)
            let frames = await socket.sentFrames()
            #expect(frames.count == 3)
            let request = try #require(try JSONSerialization.jsonObject(with: frames[1]) as? [String: Any])
            let cancel = try #require(try JSONSerialization.jsonObject(with: frames[2]) as? [String: Any])
            #expect(request["method"] as? String == "session.open")
            #expect(cancel["type"] as? String == "cancel")
            #expect(cancel["id"] as? String == request["id"] as? String)
            await client.close()
        }
    }

    @Test("typed response decoding reports the RPC method and sanitized missing-key path")
    func typedResponseDecodeDiagnostics() async throws {
        struct Response: Decodable {
            struct Session: Decodable {
                struct Stats: Decodable { let tokens: Int }
                let stats: Stats
            }
            let session: Session
        }

        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        await socket.enqueue(helloFrame())
        _ = try await client.connect(profile: profile, token: "token")

        let request = Task {
            try await client.request("session.open", EmptyParams(), as: Response.self)
        }
        defer { request.cancel() }
        try await socket.waitUntilSent(count: 2)
        let sent = try await decodedValue(in: socket, index: 1)
        let requestID = try #require(sent.objectValue?["id"]?.stringValue)
        await socket.enqueue(responseFrame(
            id: requestID,
            result: .object(["session": .object(["stats": .object([:])])])
        ))

        do {
            _ = try await valueOfOwnedTask(request)
            Issue.record("malformed typed response unexpectedly decoded")
        } catch let failure as GatewayFailure {
            #expect(failure.code == "invalid_response")
            #expect(failure.retryable == false)
            #expect(failure.message.contains("session.open"))
            #expect(failure.message.contains("session.stats.tokens"))
            #expect(failure.message.contains("View Logs"))
            #expect(failure.details?.objectValue?["category"] == .string("missing_required_data"))
            #expect(failure.details?.objectValue?["codingPath"] == .string("session.stats.tokens"))
        }
        await client.close()
    }

    @Test("typed response diagnostics redact response-owned dictionary keys")
    func typedResponseDecodeDiagnosticsRedactDynamicKeys() throws {
        struct Response: Decodable {
            struct Session: Decodable { let required: Int }
            let sessions: [String: Session]
        }
        let sensitiveKey = "01a0228a-secret-provider-value"
        let value = JSONValue.object([
            "sessions": .object([sensitiveKey: .object([:])]),
        ])

        do {
            _ = try GatewayResponseDecoding.decode(value, as: Response.self, method: "session.open")
            Issue.record("malformed dictionary response unexpectedly decoded")
        } catch let failure as GatewayFailure {
            let path = try #require(failure.details?.objectValue?["codingPath"]?.stringValue)
            #expect(path == "sessions.<redacted>.required")
            #expect(!failure.message.contains(sensitiveKey))
            #expect(!path.contains(sensitiveKey))
        }
    }

    @Test("canonical file preview identities route only valid upload UUIDs")
    func canonicalFilePreviewRoutes() {
        #expect(GatewayClient.mediaPath(id: "blob-value") == "/v1/blobs/blob-value")
        #expect(GatewayClient.mediaPath(id: "upload:00000000-0000-4000-8000-000000000001")
            == "/v1/uploads/00000000-0000-4000-8000-000000000001")
        #expect(GatewayClient.mediaPath(id: "upload:") == nil)
        #expect(GatewayClient.mediaPath(id: "upload:../../private") == nil)
    }

    @Test("event activation is idempotent for one connection epoch")
    func eventActivationIsIdempotent() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock
            )
            await socket.enqueue(helloFrame())
            let identity = try await client.connectForLifecycle(profile: profile, token: "token")
            try await client.activateEvents(connectionID: identity.id)
            try await client.activateEvents(connectionID: identity.id)
            try await clock.waitUntilSleeping(count: 1)

            #expect(await socket.pendingReceiverCount() == 1)
            #expect(clock.activeSleeperCount() == 1)
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
            #expect(delivery.event.admittedBytes > 0)
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

    @Test("node-budget frame decode records bounded evidence before strict retirement")
    func nodeBudgetFrameDecodeDiagnostic() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            var events = client.events.makeAsyncIterator()
            let request = Task { try await client.requestValue("test.large", EmptyParams()) }
            defer { request.cancel() }
            try await socket.waitUntilSent(count: 2)
            let requestValue = try await decodedValue(in: socket, index: 1)
            let requestID = try #require(requestValue.objectValue?["id"]?.stringValue)

            // Each item has seven scalar members, keeping collection limits below
            // their cap while the complete result exceeds the node budget.
            let item = #"{"a":0,"b":0,"c":0,"d":0,"e":0,"f":0,"g":0}"#
            let result = #"{"session":{"transcript":["#
                + Array(repeating: item, count: 4_096).joined(separator: ",")
                + #"]}}"#
            let frame = Data(("{\"type\":\"response\",\"id\":\"" + requestID + "\",\"ok\":true,\"result\":" + result + "}").utf8)
            #expect(frame.count < GatewayFramePolicy.maximumInboundBytes)
            await socket.enqueue(frame)

            do {
                _ = try await valueOfOwnedTask(request)
                Issue.record("node-budget response unexpectedly succeeded")
            } catch let failure as GatewayPossiblySentError {
                #expect(failure.failure.code == "possibly_sent")
            } catch {
                Issue.record("unexpected node-budget response failure: \(error)")
            }
            let disconnected = try #require(await events.next())
            #expect(disconnected.event.topic == "transport.disconnected")
            #expect(disconnected.event.payload.objectValue?["reason"] == .string("disconnected"))

            let diagnostics = await client.diagnostics()
            let decode = try #require(diagnostics.first { $0.reason == .decodeLimit })
            #expect(decode.frameBytes == frame.count)
            #expect(decode.decodeLimitKind == .nodes)
            #expect(decode.decodeActual == JSONValueDecodingLimits.gateway.maximumNodes + 1)
            #expect(decode.decodeMaximum == JSONValueDecodingLimits.gateway.maximumNodes)
            #expect(decode.decodeCodingPath == "result.<dynamic>.<dynamic>")
            #expect(decode.clientID != nil)
            #expect(decode.connectionID != nil)
            #expect(decode.profileID == profile.id)
            #expect(diagnostics.contains { $0.reason == .transport })
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

    @Test("the hello deadline advances on the injected monotonic clock")
    func virtualHelloTimeout() async throws {
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
            // This socket opens at once, so the wait the deadline owns is the
            // hello one that follows the write.
            try await socket.waitUntilSent(count: 1)
            try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.helloDeadline)
            clock.advance(by: GatewayConnectionPolicy.helloDeadline)

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
            #expect(await client.diagnostics().contains { $0.reason == .canceled })
            await client.close()
        }
    }

    @Test("ping completion remembers cancellation before install and ignores late callbacks")
    func pingCompletionCancellationIsSingleSettlement() async throws {
        for cancelBeforeInstall in [true, false] {
            let completion = GatewayPingCompletion()
            if cancelBeforeInstall { completion.cancel() }
            await #expect(throws: CancellationError.self) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    #expect(completion.install(continuation) == !cancelBeforeInstall)
                    completion.cancel()
                    completion.settle(.success(()))
                    completion.cancel()
                }
            }
        }
        let completion = GatewayPingCompletion()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            #expect(completion.install(continuation))
            completion.settle(.success(()))
            completion.cancel()
            completion.settle(.failure(URLError(.networkConnectionLost)))
        }
    }

    @Test("application RPCs are definitely unsent until hello and receive activation finish")
    func requestsRequireActivatedHello() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let connecting = Task { try await client.connectForLifecycle(profile: profile, token: "token") }
            defer { connecting.cancel() }
            try await socket.waitUntilSent(count: 1)
            await #expect(throws: GatewayDefinitelyNotSentError.self) {
                try await client.requestValue("system.logs", EmptyParams())
            }
            await socket.enqueue(helloFrame())
            let connection = try await valueOfOwnedTask(connecting)
            await #expect(throws: GatewayDefinitelyNotSentError.self) {
                try await client.requestValue("system.logs", EmptyParams())
            }
            #expect(await socket.sentFrames().count == 1)
            try await client.activateEvents(connectionID: connection.id)
            let request = Task { try await client.requestValue("system.logs", EmptyParams()) }
            defer { request.cancel() }
            try await socket.waitUntilSent(count: 2)
            let frame = try await decodedValue(in: socket, index: 1)
            let id = try #require(frame.objectValue?["id"]?.stringValue)
            await socket.enqueue(responseFrame(id: id, result: .object([:])))
            _ = try await valueOfOwnedTask(request)
            await client.close()
        }
    }

    @Test("a disconnected epoch admission cannot cross a replacement connection")
    func disconnectedEpochAdmissionCannotCrossReplacement() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let admission = await client.activeConnectionAdmission()
        #expect(admission.connectionID == nil)

        await socket.enqueue(helloFrame())
        _ = try await client.connect(profile: profile, token: "token")
        await #expect(throws: GatewayDefinitelyNotSentError.self) {
            try await client.requestValue(
                "test.echo",
                EmptyParams(),
                expectedConnection: admission
            )
        }
        #expect(await socket.sentFrames().count == 1)
        await client.close()
    }

    @Test("a stall before the socket opens ends at the transport-open deadline")
    func transportOpenStallIsRetiredAtItsDeadline() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket(suspendsSend: true)
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock
            )
            let connection = Task { try await client.connect(profile: profile, token: "token") }
            defer { connection.cancel() }
            try await socket.waitUntilSendInvoked(count: 1)
            try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.transportOpenDeadline)
            clock.advance(by: GatewayConnectionPolicy.transportOpenDeadline)
            for _ in 0..<10 { await Task.yield() }
            try await socket.waitUntilCloseInvoked()
            await socket.releaseSend()
            await #expect(throws: GatewayFailure.self) { try await valueOfOwnedTask(connection) }
            #expect(await socket.closeInvocationCount() >= 1)
            #expect(await client.activeConnectionID() == nil)
            await client.close()
        }
    }

    @Test("a socket that opened but never answers hello keeps the hello deadline")
    func slowHelloKeepsItsOwnDeadline() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock
            )
            let connection = Task { try await client.connect(profile: profile, token: "token") }
            defer { connection.cancel() }
            try await socket.waitUntilSendInvoked(count: 1)
            // The hello write completed, so the socket is open: the pending wait
            // is the hello bound, and the transport bound has no answer to end.
            try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.helloDeadline)
            clock.advance(by: GatewayConnectionPolicy.transportOpenDeadline)
            for _ in 0..<10 { await Task.yield() }
            #expect(await socket.closeInvocationCount() == 0)
            // A Mac that answers late, but inside its own bound, is admitted.
            await socket.enqueue(helloFrame())
            let info = try await valueOfOwnedTask(connection)
            #expect(info.machineId == "machine")
            await client.close()
        }
    }

    @Test("a socket that opened and then went silent ends at the hello deadline")
    func silentHelloEndsAtTheHelloDeadline() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock
            )
            let connection = Task { try await client.connect(profile: profile, token: "token") }
            defer { connection.cancel() }
            try await socket.waitUntilSendInvoked(count: 1)
            try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.helloDeadline)
            clock.advance(by: GatewayConnectionPolicy.transportOpenDeadline)
            for _ in 0..<10 { await Task.yield() }
            #expect(await socket.closeInvocationCount() == 0)
            clock.advance(by: GatewayConnectionPolicy.helloDeadline)
            for _ in 0..<10 { await Task.yield() }
            try await socket.waitUntilCloseInvoked()
            await #expect(throws: GatewayFailure.self) { try await valueOfOwnedTask(connection) }
            #expect(await client.activeConnectionID() == nil)
            await client.close()
        }
    }

    @Test("connect failures say whether the WebSocket opened and on which interfaces", arguments: [false, true])
    func connectFailureRecordsTransportOpening(opens: Bool) async throws {
        try await withTestWatchdog {
            let suite = "TronConnectFailure.\(UUID())"
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let store = IOSClientDiagnosticStore(defaults: try #require(UserDefaults(suiteName: suite)))
            let clock = ManualClock()
            // A path that never reaches the Mac stalls the hello write on an
            // unopened socket and gives up at the transport-open bound; a Mac
            // that accepts but never answers stalls the hello read on an open
            // socket and gives up at the hello bound.
            let socket = opens
                ? ScriptedGatewaySocket(metadata: .init(closeCode: nil, httpStatusCode: nil, transportOpenMilliseconds: 42))
                : ScriptedGatewaySocket(suspendsSend: true, metadata: .init(closeCode: nil, httpStatusCode: nil, waitedForConnectivity: true))
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock,
                diagnosticStore: store,
                networkPath: { "wifi,other" }
            )
            let connection = Task { try await client.connect(profile: profile, token: "token") }
            defer { connection.cancel() }
            try await socket.waitUntilSendInvoked(count: 1)
            let deadline = opens ? GatewayConnectionPolicy.helloDeadline : GatewayConnectionPolicy.transportOpenDeadline
            try await clock.waitUntilSleeping(count: 1, duration: deadline)
            clock.advance(by: deadline)
            for _ in 0..<10 { await Task.yield() }
            try await socket.waitUntilCloseInvoked()
            if !opens { await socket.releaseSend() }
            await #expect(throws: GatewayFailure.self) { try await valueOfOwnedTask(connection) }
            await store.flush()
            // The handshake record, not the transport retirement that follows it.
            let failure = try #require(await store.load().first {
                $0.record.event == "gateway.connection" && $0.record.message.contains("outcome=failure")
                    && !$0.record.message.hasPrefix("stage=transport ")
            }).record.message
            #expect(failure.contains("reason=timeout"))
            #expect(failure.contains("interfaces=wifi,other"))
            if opens {
                #expect(failure.contains("stage=hello-receive"))
                #expect(failure.contains("transportOpened=true"))
                #expect(failure.contains("transportOpenMs=42"))
            } else {
                #expect(failure.contains("stage=transport-open"))
                #expect(failure.contains("transportOpened=false"))
                #expect(failure.contains("waitedForConnectivity=true"))
                #expect(!failure.contains("transportOpenMs="))
            }
            await client.close()
        }
    }

    @Test("a successful handshake records that the transport opened")
    func successfulHandshakeRecordsTransportOpened() async throws {
        try await withTestWatchdog {
            let suite = "TronConnectSuccess.\(UUID())"
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let store = IOSClientDiagnosticStore(defaults: try #require(UserDefaults(suiteName: suite)))
            // The scripted socket reports no open time; completing hello proves it opened.
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                diagnosticStore: store,
                networkPath: { nil }
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")
            await store.flush()
            let success = try #require(await store.load().first {
                $0.record.event == "gateway.connection" && $0.record.message.contains("stage=hello-receive outcome=success")
            }).record.message
            #expect(success.contains("transportOpened=true"))
            #expect(success.contains("interfaces=unknown"))
            await client.close()
        }
    }

    // Failure modes (O-1 correlation key): the hello omits or mis-populates
    // `diagnostics`; the Gateway's connectionId is missing from the success
    // record or from later records of the same epoch; a successor epoch
    // inherits its predecessor's Gateway ID; a hello without connectionId
    // fails the handshake.
    @Test("hello carries the correlation key and connection records name the Gateway connection")
    func helloCorrelationKey() async throws {
        try await withTestWatchdog {
            let suite = "TronCorrelation.\(UUID())"
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let store = IOSClientDiagnosticStore(defaults: try #require(UserDefaults(suiteName: suite)))
            let first = ScriptedGatewaySocket()
            let second = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(sockets: [first, second]).factory,
                diagnosticStore: store
            )
            do {
                await first.enqueue(helloFrame(connectionID: "gateway-connection-1"))
                let initial = try await client.connectForLifecycle(profile: profile, token: "token")
                #expect(try await decodedValue(in: first, index: 0).objectValue?["diagnostics"] == .object([
                    "clientId": .string(client.diagnosticOwnerID),
                    "attemptId": .string("initial"),
                    "epoch": .string(String(initial.id)),
                ]))
                #expect(initial.gatewayConnectionID == "gateway-connection-1")

                // The key is diagnostic: a Gateway that omits it still admits.
                await second.enqueue(helloFrame())
                let replacement = try await client.reconnectForLifecycle(
                    profile: profile, token: "token", attemptID: "fixture-attempt"
                )
                #expect(try await decodedValue(in: second, index: 0).objectValue?["diagnostics"] == .object([
                    "clientId": .string(client.diagnosticOwnerID),
                    "attemptId": .string("fixture-attempt"),
                    "epoch": .string(String(replacement.id)),
                ]))
                #expect(replacement.gatewayConnectionID == nil)
                await client.close()
                await store.flush()

                let records = await store.load()
                    .filter { $0.record.event == "gateway.connection" }
                    .map(\.record.message)
                let initialRecords = records.filter { $0.contains("connectionID=\(initial.id) ") }
                #expect(initialRecords.contains { $0.hasPrefix("stage=hello-receive outcome=success") })
                #expect(initialRecords.contains { $0.hasPrefix("stage=transport ") })
                #expect(initialRecords.allSatisfy { $0.contains("gatewayConnectionId=gateway-connection-1") })
                let replacementRecords = records.filter { $0.contains("connectionID=\(replacement.id) ") }
                #expect(replacementRecords.contains { $0.hasPrefix("stage=hello-receive outcome=success") })
                #expect(replacementRecords.allSatisfy { !$0.contains("gatewayConnectionId=") })
            } catch {
                await client.close()
                throw error
            }
        }
    }

    @Test("hello deadline closes before a cancellation-insensitive hello receive can finish")
    func stalledHelloReceiveClosesBeforeLateCallback() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket(deliversCallbacksAfterClose: true)
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock
            )
            let connection = Task { try await client.connect(profile: profile, token: "token") }
            defer { connection.cancel() }
            try await socket.waitUntilSendInvoked(count: 1)
            try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.helloDeadline)
            clock.advance(by: GatewayConnectionPolicy.helloDeadline)
            for _ in 0..<10 { await Task.yield() }
            try await socket.waitUntilCloseInvoked()
            await socket.enqueue(helloFrame())
            await #expect(throws: GatewayFailure.self) { try await valueOfOwnedTask(connection) }
            #expect(await socket.closeInvocationCount() >= 1)
            #expect(await client.activeConnectionID() == nil)
            await client.close()
        }
    }

    @Test("current send failure retires its epoch without losing possibly-sent classification")
    func currentSendFailureRetiresEpoch() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")
            await socket.failNextSend(URLError(.networkConnectionLost))
            var events = client.events.makeAsyncIterator()
            let request = Task { try await client.requestValue("session.prompt", EmptyParams()) }
            defer { request.cancel() }
            try await socket.waitUntilSendInvoked(count: 2)
            await #expect(throws: GatewayPossiblySentError.self) { try await valueOfOwnedTask(request) }
            let disconnected = await events.next()
            #expect(disconnected?.event.topic == "transport.disconnected")
            #expect(disconnected?.event.payload.objectValue?["reason"] == .string("transport_send_failed"))
            let diagnostic = try #require(await client.diagnostics().first { $0.reason == .sendFailure })
            #expect(diagnostic.platformCode == URLError.networkConnectionLost.rawValue)
            #expect(await socket.closeInvocationCount() == 1)
            #expect(await client.activeConnectionID() == nil)
            await client.close()
        }
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

    @Test("transport pings precede the Gateway heartbeat and an enqueue failure retires the epoch")
    func deterministicLivenessTiming() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket()
            await socket.failNextPing(GatewayFailure(
                code: "disconnected", message: "ping failed", retryable: true, details: nil
            ))
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000025")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")
            try await clock.waitUntilSleeping(count: 1)

            var eventIterator = client.events.makeAsyncIterator()
            clock.advance(by: .seconds(10))
            try await socket.waitUntilPingInvoked(count: 1)
            try await socket.waitUntilClosed()
            let event = await eventIterator.next()
            #expect(event?.event.topic == "transport.disconnected")
            #expect(await socket.sentFrames().count == 1)
            #expect(await socket.closeInvocationCount() == 1)
            #expect(await socket.closeTransitionCount() == 1)
            #expect(await client.info == nil)
        }
    }

    @Test("a frame suspended before hub admission cannot enter its replacement epoch")
    func lateFrameAdmissionIsFenced() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let old = ScriptedGatewaySocket()
            let replacement = ScriptedGatewaySocket()
            let gate = TestReadGate()
            let oldReports = AsyncStream<GatewayEventAdmission>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let newReports = AsyncStream<GatewayEventAdmission>.makeStream(bufferingPolicy: .bufferingNewest(2))
            defer {
                oldReports.continuation.finish()
                newReports.continuation.finish()
            }
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(sockets: [old, replacement]).factory,
                clock: clock.clock,
                eventBufferPolicy: .init(maximumEvents: 2, maximumBytes: 4096)
            )
            do {
                await old.enqueue(helloFrame())
                _ = try await GatewayClient.$hostedEventAdmissionGate.withValue({
                    await gate.wait()
                    return { oldReports.continuation.yield($0) }
                }) {
                    try await client.connect(profile: profile, token: "token")
                }
                await old.enqueue(eventFrame(topic: "packages.progress", payload: .object(["value": .number(0)])))
                try await gate.waitForEntry()
                await replacement.enqueue(helloFrame())
                _ = try await GatewayClient.$hostedEventAdmissionGate.withValue({
                    { newReports.continuation.yield($0) }
                }) {
                    try await client.connect(profile: profile, token: "token")
                }
                let replacementID = try #require(await client.activeConnectionID())
                var reports = newReports.stream.makeAsyncIterator()
                let firstFrame = eventFrame(topic: "packages.progress", payload: .object(["value": .number(1)]))
                await replacement.enqueue(firstFrame)
                let first = try #require(await reports.next())
                #expect(first.accepted)
                #expect(first.admittedBytes == firstFrame.count)
                await gate.release()
                var retired = oldReports.stream.makeAsyncIterator()
                let late = try #require(await retired.next())
                #expect(!late.accepted)
                #expect(late.reason == .retiredEpoch)
                #expect(late.snapshot == first.snapshot)
                await replacement.enqueue(eventFrame(topic: "packages.progress", payload: .object(["value": .number(2)])))
                let second = try #require(await reports.next())
                try #require(second.accepted)
                #expect(second.snapshot.bufferedEventCount == 2)
                #expect(second.snapshot.admittedCount == 2)
                var events = client.events.makeAsyncIterator()
                for expected in 1...2 {
                    let event = try #require(await events.next())
                    #expect(event.connectionID == replacementID)
                    #expect(event.event.admittedBytes == firstFrame.count)
                    #expect(event.event.payload.objectValue?["value"]?.intValue == expected)
                }
                #expect(await client.activeConnectionID() == replacementID)
                await client.close()
            } catch {
                await gate.release()
                await client.close()
                throw error
            }
        }
    }

    @Test("a missing pong closes the exact socket and emits one transport retirement")
    func missingPongRetiresExactEpoch() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let predecessor = ScriptedGatewaySocket()
            let socket = ScriptedGatewaySocket(suspendsPing: true)
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(sockets: [predecessor, socket]).factory,
                clock: clock.clock
            )
            do {
                await predecessor.enqueue(helloFrame())
                _ = try await client.connectForLifecycle(profile: profile, token: "token")
                await socket.enqueue(helloFrame())
                let connection = try await client.reconnectForLifecycle(
                    profile: profile, token: "token", activateEvents: true, attemptID: "fixture-attempt"
                )
                try await clock.waitUntilSleeping(count: 1, duration: .seconds(10))
                var events = client.events.makeAsyncIterator()
                clock.advance(by: .seconds(10))
                try await socket.waitUntilPingInvoked(count: 1)
                try await clock.waitUntilSleeping(count: 1, duration: .seconds(8))
                clock.advance(by: .seconds(8))
                try await socket.waitUntilClosed()
                let event = await events.next()
                #expect(event?.connectionID == connection.id)
                #expect(event?.event.topic == "transport.disconnected")
                #expect(event?.event.payload.objectValue?["reason"] == .string("pong_timeout"))
                let diagnostics = await client.diagnostics()
                let probe = try #require(diagnostics.first { $0.stage == .liveness })
                #expect(probe.reason == .pingTimeout)
                #expect(probe.durationMilliseconds == 8_000)
                #expect(probe.platformCode == nil)
                let retirement = try #require(diagnostics.first { $0.stage == .transport && $0.connectionID == connection.id })
                #expect(retirement.durationMilliseconds == 18_000)
                #expect(probe.attemptID == "fixture-attempt")
                #expect(retirement.attemptID == probe.attemptID)
                #expect(await client.info == nil)
                await client.close()
            } catch {
                await client.close()
                throw error
            }
        }
    }

    @Test("server traffic cannot suppress the transport heartbeat proof")
    func inboundTrafficDoesNotSuppressLivenessProbe() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                clock: clock.clock,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")
            try await clock.waitUntilSleeping(count: 1)

            clock.advance(by: .seconds(5))
            var eventIterator = client.events.makeAsyncIterator()
            await socket.enqueue(eventFrame(topic: "session.summary", payload: .object([:])))
            #expect(await eventIterator.next()?.event.topic == "session.summary")

            clock.advance(by: .seconds(5))
            try await socket.waitUntilPingInvoked(count: 1)
            #expect(await socket.sentFrames().count == 1)
            for _ in 0..<50 {
                if clock.recordedSleeps().filter({ $0 == .seconds(10) }).count >= 2 { break }
                await Task.yield()
            }
            #expect(clock.recordedSleeps().filter({ $0 == .seconds(10) }).count >= 2)
            clock.advance(by: .seconds(10))
            try await socket.waitUntilPingInvoked(count: 2)
            #expect(await client.info?.machineId == "machine")
            await client.close()
        }
    }

    @Test("a pong queued behind inbound data does not retire the link")
    func inboundDataAnswersQueuedPong() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket(suspendsPing: true)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory, clock: clock.clock)
            do {
                await socket.enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "synthetic-token")
                let connectionID = try #require(await client.activeConnectionID())
                var events = client.events.makeAsyncIterator()
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPingInterval)
                clock.advance(by: GatewayConnectionPolicy.clientPingInterval)
                try await socket.waitUntilPingInvoked(count: 1)
                // The probe's own deadline must be registered before the clock
                // moves, or the frame below lands before the probe exists.
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPongDeadline)

                // A large frame is still arriving at the 8 s deadline, so this
                // probe's pong is queued behind it; the frame reaching the app
                // at 15 s is the same proof that the transport is alive.
                clock.advance(by: .seconds(5))
                await socket.enqueue(eventFrame(topic: "session.summary", payload: .object([:])))
                #expect(await events.next()?.event.topic == "session.summary")
                clock.advance(by: .seconds(3))

                // The deadline passed in data, not in silence, so the epoch
                // survives and waits for the next shared grid tick. The probe
                // leaves one debug record so a run that sees no `pong_timeout`
                // retirement can still tell the excuse path ran.
                try await clock.waitUntilSleeping(count: 1, duration: .seconds(2))
                #expect(await client.activeConnectionID() == connectionID)
                #expect(await socket.pingInvocationCount() == 1)
                let liveness = await client.diagnostics().filter { $0.stage == .liveness }
                #expect(liveness.count == 1)
                #expect(liveness.first?.outcome == .excused)
                #expect(liveness.first?.reason == .pingTimeout)
                #expect(liveness.first?.durationMilliseconds == 8_000)

                clock.advance(by: .seconds(2))
                try await socket.waitUntilPingInvoked(count: 2)
                #expect(await client.info?.machineId == "machine")
                await client.close()
            } catch {
                await client.close()
                throw error
            }
        }
    }

    @Test("silence after data retires the link within eighteen seconds of the last frame")
    func silenceAfterDataRetiresWithinBound() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket(suspendsPing: true)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory, clock: clock.clock)
            do {
                await socket.enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "synthetic-token")
                let connectionID = try #require(await client.activeConnectionID())
                var events = client.events.makeAsyncIterator()
                // The first grid tick probes at 10 s even though data is
                // arriving; the frame at 10.5 s answers that probe.
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPingInterval)
                clock.advance(by: GatewayConnectionPolicy.clientPingInterval)
                try await socket.waitUntilPingInvoked(count: 1)
                // The probe's own deadline must be registered before the clock
                // moves, or the frame below lands before the probe exists.
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPongDeadline)
                clock.advance(by: .milliseconds(500))
                await socket.enqueue(eventFrame(topic: "session.summary", payload: .object([:])))
                #expect(await events.next()?.event.topic == "session.summary")
                // That frame proves liveness for the first probe, so the wait
                // re-arms at the next grid tick (20 s).
                clock.advance(by: .milliseconds(7_500))
                try await clock.waitUntilSleeping(count: 1, duration: .seconds(2))

                // Silence from 10.5 s: no frame answers the probe at 20 s, so
                // the link is retired at that probe's 28 s deadline, 17.5 s
                // after the last frame and inside the 18 s bound.
                clock.advance(by: .seconds(2))
                try await socket.waitUntilPingInvoked(count: 2)
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPongDeadline)
                clock.advance(by: GatewayConnectionPolicy.clientPongDeadline)
                try await socket.waitUntilClosed()

                let diagnostics = await client.diagnostics()
                let probe = try #require(diagnostics.first { $0.stage == .liveness })
                #expect(probe.reason == .pingTimeout)
                #expect(probe.durationMilliseconds == 8_000)
                let retirement = try #require(diagnostics.first { $0.stage == .transport && $0.connectionID == connectionID })
                #expect(retirement.durationMilliseconds == 28_000)
                #expect(retirement.reason == .pingTimeout)
                await client.close()
            } catch {
                await client.close()
                throw error
            }
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
            let reconnectedSocket = ScriptedGatewaySocket()
            let factory = ScriptedGatewaySocketFactory(sockets: [oldSocket, replacementSocket, reconnectedSocket])
            let client = GatewayClient(
                socketFactory: factory.factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000051")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000052")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000053")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000054")!,
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
            await reconnectedSocket.enqueue(helloFrame())
            _ = try await client.reconnect()
            #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
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

    @Test("late metadata from a retired socket cannot disconnect or relabel its replacement")
    func staleMetadataIsIsolated() async throws {
        try await withTestWatchdog {
            let metadata = TestReadGate()
            let oldSocket = ScriptedGatewaySocket(metadata: .init(closeCode: 1013, httpStatusCode: 101), metadataGate: metadata)
            let replacement = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [oldSocket, replacement]).factory)
            do {
                await oldSocket.enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "old")
                let oldID = await client.activeConnectionID()
                await oldSocket.failPendingReceivers(URLError(.networkConnectionLost))
                try await metadata.waitForEntry()
                await replacement.enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "new")
                let replacementID = await client.activeConnectionID()
                #expect(replacementID != oldID)
                await metadata.release()
                try await oldSocket.waitUntilClosed()
                var iterator = client.events.makeAsyncIterator()
                await replacement.enqueue(eventFrame(topic: "current.changed", payload: .number(2)))
                #expect(await iterator.next()?.event.topic == "current.changed")
                #expect(await client.activeConnectionID() == replacementID)
                let diagnostics = await client.diagnostics()
                #expect(diagnostics.first(where: { $0.closeCode == 1013 })?.connectionID == oldID)
                await client.close()
            } catch {
                await metadata.release()
                await oldSocket.close()
                await client.close()
                throw error
            }
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

            for revision in 0..<1_025 {
                await socket.enqueue(eventFrame(topic: "test.changed", payload: .number(Double(revision))))
            }
            try await socket.waitUntilCloseInvoked()
            #expect(await socket.closeTransitionCount() == 0)
            let diagnostics = await client.diagnostics()
            #expect(diagnostics.contains {
                $0.reason == .eventOverflow
                    && $0.overflowCount == 1_024
                    && $0.overflowReason == .countLimit
                    && ($0.queueCountHighWaterMark ?? 0) == 1_024
                    && ($0.admittedEventCount ?? 0) == 1_024
                    && ($0.pressureCrossings ?? 0) <= 4
            })

            let (bufferDrained, bufferDrainedContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let consumer = Task { () -> [GatewayEvent] in
                var iterator = client.events.makeAsyncIterator()
                var events: [GatewayEvent] = []
                for index in 0..<1_025 {
                    guard let delivery = await iterator.next() else { break }
                    events.append(delivery.event)
                    if index == 1_023 {
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
            #expect(events.count == 1_025)
            #expect(events.dropLast().map(\.topic).allSatisfy { $0 == "test.changed" })
            #expect(events.dropLast().compactMap { $0.payload.intValue } == Array(0..<1_024))
            #expect(events.last?.topic == "transport.disconnected")
            #expect(events.filter { $0.topic == "transport.disconnected" }.count == 1)
            #expect(await socket.closeInvocationCount() == 1)
            #expect(await socket.closeTransitionCount() == 1)
        }
    }

    @Test("notification history requests one exact older page when scroll pagination asks for it")
    func notificationHistoryRequestsRequestedPageOnly() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        do {
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "synthetic-token")
            let connectionID = try #require(await client.activeConnectionID())
            let loading = Task {
                try await NotificationInboxGatewayClient.list(
                    client: client,
                    filter: .unread,
                    cursor: "older-cursor",
                    expectedConnectionID: connectionID
                )
            }
            try await socket.waitUntilSent(count: 2)
            let request = try await decodedValue(in: socket, index: 1)
            #expect(request.objectValue?["method"] == .string("notification.inbox.list"))
            #expect(request.objectValue?["params"]?.objectValue?["filter"] == .string("unread"))
            #expect(request.objectValue?["params"]?.objectValue?["cursor"] == .string("older-cursor"))
            #expect(request.objectValue?["params"]?.objectValue?["limit"] == .number(50))
            let id = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(responseFrame(id: id, result: inboxPage(id: "notification-old", nextCursor: nil)))
            let page = try await loading.value
            #expect(page.notifications.map(\.id) == ["notification-old"])
            #expect(page.nextCursor == nil)
            #expect((await socket.sentFrames()).count == 2)
            await client.close()
        } catch {
            await client.close()
            throw error
        }
    }

    @Test("notification pagination cannot join pages across a replacement connection")
    func notificationPagesStayOnExactEpoch() async throws {
        try await withTestWatchdog {
            let sockets = [ScriptedGatewaySocket(), ScriptedGatewaySocket()]
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: sockets).factory)
            let gate = TestReadGate()
            var read: Task<NotificationInboxGatewayClient.Snapshot, Error>?
            var responder: Task<Void, Error>?
            do {
                await sockets[0].enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "synthetic-token")
                read = Task {
                    try await NotificationInboxGatewayClient.$hostedAfterPage.withValue({ await gate.wait() }) {
                        try await NotificationInboxGatewayClient.list(client: client, filter: .all)
                    }
                }
                try await sockets[0].waitUntilSent(count: 2)
                let request = try await decodedValue(in: sockets[0], index: 1)
                let id = try #require(request.objectValue?["id"]?.stringValue)
                await sockets[0].enqueue(responseFrame(id: id, result: inboxPage(id: "notification-old", nextCursor: "next-page")))
                try await gate.waitForEntry()
                await sockets[1].enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "synthetic-token")
                responder = Task {
                    try await sockets[1].waitUntilSent(count: 2)
                    let request = try await decodedValue(in: sockets[1], index: 1)
                    let id = try #require(request.objectValue?["id"]?.stringValue)
                    await sockets[1].enqueue(responseFrame(id: id, result: inboxPage(id: "notification-new", nextCursor: nil)))
                }
                await gate.release()
                do {
                    let mixed = try await valueOfOwnedTask(try #require(read))
                    Issue.record("A retired read returned \(mixed.notifications.count) rows from replacement pagination")
                } catch is CancellationError { }
                #expect(await sockets[1].sentFrames().count == 1)
                responder?.cancel()
                if let responder {
                    do { try await responder.value }
                    catch is CancellationError { }
                }
                await client.close()
            } catch {
                read?.cancel()
                responder?.cancel()
                await gate.release()
                if let read { _ = await read.result }
                if let responder {
                    if case .failure(let cleanupError) = await responder.result, !(cleanupError is CancellationError) {
                        Issue.record(cleanupError)
                    }
                }
                await client.close()
                throw error
            }
        }
    }

    private func inboxPage(id: String, nextCursor: String?) -> JSONValue {
        var page: [String: JSONValue] = [
            "revision": .string("same-revision"), "unreadCount": .number(2),
            "notifications": .array([.object([
                "version": .number(1), "id": .string(id), "kind": .string("explicit"),
                "createdAt": .string("2026-01-01T00:00:00Z"), "updatedAt": .string("2026-01-01T00:00:00Z"),
                "title": .string("Fixture"), "message": .string("Synthetic inbox row"),
                "sessionId": .string("session-fixture"), "isUnread": .bool(true), "outcome": .string("queued")
            ])])
        ]
        if let nextCursor { page["nextCursor"] = .string(nextCursor) }
        return .object(page)
    }

    @Test("successful pong advances progress without an application request")
    func successfulPongRefreshesProgress() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory, clock: clock.clock)
            do {
                await socket.enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "synthetic-token")
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPingInterval)
                clock.advance(by: GatewayConnectionPolicy.clientPingInterval)
                try await socket.waitUntilPingInvoked(count: 1)
                // This next registration happens after the completed pong has
                // crossed back to the connection owner.
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPingInterval)
                clock.advance(by: .seconds(3))
                try await client.ensureResponsive(maximumSilence: .seconds(4))
                #expect(await socket.sentFrames().count == 1)
                await client.close()
            } catch {
                await client.close()
                throw error
            }
        }
    }

    @Test("sockets activated at different phases ping at the same shared grid instants")
    func socketsPingOnOneSharedGrid() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let first = ScriptedGatewaySocket()
            let second = ScriptedGatewaySocket()
            let firstClient = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: first).factory, clock: clock.clock)
            let secondClient = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: second).factory, clock: clock.clock)
            do {
                await first.enqueue(helloFrame())
                _ = try await firstClient.connect(profile: profile, token: "synthetic-token")
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPingInterval)
                clock.advance(by: .seconds(3))
                await second.enqueue(helloFrame())
                _ = try await secondClient.connect(profile: profile, token: "synthetic-token")
                // Activated three seconds into the period: the first ping waits
                // for the next shared tick, never longer than one interval.
                try await clock.waitUntilSleeping(count: 1, duration: .seconds(7))
                clock.advance(by: .milliseconds(6_999))
                #expect(await first.pingInvocationCount() == 0)
                #expect(await second.pingInvocationCount() == 0)
                clock.advance(by: .milliseconds(1))
                try await first.waitUntilPingInvoked(count: 1)
                try await second.waitUntilPingInvoked(count: 1)
                try await clock.waitUntilSleeping(count: 2, duration: GatewayConnectionPolicy.clientPingInterval)
                clock.advance(by: GatewayConnectionPolicy.clientPingInterval)
                try await first.waitUntilPingInvoked(count: 2)
                try await second.waitUntilPingInvoked(count: 2)
                await firstClient.close()
                await secondClient.close()
            } catch {
                await firstClient.close()
                await secondClient.close()
                throw error
            }
        }
    }

    @Test("a slow pong keeps the next ping on its grid tick")
    func slowPongKeepsPingGrid() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket(suspendsPing: true)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory, clock: clock.clock)
            do {
                await socket.enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "synthetic-token")
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPingInterval)
                clock.advance(by: GatewayConnectionPolicy.clientPingInterval)
                try await socket.waitUntilPingInvoked(count: 1)
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPongDeadline)
                clock.advance(by: .seconds(3))
                await socket.releasePing()
                // The pong arrived three seconds after the tick; the next ping
                // still fires exactly one interval after the previous one.
                try await clock.waitUntilSleeping(count: 1, duration: .seconds(7))
                clock.advance(by: .seconds(7))
                try await socket.waitUntilPingInvoked(count: 2)
                #expect(await client.info?.machineId == "machine")
                await client.close()
            } catch {
                await client.close()
                throw error
            }
        }
    }

    @Test("a genuine ping failure after inbound data still retires the epoch")
    func pingFailureAfterInboundDataStillRetires() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket(suspendsPing: true)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory, clock: clock.clock)
            do {
                await socket.enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "synthetic-token")
                let connectionID = try #require(await client.activeConnectionID())
                var events = client.events.makeAsyncIterator()
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPingInterval)
                clock.advance(by: GatewayConnectionPolicy.clientPingInterval)
                try await socket.waitUntilPingInvoked(count: 1)
                // The probe's own deadline must be registered before the clock
                // moves, or the frame below lands before the probe exists.
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPongDeadline)

                // A frame arrives after the probe was sent, which is exactly
                // the shape an excused deadline leaves behind. This probe then
                // fails on the send path itself, so only `pong_timeout` may be
                // excused and the epoch has to retire.
                clock.advance(by: .seconds(3))
                await socket.enqueue(eventFrame(topic: "session.summary", payload: .object([:])))
                #expect(await events.next()?.event.topic == "session.summary")
                await socket.releasePing(throwing: GatewayFailure(
                    code: "disconnected", message: "ping failed", retryable: true, details: nil
                ))

                try await socket.waitUntilClosed()
                #expect(await client.activeConnectionID() == nil)
                let diagnostics = await client.diagnostics()
                let probe = try #require(diagnostics.first { $0.stage == .liveness })
                #expect(probe.outcome == .failure)
                #expect(probe.reason == .transport)
                #expect(!diagnostics.contains { $0.stage == .liveness && $0.outcome == .excused })
                let retirement = try #require(diagnostics.first { $0.stage == .transport && $0.connectionID == connectionID })
                #expect(retirement.reason == .transport)
                await client.close()
            } catch {
                await client.close()
                throw error
            }
        }
    }

    @Test("a late clock wake excuses a probe the frame answered and returns to the shared grid")
    func lateClockWakeProbesOnce() async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket(suspendsPing: true)
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory, clock: clock.clock)
            do {
                await socket.enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "synthetic-token")
                let connectionID = try #require(await client.activeConnectionID())
                var events = client.events.makeAsyncIterator()
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPingInterval)

                // A suspension wakes the sleep 50 s late. That wakeup owes one
                // probe, and the next one is the next grid tick (70 s), not one
                // per missed interval.
                clock.advance(by: .seconds(60))
                try await socket.waitUntilPingInvoked(count: 1)
                // The probe's own deadline must be registered before the clock
                // moves, or the frame below lands before the probe exists.
                try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionPolicy.clientPongDeadline)

                // The probe's pong is queued behind a frame still arriving at
                // the deadline, so the late wake excuses the probe instead of
                // retiring a link that is carrying data.
                clock.advance(by: .seconds(3))
                await socket.enqueue(eventFrame(topic: "session.summary", payload: .object([:])))
                #expect(await events.next()?.event.topic == "session.summary")
                clock.advance(by: .seconds(5))

                try await clock.waitUntilSleeping(count: 1, duration: .seconds(2))
                #expect(await socket.pingInvocationCount() == 1)
                #expect(await client.activeConnectionID() == connectionID)
                let liveness = await client.diagnostics().filter { $0.stage == .liveness }
                #expect(liveness.count == 1)
                #expect(liveness.first?.outcome == .excused)

                // The next probe is the next grid tick (70 s), and the wait
                // stops owing probes for the intervals the suspension skipped.
                clock.advance(by: .seconds(2))
                try await socket.waitUntilPingInvoked(count: 2)
                #expect(await client.info?.machineId == "machine")
                await client.close()
            } catch {
                await client.close()
                throw error
            }
        }
    }

    @Test("session list request records bounded RPC outcome with request correlation")
    func sessionListRequestRecordsRPCDiagnostic() async throws {
        try await withTestWatchdog {
            let suite = "TronCatalogRPC.\(UUID())"
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let store = IOSClientDiagnosticStore(defaults: try #require(UserDefaults(suiteName: suite)))
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000049")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000050")!,
                ]).source,
                diagnosticStore: store
            )
            do {
                await socket.enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "synthetic-token")
                let request = Task { try await client.requestValue("session.list", EmptyParams()) }
                try await socket.waitUntilSent(count: 2)
                let frame = try JSONDecoder.gateway.decode([String: JSONValue].self, from: await socket.sentFrames()[1])
                let requestID = try #require(frame["id"]?.stringValue)
                await socket.enqueue(responseFrame(
                    id: requestID,
                    result: .object([
                        "sessions": .array([]),
                        "listRevision": .number(1),
                        "projectionToken": .string("epoch-1:1"),
                    ])
                ))
                _ = try await valueOfOwnedTask(request)
                await store.flush()
                let records = await store.load()
                let diagnostic = try #require(records.first { $0.record.event == "gateway.rpc" })
                #expect(diagnostic.record.message.contains("method=session.list"))
                #expect(diagnostic.record.message.contains("requestID=00000000-0000-0000-0000-000000000050"))
                #expect(diagnostic.record.message.contains("outcome=success"))
                #expect(diagnostic.record.message.contains("durationMs="))
                #expect(!diagnostic.record.message.contains("synthetic-token"))
                await client.close()
            } catch {
                await client.close()
                await store.flush()
                throw error
            }
        }
    }

    @Test("transport pressure is retained without an event consumer or Logs read")
    func transportPersistsWithoutConsumer() async throws {
        try await withTestWatchdog {
            let suite = "TronTransportIncident.\(UUID())"
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let store = IOSClientDiagnosticStore(defaults: try #require(UserDefaults(suiteName: suite)))
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([UUID(uuidString: "00000000-0000-0000-0000-000000000049")!]).source,
                eventBufferPolicy: .init(maximumEvents: 2, maximumBytes: 4_096),
                diagnosticStore: store
            )
            do {
                await socket.enqueue(helloFrame())
                _ = try await client.connect(profile: profile, token: "synthetic-token")
                for index in 0..<3 {
                    await socket.enqueue(eventFrame(topic: "session.progress", payload: .number(Double(index))))
                }
                try await socket.waitUntilClosed()
                await store.flush()
                let retained = await store.load()
                #expect(retained.contains { $0.record.message.contains("stage=queue-pressure") })
                #expect(retained.contains { $0.record.message.contains("reason=event_overflow") })
                #expect(retained.contains { $0.record.message.contains("clientID=\(client.diagnosticOwnerID)") })
                #expect(retained.allSatisfy { !$0.record.message.contains("synthetic-token") })
                await client.close()
                await store.flush()
            } catch {
                await client.close()
                await store.flush()
                throw error
            }
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

    private func helloFrame(connectionID: String? = nil) -> Data {
        let connection = connectionID.map { #","connectionId":"\#($0)""# } ?? ""
        return Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]\#(connection)}"#.utf8)
    }

    /// The Gateway's own `busy` answer for a shed read (`G-12`), with the retry
    /// hint the phone is expected to honour.
    private func shedResponseFrame(id: String, retryAfterMs: Int) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(false),
            "error": .object([
                "code": .string("busy"),
                "message": .string("session.list did not answer within 5000ms"),
                "retryable": .bool(true),
                "details": .object(["retryAfterMs": .number(Double(retryAfterMs))]),
            ]),
        ]))
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

/// Hands each dial the next socket its URL host names and records the dial
/// order and pins, so a race's lanes cannot be swapped by the order the factory
/// runs in.
private final class HostRoutedGatewaySocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [String: [ScriptedGatewaySocket]]
    private var hosts: [String] = []
    private var pins: [String?] = []
    private var authorizations: [String?] = []

    init(queued: [String: [ScriptedGatewaySocket]]) {
        self.queued = queued
    }

    var factory: GatewaySocketFactory {
        GatewaySocketFactory { [self] request, pin in
            let host = request.url?.host ?? ""
            lock.lock()
            hosts.append(host)
            pins.append(pin)
            authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
            let socket = queued[host]?.first
            if queued[host]?.isEmpty == false { queued[host]?.removeFirst() }
            lock.unlock()
            precondition(socket != nil, "routed socket factory has no socket for \(host)")
            return socket!
        }
    }

    var dialedHosts: [String] {
        lock.lock(); defer { lock.unlock() }
        return hosts
    }

    var dialedPins: [String?] {
        lock.lock(); defer { lock.unlock() }
        return pins
    }

    var dialedAuthorizations: [String?] {
        lock.lock(); defer { lock.unlock() }
        return authorizations
    }
}

private actor HTTPRequestIDCapture {
    private var requestID: String?

    func record(_ request: URLRequest) {
        requestID = request.value(forHTTPHeaderField: "X-Tron-Request-ID")
    }

    func value() -> String? { requestID }
}

/// The routes one test's injected HTTP transports were asked to carry, so a
/// case can say where an epoch's live view, media and uploads went (E-3c).
private actor RecordedHTTPCalls {
    private var calls: [(url: URL, pin: String?, requestID: String?)] = []

    func record(_ request: URLRequest, pin: String?) {
        guard let url = request.url else { return }
        calls.append((url, pin, request.value(forHTTPHeaderField: "X-Tron-Request-ID")))
    }

    func recorded() -> [(url: URL, pin: String?, requestID: String?)] { calls }
}

@Suite("Gateway client LAN lane race (E-3c)")
struct GatewayClientLanLaneTests {
    private static let helloFrame = Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":[]}"#.utf8)
    private static let lanHost = "192.168.1.24"
    private static let savedHost = "gateway.test"

    private static let pin = Data(repeating: 7, count: 32).base64EncodedString()

    private func lanProfile() -> GatewayProfile {
        GatewayProfile(
            id: "machine", label: "Mac", host: Self.savedHost, port: 9_847,
            machineId: "machine", deviceId: "device",
            lanEndpoints: [GatewayLanEndpoint(host: Self.lanHost, port: 9_847)!],
            lanPin: Self.pin
        )
    }

    private func savedOnlyProfile() -> GatewayProfile {
        GatewayProfile(
            id: "machine", label: "Mac", host: Self.savedHost, port: 9_847,
            machineId: "machine", deviceId: "device"
        )
    }

    private func wifiOnlyPath() -> @Sendable () -> String? { { "wifi,other" } }

    @Test("an epoch the LAN lane carries routes HTTP and its pin to that lane")
    func httpRoutesFollowTheWinningLane() async throws {
        let calls = RecordedHTTPCalls()
        let appLogURL = FileManager.default.temporaryDirectory.appending(path: "lan-upload-app-log-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: appLogURL)
            try? FileManager.default.removeItem(at: appLogURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: appLogURL)
        let uploadID = UUID().uuidString
        let payload = Data("media".utf8)
        let lan = ScriptedGatewaySocket()
        await lan.enqueue(Self.helloFrame)
        let factory = HostRoutedGatewaySocketFactory(queued: [Self.lanHost: [lan]])
        let client = GatewayClient(
            socketFactory: factory.factory,
            boundedHTTPDataTransport: BoundedHTTPDataTransport { request, _, pin in
                await calls.record(request, pin: pin)
                if request.httpMethod == "POST" {
                    return (Data(#"{"upload":{"id":"\#(uploadID)"}}"#.utf8),
                            HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
                }
                return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            boundedHTTPFileTransport: BoundedHTTPFileTransport { request, _, pin in
                await calls.record(request, pin: pin)
                return BoundedHTTPDownloadedFile(
                    url: FileManager.default.temporaryDirectory.appending(path: "e-3c-\(UUID().uuidString)"),
                    response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    byteCount: Int64(payload.count)
                )
            },
            appLog: appLog,
            networkPath: wifiOnlyPath()
        )
        let profile = lanProfile()
        _ = try await client.connect(profile: profile, token: "token")

        let blobID = UUID().uuidString
        let exportID = UUID().uuidString
        let (blob, _) = try await client.blob(id: blobID, profileID: profile.id, maximumBytes: 1_024)
        #expect(blob == payload)
        let export = try await client.blobFile(id: exportID, maximumBytes: 1_024)
        let uploaded = try await client.upload(name: "photo.bin", mimeType: "application/octet-stream", data: payload)

        #expect(uploaded == uploadID)
        #expect(export.lastPathComponent.hasPrefix("e-3c-"))
        let recorded = await calls.recorded()
        // Every route — media, the staged export file, and an upload — runs on
        // the lane that won, with the pin its certificate must match.
        #expect(recorded.count == 3)
        #expect(recorded.allSatisfy { $0.url.host == Self.lanHost && $0.url.scheme == "https" })
        #expect(recorded.allSatisfy { $0.pin == Self.pin })
        let uploadRequestID = try #require(recorded.last?.requestID)
        #expect(UUID(uuidString: uploadRequestID) != nil)
        var uploadRecords: [AppLogRecord] = []
        for _ in 0..<100 {
            uploadRecords = await appLog.snapshot().filter { $0.event.hasPrefix("http.upload.") }
            if uploadRecords.contains(where: { $0.event == "http.upload.terminal" }) { break }
            await Task.yield()
        }
        #expect(uploadRecords.map(\.event).sorted() == ["http.upload.requested", "http.upload.terminal"])
        #expect(uploadRecords.allSatisfy { $0.requestID == uploadRequestID && $0.profileID == nil })
        #expect(uploadRecords.allSatisfy { $0.message.contains("route=lan-pinned") })
        #expect(uploadRecords.first(where: { $0.event == "http.upload.terminal" })?.outcome == "success")
        #expect(Set(recorded.map(\.url.path)) == [
            "/v1/blobs/\(blobID)", "/v1/blobs/\(exportID)", "/v1/uploads",
        ])
        await client.close()
    }

    @Test("an epoch the saved endpoint carries keeps HTTP there with no pin")
    func httpRoutesStayOnTheSavedEndpoint() async throws {
        let calls = RecordedHTTPCalls()
        let payload = Data("media".utf8)
        let socket = ScriptedGatewaySocket()
        await socket.enqueue(Self.helloFrame)
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
            boundedHTTPDataTransport: BoundedHTTPDataTransport { request, _, pin in
                await calls.record(request, pin: pin)
                return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            networkPath: wifiOnlyPath()
        )
        let profile = savedOnlyProfile()
        _ = try await client.connect(profile: profile, token: "token")
        _ = try await client.blob(id: UUID().uuidString, profileID: profile.id, maximumBytes: 1_024)

        let recorded = await calls.recorded()
        #expect(recorded.count == 1)
        #expect(recorded.first?.url.host == Self.savedHost)
        #expect(recorded.first?.url.scheme == "http")
        #expect(recorded.first?.pin == nil)
        await client.close()
    }

    @Test("the pinned LAN lane wins the race before the saved endpoint is dialed")
    func lanLaneWinsTheRace() async throws {
        let lan = ScriptedGatewaySocket()
        let saved = ScriptedGatewaySocket()
        let factory = HostRoutedGatewaySocketFactory(queued: [Self.lanHost: [lan], Self.savedHost: [saved]])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())
        await lan.enqueue(Self.helloFrame)

        let identity = try await client.connectForLifecycle(profile: lanProfile(), token: "token")

        #expect(identity.info.machineId == "machine")
        // The staggered lane never dials at all: the LAN lane answered first.
        #expect(factory.dialedHosts == [Self.lanHost])
        // The pin travels with the LAN lane's dial and not with the saved one.
        #expect(factory.dialedPins == [Self.pin])
        // The credential rides the request the pinned handshake admits: the
        // socket's own trust evaluation is what runs before any request byte.
        #expect(factory.dialedAuthorizations == ["Bearer token"])
        #expect(await lan.sendInvocationCount() == 1)
        await client.close()
    }

    @Test("a LAN lane that never answers is retired and the saved endpoint carries the attempt")
    func savedEndpointWinsAfterTheStagger() async throws {
        let lan = ScriptedGatewaySocket()
        let saved = ScriptedGatewaySocket()
        let factory = HostRoutedGatewaySocketFactory(queued: [Self.lanHost: [lan], Self.savedHost: [saved]])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())
        await saved.enqueue(Self.helloFrame)

        let started = ContinuousClock.now
        _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")
        let elapsed = started.duration(to: ContinuousClock.now)

        #expect(elapsed >= .milliseconds(200))
        #expect(factory.dialedHosts.sorted() == [Self.lanHost, Self.savedHost].sorted())
        #expect(factory.dialedPins.contains(Self.pin))
        // The losing lane is closed here, so the Mac does not keep a connection
        // this phone never uses.
        #expect(await lan.closed())
        let winner = await client.diagnostics().first { $0.stage == .helloReceive && $0.outcome == .success }
        #expect(winner?.handshake?.transport == "tailscale")
        await client.close()
    }

    @Test("a reconnect races both lanes without the stagger")
    func reconnectRacesBothLanesImmediately() async throws {
        let lan = ScriptedGatewaySocket()
        let saved = ScriptedGatewaySocket()
        let factory = HostRoutedGatewaySocketFactory(queued: [Self.lanHost: [lan], Self.savedHost: [saved]])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())
        await saved.enqueue(Self.helloFrame)

        let started = ContinuousClock.now
        _ = try await client.reconnectForLifecycle(profile: lanProfile(), token: "token")
        let elapsed = started.duration(to: ContinuousClock.now)

        // A lane that just died must not delay the attempt that replaces it.
        #expect(elapsed < .milliseconds(200))
        #expect(factory.dialedHosts.count == 2)
        await client.close()
    }

    @Test("a lane this network already carries skips the stagger")
    func knownLaneSkipsTheStagger() async throws {
        let fallingLan = ScriptedGatewaySocket()
        let firstSaved = ScriptedGatewaySocket()
        let hangingLan = ScriptedGatewaySocket()
        let secondSaved = ScriptedGatewaySocket()
        await fallingLan.failNextSend(URLError(.cannotConnectToHost))
        await firstSaved.enqueue(Self.helloFrame)
        await secondSaved.enqueue(Self.helloFrame)
        let factory = HostRoutedGatewaySocketFactory(queued: [
            Self.lanHost: [fallingLan, hangingLan],
            Self.savedHost: [firstSaved, secondSaved],
        ])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())
        _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")
        #expect(factory.dialedHosts.count == 2)

        // The same network again: the LAN lane hangs, and the saved endpoint —
        // the lane that carried it — is dialed without waiting out the stagger.
        let started = ContinuousClock.now
        _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")
        let elapsed = started.duration(to: ContinuousClock.now)

        #expect(elapsed < .milliseconds(200))
        await client.close()
    }

    @Test("a LAN lane the pin refuses is named and sends no credential")
    func pinMismatchIsNamedAndSendsNoCredential() async throws {
        let lan = ScriptedGatewaySocket(metadata: GatewaySocketMetadata(
            closeCode: nil, httpStatusCode: nil, certificatePinRejected: true
        ))
        let saved = ScriptedGatewaySocket()
        // What the socket's own cancelled server-trust challenge fails with:
        // `cancelAuthenticationChallenge` ends the request as cancelled.
        await lan.failNextSend(URLError(.cancelled))
        await saved.enqueue(Self.helloFrame)
        let factory = HostRoutedGatewaySocketFactory(queued: [Self.lanHost: [lan], Self.savedHost: [saved]])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())

        _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")

        let refusal = await client.diagnostics().first {
            $0.outcome == .failure && $0.handshake?.transport == "lan"
        }
        #expect(refusal?.reason == .lanPinMismatch)
        #expect(refusal?.handshake?.transportOpened == false)
        // The refused lane wrote no credential: its only send is the refused
        // one, and the socket that carried the connection is the saved endpoint.
        #expect(await lan.sentFrames().isEmpty)
        #expect(factory.dialedAuthorizations.last == "Bearer token")
        #expect(factory.dialedHosts.last == Self.savedHost)
        await client.close()
    }

    @Test("a denied Local Network permission is recorded once and the lane is not dialed again")
    func deniedPermissionStaysOnTailscale() async throws {
        let suite = "GatewayClientLanLaneTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let permission = GatewayLanPermissionRecord(defaults: defaults)

        let lan = ScriptedGatewaySocket()
        let saved = ScriptedGatewaySocket()
        await lan.failNextSend(URLError(.notConnectedToInternet))
        await saved.enqueue(Self.helloFrame)
        let factory = HostRoutedGatewaySocketFactory(queued: [Self.lanHost: [lan], Self.savedHost: [saved]])
        let client = GatewayClient(
            socketFactory: factory.factory,
            lanPermission: permission,
            networkPath: wifiOnlyPath()
        )

        _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")

        // The denial is recorded at the install, not per attempt.
        let denial = await client.diagnostics().first { $0.reason == .lanDenied }
        #expect(denial?.handshake?.transport == "lan")
        #expect(permission.isDenied)

        // The next connection dials only the endpoint that works.
        let secondSaved = ScriptedGatewaySocket()
        await secondSaved.enqueue(Self.helloFrame)
        let secondFactory = HostRoutedGatewaySocketFactory(queued: [
            Self.lanHost: [ScriptedGatewaySocket()],
            Self.savedHost: [secondSaved],
        ])
        let secondClient = GatewayClient(
            socketFactory: secondFactory.factory,
            lanPermission: permission,
            networkPath: wifiOnlyPath()
        )
        _ = try await secondClient.connectForLifecycle(profile: lanProfile(), token: "token")
        #expect(secondFactory.dialedHosts == [Self.savedHost])
        await client.close()
        await secondClient.close()
    }

    @Test("the LAN lane's own answer is the one the attempt reports")
    func lanAnswerOutranksTheSavedLaneTimeout() async throws {
        let lan = ScriptedGatewaySocket(metadata: GatewaySocketMetadata(closeCode: nil, httpStatusCode: 401))
        let saved = ScriptedGatewaySocket()
        await lan.failNextSend(URLError(.badServerResponse))
        await saved.failNextSend(URLError(.timedOut))
        let factory = HostRoutedGatewaySocketFactory(queued: [Self.lanHost: [lan], Self.savedHost: [saved]])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())

        // The revoked device is answered 401 by the LAN lane and times out on
        // the saved lane. Reporting the timeout would keep the phone retrying a
        // Mac that has already refused it.
        var thrown: (any Error)?
        do {
            _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")
        } catch {
            thrown = error
        }
        let failure = try #require(thrown as? GatewayFailure)
        #expect(failure.code == "unauthenticated")
        #expect(!failure.retryable)

        // The attempt's newest record is the lane whose failure it reported,
        // and a 401 is not a LAN that is unreachable.
        let reported = try #require(await client.latestHandshakeDiagnostic(after: 0))
        #expect(reported.handshake?.transport == "lan")
        #expect(reported.httpStatusCode == 401)
        #expect(reported.reason == .transport)
        let lanRecord = try #require(await client.diagnostics().first { $0.handshake?.transport == "lan" })
        #expect(lanRecord.reason != .lanUnreachable)
        await client.close()
    }

    @Test("a typed refusal on the LAN lane is not reported as an unreachable LAN")
    func lanProtocolMismatchKeepsItsOwnReason() async throws {
        // At home the LAN lane is the one that dialed the Mac, so its record is
        // where the one-step cause has to live: a version mismatch is the Mac's
        // own answer, not a LAN that could not reach it (F-3).
        let lan = ScriptedGatewaySocket(metadata: GatewaySocketMetadata(
            closeCode: GatewayProtocolMismatchClose.closeCode,
            httpStatusCode: 101,
            closeReason: #"{"code":"protocol_mismatch","gatewayProtocol":6,"minProtocol":6}"#
        ))
        let saved = ScriptedGatewaySocket()
        await lan.failPendingReceivers(URLError(.networkConnectionLost))
        await saved.failNextSend(URLError(.timedOut))
        let factory = HostRoutedGatewaySocketFactory(queued: [Self.lanHost: [lan], Self.savedHost: [saved]])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())

        var thrown: (any Error)?
        do {
            _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")
        } catch {
            thrown = error
        }
        let failure = try #require(thrown as? GatewayFailure)
        #expect(failure.code == "protocol_mismatch")
        #expect(!failure.retryable)
        let reported = try #require(await client.latestHandshakeDiagnostic(after: 0))
        #expect(reported.handshake?.transport == "lan")
        #expect(reported.reason == .protocolMismatch)
        await client.close()
    }

    @Test("a network the LAN lane carried keeps the LAN lane's head start")
    func rememberedLanKeepsTheStagger() async throws {
        let firstLan = ScriptedGatewaySocket()
        let firstSaved = ScriptedGatewaySocket()
        let hangingLan = ScriptedGatewaySocket()
        let secondSaved = ScriptedGatewaySocket()
        await firstLan.enqueue(Self.helloFrame)
        // The first connect never dials the saved lane (the LAN lane wins inside
        // the stagger), so this is the socket its next attempt reaches.
        await firstSaved.enqueue(Self.helloFrame)
        let factory = HostRoutedGatewaySocketFactory(queued: [
            Self.lanHost: [firstLan, hangingLan],
            Self.savedHost: [firstSaved, secondSaved],
        ])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())
        _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")
        #expect(factory.dialedHosts == [Self.lanHost])

        // The same network, with the LAN lane no longer answering: the saved
        // endpoint still waits the stagger, so the local socket is not lost to
        // whichever hello lands first. Skipping the stagger here would make the
        // home network a coin flip.
        let started = ContinuousClock.now
        _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")
        let elapsed = started.duration(to: ContinuousClock.now)

        #expect(elapsed >= .milliseconds(200))
        #expect(factory.dialedHosts.count == 3)
        await client.close()
    }

    @Test("a reconnect keeps a head start for the LAN lane this network carried")
    func reconnectKeepsTheLanHeadStart() async throws {
        let firstLan = ScriptedGatewaySocket()
        let firstSaved = ScriptedGatewaySocket()
        let hangingLan = ScriptedGatewaySocket()
        let secondSaved = ScriptedGatewaySocket()
        await firstLan.enqueue(Self.helloFrame)
        await firstSaved.enqueue(Self.helloFrame)
        let factory = HostRoutedGatewaySocketFactory(queued: [
            Self.lanHost: [firstLan, hangingLan],
            Self.savedHost: [firstSaved, secondSaved],
        ])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())
        _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")

        // A lane that just died must not spend the attempt's budget, so the
        // head start is short — but it is not nothing, or the lane that carried
        // the network loses to the first hello to land.
        let started = ContinuousClock.now
        _ = try await client.reconnectForLifecycle(profile: lanProfile(), token: "token")
        let elapsed = started.duration(to: ContinuousClock.now)

        #expect(elapsed >= .milliseconds(40))
        #expect(elapsed < .milliseconds(200))
        await client.close()
    }

    @Test("an equal finish goes to the LAN lane")
    func equalFinishGoesToTheLanLane() async throws {
        let lan = ScriptedGatewaySocket()
        let saved = ScriptedGatewaySocket()
        await saved.enqueue(Self.helloFrame)
        let factory = HostRoutedGatewaySocketFactory(queued: [Self.lanHost: [lan], Self.savedHost: [saved]])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())
        // A race with no head start: the saved lane answers at once and the LAN
        // lane answers inside the tie window, which the local lane must win.
        let answering = Task { try? await Task.sleep(for: .milliseconds(10)); await lan.enqueue(Self.helloFrame) }

        _ = try await client.reconnectForLifecycle(profile: lanProfile(), token: "token")
        await answering.value

        let winner = try #require(await client.diagnostics().first { $0.stage == .helloReceive && $0.outcome == .success })
        #expect(winner.handshake?.transport == "lan")
        #expect(await saved.closed())
        await client.close()
    }

    @Test("a LAN lane that fails promptly does not hold the attempt for the stagger")
    func failedLanLaneWakesTheStagger() async throws {
        let lan = ScriptedGatewaySocket()
        let saved = ScriptedGatewaySocket()
        await lan.failNextSend(URLError(.cannotConnectToHost))
        await saved.enqueue(Self.helloFrame)
        let factory = HostRoutedGatewaySocketFactory(queued: [Self.lanHost: [lan], Self.savedHost: [saved]])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())

        let started = ContinuousClock.now
        _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")
        let elapsed = started.duration(to: ContinuousClock.now)

        #expect(elapsed < .milliseconds(200))
        #expect(factory.dialedHosts.count == 2)
        await client.close()
    }

    @Test("a system-reported Local Network denial skips the lane and records it")
    func systemReportedDenialSkipsTheLane() async throws {
        let suite = "GatewayClientLanLaneTests.denied.\\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let permission = GatewayLanPermissionRecord(defaults: defaults)
        // What the app's path monitor writes when iOS reports the denial: no
        // dial ever sees -1009, and the lane must still be left out and named.
        permission.update(systemDenied: true)

        let saved = ScriptedGatewaySocket()
        await saved.enqueue(Self.helloFrame)
        let factory = HostRoutedGatewaySocketFactory(queued: [
            Self.lanHost: [ScriptedGatewaySocket()],
            Self.savedHost: [saved],
        ])
        let client = GatewayClient(
            socketFactory: factory.factory,
            lanPermission: permission,
            networkPath: wifiOnlyPath()
        )

        _ = try await client.connectForLifecycle(profile: lanProfile(), token: "token")

        #expect(factory.dialedHosts == [Self.savedHost])
        let denial = try #require(await client.diagnostics().first { $0.reason == .lanDenied })
        #expect(denial.stage == .transportRace)
        #expect(denial.handshake?.transport == "lan")
        // The permission is state, not a one-way latch: the monitor's next
        // reading of a path that does not report the denial clears it.
        permission.update(systemDenied: false)
        #expect(!permission.isDenied)
        await client.close()
    }

    @Test("a saved endpoint with no LAN advertisement records no transport")
    func unracedAttemptRecordsNoTransport() async throws {
        let socket = ScriptedGatewaySocket()
        await socket.enqueue(Self.helloFrame)
        let factory = ScriptedGatewaySocketFactory(socket: socket)
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())

        _ = try await client.connectForLifecycle(profile: savedOnlyProfile(), token: "token")

        let winner = try #require(await client.diagnostics().first { $0.stage == .helloReceive && $0.outcome == .success })
        #expect(winner.handshake?.transport == nil)
        await client.close()
    }

    @Test("a hello-receive failure names a socket that opened")
    func helloReceiveFailureNamesAnOpenedSocket() async throws {
        let socket = ScriptedGatewaySocket()
        await socket.failPendingReceivers(URLError(.networkConnectionLost))
        let factory = ScriptedGatewaySocketFactory(socket: socket)
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())

        await #expect(throws: (any Error).self) {
            _ = try await client.connectForLifecycle(profile: savedOnlyProfile(), token: "token")
        }

        // The hello write completed before the receive, so the socket opened
        // even though the transport's own metadata never observed it.
        let failure = try #require(await client.diagnostics().first {
            $0.stage == .helloReceive && $0.outcome == .failure
        })
        #expect(failure.handshake?.transportOpened == true)
        await client.close()
    }

    @Test("a close ends the lanes an attempt is still dialing")
    func closeEndsTheInFlightLanes() async throws {
        let lan = ScriptedGatewaySocket(suspendsSend: true)
        let saved = ScriptedGatewaySocket()
        let factory = HostRoutedGatewaySocketFactory(queued: [Self.lanHost: [lan], Self.savedHost: [saved]])
        let client = GatewayClient(socketFactory: factory.factory, networkPath: wifiOnlyPath())

        let attempt = Task { try? await client.connectForLifecycle(profile: lanProfile(), token: "token") }
        try await lan.waitUntilSendInvoked(count: 1)
        await client.close()

        // No epoch owned these sockets, so only the attempt record could end
        // the one that was still dialing.
        try await lan.waitUntilClosed()
        attempt.cancel()
        _ = await attempt.value
    }
}
