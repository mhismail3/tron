import Foundation
import Testing
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let request = URLRequest(url: URL(string: "https://gateway.test/bounded")!)
        do {
            _ = try await BoundedURLSessionDataLoader.load(
                request,
                maximumBytes: 4,
                configuration: configuration
            )
            Issue.record("Oversized response unexpectedly completed")
        } catch let error as URLError {
            #expect(error.code == .dataLengthExceedsMaximum)
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
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
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
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
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
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
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
            await oldSocket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")

            let upload = Task {
                try await client.upload(name: "photo.jpg", mimeType: "image/jpeg", data: Data("photo".utf8))
            }
            await gate.waitUntilStarted()
            await replacementSocket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
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
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
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
            await oldSocket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
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
            await replacementSocket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")
            await gate.succeed()

            #expect(try await upload.value == "reconnected-upload")
            await client.close()
        }
    }

    @Test("file upload transport propagates cancellation to its active operation")
    func gatewayFileUploadCancellation() async throws {
        try await withTestWatchdog {
            let cancellation = UploadCancellationRecorder()
            let transport = BoundedHTTPUploadTransport { _, _, _ in
                try await cancellation.suspend()
            }
            let request = URLRequest(url: URL(string: "https://gateway.test/v1/uploads")!)
            let operation = Task {
                try await transport.data(for: request, fileURL: URL(fileURLWithPath: "/tmp/file"), maximumBytes: 64)
            }
            await cancellation.waitUntilStarted()
            operation.cancel()
            await #expect(throws: CancellationError.self) { try await operation.value }
            #expect(await cancellation.wasCancelled)
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
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!
                return BoundedHTTPDownloadedFile(url: staged, response: response, byteCount: 6)
            }
            let client = GatewayClient(
                socketFactory: factory.factory,
                boundedHTTPFileTransport: fileTransport
            )
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")

            #expect(try await client.blobFile(id: "export/id", maximumBytes: 25) == staged)
            let recorded = try #require(await recorder.value)
            #expect(recorded.maximumBytes == 25)
            #expect(recorded.request.url?.path == "/v1/blobs/export/id")
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
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
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

private actor UploadCancellationRecorder {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private(set) var wasCancelled = false

    func suspend() async throws -> (Data, HTTPURLResponse) {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func cancel() {
        wasCancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
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
