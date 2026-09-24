import Foundation
import Testing
@testable import TronMobile

@MainActor @Suite("Session History read ownership")
struct SessionHistoryStoreTests {
    static let identity = SessionHistoryReadIdentity(profileID: "fixture", target: .init(sessionID: "session", generation: 1), runtimeGeneration: "runtime", reconciliationGeneration: 1)
    nonisolated static func node(_ id: String) -> SessionTreeNode {
        SessionTreeNode(id: id, parentId: nil, timestamp: "2026-01-01T00:00:00Z", kind: "message", label: nil,
                        preview: "Message \(id)", role: .user, depth: 0, childCount: 0, isCurrentPath: true)
    }
    nonisolated static func page(_ id: String, runtime: String = "runtime") throws -> JSONValue {
        try JSONValue.encode(SessionHistoryPage(runtimeGeneration: runtime, nodes: [node(id)], older: nil, newer: nil, totalEntries: 1))
    }
    nonisolated static func detail(offset: Int = 0, text: String = "Complete message", next: Int? = nil, total: Int? = nil) throws -> JSONValue {
        try JSONValue.encode(SessionHistoryEntryPage(runtimeGeneration: "runtime", entryId: "entry", text: text,
            offset: offset, nextOffset: next, previousOffset: offset > 0 ? max(0, offset - 24_000) : nil,
            totalCharacters: total ?? offset + text.utf16.count, metadata: .object(["role": .string("user")])))
    }

    @Test("duplicate initial requests coalesce and a retired failure cannot replace its successor")
    func listOwnership() async throws {
        try await withTestWatchdog { @MainActor in
            let gate = HistoryRequestGate()
            let store = SessionHistoryStore()
            let first = Task { await store.load(identity: Self.identity, cursor: nil, request: gate.request, isCurrent: { true }) }
            await gate.waitForCount(1)
            let duplicate = await store.load(identity: Self.identity, cursor: nil, request: gate.request, isCurrent: { true })
            #expect(!duplicate)
            #expect(await gate.count == 1)
            store.suspend()
            let next = Task { await store.load(identity: Self.identity, cursor: nil, request: gate.request, isCurrent: { true }) }
            await gate.waitForCount(2)
            await gate.finish(1, value: try Self.page("new"))
            #expect(await next.value)
            await gate.finish(0, value: .null)
            #expect(!(await first.value))
            #expect(store.page?.nodes.first?.id == "new")
            #expect(store.error == nil && !store.loading)
        }
    }

    @Test("coverage cancels publication and reactivation can load without a second wake")
    func coverageAndCancellation() async throws {
        try await withTestWatchdog { @MainActor in
            let gate = HistoryRequestGate()
            let fence = HistoryPublicationFence()
            let store = SessionHistoryStore()
            let first = Task { await store.load(identity: Self.identity, cursor: nil, request: gate.request, isCurrent: { fence.active }) }
            await gate.waitForCount(1)
            fence.active = false; first.cancel(); store.suspend()
            await gate.finish(0, value: try Self.page("covered"))
            #expect(!(await first.value))
            #expect(store.page == nil && store.error == nil && !store.loading)
            fence.active = true
            let resumed = await store.load(identity: Self.identity, cursor: nil, request: { _, _ in try Self.page("resumed") }, isCurrent: { fence.active })
            #expect(resumed)
            #expect(store.page?.nodes.first?.id == "resumed")
        }
    }

    @Test("exact profile target runtime and reconciliation identity reject stale success")
    func replacedIdentity() async throws {
        try await withTestWatchdog { @MainActor in
            let gate = HistoryRequestGate()
            let store = SessionHistoryStore()
            let old = Task { await store.load(identity: Self.identity, cursor: nil, request: gate.request, isCurrent: { true }) }
            await gate.waitForCount(1)
            let replacement = SessionHistoryReadIdentity(profileID: "other", target: .init(sessionID: "session", generation: 2), runtimeGeneration: "replacement", reconciliationGeneration: 2)
            let latest = await store.load(identity: replacement, cursor: nil,
                request: { _, _ in try Self.page("latest", runtime: "replacement") }, isCurrent: { true })
            #expect(latest)
            await gate.finish(0, value: try Self.page("old"))
            #expect(!(await old.value))
            #expect(store.identity == replacement && store.page?.nodes.first?.id == "latest")
        }
    }

