import Foundation
import Testing
@testable import TronMobile

@Suite("Bounded HTTP file transport", .serialized)
struct BoundedHTTPFileTransportTests {
    @Test("expected and streamed byte limits fail closed at exact boundaries")
    func admissionBoundaries() throws {
        let admission = BoundedHTTPFileAdmission(maximumBytes: 4)
        try admission.admitExpectedLength(-1)
        try admission.admitExpectedLength(4)
        try admission.admitProgress(0)
        try admission.admitProgress(4)
        #expect(throws: URLError.self) { try admission.admitExpectedLength(5) }
        #expect(throws: URLError.self) { try admission.admitProgress(5) }
        #expect(throws: URLError.self) { try admission.admitProgress(-1) }
    }

    @Test("concrete URLSession download publishes exact files and honors early cancellation")
    func concreteLoaderLifecycle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedFileURLProtocol.self]
        let transport = BoundedHTTPFileTransport.urlSession(configuration: configuration)
        let request = URLRequest(url: URL(string: "https://gateway.invalid/export")!)

        BoundedFileURLProtocol.state.set(.response(status: 200, data: Data("four".utf8)))
        let result = try await transport.download(for: request, maximumBytes: 4)
        defer { BoundedHTTPFileStaging.shared.discard(result.url) }
        #expect(try Data(contentsOf: result.url) == Data("four".utf8))
        #expect(result.byteCount == 4)

        BoundedFileURLProtocol.state.set(.response(status: 200, data: Data("fifth".utf8)))
        await #expect(throws: URLError.self) {
            _ = try await transport.download(for: request, maximumBytes: 4)
        }

        BoundedFileURLProtocol.state.set(.pending)
        let pending = Task { try await transport.download(for: request, maximumBytes: 4) }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    @Test("staging is count bounded, active-safe, and explicitly retired")
    func stagingLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = BoundedHTTPFileStaging(root: root, maximumFiles: 1, maximumAge: 10)
        let first = try staging.reserveDestination(now: Date(timeIntervalSince1970: 100))
        try Data([1]).write(to: first)
        #expect(throws: URLError.self) {
            _ = try staging.reserveDestination(now: Date(timeIntervalSince1970: 100))
        }
        #expect(FileManager.default.fileExists(atPath: first.path))
        staging.discard(first)
        #expect(!FileManager.default.fileExists(atPath: first.path))

        let stale = root.appending(path: "stale")
        try Data([2]).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 80)],
            ofItemAtPath: stale.path
        )
        let replacement = try staging.reserveDestination(now: Date(timeIntervalSince1970: 100))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        staging.discard(replacement)
    }

    @Test("injected downloads preserve file-backed results without reading data")
    func injectedDownload() async throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("file-backed".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://gateway.invalid/v1/blobs/id")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let transport = BoundedHTTPFileTransport { request, maximumBytes in
            #expect(request.url?.path == "/v1/blobs/id")
            #expect(maximumBytes == 32)
            return BoundedHTTPDownloadedFile(url: source, response: response, byteCount: 11)
        }
        let result = try await transport.download(
            for: URLRequest(url: response.url!),
            maximumBytes: 32
        )
        #expect(result.url == source)
        #expect(result.byteCount == 11)
    }
}

private final class BoundedFileURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable {
        case response(status: Int, data: Data)
        case pending
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var behavior: Behavior = .pending

        func set(_ behavior: Behavior) {
            lock.lock()
            self.behavior = behavior
            lock.unlock()
        }

        func get() -> Behavior {
            lock.lock()
            defer { lock.unlock() }
            return behavior
        }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.state.get() {
        case .pending:
            return
        case .response(let status, let data):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(data.count)"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
