import Foundation
import Testing
@testable import TronMobileCore
@testable import TronMobile

@Suite("Bounded HTTP data transport")
struct BoundedHTTPDataTransportTests {
    @Test("content length is rejected before body accumulation")
    func contentLengthAdmission() throws {
        var accumulator = BoundedHTTPBodyAccumulator(maximumBytes: 4)
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://gateway.test/v1/blobs/blob")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "5"]
        ))

        #expect(throws: URLError.self) {
            try accumulator.admit(response: response)
        }
        #expect(accumulator.data.isEmpty)
    }

    @Test("chunked bodies cannot cross the exact byte ceiling")
    func chunkAdmission() throws {
        var accumulator = BoundedHTTPBodyAccumulator(maximumBytes: 4)
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://gateway.test/v1/blobs/blob")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        try accumulator.admit(response: response)
        try accumulator.append(Data([1, 2]))
        try accumulator.append(Data([3, 4]))
        #expect(accumulator.data == Data([1, 2, 3, 4]))

        #expect(throws: URLError.self) {
            try accumulator.append(Data([5]))
        }
        #expect(accumulator.data == Data([1, 2, 3, 4]))
    }

    @Test("oversized response headers finish without re-entering the delegate lock")
    func oversizedHeaderFinishes() async throws {
        try await assertLoaderRejects(OversizedContentLengthURLProtocol.self)
    }

    @Test("oversized streamed bodies finish without re-entering the delegate lock")
    func oversizedStreamFinishes() async throws {
        try await assertLoaderRejects(OversizedChunkURLProtocol.self)
    }

    private func assertLoaderRejects(_ protocolClass: AnyClass) async throws {
        let sessions = BoundedHTTPDataSessions {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [protocolClass]
            return configuration
        }
        // A read runs on the shared session, a write on a fresh one; both keep the ceiling.
        for method in ["GET", "POST"] {
            var request = URLRequest(url: URL(string: "https://gateway.test/bounded")!)
            request.httpMethod = method
            do {
                _ = try await BoundedURLSessionDataLoader.load(
                    request,
                    maximumBytes: 4,
                    sessions: sessions
                )
                Issue.record("Oversized \(method) response unexpectedly completed")
            } catch let error as URLError {
                #expect(error.code == .dataLengthExceedsMaximum)
            }
        }
    }

    // The production transports below run over real loopback TCP so the
    // shared read session's connection reuse and isolation are observable.

    @Test("reads reuse one keep-alive connection while writes keep a fresh connection each")
    func readsReuseConnectionWritesDoNot() async throws {
        try await withTestWatchdog {
            let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("ok".utf8)) }
            defer { server.stop() }
            for _ in 0..<3 {
                let (data, response) = try await BoundedHTTPDataTransport.noRedirects.data(
                    for: URLRequest(url: server.url("/frame")),
                    maximumBytes: 2
                )
                #expect(data == Data("ok".utf8))
                #expect(response.statusCode == 200)
            }
            var admission = URLRequest(url: server.url("/lease"))
            admission.httpMethod = "POST"
            admission.httpBody = Data("{}".utf8)
            var close = URLRequest(url: server.url("/lease"))
            close.httpMethod = "DELETE"
            for request in [admission, close] {
                _ = try await BoundedHTTPDataTransport.noRedirects.data(for: request, maximumBytes: 2)
            }
            let requests = server.recordedRequests()
            #expect(requests.map(\.method) == ["GET", "GET", "GET", "POST", "DELETE"])
            #expect(requests.map(\.connection) == [1, 1, 1, 2, 3])
            #expect(requests[3].body == Data("{}".utf8))
        }
    }

    @Test("declared and streamed byte ceilings stay per request on the shared read session")
    func sharedReadsKeepPerRequestCeilings() async throws {
        try await withTestWatchdog {
            let server = try await LoopbackHTTPServer.start { request in
                switch request.path {
                case "/declared": .init(body: Data("fifth".utf8))
                case "/streamed": .init(body: Data("fifth".utf8), chunked: true)
                default: .init(body: Data("four".utf8))
                }
            }
            defer { server.stop() }
            for path in ["/declared", "/streamed"] {
                do {
                    _ = try await BoundedHTTPDataTransport.urlSession.data(for: URLRequest(url: server.url(path)), maximumBytes: 4)
                    Issue.record("Oversized \(path) response unexpectedly completed")
                } catch let error as URLError {
                    #expect(error.code == .dataLengthExceedsMaximum)
                }
            }
            let (data, _) = try await BoundedHTTPDataTransport.urlSession.data(for: URLRequest(url: server.url("/exact")), maximumBytes: 4)
            #expect(data == Data("four".utf8))
        }
    }

    @Test("redirect policy stays per request on the shared read session")
    func sharedReadsKeepPerRequestRedirectPolicy() async throws {
        try await withTestWatchdog {
            let server = try await LoopbackHTTPServer.start { request in
                request.path == "/moved"
                    ? .init(status: 302, headers: [("Location", "/target")])
                    : .init(body: Data("target".utf8))
            }
            defer { server.stop() }
            let moved = URLRequest(url: server.url("/moved"))
            for _ in 0..<2 {
                let (_, refused) = try await BoundedHTTPDataTransport.noRedirects.data(for: moved, maximumBytes: 64)
                #expect(refused.statusCode == 302)
                #expect(refused.url == moved.url)
                let (data, followed) = try await BoundedHTTPDataTransport.urlSession.data(for: moved, maximumBytes: 64)
                #expect(followed.statusCode == 200)
                #expect(followed.url == server.url("/target"))
                #expect(data == Data("target".utf8))
            }
        }
    }

    @Test("cancelling one shared read leaves concurrent and later reads running")
    func sharedReadCancellationIsIsolated() async throws {
        try await withTestWatchdog {
            let gate = LoopbackResponseGate()
            let server = try await LoopbackHTTPServer.start { request in
                if request.path.hasPrefix("/held") { await gate.wait() }
                return .init(body: Data("ok".utf8))
            }
            defer { server.stop() }
            let cancelled = Task {
                try await BoundedHTTPDataTransport.noRedirects.data(for: URLRequest(url: server.url("/held-a")), maximumBytes: 2)
            }
            let survivor = Task {
                try await BoundedHTTPDataTransport.noRedirects.data(for: URLRequest(url: server.url("/held-b")), maximumBytes: 2)
            }
            try await server.waitUntilRequests(count: 2)
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
            await gate.release()
            #expect(try await survivor.value.0 == Data("ok".utf8))
            let (later, _) = try await BoundedHTTPDataTransport.noRedirects.data(for: URLRequest(url: server.url("/later")), maximumBytes: 2)
            #expect(later == Data("ok".utf8))
        }
    }

    @Test("concurrent shared reads start at once like fresh per-request sessions")
    func sharedReadsAreNotQueuedPerHost() async throws {
        try await withTestWatchdog {
            let gate = LoopbackResponseGate()
            let server = try await LoopbackHTTPServer.start { _ in
                await gate.wait()
                return .init(body: Data("ok".utf8))
            }
            defer { server.stop() }
            let reads = (0..<12).map { index in
                Task {
                    try await BoundedHTTPDataTransport.urlSession.data(for: URLRequest(url: server.url("/blob/\(index)")), maximumBytes: 2)
                }
            }
            // CFNetwork's default per-host limit would hold all but a few here.
            try await server.waitUntilRequests(count: reads.count)
            await gate.release()
            for read in reads { #expect(try await read.value.0 == Data("ok".utf8)) }
            #expect(server.connectionCount() == reads.count)
        }
    }

    @Test("shared reads carry no cached response or cookie into a later request")
    func sharedReadsKeepNoCacheOrCookies() async throws {
        try await withTestWatchdog {
            let server = try await LoopbackHTTPServer.start { _ in
                .init(
                    headers: [
                        ("Cache-Control", "private, immutable, max-age=31536000"),
                        ("ETag", "\"blob\""),
                        ("Set-Cookie", "lease=fixture"),
                    ],
                    body: Data("blob".utf8)
                )
            }
            defer { server.stop() }
            for _ in 0..<2 {
                let (data, _) = try await BoundedHTTPDataTransport.urlSession.data(for: URLRequest(url: server.url("/blob")), maximumBytes: 4)
                #expect(data == Data("blob".utf8))
            }
            let requests = server.recordedRequests()
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.headers["cookie"] == nil && $0.headers["if-none-match"] == nil })
        }
    }

    @Test("a keep-alive connection the server retired does not fail the next read")
    func retiredKeepAliveConnectionIsRetriedForReads() async throws {
        try await withTestWatchdog {
            // Every connection answers once, then closes as its next request arrives.
            let server = try await LoopbackHTTPServer.start { request in
                request.sequenceOnConnection > 1 ? .init(closesWithoutResponse: true) : .init(body: Data("ok".utf8))
            }
            defer { server.stop() }
            for _ in 0..<3 {
                let (data, _) = try await BoundedHTTPDataTransport.noRedirects.data(for: URLRequest(url: server.url("/frame")), maximumBytes: 2)
                #expect(data == Data("ok".utf8))
            }
        }
    }

    @Test("a dropped connection fails reads and writes with the same transport error")
    func droppedConnectionErrorsMatchAcrossSessions() async throws {
        try await withTestWatchdog {
            let server = try await LoopbackHTTPServer.start { _ in .init(closesWithoutResponse: true) }
            defer { server.stop() }
            var codes: [URLError.Code] = []
            for method in ["GET", "DELETE"] {
                var request = URLRequest(url: server.url("/frame"))
                request.httpMethod = method
                do {
                    _ = try await BoundedHTTPDataTransport.noRedirects.data(for: request, maximumBytes: 2)
                    Issue.record("\(method) unexpectedly completed")
                } catch let error as URLError {
                    codes.append(error.code)
                }
            }
            #expect(codes == [.networkConnectionLost, .networkConnectionLost])
            #expect(GatewayClient.LiveError.classify(URLError(codes[0])) == .connectionInterrupted)
        }
    }

    @Test("profile-owned uploads remain available during a WebSocket reconnect")
    func gatewayUploadBoundary() async throws {
        try await withTestWatchdog {
            let profile = GatewayProfile(
                id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let socket = ScriptedGatewaySocket()
            let recorder = BoundedTransportRecorder()
            let transport = BoundedHTTPDataTransport { request, maximumBytes in
                await recorder.record(request: request, maximumBytes: maximumBytes)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data(#"{"upload":{"id":"upload-id"}}"#.utf8), response)
            }
            let factory = ScriptedGatewaySocketFactory(socket: socket)
            let client = GatewayClient(
                socketFactory: factory.factory,
                boundedHTTPDataTransport: transport
            )
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            let connection = try await client.connectForLifecycle(profile: profile, token: "secret")
            await client.closeIfCurrent(connectionID: connection.id)

            #expect(try await client.upload(name: "notes.txt", mimeType: "text/plain", data: Data("body".utf8)) == "upload-id")
            let recorded = try #require(await recorder.value)
            #expect(recorded.maximumBytes == GatewayUploadPolicy.maximumResponseBytes)
            #expect(recorded.request.httpBody == Data("body".utf8))
            #expect(recorded.request.url?.path == "/v1/uploads")
            #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            #expect(recorded.request.value(forHTTPHeaderField: "Content-Length") == "4")
            await client.close()
        }
    }

    @Test("discard uses the authenticated upload route and admits an empty response")
    func gatewayUploadDiscardBoundary() async throws {
        try await withTestWatchdog {
            let profile = GatewayProfile(
                id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let socket = ScriptedGatewaySocket()
            let recorder = BoundedTransportRecorder()
            let transport = BoundedHTTPDataTransport { request, maximumBytes in
                await recorder.record(request: request, maximumBytes: maximumBytes)
                return (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 204, httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                boundedHTTPDataTransport: transport
            )
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")

            try await client.discardUpload("00000000-0000-4000-8000-000000000001")
            let recorded = try #require(await recorder.value)
            #expect(recorded.maximumBytes == GatewayUploadPolicy.maximumResponseBytes)
            #expect(recorded.request.httpMethod == "DELETE")
            #expect(recorded.request.url?.path == "/v1/uploads/00000000-0000-4000-8000-000000000001")
            #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            await client.close()
        }
    }

    @Test("data upload preserves gateway failures instead of masking them")
    func gatewayUploadPreservesFailure() async throws {
        try await withTestWatchdog {
            let profile = GatewayProfile(
                id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let socket = ScriptedGatewaySocket()
            let transport = BoundedHTTPDataTransport { request, _ in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 503, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data(#"{"error":{"code":"busy","message":"Stored uploads are temporarily full","retryable":true,"details":null}}"#.utf8), response)
            }
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                boundedHTTPDataTransport: transport
            )
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")

            do {
                _ = try await client.upload(name: "photo.heic", mimeType: "image/heic", data: Data("photo".utf8))
                Issue.record("Upload unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure == GatewayFailure(code: "busy", message: "Stored uploads are temporarily full", retryable: true, details: nil))
            }
            await client.close()
        }
    }

    @Test("data upload survives a same-profile websocket reconnect")
    func gatewayDataUploadReconnect() async throws {
        try await withTestWatchdog {
            let profile = GatewayProfile(
                id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let oldSocket = ScriptedGatewaySocket()
            let replacementSocket = ScriptedGatewaySocket()
            let gate = UploadResponseGate()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(sockets: [oldSocket, replacementSocket]).factory,
                boundedHTTPDataTransport: BoundedHTTPDataTransport { request, _ in
                    try await gate.response(for: request)
                }
            )
            await oldSocket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")

            let upload = Task {
                try await client.upload(name: "photo.jpg", mimeType: "image/jpeg", data: Data("photo".utf8))
            }
            await gate.waitUntilStarted()
            await replacementSocket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")
            await gate.succeed()

            #expect(try await upload.value == "reconnected-upload")
            await client.close()
        }
    }

    @Test("file uploads retain bounded responses without constructing an HTTP body")
    func gatewayFileUploadBoundary() async throws {
        try await withTestWatchdog {
            let profile = GatewayProfile(
                id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let socket = ScriptedGatewaySocket()
            let recorder = BoundedUploadTransportRecorder()
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data("file-body".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let transport = BoundedHTTPUploadTransport { request, fileURL, maximumBytes in
                await recorder.record(request: request, fileURL: fileURL, maximumBytes: maximumBytes)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data(#"{"upload":{"id":"file-upload"}}"#.utf8), response)
            }
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                boundedHTTPUploadTransport: transport
            )
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")

            #expect(try await client.upload(
                name: "session.jsonl",
                mimeType: "application/x-ndjson",
                fileURL: file,
                byteCount: 9
            ) == "file-upload")
            let recorded = try #require(await recorder.value)
            #expect(recorded.maximumBytes == GatewayUploadPolicy.maximumResponseBytes)
            #expect(recorded.fileURL == file)
            #expect(recorded.request.httpBody == nil)
            #expect(recorded.request.url?.path == "/v1/uploads")
            #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            #expect(recorded.request.value(forHTTPHeaderField: "Content-Type") == "application/x-ndjson")
            #expect(recorded.request.value(forHTTPHeaderField: "Content-Length") == "9")
            await client.close()
        }
    }

    @Test("same-profile reconnect preserves a completed file upload")
    func gatewayFileUploadReconnect() async throws {
        try await withTestWatchdog {
            let profile = GatewayProfile(
                id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let oldSocket = ScriptedGatewaySocket()
            let replacementSocket = ScriptedGatewaySocket()
            let gate = UploadResponseGate()
            let transport = BoundedHTTPUploadTransport { request, _, _ in
                try await gate.response(for: request)
            }
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(sockets: [oldSocket, replacementSocket]).factory,
                boundedHTTPUploadTransport: transport
            )
            await oldSocket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")

            let upload = Task {
                try await client.upload(
                    name: "session.jsonl",
                    mimeType: "application/x-ndjson",
                    fileURL: URL(fileURLWithPath: "/tmp/session.jsonl"),
                    byteCount: 7
                )
            }
            await gate.waitUntilStarted()
            await replacementSocket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")
            await gate.succeed()

            #expect(try await upload.value == "reconnected-upload")
            await client.close()
        }
    }

    @Test("export blob reads remain file-backed and epoch-bound")
    func gatewayBlobFileBoundary() async throws {
        try await withTestWatchdog {
            let profile = GatewayProfile(
                id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let socket = ScriptedGatewaySocket()
            let factory = ScriptedGatewaySocketFactory(socket: socket)
            let recorder = BoundedTransportRecorder()
            let staged = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data("export".utf8).write(to: staged)
            defer { try? FileManager.default.removeItem(at: staged) }
            let fileTransport = BoundedHTTPFileTransport { request, maximumBytes in
                await recorder.record(request: request, maximumBytes: maximumBytes)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 206, httpVersion: nil,
                    headerFields: [
                        "Content-Type": "text/html",
                        "Content-Range": "bytes 3-5/6",
                    ]
                )!
                return BoundedHTTPDownloadedFile(url: staged, response: response, byteCount: 6)
            }
            let client = GatewayClient(
                socketFactory: factory.factory,
                boundedHTTPFileTransport: fileTransport
            )
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")

            #expect(try await client.blobFile(id: "export/id", maximumBytes: 25, expectedBytes: 6) == staged)
            let recorded = try #require(await recorder.value)
            #expect(recorded.maximumBytes == 25)
            #expect(recorded.request.url?.path == "/v1/blobs/export/id")
            #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            await #expect(throws: GatewayFailure.self) {
                try await client.blobFile(id: "export/id", maximumBytes: 25, expectedBytes: 7)
            }
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            await client.close()
        }
    }

    @Test("display media staging uses the exact authenticated session route")
    func displayArtifactFileBoundary() async throws {
        try await withTestWatchdog {
            let profile = GatewayProfile(
                id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let socket = ScriptedGatewaySocket()
            let recorder = BoundedTransportRecorder()
            let staged = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data("media".utf8).write(to: staged)
            defer { BoundedHTTPFileStaging.shared.discard(staged) }
            let fileTransport = BoundedHTTPFileTransport { request, maximumBytes in
                await recorder.record(request: request, maximumBytes: maximumBytes)
                return BoundedHTTPDownloadedFile(
                    url: staged,
                    response: HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "video/mp4"]
                    )!,
                    byteCount: 5
                )
            }
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                boundedHTTPFileTransport: fileTransport
            )
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","display-artifacts.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")
            let id = "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc3b"
            #expect(try await client.displayArtifactFile(
                id: id,
                sessionID: "session-1",
                profileID: profile.id,
                maximumBytes: 5,
                expectedBytes: 5
            ) == staged)
            let recorded = try #require(await recorder.value)
            #expect(recorded.maximumBytes == 5)
            #expect(recorded.request.url?.path == "/v1/sessions/session-1/display-artifacts/\(id)")
            #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            await client.close()
        }
    }

    @Test("profile-bound blob reads survive a WebSocket epoch handoff")
    func gatewayBlobBoundary() async throws {
        try await withTestWatchdog {
            let profile = GatewayProfile(
                id: "machine",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let socket = ScriptedGatewaySocket()
            let factory = ScriptedGatewaySocketFactory(socket: socket)
            let recorder = BoundedTransportRecorder()
            let transport = BoundedHTTPDataTransport { request, maximumBytes in
                await recorder.record(request: request, maximumBytes: maximumBytes)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                )!
                return (Data([1, 2, 3]), response)
            }
            let client = GatewayClient(
                socketFactory: factory.factory,
                boundedHTTPDataTransport: transport
            )
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            let connection = try await client.connectForLifecycle(profile: profile, token: "secret")
            await client.closeIfCurrent(connectionID: connection.id)

            let value = try await client.blob(
                id: "blob/id",
                profileID: profile.id,
                maximumBytes: 25
            )
            #expect(value.0 == Data([1, 2, 3]))
            #expect(value.1 == "image/png")
            let recorded = try #require(await recorder.value)
            #expect(recorded.maximumBytes == 25)
            #expect(recorded.request.url?.path == "/v1/blobs/blob/id")
            #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")

            await #expect(throws: CancellationError.self) {
                try await client.blob(
                    id: "blob",
                    profileID: "replacement",
                    maximumBytes: 25
                )
            }
            #expect(await recorder.count == 1)
            await client.close()
        }
    }
}

