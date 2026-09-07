import Foundation
import Synchronization
import Testing
@testable import TronMobile

@MainActor
struct ChatDetailDocumentPreparationTests {
    @Test("inactive detail performs no work and unchanged reactivation reuses its document")
    func demandAndReuse() async {
        let calls = Mutex(0)
        let preparation = ChatDetailDocumentPreparation(prepare: { source in
            let parsesOnMainThread = { Thread.isMainThread }()
            #expect(!parsesOnMainThread)
            calls.withLock { $0 += 1 }
            return MarkdownPresentation.Document(source: source)
        })
        var records: [String] = []
        await preparation.load(source: "**private summary**", isCurrent: { false }, record: { records.append($0) })
        #expect(calls.withLock { $0 } == 0)
        #expect(records.isEmpty)
        await preparation.load(source: "**private summary**", isCurrent: { true }, record: { records.append($0) })
        let revision = preparation.revision
        preparation.mounted { records.append($0) }
        preparation.mounted { records.append($0) }
        await preparation.load(source: "**private summary**", isCurrent: { false }, record: { records.append($0) })
        await preparation.load(source: "**private summary**", isCurrent: { true }, record: { records.append($0) })
        #expect(calls.withLock { $0 } == 1)
        #expect(preparation.revision == revision)
        #expect(preparation.document?.source == "**private summary**")
        #expect(records.filter { $0.contains("content-mounted") }.count == 1)
        #expect(records.allSatisfy { !$0.contains("private summary") })
    }

    @Test("replacement drains the previous parser and cannot publish its stale document")
    func replacementDrainsParser() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let queued = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); queued.continuation.finish() }
        let parser = DetailParserGate(entered: entered.continuation)
        let preparation = ChatDetailDocumentPreparation(prepare: { await parser.parse($0) })
        var records: [String] = []
        let record: @MainActor (String) -> Void = {
            records.append($0)
            if $0.contains("phase=requested generation=2 ") { queued.continuation.yield(()) }
        }
        var tasks: [Task<Void, Never>] = []
        tasks.append(Task { await preparation.load(source: "old", isCurrent: { true }, record: record) })
        do {
            try await awaitSignal(entered.stream)
            tasks.append(Task { await preparation.load(source: "new", isCurrent: { true }, record: record) })
            try await awaitSignal(queued.stream)
            #expect(await parser.calls == 1)
            #expect(preparation.document == nil)
            await parser.release()
            for task in tasks { await task.value }
            #expect(await parser.maximumActive == 1)
            #expect(preparation.document?.source == "new")
            #expect(records.contains { $0.contains("phase=discarded generation=1") })
            #expect(records.contains { $0.contains("phase=prepared generation=2") })
        } catch {
            for task in tasks { task.cancel() }
            await parser.release()
            for task in tasks { await task.value }
            throw error
        }
    }

    @Test("dismissal fences late completion and a later demand can prepare again")
    func dismissalAndReactivation() async throws {
        let entered = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish() }
        let parser = DetailParserGate(entered: entered.continuation)
        let preparation = ChatDetailDocumentPreparation(prepare: { await parser.parse($0) })
        let task = Task { await preparation.load(source: "summary", isCurrent: { true }, record: { _ in }) }
        do {
            try await awaitSignal(entered.stream)
            preparation.retire(record: { _ in })
            await parser.release()
            await task.value
            #expect(preparation.document == nil)
            await preparation.load(source: "summary", isCurrent: { true }, record: { _ in })
            #expect(preparation.document?.source == "summary")
            #expect(await parser.calls == 2)
        } catch {
            task.cancel()
            await parser.release()
            await task.value
            throw error
        }
    }

    private func awaitSignal(_ stream: AsyncStream<Void>) async throws {
        try await withTestWatchdog(timeout: .seconds(3)) {
            var iterator = stream.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }
}

/// Deliberately ignores cancellation while parsing, as synchronous Markdown
/// parsing does. Cleanup always opens this exact gate before awaiting tasks.
private actor DetailParserGate {
    let entered: AsyncStream<Void>.Continuation
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var calls = 0

    init(entered: AsyncStream<Void>.Continuation) { self.entered = entered }

    func parse(_ source: String) async -> MarkdownPresentation.Document {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if calls == 1 {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() }
                else { gate = continuation }
                entered.yield(())
            }
        }
        return MarkdownPresentation.Document(source: source)
    }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}
