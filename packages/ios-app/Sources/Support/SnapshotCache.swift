import CryptoKit
import Foundation

enum SnapshotCachePolicy {
    static let maximumEncodedBytes = 8 * 1_024 * 1_024
    static let maximumSessionCount = 250
    static let maximumTranscriptEntriesPerSnapshot = 500
    static let maximumEncodedSessionBytes = 128 * 1_024
    static let maximumEncodedSnapshotBytes = 2 * 1_024 * 1_024
    static let maximumEncodedTranscriptItemBytes = 512 * 1_024
    static let envelopeReserveBytes = 4 * 1_024
}

actor SnapshotCache {
    struct Value: Sendable {
        let sessions: [SessionSummary]
        let snapshots: [SessionSnapshot]
        static let empty = Value(sessions: [], snapshots: [])
    }

    private struct Document: Codable {
        let version: Int
        let sessions: [SessionSummary]
        let snapshots: [SessionSnapshot]
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
            guard document.version == 3 else {
                try? FileManager.default.removeItem(at: source)
                performanceSignposts.end(
                    interval,
                    result: .discarded,
                    metrics: PerformanceMetrics(byteCount: data.count)
                )
                return .empty
            }
            performanceSignposts.end(
                interval,
                result: .success,
                metrics: PerformanceMetrics(
                    itemCount: document.sessions.count + document.snapshots.count,
                    byteCount: data.count
                )
            )
            return Value(sessions: document.sessions, snapshots: document.snapshots)
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
        snapshots: [SessionSnapshot]
    ) {
        guard !removedProfileIDs.contains(profileID),
              generation >= (latestSaveGenerationByProfile[profileID] ?? Int.min) else { return }
        latestSaveGenerationByProfile[profileID] = generation
        let interval = performanceSignposts.begin(.cacheSave)
        do {
            try prepareRoot()
            var document = try Self.boundedDocument(sessions: sessions, snapshots: snapshots)
            var data = try JSONEncoder.gateway.encode(document)
            while data.count > SnapshotCachePolicy.maximumEncodedBytes {
                if !document.snapshots.isEmpty {
                    document = Document(
                        version: document.version,
                        sessions: document.sessions,
                        snapshots: Array(document.snapshots.dropLast())
                    )
                } else if let removedSession = document.sessions.last {
                    document = Document(
                        version: document.version,
                        sessions: Array(document.sessions.dropLast()),
                        snapshots: document.snapshots.filter { $0.sessionId != removedSession.id }
                    )
                } else {
                    break
                }
                data = try JSONEncoder.gateway.encode(document)
            }
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
                    itemCount: document.sessions.count + document.snapshots.count,
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

    private static func boundedDocument(
        sessions: [SessionSummary],
        snapshots: [SessionSnapshot]
    ) throws -> Document {
        let budget = SnapshotCachePolicy.maximumEncodedBytes - SnapshotCachePolicy.envelopeReserveBytes
        var estimatedBytes = 0
        var seenSessionIDs: Set<String> = []
        var admittedSessions: [SessionSummary] = []
        for session in sessions where admittedSessions.count < SnapshotCachePolicy.maximumSessionCount {
            guard seenSessionIDs.insert(session.id).inserted else { continue }
            guard admitsEncodingShape(session, maximumBytes: SnapshotCachePolicy.maximumEncodedSessionBytes) else {
                continue
            }
            let size = try JSONEncoder.gateway.encode(session).count
            guard size <= SnapshotCachePolicy.maximumEncodedSessionBytes,
                  estimatedBytes <= budget - size else { continue }
            admittedSessions.append(session)
            estimatedBytes += size
        }

        let admittedIDs = Set(admittedSessions.map(\.id))
        var seenSnapshotIDs: Set<String> = []
        var admittedSnapshots: [SessionSnapshot] = []
        for snapshot in snapshots where admittedIDs.contains(snapshot.sessionId) {
            guard seenSnapshotIDs.insert(snapshot.sessionId).inserted,
                  let bounded = try boundedSnapshot(snapshot) else { continue }
            let size = try JSONEncoder.gateway.encode(bounded).count
            guard estimatedBytes <= budget - size else { continue }
            admittedSnapshots.append(bounded)
            estimatedBytes += size
        }
        return Document(version: 3, sessions: admittedSessions, snapshots: admittedSnapshots)
    }

    private static func boundedSnapshot(_ snapshot: SessionSnapshot) throws -> SessionSnapshot? {
        let empty = trim(snapshot, maximumTranscriptEntries: 0)
        guard admitsEncodingShape(empty, maximumBytes: SnapshotCachePolicy.maximumEncodedSnapshotBytes) else {
            return nil
        }
        let emptySize = try JSONEncoder.gateway.encode(empty).count
        guard emptySize <= SnapshotCachePolicy.maximumEncodedSnapshotBytes else { return nil }

        let maximumEntries = min(
            SnapshotCachePolicy.maximumTranscriptEntriesPerSnapshot,
            snapshot.transcript.count
        )
        let budget = SnapshotCachePolicy.maximumEncodedSnapshotBytes - SnapshotCachePolicy.envelopeReserveBytes
        var estimatedBytes = emptySize
        var admittedCount = 0
        for item in snapshot.transcript.suffix(maximumEntries).reversed() {
            guard admitsEncodingShape(
                item,
                maximumBytes: SnapshotCachePolicy.maximumEncodedTranscriptItemBytes
            ) else { break }
            let size = try JSONEncoder.gateway.encode(item).count
            guard size <= SnapshotCachePolicy.maximumEncodedTranscriptItemBytes,
                  estimatedBytes <= budget - size else { break }
            admittedCount += 1
            estimatedBytes += size
        }

        while true {
            let candidate = trim(snapshot, maximumTranscriptEntries: admittedCount)
            if try JSONEncoder.gateway.encode(candidate).count <= SnapshotCachePolicy.maximumEncodedSnapshotBytes {
                return candidate
            }
            guard admittedCount > 0 else { return nil }
            admittedCount -= 1
        }
        return nil
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

    private static func trim(
        _ snapshot: SessionSnapshot,
        maximumTranscriptEntries: Int = SnapshotCachePolicy.maximumTranscriptEntriesPerSnapshot
    ) -> SessionSnapshot {
        let transcript = Array(snapshot.transcript.suffix(maximumTranscriptEntries))
        let omitted = snapshot.transcript.count - transcript.count
        let trimmedStart: Int?
        if let sourceStart = snapshot.transcriptStart {
            let (candidate, overflow) = max(0, sourceStart).addingReportingOverflow(omitted)
            trimmedStart = overflow ? nil : candidate
        } else {
            trimmedStart = nil
        }
        return SessionSnapshot(
            sessionId: snapshot.sessionId,
            runtimeGeneration: snapshot.runtimeGeneration,
            revision: snapshot.revision,
            eventSequence: snapshot.eventSequence,
            phase: snapshot.phase.isActive ? .interrupted : snapshot.phase,
            name: snapshot.name,
            cwd: snapshot.cwd,
            parentSessionId: snapshot.parentSessionId,
            model: snapshot.model,
            thinkingLevel: snapshot.thinkingLevel,
            availableThinkingLevels: snapshot.availableThinkingLevels,
            contextUsage: snapshot.contextUsage,
            stats: snapshot.stats,
            queued: snapshot.queued,
            transcript: transcript,
            transcriptStart: trimmedStart,
            transcriptTotal: snapshot.transcriptTotal,
            streaming: nil,
            leafEntryId: snapshot.leafEntryId,
            operation: nil,
            retry: nil,
            // Preserve only running tools so the offline projection cannot
            // manufacture completion while Gateway work may still continue.
            toolExecutions: snapshot.toolExecutions.filter { $0.status == .running },
            extensionPresentation: ExtensionPresentationState(
                version: 2,
                hostEpoch: snapshot.extensionPresentation.hostEpoch,
                revision: snapshot.extensionPresentation.revision,
                capabilities: [],
                diagnostics: [],
                semanticState: .init(
                    statuses: [:],
                    working: .init(message: nil, visible: true),
                    hiddenThinkingLabel: nil,
                    widgets: [],
                    title: nil,
                    toolsExpanded: false,
                    editorRevision: 0,
                    editorText: ""
                ),
                surfaces: [],
                pendingInteractions: [],
                inputLease: nil,
                projection: .init(complete: false, omitted: ["ephemeralPresentation"])
            ),
            diagnostics: [],
            isCachedProjection: true
        )
    }
}
