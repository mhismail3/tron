import CryptoKit
import Foundation

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
        do {
            let data = try Data(contentsOf: path(profileID))
            let document = try JSONDecoder.gateway.decode(Document.self, from: data)
            guard document.version == 3 else {
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
            performanceSignposts.end(interval, result: .discarded, metrics: .none)
            return .empty
        }
    }

    func save(
        profileID: String,
        generation: Int = 0,
        sessions: [SessionSummary],
        snapshots: [SessionSnapshot]
    ) {
        guard generation >= (latestSaveGenerationByProfile[profileID] ?? Int.min) else { return }
        latestSaveGenerationByProfile[profileID] = generation
        let interval = performanceSignposts.begin(.cacheSave)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let limitedSessions = Array(sessions.prefix(250))
            let admitted = Set(limitedSessions.map(\.id))
            let limitedSnapshots = snapshots.filter { admitted.contains($0.sessionId) }.map(Self.trim)
            let data = try JSONEncoder.gateway.encode(Document(version: 3, sessions: limitedSessions, snapshots: limitedSnapshots))
            let destination = path(profileID)
            try data.write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            performanceSignposts.end(
                interval,
                result: .success,
                metrics: PerformanceMetrics(
                    itemCount: limitedSessions.count + limitedSnapshots.count,
                    byteCount: data.count
                )
            )
        } catch {
            performanceSignposts.end(interval, result: .failure, metrics: .none)
            // This cache is disposable. Live gateway snapshots remain canonical.
        }
    }

    private func path(_ profileID: String) -> URL {
        let digest = SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "\(digest).json", directoryHint: .notDirectory)
    }

    private static func trim(_ snapshot: SessionSnapshot) -> SessionSnapshot {
        let transcript = Array(snapshot.transcript.suffix(500))
        let omitted = snapshot.transcript.count - transcript.count
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
            transcriptStart: (snapshot.transcriptStart ?? 0) + omitted,
            transcriptTotal: snapshot.transcriptTotal ?? snapshot.transcript.count,
            streaming: nil,
            leafEntryId: snapshot.leafEntryId,
            operation: nil,
            retry: nil,
            toolExecutions: [],
            extensionUI: ExtensionUIState(
                statuses: [:],
                working: .init(message: nil, visible: true),
                hiddenThinkingLabel: nil,
                widgets: [],
                title: nil,
                editorRevision: snapshot.extensionUI.editorRevision,
                editorText: "",
                pendingInteractions: []
            ),
            diagnostics: snapshot.diagnostics
        )
    }
}
