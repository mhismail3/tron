import Foundation
import Network
import Testing
@testable import TronMac

@Suite("MenuBarLogReader — owned WebSocket boundary")
struct MenuBarLogReaderTransportTests {
    @Test("silent peers cannot outlive the whole request deadline", arguments: [LogPeer.Plan.holdHello, .holdResponse])
    fileprivate func deadlineBoundsSilentPeer(plan: LogPeer.Plan) async throws {
        let peer = try LogPeer(plan: plan)
        defer { peer.stop() }
        let port = try await peer.start()
        let started = ContinuousClock.now
        let result = await MenuBarLogReader.fetchRecentLogs(host: "127.0.0.1", port: port, token: "synthetic", timeout: 1)
        #expect(result == .failure(.serverUnavailable))
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(!peer.watchdogFired)
        #expect(peer.receivedTypes.first == "hello")
        #expect(peer.receivedTypes.filter { $0 == "request" }.count == (plan == .holdHello ? 0 : 1))
        #expect(await peer.wait(for: .closed))
    }

    @Test("cancellation retires the exact pending socket", arguments: [LogPeer.Plan.holdHello, .holdResponse])
    fileprivate func cancellationRetiresSocket(plan: LogPeer.Plan) async throws {
        let peer = try LogPeer(plan: plan)
        defer { peer.stop() }
        let port = try await peer.start()
        let pending = Task {
            await MenuBarLogReader.fetchRecentLogs(host: "127.0.0.1", port: port, token: nil, timeout: 10)
        }
        defer { pending.cancel() }
        #expect(await peer.wait(for: plan == .holdHello ? .hello : .request))
        let cancelled = ContinuousClock.now
        pending.cancel()
        #expect(await pending.value == .failure(.serverUnavailable))
        #expect(cancelled.duration(to: .now) < .seconds(2))
        #expect(!peer.watchdogFired)
        #expect(await peer.wait(for: .closed))
    }

    @Test("normal large log replies preserve request, formatting and clipboard fallback")
    func preservesLargeLogReply() async throws {
        let message = String(repeating: "x", count: 1_990)
        let record = ["timestamp": "2026-09-05T00:00:00Z", "level": "info", "message": message]
        let response = try JSONSerialization.data(withJSONObject: [
            "type": "response", "id": "mac-system-logs", "ok": true,
            "result": ["records": Array(repeating: record, count: 200)],
        ])
        #expect(response.count > 256 * 1024)
        let peer = try LogPeer(plan: .reply(String(decoding: response, as: UTF8.self)))
        defer { peer.stop() }
        let port = try await peer.start()
        let result = await MenuBarLogReader.fetchRecentLogs(host: "127.0.0.1", port: port, token: "synthetic", timeout: 3)
        let expected = Array(repeating: "[2026-09-05T00:00:00Z] INFO TRON: \(message)", count: 200).joined(separator: "\n")
        #expect(result == .success(expected))
        #expect(peer.authorization == "Bearer synthetic")
        #expect(peer.receivedTypes == ["hello", "request"])
        let request = try #require(peer.request)
        #expect(request["id"] as? String == "mac-system-logs")
        #expect(request["method"] as? String == "system.logs")
        #expect((request["params"] as? [String: Int])?["limit"] == 200)
        let composer = FeedbackIssueComposer(appVersion: "0.1.0", buildNumber: "1", osVersion: "fixture")
        #expect(composer.openPlan(serverDescription: "running", logs: expected)?.copiedFullBodyToClipboard == true)
        #expect(await peer.wait(for: .closed))
    }

    @Test("oversized log messages fail without waiting for fixture cleanup")
    func oversizedReplyIsBounded() async throws {
        let response = #"{"type":"response","id":"mac-system-logs","ok":true,"result":{"records":[{"timestamp":"fixture","level":"info","message":""#
            + String(repeating: "x", count: 1_048_576) + #""}]}}"#
        let peer = try LogPeer(plan: .reply(response))
        defer { peer.stop() }
        let port = try await peer.start()
        #expect(await MenuBarLogReader.fetchRecentLogs(host: "127.0.0.1", port: port, token: nil, timeout: 3) == .failure(.serverUnavailable))
        #expect(await peer.wait(for: .closed))
        #expect(!peer.watchdogFired)
    }

    @Test("invalid hello never admits a log request")
    func invalidHelloStopsRequest() async throws {
        let peer = try LogPeer(plan: .invalidHello)
        defer { peer.stop() }
        let port = try await peer.start()
        let result = await MenuBarLogReader.fetchRecentLogs(host: "127.0.0.1", port: port, token: nil)
        #expect(result == .failure(.unreadableOutput("Gateway protocol is not compatible.")))
        #expect(await peer.wait(for: .closed))
        #expect(peer.receivedTypes == ["hello"])
    }

    @Test("eight unrelated frames terminate without replay")
    func unrelatedFramesAreBounded() async throws {
        let peer = try LogPeer(plan: .unrelatedFrames)
        defer { peer.stop() }
        let port = try await peer.start()
        #expect(await MenuBarLogReader.fetchRecentLogs(host: "127.0.0.1", port: port, token: nil) == .failure(.serverUnavailable))
        #expect(await peer.wait(for: .closed))
        #expect(peer.receivedTypes == ["hello", "request"])
        #expect(!peer.watchdogFired)
    }

