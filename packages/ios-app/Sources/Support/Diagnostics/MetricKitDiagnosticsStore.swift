import Foundation
import MetricKit

enum MetricKitPayloadKind: String, Codable, Sendable {
    case metrics
    case diagnostics
}

struct MetricKitDiagnosticsRetention: Sendable {
    var maxAgeDays: Int = 30
    var maxFiles: Int = 50
    var maxTotalBytes: Int = 10_000_000
}

struct MetricKitDiagnosticsPayloadFile: Encodable, Sendable {
    let fileName: String
    let kind: MetricKitPayloadKind
    let receivedAt: String
    let payload: AnyCodable
}

struct MetricKitDiagnosticsSnapshot: Encodable, Sendable {
    let files: [MetricKitDiagnosticsPayloadFile]
    let truncated: Bool
    let availableFileCount: Int
    let includedFileCount: Int
    let availableBytes: Int
    let includedBytes: Int
}

private struct StoredMetricKitPayload: Codable, Sendable {
    let kind: MetricKitPayloadKind
    let receivedAt: String
    let payload: AnyCodable
}

final class MetricKitDiagnosticsStore: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitDiagnosticsStore()

    private let directoryURL: URL
    private let retention: MetricKitDiagnosticsRetention
    private let fileManager: FileManager
    private let lock = NSLock()
    private var isStarted = false

    init(
        directoryURL: URL? = nil,
        retention: MetricKitDiagnosticsRetention = MetricKitDiagnosticsRetention(),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.retention = retention
        if let directoryURL {
            self.directoryURL = directoryURL
        } else if let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            self.directoryURL = appSupport
                .appendingPathComponent("Tron", isDirectory: true)
                .appendingPathComponent("MetricKitDiagnostics", isDirectory: true)
        } else {
            preconditionFailure("Application Support directory unavailable; cannot initialize MetricKit diagnostics store")
        }
        super.init()
    }

    func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        MXMetricManager.shared.add(self)
        try? pruneStoredPayloads(now: Date())
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            do {
                try storePayloadData(payload.jsonRepresentation(), kind: .metrics)
            } catch {
                TronLogger.shared.warning("Failed to store MetricKit metrics payload: \(error.localizedDescription)", category: .general)
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            do {
                try storePayloadData(payload.jsonRepresentation(), kind: .diagnostics)
            } catch {
                TronLogger.shared.warning("Failed to store MetricKit diagnostic payload: \(error.localizedDescription)", category: .general)
            }
        }
    }

    func storePayloadData(
        _ data: Data,
        kind: MetricKitPayloadKind,
        receivedAt: Date = Date()
    ) throws {
        try ensureDirectory()
        let stored = StoredMetricKitPayload(
            kind: kind,
            receivedAt: Self.isoFormatter.string(from: receivedAt),
            payload: AnyCodable(Self.jsonPayload(from: data))
        )
        let encoded = try Self.encoder.encode(stored)
        let url = directoryURL.appendingPathComponent(Self.fileName(kind: kind, date: receivedAt))

        lock.lock()
        defer { lock.unlock() }
        try encoded.write(to: url, options: [.atomic])
        try fileManager.setAttributes(
            [.modificationDate: receivedAt],
            ofItemAtPath: url.path
        )
        try pruneStoredPayloadsLocked(now: receivedAt)
    }

    func loadPayloads(maxFiles: Int = 50, maxBytes: Int = 1_000_000) throws -> MetricKitDiagnosticsSnapshot {
        try ensureDirectory()

        lock.lock()
        defer { lock.unlock() }

        try pruneStoredPayloadsLocked(now: Date())
        let resources = try payloadResourcesLocked().sorted { $0.modifiedAt > $1.modifiedAt }
        let availableBytes = resources.reduce(0) { $0 + $1.size }
        var included: [MetricKitDiagnosticsPayloadFile] = []
        var includedBytes = 0
        var truncated = false

        for resource in resources {
            guard included.count < maxFiles,
                  includedBytes + resource.size <= maxBytes
            else {
                truncated = true
                break
            }

            let data = try Data(contentsOf: resource.url)
            let stored = try Self.decoder.decode(StoredMetricKitPayload.self, from: data)
            included.append(
                MetricKitDiagnosticsPayloadFile(
                    fileName: resource.url.lastPathComponent,
                    kind: stored.kind,
                    receivedAt: stored.receivedAt,
                    payload: stored.payload
                )
            )
            includedBytes += resource.size
        }

        return MetricKitDiagnosticsSnapshot(
            files: included,
            truncated: truncated,
            availableFileCount: resources.count,
            includedFileCount: included.count,
            availableBytes: availableBytes,
            includedBytes: includedBytes
        )
    }

    func storedPayloadFileCount() throws -> Int {
        try ensureDirectory()
        lock.lock()
        defer { lock.unlock() }
        return try payloadResourcesLocked().count
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func pruneStoredPayloads(now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        try pruneStoredPayloadsLocked(now: now)
    }

    private func pruneStoredPayloadsLocked(now: Date) throws {
        try ensureDirectory()
        let cutoff = now.addingTimeInterval(-Double(retention.maxAgeDays) * 24 * 60 * 60)
        var resources = try payloadResourcesLocked()

        for resource in resources where resource.modifiedAt < cutoff {
            try? fileManager.removeItem(at: resource.url)
        }

        resources = try payloadResourcesLocked().sorted { $0.modifiedAt < $1.modifiedAt }
        while resources.count > retention.maxFiles, let oldest = resources.first {
            try? fileManager.removeItem(at: oldest.url)
            resources.removeFirst()
        }

        var totalBytes = resources.reduce(0) { $0 + $1.size }
        while totalBytes > retention.maxTotalBytes, let oldest = resources.first {
            try? fileManager.removeItem(at: oldest.url)
            totalBytes -= oldest.size
            resources.removeFirst()
        }
    }

    private func payloadResourcesLocked() throws -> [PayloadResource] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        return try urls.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return PayloadResource(
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                size: values.fileSize ?? 0
            )
        }
    }

    private static func jsonPayload(from data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data)) ?? [
            "unparseable": true,
            "byteCount": data.count,
        ]
    }

    private static func fileName(kind: MetricKitPayloadKind, date: Date) -> String {
        let seconds = Int(date.timeIntervalSince1970)
        return "\(kind.rawValue)-\(seconds)-\(UUID().uuidString).json"
    }

    private struct PayloadResource {
        let url: URL
        let modifiedAt: Date
        let size: Int
    }

    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
