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

    @Test("uploads bound response accumulation and retain request bytes")
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
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")

            #expect(try await client.upload(name: "notes.txt", mimeType: "text/plain", data: Data("body".utf8)) == "upload-id")
            let recorded = try #require(await recorder.value)
            #expect(recorded.maximumBytes == GatewayUploadPolicy.maximumResponseBytes)
            #expect(recorded.request.httpBody == Data("body".utf8))
            #expect(recorded.request.url?.path == "/v1/uploads")
            #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
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
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!
                return BoundedHTTPDownloadedFile(url: staged, response: response, byteCount: 6)
            }
            let client = GatewayClient(
                socketFactory: factory.factory,
                boundedHTTPFileTransport: fileTransport
            )
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await client.connectForLifecycle(profile: profile, token: "secret")

            #expect(try await client.blobFile(id: "export/id", maximumBytes: 25) == staged)
            let recorded = try #require(await recorder.value)
            #expect(recorded.maximumBytes == 25)
            #expect(recorded.request.url?.path == "/v1/blobs/export/id")
            #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            await client.close()
        }
    }

    @Test("epoch-bound blob reads pass the limit into the streaming transport")
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
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8))
            let connection = try await client.connectForLifecycle(profile: profile, token: "secret")

            let value = try await client.blob(
                id: "blob/id",
                profileID: profile.id,
                connectionID: connection.id,
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
                    connectionID: connection.id,
                    maximumBytes: 25
                )
            }
            #expect(await recorder.count == 1)
            await client.close()
        }
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
