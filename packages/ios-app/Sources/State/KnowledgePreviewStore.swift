import CryptoKit
import Foundation
import ImageIO
import Observation
import TronMobileCore
import UIKit

enum KnowledgePreviewPolicy {
    /// The cached image is bounded for a 52-point catalogue row and the detail's
    /// slightly larger header, on the densest supported display.
    static let maximumImagePixels = 192
    /// The mounted window the store keeps decoded. Older images stay on disk and
    /// are decoded again on demand.
    static let maximumMemoryImages = 80
    /// Recent library images kept as their exact original bytes, addressed by
    /// hash so a file can never disagree with the reference that named it.
    static let maximumDiskBytes = 32 * 1_024 * 1_024
    /// Rows that mount together ask once instead of racing per row.
    static let coalescingWindow: Duration = .milliseconds(40)
}

/// Content-addressed preview bytes on disk. The file name is the object hash the
/// Gateway published, so a cached image is self-verifying and never stale; the
/// directory is bounded by its oldest files.
actor KnowledgePreviewDiskCache {
    private let root: URL
    private let maximumBytes: Int

    init(root: URL? = nil, maximumBytes: Int = KnowledgePreviewPolicy.maximumDiskBytes) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "KnowledgePreviews", directoryHint: .isDirectory)
        self.maximumBytes = max(0, maximumBytes)
    }

    /// Returns the exact stored bytes only when they still hash to the name.
    func data(for hash: String) -> Data? {
        guard let url = fileURL(for: hash), let data = try? Data(contentsOf: url) else { return nil }
        guard !data.isEmpty, KnowledgePreviewDigest.hex(data) == hash else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return data
    }

    func store(hash: String, data: Data) {
        guard maximumBytes > 0, !data.isEmpty, data.count <= KnowledgePreviewPolicy.maximumDiskBytes, KnowledgePreviewDigest.hex(data) == hash, let url = fileURL(for: hash) else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        evictIfNeeded()
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    func byteCount() -> Int {
        guard let values = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return 0 }
        return values.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func fileURL(for hash: String) -> URL? {
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        return root.appending(path: "\(hash).img", directoryHint: .notDirectory)
    }

    private func evictIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var total = 0
        var described: [(url: URL, size: Int, modified: Date)] = []
        for value in values {
            let resource = try? value.resourceValues(forKeys: Set(keys))
            let size = resource?.fileSize ?? 0
            total += size
            described.append((value, size, resource?.contentModificationDate ?? .distantPast))
        }
        guard total > maximumBytes else { return }
        for candidate in described.sorted(by: { $0.modified < $1.modified }) {
            guard total > maximumBytes else { break }
            try? FileManager.default.removeItem(at: candidate.url)
            total -= candidate.size
        }
    }
}

enum KnowledgePreviewDigest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Downsampling is I/O-free and bounded; it runs off the main actor because a
/// page of previews decodes several images at once.
enum KnowledgePreviewDecoder {
    nonisolated static func downsample(_ data: Data, maximumPixels: Int = KnowledgePreviewPolicy.maximumImagePixels) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

/// The Library's single preview owner. Images are addressed by object hash, so
/// one image is fetched at most once per Gateway and a cached image can never
/// disagree with the reference that named it. Rows that mount together are
/// coalesced into bounded batches instead of one request per row.
@MainActor @Observable
final class KnowledgePreviewStore {
    private struct Wanted { let request: KnowledgePreviewRequest; let includeArchived: Bool }

    private(set) var images: [String: UIImage] = [:]
    private let disk: KnowledgePreviewDiskCache
    private let loadBatch: @Sendable ([KnowledgePreviewRequest], Bool) async throws -> KnowledgePreviewBatchResult
    private let coalescingWindow: Duration
    private let maximumMemoryImages: Int
    private var order: [String] = []
    private var pending: [(request: KnowledgePreviewRequest, includeArchived: Bool)] = []
    private var inFlight: Set<String> = []
    private var waiters: [String: [CheckedContinuation<UIImage?, Never>]] = [:]
    private var unavailable: Set<String> = []
    private var wanted: [String: Wanted] = [:]
    private var wantedOrder: [String] = []
    private var flushTask: Task<Void, Never>?
    private var generation = 0

    init(
        disk: KnowledgePreviewDiskCache = KnowledgePreviewDiskCache(),
        coalescingWindow: Duration = KnowledgePreviewPolicy.coalescingWindow,
        maximumMemoryImages: Int = KnowledgePreviewPolicy.maximumMemoryImages,
        loadBatch: @escaping @Sendable ([KnowledgePreviewRequest], Bool) async throws -> KnowledgePreviewBatchResult
    ) {
        self.disk = disk
        self.coalescingWindow = coalescingWindow
        self.maximumMemoryImages = max(1, maximumMemoryImages)
        self.loadBatch = loadBatch
    }

    /// The decoded image for a hash, or nil while it is unknown. Reading this
    /// from a row body is what republishes the row when the image arrives.
    func image(for hash: String?) -> UIImage? {
        guard let hash else { return nil }
        return images[hash]
    }

