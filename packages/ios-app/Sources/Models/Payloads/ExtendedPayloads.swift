import Foundation

// MARK: - Metadata Payloads

/// Payload for metadata.update event
/// Server: MetadataUpdateEvent.payload
struct MetadataUpdatePayload {
    let key: String
    let previousValue: Any?
    let newValue: Any?

    init?(from payload: [String: AnyCodable]) {
        guard let key = payload.string("key") else {
            return nil
        }
        self.key = key
        self.previousValue = payload["previousValue"]?.value
        self.newValue = payload["newValue"]?.value
    }
}

/// Payload for metadata.tag event
/// Server: MetadataTagEvent.payload
struct MetadataTagPayload {
    let action: String  // "add" | "remove"
    let tag: String

    init?(from payload: [String: AnyCodable]) {
        guard let action = payload.string("action"),
              let tag = payload.string("tag") else {
            return nil
        }
        self.action = action
        self.tag = tag
    }
}

// MARK: - File Payloads

/// Payload for file.read event
/// Server: FileReadEvent.payload
struct FileReadPayload {
    let path: String
    let linesStart: Int?
    let linesEnd: Int?

    init?(from payload: [String: AnyCodable]) {
        guard let path = payload.string("path") else {
            return nil
        }
        self.path = path

        if let lines = payload.dict("lines") {
            self.linesStart = lines["start"] as? Int
            self.linesEnd = lines["end"] as? Int
        } else {
            self.linesStart = nil
            self.linesEnd = nil
        }
    }
}

/// Payload for file.write event
/// Server: FileWriteEvent.payload
struct FileWritePayload {
    let path: String
    let size: Int
    let contentHash: String

    init?(from payload: [String: AnyCodable]) {
        guard let path = payload.string("path"),
              let contentHash = payload.string("contentHash") else {
            return nil
        }
        self.path = path
        self.size = payload.int("size") ?? 0
        self.contentHash = contentHash
    }
}

/// Payload for file.edit event
/// Server: FileEditEvent.payload
struct FileEditPayload {
    let path: String
    let oldString: String
    let newString: String
    let diff: String?

    init?(from payload: [String: AnyCodable]) {
        guard let path = payload.string("path"),
              let oldString = payload.string("oldString"),
              let newString = payload.string("newString") else {
            return nil
        }
        self.path = path
        self.oldString = oldString
        self.newString = newString
        self.diff = payload.string("diff")
    }
}

// MARK: - Compaction Payloads

/// Payload for compact.boundary event
/// Server: CompactBoundaryEvent.payload
struct CompactBoundaryPayload {
    let rangeFrom: String
    let rangeTo: String
    let originalTokens: Int
    let compactedTokens: Int

    init?(from payload: [String: AnyCodable]) {
        guard let range = payload.dict("range"),
              let from = range["from"] as? String,
              let to = range["to"] as? String else {
            return nil
        }
        self.rangeFrom = from
        self.rangeTo = to
        self.originalTokens = payload.int("originalTokens") ?? 0
        self.compactedTokens = payload.int("compactedTokens") ?? 0
    }
}

/// Payload for compact.summary event
/// Server: CompactSummaryEvent.payload
struct CompactSummaryPayload {
    let summary: String
    let keyDecisions: [String]?
    let filesModified: [String]?
    let boundaryEventId: String

    init?(from payload: [String: AnyCodable]) {
        guard let summary = payload.string("summary"),
              let boundaryEventId = payload.string("boundaryEventId") else {
            return nil
        }
        self.summary = summary
        self.boundaryEventId = boundaryEventId
        self.keyDecisions = payload.stringArray("keyDecisions")
        self.filesModified = payload.stringArray("filesModified")
    }
}

// MARK: - Context Snapshot Payloads

/// Parameters for context.getSnapshot RPC method
struct ContextGetSnapshotParams: Codable {
    let sessionId: String
}

/// Result from context.getSnapshot RPC method
struct ContextSnapshotResult: Codable {
    let currentTokens: Int
    let contextLimit: Int
    let usagePercent: Double
    let thresholdLevel: String
    let breakdown: ContextBreakdown

    struct ContextBreakdown: Codable {
        let systemPrompt: Int
        let tools: Int
        let messages: Int
    }
}

// MARK: - Worktree Payloads

/// Payload for worktree.acquired event
/// Server: WorktreeAcquiredEvent.payload
struct WorktreeAcquiredPayload {
    let path: String
    let branch: String
    let baseCommit: String
    let isolated: Bool
    let forkedFrom: ForkedFromInfo?

    struct ForkedFromInfo {
        let sessionId: String
        let commit: String
    }

    init?(from payload: [String: AnyCodable]) {
        guard let path = payload.string("path"),
              let branch = payload.string("branch"),
              let baseCommit = payload.string("baseCommit") else {
            return nil
        }
        self.path = path
        self.branch = branch
        self.baseCommit = baseCommit
        self.isolated = payload.bool("isolated") ?? false

        if let forked = payload.dict("forkedFrom") {
            self.forkedFrom = ForkedFromInfo(
                sessionId: forked["sessionId"] as? String ?? "",
                commit: forked["commit"] as? String ?? ""
            )
        } else {
            self.forkedFrom = nil
        }
    }
}

/// Payload for worktree.commit event
/// Server: WorktreeCommitEvent.payload
struct WorktreeCommitPayload {
    let commitHash: String
    let message: String
    let filesChanged: [String]
    let insertions: Int?
    let deletions: Int?

    init?(from payload: [String: AnyCodable]) {
        guard let commitHash = payload.string("commitHash"),
              let message = payload.string("message") else {
            return nil
        }
        self.commitHash = commitHash
        self.message = message
        self.filesChanged = payload.stringArray("filesChanged") ?? []
        self.insertions = payload.int("insertions")
        self.deletions = payload.int("deletions")
    }
}

/// Payload for worktree.released event
/// Server: WorktreeReleasedEvent.payload
struct WorktreeReleasedPayload {
    let finalCommit: String?
    let deleted: Bool
    let branchPreserved: Bool

    init(from payload: [String: AnyCodable]) {
        self.finalCommit = payload.string("finalCommit")
        self.deleted = payload.bool("deleted") ?? false
        self.branchPreserved = payload.bool("branchPreserved") ?? false
    }
}

/// Payload for worktree.merged event
/// Server: WorktreeMergedEvent.payload
struct WorktreeMergedPayload {
    let sourceBranch: String
    let targetBranch: String
    let mergeCommit: String
    let strategy: MergeStrategy?

    init?(from payload: [String: AnyCodable]) {
        guard let sourceBranch = payload.string("sourceBranch"),
              let targetBranch = payload.string("targetBranch"),
              let mergeCommit = payload.string("mergeCommit") else {
            return nil
        }
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.mergeCommit = mergeCommit

        if let strategyStr = payload.string("strategy") {
            self.strategy = MergeStrategy(rawValue: strategyStr)
        } else {
            self.strategy = nil
        }
    }
}
