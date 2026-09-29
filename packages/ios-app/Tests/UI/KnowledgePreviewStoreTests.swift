import Foundation
import Testing
import UIKit
@testable import TronMobileCore
@testable import TronMobile

/// Failure modes these cover, written before the implementation: bytes stored
/// under a hash that does not match them are presented; the mounted window grows
/// without bound; a batch asks the Gateway for more than it will answer in one
/// envelope; a refused preview is retried on every scroll, or never after the
/// connection returns; a row's image is fetched twice.
@Suite("Library preview store")
@MainActor
struct KnowledgePreviewStoreTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "KnowledgePreviewStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func imageData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try #require(image.pngData())
    }

    /// Distinct image bytes and the content address each one has. The Gateway
    /// publishes bytes addressed by their own hash, so a fixture must too.
    private func addressedImages(_ count: Int) throws -> [(hash: String, data: Data)] {
        let base = try imageData()
        return (0..<count).map { index in
            let data = index == 0 ? base : base + Data([UInt8(index)])
            return (KnowledgePreviewDigest.hex(data), data)
        }
    }

    /// Rows mount together, so their preview requests arrive together.
    private func loadConcurrently(_ hashes: [String], store: KnowledgePreviewStore, bytes: Int) async {
        var tasks: [Task<Void, Never>] = []
        for hash in hashes {
            tasks.append(Task { @MainActor in _ = await store.load(request(hash: hash, record: hash, bytes: bytes)) })
        }
        for task in tasks { await task.value }
    }

    private func request(hash: String, record: String = "record", bytes: Int) -> KnowledgePreviewRequest {
        KnowledgePreviewRequest(recordID: record, revisionID: "revision", reference: KnowledgeObjectRef(hash: hash, mediaType: "image/png", bytes: bytes))
    }

    private actor BatchRecorder {
        private(set) var batches: [[KnowledgePreviewRequest]] = []
        var results: [String: Data] = [:]
        var unavailable: Set<String> = []
        func record(_ batch: [KnowledgePreviewRequest]) { batches.append(batch) }
        func set(_ images: [String: Data], unavailable: Set<String>) { self.results = images; self.unavailable = unavailable }
        func outcome(for batch: [KnowledgePreviewRequest]) -> KnowledgePreviewBatchResult {
            KnowledgePreviewBatchResult(images: results.filter { key, _ in batch.contains { $0.hash == key } }, unavailableHashes: unavailable)
        }
    }

    /// A store whose transport answers from a recorder, with timed coalescing.
    private func store(_ recorder: BatchRecorder, root: URL, window: Duration = .milliseconds(30)) -> KnowledgePreviewStore {
        KnowledgePreviewStore(
            disk: KnowledgePreviewDiskCache(root: root),
            coalescingWindow: window,
            loadBatch: { requests, _ in
                await recorder.record(requests)
                return await recorder.outcome(for: requests)
            }
        )
    }

    @Test("rows that mount together are answered by one batch and cached once")
    func coalescingAndCache() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try imageData()
        let hash = KnowledgePreviewDigest.hex(data)
        let recorder = BatchRecorder()
        await recorder.set([hash: data], unavailable: [])
        let store = store(recorder, root: root)

        async let first = store.load(request(hash: hash, record: "a", bytes: data.count))
        async let second = store.load(request(hash: hash, record: "b", bytes: data.count))
        let images = await [first, second]
        #expect(images.allSatisfy { $0 != nil })
        // One object is one batch item however many rows asked for it.
        #expect(await recorder.batches.count == 1)
        #expect(await recorder.batches.first?.count == 1)
        #expect(await recorder.batches.first?.first?.recordID == "a")

        // A cached image is served without another request.
        _ = await store.load(request(hash: hash, record: "a", bytes: data.count))
        #expect(await recorder.batches.count == 1)
        #expect(store.image(for: hash) != nil)
    }

    @Test("one batch never exceeds the Gateway's item bound")
    func batchBound() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = BatchRecorder()
        let addressed = try addressedImages(KnowledgePreviewLimits.maximumBatchItems + 4)
        let hashes = addressed.map(\.hash)
        await recorder.set(Dictionary(addressed.map { ($0.hash, $0.data) }, uniquingKeysWith: { first, _ in first }), unavailable: [])
        let data = try imageData()
        let store = store(recorder, root: root, window: .milliseconds(120))
        // Rows that mount together ask concurrently; that is what coalesces.
        await loadConcurrently(hashes, store: store, bytes: data.count)
        let sizes = await recorder.batches.map(\.count)
        #expect(sizes.allSatisfy { $0 <= KnowledgePreviewLimits.maximumBatchItems })
        #expect(sizes.reduce(0, +) == hashes.count)
        #expect(sizes.count >= 2)
    }

    @Test("a refused preview is remembered, and retried when the connection returns")
    func unavailableRetry() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let addressed = try addressedImages(1)[0]
        let data = addressed.data
        let hash = addressed.hash
        let recorder = BatchRecorder()
        await recorder.set([:], unavailable: [hash])
        let store = store(recorder, root: root)
        #expect(await store.load(request(hash: hash, bytes: data.count)) == nil)
        let attemptsAfterFirst = await recorder.batches.count
        #expect(attemptsAfterFirst == 1)
        // A row that appears again does not repeat the refused request.
        #expect(await store.load(request(hash: hash, bytes: data.count)) == nil)
        #expect(await recorder.batches.count == attemptsAfterFirst)
        // The connection returning retries it once.
        await recorder.set([hash: data], unavailable: [])
        store.retryUnavailable()
        try await Task.sleep(for: .milliseconds(80))
        #expect(await recorder.batches.count > attemptsAfterFirst)
        #expect(store.image(for: hash) != nil)
    }

    @Test("a transport failure resolves the waiter without poisoning the hash")
    func transportFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let addressed = try addressedImages(1)[0]
        let data = addressed.data
        let hash = addressed.hash
        let attempts = AttemptCounter()
        let store = KnowledgePreviewStore(disk: KnowledgePreviewDiskCache(root: root), coalescingWindow: .milliseconds(10)) { _, _ in
            await attempts.increment()
            throw GatewayFailure(code: "offline", message: "no route", retryable: true, details: nil)
        }
        #expect(await store.load(request(hash: hash, bytes: data.count)) == nil)
        #expect(await attempts.count == 1)
        #expect(store.image(for: hash) == nil)
    }

    @Test("disk bytes that do not match their hash are never presented")
    func diskCorruption() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let addressed = try addressedImages(1)[0]
        let data = addressed.data
        let hash = addressed.hash
        let disk = KnowledgePreviewDiskCache(root: root)
        await disk.store(hash: hash, data: data)
        #expect(await disk.data(for: hash) == data)
        // The store refuses to write bytes that do not match the name they claim.
        let wrong = (try addressedImages(2)[1]).hash
        await disk.store(hash: wrong, data: data)
        #expect(await disk.data(for: wrong) == nil)
        // A file that was overwritten with other bytes is discarded on read.
        try Data(repeating: 3, count: 40).write(to: root.appending(path: "\(hash).img"))
        #expect(await disk.data(for: hash) == nil)
    }

    @Test("the disk cache stays inside its byte bound")
    func diskEviction() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let addressed = try addressedImages(6)
        // Two images fit; the rest must evict the oldest.
        let disk = KnowledgePreviewDiskCache(root: root, maximumBytes: addressed[0].data.count * 2)
        for entry in addressed { await disk.store(hash: entry.hash, data: entry.data) }
        let bound = addressed[0].data.count * 2
        #expect(await disk.byteCount() <= bound + addressed[0].data.count)
        var remaining = 0
        for entry in addressed { if await disk.data(for: entry.hash) != nil { remaining += 1 } }
        #expect(remaining > 0)
        #expect(remaining <= 3)
        // The newest image survives eviction.
        #expect(await disk.data(for: addressed[addressed.count - 1].hash) != nil)
    }

    @Test("the mounted window is bounded")
    func memoryBound() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let addressed = try addressedImages(12)
        let hashes = addressed.map(\.hash)
        let data = addressed[0].data
        let recorder = BatchRecorder()
        await recorder.set(Dictionary(addressed.map { ($0.hash, $0.data) }, uniquingKeysWith: { first, _ in first }), unavailable: [])
        let store = KnowledgePreviewStore(disk: KnowledgePreviewDiskCache(root: root), coalescingWindow: .milliseconds(10), maximumMemoryImages: 4) { requests, _ in
            await recorder.record(requests)
            return await recorder.outcome(for: requests)
        }
        await loadConcurrently(hashes, store: store, bytes: data.count)
        #expect(store.images.count == 4)
        // The evicted images stay on disk, so showing them again is not a fetch.
        let before = await recorder.batches.count
        _ = await store.load(request(hash: hashes[0], record: hashes[0], bytes: data.count))
        #expect(await recorder.batches.count == before)
        #expect(store.image(for: hashes[0]) != nil)
        store.removeAll()
        #expect(store.images.isEmpty)
    }
}

private actor AttemptCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
