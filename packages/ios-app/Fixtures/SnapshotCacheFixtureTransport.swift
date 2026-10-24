#if HOSTED_TEST
import Foundation
import TronMobileCore

/// Wire input only. Cache storage, catalog reduction and checkpoint scheduling
/// are the real app owners; this peer never answers persistence assertions.
actor SnapshotCacheFixtureGateway {
    static let transcriptMarker = "ASSISTANT_TRANSCRIPT_NOT_A_CACHE_DOCUMENT"
    static let time = "2026-01-01T00:00:00Z"
    private weak var socket: SnapshotCacheFixtureSocket?
    let offline: Bool
    init(offline: Bool) { self.offline = offline }
    func attach(_ socket: SnapshotCacheFixtureSocket) { self.socket = socket }

    static func row(name: String = "Before summary", archived: Bool = false) -> SessionSummary {
        SessionSummary(id: archived ? "cache-archived" : "cache-live", name: name, cwd: "/fixture/cache",
            parentSessionId: nil, createdAt: time, updatedAt: time, messageCount: 1,
            firstMessage: "A summary, not a transcript", phase: .idle, summaryRevision: 1,
            archivedAt: archived ? time : nil)
    }

    func summary() async throws {
        let update = SessionSummaryUpdate(sessionId: "cache-live", summaryRevision: 2, phase: .idle,
            name: "After summary", updatedAt: Self.time, messageCount: 2,
            firstMessage: "A summary, not a transcript")
        try await socket?.deliver(JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("event"), "topic": .string("session.summary"), "sessionId": .string("cache-live"),
            "payload": try JSONValue.encode(update)])))
    }

    func response(_ method: String) throws -> JSONValue? {
        switch method {
        case "session.list":
            if offline { return nil } // retain the real loaded cache; never replace it with a fake page
            return .object(["sessions": try JSONValue.encode([Self.row()]), "nextCursor": .null,
                "listRevision": .number(1), "projectionToken": .string("cache:1"), "archivedCount": .number(7)])
        case "session.open":
            return .object(["session": try JSONValue.encode(Self.snapshot()), "syncToken": .string("cache-sync"),
                "subscriptionToken": .string("cache-subscription"), "completionRevision": .number(0)])
        case "session.sync": return .object(["synchronized": .bool(true)])
        case "session.close": return .object(["closed": .bool(true)])
        case "session.commands": return .object(["commands": .array([])])
        case "session.attention.read":
            return .object(["completionRevision": .number(0), "attentionRevision": .number(0), "isUnread": .bool(false)])
        default: return .object([:])
        }
    }

    private static func snapshot() -> SessionSnapshot {
        let content = ContentPart(id: "cache-text", ordinal: 0, thinkingRunOrdinal: nil, type: .text,
            text: transcriptMarker, attachment: nil, redacted: nil, mimeType: nil, blobId: nil,
            toolCallId: nil, name: nil, arguments: nil)
        let message = MessageTranscriptItem(id: "cache-message", parentId: nil, timestamp: time, kind: .message,
            role: .assistant, presentationId: "cache-message", content: [content])
        return SessionSnapshot(sessionId: "cache-live", runtimeGeneration: "fixture", revision: 1, eventSequence: 1,
            phase: .idle, name: "Before summary", cwd: "/fixture/cache", parentSessionId: nil, model: nil,
            thinkingLevel: "off", availableThinkingLevels: [], contextUsage: nil,
            stats: SessionStats(userMessages: 0, assistantMessages: 1, toolCalls: 0, toolResults: 0, totalMessages: 1,
                tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
            queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true, transcript: [.message(message)],
            transcriptStart: 0, transcriptTotal: 1, streaming: nil, leafEntryId: "cache-message", operation: nil,
            retry: nil, toolExecutions: [], extensionPresentation: ExtensionPresentationState(version: 3,
                hostEpoch: "fixture", revision: 1, capabilities: [], diagnostics: [],
                semanticState: .init(statuses: [:], working: .init(message: nil, visible: false), hiddenThinkingLabel: nil,
                    widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                surfaces: [], pendingInteractions: []), diagnostics: [])
    }
}

actor SnapshotCacheFixtureSocket: GatewaySocketConnection {
    private let gateway: SnapshotCacheFixtureGateway
    private var frames: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private var hello = false
    private var closed = false
    init(gateway: SnapshotCacheFixtureGateway) {
        self.gateway = gateway
        Task { await gateway.attach(self) }
    }
    func send(_ data: Data) async throws {
        let request = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard let id = request["id"]?.stringValue, let method = request["method"]?.stringValue else { return }
        guard let result = try await gateway.response(method) else { return }
        deliver(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result])))
    }
    func receive() async throws -> Data {
        if !hello {
            hello = true
            return Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":8,"minProtocolVersion":8,"machineId":"cache-fixture-machine","machineName":"Cache fixture","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
        }
        if !frames.isEmpty { return frames.removeFirst() }
        if closed || Task.isCancelled { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { receiver = $0 }
        } onCancel: { Task { await self.cancelReceive() } }
    }
    func deliver(_ data: Data) {
        if let receiver { self.receiver = nil; receiver.resume(returning: data) }
        else { frames.append(data) }
    }
    private func cancelReceive() { receiver?.resume(throwing: CancellationError()); receiver = nil }
    func ping() async throws { if closed { throw CancellationError() } }
    func close() async { closed = true; frames.removeAll(); cancelReceive() }
}

/// Only the existing summary-delay clock port is held. Cancellation releases
/// every waiter; no process signal, real filesystem replacement or private state.
actor SnapshotCacheFixtureDelay {
    nonisolated let entries: AsyncStream<Void>
    private let entered: AsyncStream<Void>.Continuation
    private var armed = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    init() { (entries, entered) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    func arm() { armed = true }
    func sleep(_ duration: Duration) async throws {
        guard armed, duration == SnapshotCachePolicy.summaryCheckpointDelay else {
            try await MonotonicClock.continuous.sleep(duration); return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation; entered.yield(()) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func release() {
        armed = false
        let pending = waiters.values; waiters.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

/// A run-local observer gate at the existing synchronous cache-save signpost
/// boundary. The native app's UI remains live while its real cache actor waits.
/// The test must release it in teardown; its owning process also has a finite
/// native-run deadline. This does not freeze Gateway/agent processes.
final class SnapshotCacheFixtureSaveGate: PerformanceSignposting, @unchecked Sendable {
    let entries: AsyncStream<Void>
    let completions: AsyncStream<Void>
    private let entered: AsyncStream<Void>.Continuation
    private let completed: AsyncStream<Void>.Continuation
    private let condition = NSCondition()
    private var armed = false
    private var released = true
    init() {
        (entries, entered) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (completions, completed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    func arm() { condition.lock(); armed = true; released = false; condition.unlock() }
    func release() { condition.lock(); armed = false; released = true; condition.broadcast(); condition.unlock() }
    func begin(_ operation: PerformanceOperation) -> PerformanceInterval {
        let interval = SystemPerformanceSignposts.shared.begin(operation)
        if case .cacheSave = operation {
            condition.lock()
            if armed {
                armed = false
                entered.yield(())
                while !released { condition.wait() }
            }
            condition.unlock()
        }
        return interval
    }
    func end(_ interval: PerformanceInterval, result: PerformanceResult, metrics: PerformanceMetrics) {
        SystemPerformanceSignposts.shared.end(interval, result: result, metrics: metrics)
        if case .cacheSave = interval.operation { completed.yield(()) }
    }
}
#endif