    /// Asks for one row's preview. A cached image is returned immediately. A
    /// Gateway refusal (`forbidden`, `missing`, `too-large`) is authoritative for
    /// this episode, so a row that scrolls back does not repeat it, while a
    /// transport failure leaves no mark and a reappearing row simply asks again.
    /// Either way the demand is retained for `retryUnavailable()`.
    @discardableResult
    func load(_ request: KnowledgePreviewRequest, includeArchived: Bool = false) async -> UIImage? {
        rememberWanted(request, includeArchived: includeArchived)
        if let cached = images[request.hash] { return cached }
        guard !unavailable.contains(request.hash) else { return nil }
        if let data = await disk.data(for: request.hash), let image = await KnowledgePreviewDecoder.downsample(data) {
            guard !Task.isCancelled else { return image }
            publish(image, hash: request.hash)
            return image
        }
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            waiters[request.hash, default: []].append(continuation)
            enqueue(request, includeArchived: includeArchived)
        }
    }

    /// A refusal or a transport failure is not permanent: the connection may
    /// have been down, or the object may have arrived since. Rows that are still
    /// on screen asked for their previews already and the store kept that demand,
    /// so one call retries every image the library wanted and never got.
    func retryUnavailable() {
        guard !unavailable.isEmpty else { return }
        unavailable.removeAll()
        for hash in wantedOrder {
            guard let entry = wanted[hash] else { continue }
            enqueue(entry.request, includeArchived: entry.includeArchived)
        }
    }

    func removeAll() {
        generation &+= 1
        images.removeAll()
        order.removeAll()
        for (_, continuations) in waiters { for continuation in continuations { continuation.resume(returning: nil) } }
        waiters.removeAll()
        pending.removeAll()
        inFlight.removeAll()
        wanted.removeAll()
        wantedOrder.removeAll()
        unavailable.removeAll()
        flushTask?.cancel()
        flushTask = nil
    }

    private func rememberWanted(_ request: KnowledgePreviewRequest, includeArchived: Bool) {
        if wanted[request.hash] == nil {
            wantedOrder.append(request.hash)
            while wantedOrder.count > 256, let oldest = wantedOrder.first {
                wantedOrder.removeFirst()
                wanted.removeValue(forKey: oldest)
            }
        }
        wanted[request.hash] = Wanted(request: request, includeArchived: includeArchived)
    }

    private func publish(_ image: UIImage, hash: String) {
        if images[hash] == nil { order.append(hash) }
        images[hash] = image
        while order.count > maximumMemoryImages, let oldest = order.first {
            order.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }

    private func enqueue(_ request: KnowledgePreviewRequest, includeArchived: Bool) {
        guard !inFlight.contains(request.hash) else { return }
        guard !pending.contains(where: { $0.request.hash == request.hash && $0.includeArchived == includeArchived }) else { return }
        inFlight.insert(request.hash)
        pending.append((request, includeArchived))
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let window = coalescingWindow
        flushTask = Task { [weak self] in
            // Let rows that mount in the same layout pass join one request.
            try? await Task.sleep(for: window)
            guard let self, !Task.isCancelled else { return }
            await self.flush()
            self.flushTask = nil
            // A request that arrived as the flush drained owns its own pass.
            if !self.pending.isEmpty { self.scheduleFlush() }
        }
    }

    private func flush() async {
        while !pending.isEmpty {
            let includeArchived = pending[0].includeArchived
            // One batch carries one authority flag, so a mixed queue flushes in
            // two passes rather than guessing at the Gateway.
            let batch = Array(pending.prefix(KnowledgePreviewLimits.maximumBatchItems).prefix { $0.includeArchived == includeArchived })
            pending.removeFirst(batch.count)
            await perform(batch.map(\.request), includeArchived: includeArchived)
        }
    }

    private func perform(_ batch: [KnowledgePreviewRequest], includeArchived: Bool) async {
        let generation = generation
        var result: KnowledgePreviewBatchResult?
        do {
            result = try await loadBatch(batch, includeArchived)
        } catch {
            result = nil
        }
        guard generation == self.generation else {
            // The store was reset while this batch was in flight; its rows are
            // gone, so completing their waiters is all that remains.
            for request in batch { resume(hash: request.hash) }
            return
        }
        if let result {
            for (hash, data) in result.images {
                guard !Task.isCancelled, let image = await KnowledgePreviewDecoder.downsample(data) else { continue }
                guard generation == self.generation else { for request in batch { resume(hash: request.hash) }; return }
                await disk.store(hash: hash, data: data)
                publish(image, hash: hash)
            }
            unavailable.formUnion(result.unavailableHashes)
        }
        for request in batch {
            inFlight.remove(request.hash)
            resume(hash: request.hash)
        }
    }

    private func resume(hash: String) {
        guard let continuations = waiters.removeValue(forKey: hash) else { return }
        let image = images[hash]
        for continuation in continuations { continuation.resume(returning: image) }
    }
}