    @Test("explicit bounded pages retain server order and require a progressing canonical boundary")
    func pagingAdmission() async throws {
        let store = SessionHistoryStore()
        let nodes = (101...200).reversed().map { Self.node("\($0)") }
        let older = SessionHistoryCursor(ordinal: 100, entryId: "101", direction: "older")
        let first = SessionHistoryPage(runtimeGeneration: "runtime", nodes: nodes, older: older, newer: nil, totalEntries: 200)
        #expect(await store.load(identity: Self.identity, cursor: nil,
            request: { _, _ in try JSONValue.encode(first) }, isCurrent: { true }))
        #expect(store.page?.nodes.map(\.id) == nodes.map(\.id))
        let second = SessionHistoryPage(runtimeGeneration: "runtime", nodes: (1...100).reversed().map { Self.node("\($0)") },
            older: nil, newer: .init(ordinal: 99, entryId: "100", direction: "newer"), totalEntries: 200)
        let advanced = await store.load(identity: Self.identity, cursor: older,
            request: { method, params in
                #expect(method == "session.history.list")
                #expect(params.objectValue?["cursor"] == (try JSONValue.encode(older)))
                return try JSONValue.encode(second)
            }, isCurrent: { true })
        #expect(advanced)
        #expect(store.page?.nodes.count == 100 && store.page?.nodes.first?.id == "100")
        #expect(!(await store.load(identity: Self.identity, cursor: older,
            request: { _, _ in try JSONValue.encode(first) }, isCurrent: { true })))
        #expect(store.error != nil)
        #expect(store.page?.nodes.first?.id == "100", "Failed paging does not evict the completed window")
    }

    nonisolated static func window(_ range: ClosedRange<Int>, total: Int) -> SessionHistoryPage {
        SessionHistoryPage(runtimeGeneration: "runtime", nodes: range.reversed().map { node("\($0)") },
            older: range.lowerBound > 1 ? .init(ordinal: range.lowerBound - 1, entryId: "\(range.lowerBound)", direction: "older") : nil,
            newer: range.upperBound < total ? .init(ordinal: range.upperBound - 1, entryId: "\(range.upperBound)", direction: "newer") : nil,
            totalEntries: total)
    }

    @Test("range labels follow canonical ordinals through first last partial and append-shifted windows")
    func exactRanges() throws {
        for (range, total) in [(1894...1993, 1993), (1794...1893, 1993), (1...93, 1993), (1894...1993, 2007), (1994...2007, 2007), (1...1, 1)] {
            let page = try Self.window(range, total: total).admitted(runtime: "runtime")
            #expect(page.entryRange == range)
            #expect((page.older != nil) == (range.lowerBound > 1))
            #expect((page.newer != nil) == (range.upperBound < total))
            #expect(page.rangeDescription == "Entries \(range.lowerBound.formatted())–\(range.upperBound.formatted()) of \(total.formatted())")
        }
        let empty = SessionHistoryPage(runtimeGeneration: "runtime", nodes: [], older: nil, newer: nil, totalEntries: 0)
        #expect(try empty.admitted(runtime: "runtime").entryRange == nil)
        #expect(empty.rangeDescription == "No recorded entries")
        let malformed = SessionHistoryPage(runtimeGeneration: "runtime", nodes: [Self.node("10")],
            older: .init(ordinal: 8, entryId: "10", direction: "older"), newer: nil, totalEntries: 10)
        #expect(throws: SessionHistoryReadError.self) { try malformed.admitted(runtime: "runtime") }
        #expect(throws: SessionHistoryReadError.self) {
            try SessionHistoryPage(runtimeGeneration: "runtime", nodes: [], older: nil, newer: nil, totalEntries: 10).admitted(runtime: "runtime")
        }
    }

    @Test("only successful explicit navigation advances native viewport identity")
    func viewportCommitOwnership() async throws {
        try await withTestWatchdog { @MainActor in
            let store = SessionHistoryStore()
            let initial = Self.window(101...200, total: 200)
            #expect(await store.load(identity: Self.identity, cursor: nil,
                request: { _, _ in try JSONValue.encode(initial) }, isCurrent: { true }))
            #expect(store.viewportGeneration == 0)
            let gate = HistoryRequestGate()
            let pending = Task { await store.load(identity: Self.identity, cursor: initial.older, resetViewport: true,
                request: gate.request, isCurrent: { true }) }
            await gate.waitForCount(1)
            store.suspend()
            #expect(await store.load(identity: Self.identity, cursor: nil,
                request: { _, _ in try JSONValue.encode(initial) }, isCurrent: { true }))
            await gate.finish(0, value: try JSONValue.encode(Self.window(1...100, total: 200)))
            #expect(!(await pending.value))
            #expect(store.viewportGeneration == 0)
            #expect(!(await store.load(identity: Self.identity, cursor: initial.older, resetViewport: true,
                request: { _, _ in .null }, isCurrent: { true })))
            #expect(store.viewportGeneration == 0 && store.page?.entryRange == 101...200)
            #expect(await store.load(identity: Self.identity, cursor: initial.older, resetViewport: true,
                request: { _, _ in try JSONValue.encode(Self.window(1...100, total: 200)) }, isCurrent: { true }))
            #expect(store.viewportGeneration == 1 && store.page?.entryRange == 1...100)
        }
    }

    @Test("entry detail preserves Unicode text and reaches a large message tail without accumulating bodies")
    func fullDetailPages() async throws {
        let store = SessionHistoryEntryStore()
        let text = String(repeating: "é", count: 23_998) + "😀"
        await store.load(identity: Self.identity, entryID: "entry", offset: 0,
            request: { _, _ in try Self.detail(text: text, next: 24_000, total: 24_010) }, isCurrent: { true })
        #expect(store.page?.text == text && store.page?.nextOffset == 24_000)
        await store.load(identity: Self.identity, entryID: "entry", offset: 24_000,
            request: { _, params in
                #expect(params.objectValue?["offset"] == .number(24_000))
                return try Self.detail(offset: 24_000, text: "final tail")
            }, isCurrent: { true })
        #expect(store.page?.text == "final tail" && store.page?.nextOffset == nil)
        #expect(store.page?.text.utf16.count == 10)
    }

    @Test("entry stale errors and oversized metadata cannot cross the current request fence")
    func detailOwnership() async throws {
        try await withTestWatchdog { @MainActor in
            let gate = HistoryRequestGate()
            let store = SessionHistoryEntryStore()
            let pending = Task { await store.load(identity: Self.identity, entryID: "entry", offset: 0, request: gate.request, isCurrent: { true }) }
            await gate.waitForCount(1)
            store.suspend()
            await store.load(identity: Self.identity, entryID: "entry", offset: 0,
                request: { _, _ in try Self.detail() }, isCurrent: { true })
            await gate.finish(0, value: .null); await pending.value
            #expect(store.page?.text == "Complete message" && store.error == nil && !store.loading)
            var malformed = try Self.detail().objectValue!
            malformed["metadata"] = .object(["oversized": .string(String(repeating: "x", count: 40_000))])
            let invalid = JSONValue.object(malformed)
            await store.load(identity: Self.identity, entryID: "entry", offset: 0,
                request: { _, _ in invalid }, isCurrent: { true })
            #expect(store.error != nil && store.page?.text == "Complete message")
        }
    }

    @Test("bookmark records act on the real labeled entry, while branch continuation stays in-session")
    func actionTargets() {
        let bookmark = SessionTreeNode(bookmarkTargetId: "prompt", id: "label-receipt", parentId: "prompt",
            timestamp: "2026-01-01T00:00:00Z", kind: "label", label: "Checkpoint", preview: "Checkpoint", role: nil,
            depth: 0, childCount: 0, isCurrentPath: true)
        #expect(SessionHistoryPolicy.bookmarkEntryID(bookmark) == "prompt")
        #expect(SessionHistoryPolicy.bookmarkTitle(bookmark) == "Edit Bookmark")
        #expect(SessionHistoryPolicy.canBookmark(bookmark))
        var orphan = bookmark
        orphan.bookmarkTargetId = nil
        #expect(!SessionHistoryPolicy.canBookmark(orphan))
        let branch = SessionTreeNode(id: "branch", parentId: "prompt", timestamp: "2026-01-01T00:00:00Z", kind: "branchSummary",
            label: nil, preview: "Alternative", role: nil, depth: 0, childCount: 0, isCurrentPath: false)
        #expect(SessionHistoryPolicy.navigationTitle(for: branch) == "Continue on Branch")
        #expect(SessionHistoryRowPresentation(node: branch).kindLabel == "Branch")
        let contextEdit = SessionTreeNode(id: "edit", parentId: "prompt", timestamp: "2026-01-01T00:00:01Z",
            kind: "contextEdit", label: nil, preview: "Model context edit: prompt", role: nil, depth: 0,
            childCount: 0, isCurrentPath: true)
        let systemMessage = SessionTreeNode(id: "system", parentId: "edit", timestamp: "2026-01-01T00:00:02Z",
            kind: "systemMessage", label: nil, preview: "System context message", role: nil, depth: 0,
            childCount: 0, isCurrentPath: true)
        #expect(SessionHistoryRowPresentation(node: contextEdit).kindLabel == "Context edit")
        #expect(SessionHistoryRowPresentation(node: systemMessage).kindLabel == "System context")
    }
}

@MainActor private final class HistoryPublicationFence { var active = true }
private actor HistoryRequestGate {
    var count = 0
    private var replies: [Int: CheckedContinuation<JSONValue, Never>] = [:]
    private var arrivals: [Int: CheckedContinuation<Void, Never>] = [:]
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let index = count; count += 1
        arrivals.removeValue(forKey: count)?.resume()
        return await withCheckedContinuation { replies[index] = $0 }
    }
    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { arrivals[expected] = $0 }
    }
    func finish(_ index: Int, value: JSONValue) { replies.removeValue(forKey: index)?.resume(returning: value) }
}