    @Test("Gateway failure text reaches only the redacted issue body")
    func gatewayErrorIsRedactedAtExport() async throws {
        let detail = #"failed {"token":"short-secret"}"#
        let response = try JSONSerialization.data(withJSONObject: [
            "type": "response", "id": "mac-system-logs", "ok": false,
            "error": ["code": "fixture", "message": detail],
        ])
        let peer = try LogPeer(plan: .reply(String(decoding: response, as: UTF8.self)))
        defer { peer.stop() }
        let port = try await peer.start()
        let result = await MenuBarLogReader.fetchRecentLogs(host: "127.0.0.1", port: port, token: nil)
        #expect(result == .failure(.gatewayRequestFailed(detail)))
        guard case .failure(let error) = result else { Issue.record("expected Gateway error"); return }
        let composer = FeedbackIssueComposer(appVersion: "0.1.0", buildNumber: "1", osVersion: "fixture")
        let plan = try #require(composer.openPlan(serverDescription: "running", logs: "Log capture failed: \(error.message)"))
        let body = try #require(URLComponents(url: plan.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        #expect(body.contains("Log capture failed: failed"))
        #expect(!body.contains("short-secret"))
        #expect(await peer.wait(for: .closed))
    }
}

/// Only loopback/ephemeral sockets and synthetic messages. Network.framework
/// owns WebSocket framing; this fixture does not emulate the production client.
/// The watchdog releases known-bad clients, but can never make a deadline pass.
private final class LogPeer: @unchecked Sendable {
    enum Plan: Equatable, Sendable { case holdHello, holdResponse, reply(String), invalidHello, unrelatedFrames }
    enum Event: Sendable { case hello, request, closed }
    private let plan: Plan
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tron-test-log-peer")
    private let lock = NSLock()
    private let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation
    private var connection: NWConnection?
    private var stopped = false
    private var didClose = false
    private var didStart = false
    private var watchdog: DispatchWorkItem?
    private var expired = false
    private var frames: [[String: Any]] = []
    private let handshake = AuthorizationCapture()

    private final class AuthorizationCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var header: String?
        var value: String? {
            get { lock.withLock { header } }
            set { lock.withLock { header = newValue } }
        }
    }

    var watchdogFired: Bool { lock.withLock { expired } }
    var receivedTypes: [String] { lock.withLock { frames.compactMap { $0["type"] as? String } } }
    var authorization: String? { handshake.value }
    var request: [String: Any]? { lock.withLock { frames.first { $0["type"] as? String == "request" } } }

    init(plan: Plan) throws {
        self.plan = plan
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let options = NWProtocolWebSocket.Options()
        let capture = handshake
        options.setClientRequestHandler(queue) { _, headers in
            capture.value = headers.first { $0.name.lowercased() == "authorization" }?.value
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        // Listener creation snapshots the protocol options, including this hook.
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let admitted = self.lock.withLock {
                guard !self.stopped, self.connection == nil else { return false }
                self.connection = connection
                return true
            }
            guard admitted else { connection.cancel(); return }
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.peerClosed() }
            }
            connection.start(queue: self.queue)
            self.receive(connection)
        }
    }

    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let result: Result<Int, Error>
                switch state {
                case .ready: result = .success(Int(self.listener.port!.rawValue))
                case .failed(let error): result = .failure(error)
                case .cancelled: result = .failure(CancellationError())
                default: return
                }
                let first = self.lock.withLock { if self.didStart { return false }; self.didStart = true; return true }
                if first { continuation.resume(with: result) }
            }
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.expired = true }
                self.stop()
            }
            lock.withLock { watchdog = timer }
            queue.asyncAfter(deadline: .now() + 5, execute: timer)
            listener.start(queue: queue)
        }
    }

    func wait(for wanted: Event) async -> Bool {
        for await event in events { if event == wanted { return true } }
        return false
    }

    func stop() {
        let owned = lock.withLock { stopped = true; return (connection, watchdog) }
        owned.1?.cancel()
        owned.0?.cancel()
        listener.cancel()
        eventSink.finish()
    }

    private func peerClosed() {
        let first = lock.withLock { if stopped || didClose { return false }; didClose = true; return true }
        if first { eventSink.yield(.closed); eventSink.finish() }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close || data == nil {
                self.peerClosed()
                connection.cancel()
                return
            }
            if let data, let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.lock.withLock { self.frames.append(frame) }
                if frame["type"] as? String == "hello" {
                    self.eventSink.yield(.hello)
                    if self.plan != .holdHello {
                        self.send(self.plan == .invalidHello ? #"{"type":"hello","protocolVersion":0,"minProtocolVersion":0}"# : #"{"type":"hello","protocolVersion":5,"minProtocolVersion":5}"#, on: connection)
                    }
                } else if frame["type"] as? String == "request" {
                    self.eventSink.yield(.request)
                    if case .reply(let text) = self.plan { self.send(text, on: connection) }
                    if self.plan == .invalidHello {
                        // A client bypassing hello validation must fail the
                        // admission oracle, not merely time out in this fixture.
                        self.send(#"{"type":"response","id":"mac-system-logs","ok":true,"result":{"records":[]}}"#, on: connection)
                    }
                    if self.plan == .unrelatedFrames {
                        for _ in 0..<8 { self.send(#"{"type":"event","id":"other"}"#, on: connection) }
                    }
                }
            }
            self.receive(connection)
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "fixture", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