private actor UploadResponseGate {
    private var request: URLRequest?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        if request != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func succeed() {
        guard let request, let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!
        continuation?.resume(returning: (Data(#"{"upload":{"id":"reconnected-upload"}}"#.utf8), response))
        continuation = nil
    }
}

private actor BoundedUploadTransportRecorder {
    struct Value: @unchecked Sendable {
        let request: URLRequest
        let fileURL: URL
        let maximumBytes: Int
    }

    private(set) var value: Value?

    func record(request: URLRequest, fileURL: URL, maximumBytes: Int) {
        value = Value(request: request, fileURL: fileURL, maximumBytes: maximumBytes)
    }
}

private actor BoundedTransportRecorder {
    struct Value: @unchecked Sendable {
        let request: URLRequest
        let maximumBytes: Int
    }

    private(set) var value: Value?
    private(set) var count = 0

    func record(request: URLRequest, maximumBytes: Int) {
        count += 1
        value = Value(request: request, maximumBytes: maximumBytes)
    }
}

private class BoundedResponseURLProtocol: URLProtocol {
    class var responseHeaders: [String: String]? { nil }
    class var responseData: Data { Data([1, 2, 3, 4, 5]) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: Self.responseHeaders
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OversizedContentLengthURLProtocol: BoundedResponseURLProtocol {
    override class var responseHeaders: [String: String]? { ["Content-Length": "5"] }
}

private final class OversizedChunkURLProtocol: BoundedResponseURLProtocol {}

/// Holds loopback responses until the test releases them.
actor LoopbackResponseGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
