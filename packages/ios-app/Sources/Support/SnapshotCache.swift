import CryptoKit
import Foundation

enum SnapshotCachePolicy {
    static let maximumEncodedBytes = 8 * 1_024 * 1_024
    static let maximumSessionCount = 250
    static let maximumEncodedSessionBytes = 128 * 1_024
    static let envelopeReserveBytes = 4 * 1_024
}

actor SnapshotCache {
    struct Value: Sendable {
        let sessions: [SessionSummary]
        static let empty = Value(sessions: [])
    }

    private struct Document: Codable {
        let version: Int
        let sessions: [SessionSummary]
    }

    private let root: URL
    private let performanceSignposts: any PerformanceSignposting
    private var latestSaveGenerationByProfile: [String: Int] = [:]
    private var removedProfileIDs: Set<String> = []

    init(
        root: URL? = nil,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared
    ) {
        self.performanceSignposts = performanceSignposts
        if let root { self.root = root }
        else {
            self.root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "GatewaySnapshots", directoryHint: .isDirectory)
        }
    }

    func load(profileID: String) -> Value {
        let interval = performanceSignposts.begin(.cacheLoad)
        let source = path(profileID)
        var loadedByteCount = 0
        do {
            let fileSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize >= 0, fileSize <= SnapshotCachePolicy.maximumEncodedBytes else {
                try? FileManager.default.removeItem(at: source)
                performanceSignposts.end(
                    interval,
                    result: .discarded,
                    metrics: PerformanceMetrics(byteCount: max(0, fileSize))
                )
                return .empty
            }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: SnapshotCachePolicy.maximumEncodedBytes) ?? Data()
            loadedByteCount = data.count
            guard data.count <= SnapshotCachePolicy.maximumEncodedBytes else {
                try? FileManager.default.removeItem(at: source)
                performanceSignposts.end(
                    interval,
                    result: .discarded,
                    metrics: PerformanceMetrics(byteCount: data.count)
                )
                return .empty
            }
            let document = try JSONDecoder.gateway.decode(Document.self, from: data)
            guard document.version == 3 || document.version == 4 else {
                try? FileManager.default.removeItem(at: source)
                performanceSignposts.end(
                    interval,
                    result: .discarded,
                    metrics: PerformanceMetrics(byteCount: data.count)
                )
                return .empty
            }
            // Admission is intentionally lossy: malformed or oversized rows
            // and duplicate IDs are dropped in stored order, while a malformed
            // envelope still discards the whole file in the outer catch.
            let admittedSessions = Self.boundedSessions(document.sessions)
            performanceSignposts.end(
                interval,
                result: .success,
                metrics: PerformanceMetrics(
                    itemCount: admittedSessions.count,
                    byteCount: data.count
                )
            )
            return Value(sessions: admittedSessions)
        } catch {
            try? FileManager.default.removeItem(at: source)
            performanceSignposts.end(
                interval,
                result: .discarded,
                metrics: loadedByteCount > 0 ? PerformanceMetrics(byteCount: loadedByteCount) : .none
            )
            return .empty
        }
    }

    func save(
        profileID: String,
        generation: Int = 0,
        sessions: [SessionSummary],
    ) {
        guard !removedProfileIDs.contains(profileID),
              generation >= (latestSaveGenerationByProfile[profileID] ?? Int.min) else { return }
        latestSaveGenerationByProfile[profileID] = generation
        let interval = performanceSignposts.begin(.cacheSave)
        do {
            try prepareRoot()
            // Session summaries are the only persisted projection.
            let document = Document(version: 4, sessions: Self.boundedSessions(sessions))
            let data = try JSONEncoder.gateway.encode(document)
            guard data.count <= SnapshotCachePolicy.maximumEncodedBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let destination = path(profileID)
            try data.write(
                to: destination,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            performanceSignposts.end(
                interval,
                result: .success,
                metrics: PerformanceMetrics(
                    itemCount: document.sessions.count,
                    byteCount: data.count
                )
            )
        } catch {
            performanceSignposts.end(interval, result: .failure, metrics: .none)
            // This cache is disposable. Live gateway snapshots remain canonical.
        }
    }

    func remove(profileID: String) {
        removedProfileIDs.insert(profileID)
        latestSaveGenerationByProfile[profileID] = nil
        try? FileManager.default.removeItem(at: path(profileID))
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)
    }

    private func path(_ profileID: String) -> URL {
        let digest = SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "\(digest).json", directoryHint: .notDirectory)
    }

    private static func boundedSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        let budget = SnapshotCachePolicy.maximumEncodedBytes - SnapshotCachePolicy.envelopeReserveBytes
        var estimatedBytes = 0
        var seen: Set<String> = []
        var admitted: [SessionSummary] = []
        for session in sessions where admitted.count < SnapshotCachePolicy.maximumSessionCount {
            guard !session.id.isEmpty,
                  admitsEncodingShape(session, maximumBytes: SnapshotCachePolicy.maximumEncodedSessionBytes),
                  let encoded = try? JSONEncoder.gateway.encode(session),
                  encoded.count <= SnapshotCachePolicy.maximumEncodedSessionBytes,
                  estimatedBytes <= budget - encoded.count,
                  seen.insert(session.id).inserted else { continue }
            admitted.append(session)
            estimatedBytes += encoded.count
        }
        return admitted
    }

    private static func admitsEncodingShape<T>(_ value: T, maximumBytes: Int) -> Bool {
        var remaining = maximumBytes
        func consume(_ value: Any) -> Bool {
            guard remaining >= 0 else { return false }
            if let string = value as? String {
                var encodedBytes = 2
                for scalar in string.unicodeScalars {
                    switch scalar.value {
                    case 0x00 ... 0x1F: encodedBytes += 6
                    case 0x22, 0x5C: encodedBytes += 2
                    case 0x00 ... 0x7F: encodedBytes += 1
                    case 0x80 ... 0x7FF: encodedBytes += 2
                    case 0x800 ... 0xFFFF: encodedBytes += 3
                    default: encodedBytes += 4
                    }
                    guard encodedBytes <= remaining else { return false }
                }
                remaining -= encodedBytes
                return true
            }
            let mirror = Mirror(reflecting: value)
            guard !mirror.children.isEmpty else {
                remaining -= 32
                return remaining >= 0
            }
            for child in mirror.children {
                remaining -= 16
                guard remaining >= 0, consume(child.value) else { return false }
            }
            return true
        }
        return consume(value)
    }


}
