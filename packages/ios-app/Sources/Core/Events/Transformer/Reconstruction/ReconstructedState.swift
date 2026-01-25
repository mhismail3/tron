import Foundation

/// Reconstructed session state from event history.
///
/// This structure contains all information needed to display a session,
/// including messages, token usage, model info, and extended state
/// like file activity, git worktree operations, and compaction history.
///
/// ## Usage
/// ```swift
/// let state = SessionStateReconstructor.reconstruct(from: events)
/// // Access messages
/// for message in state.messages { ... }
/// // Access accumulated token usage
/// let totalTokens = state.totalTokenUsage.inputTokens + state.totalTokenUsage.outputTokens
/// ```
struct ReconstructedState {
    /// Chat messages for display
    var messages: [ChatMessage]

    /// Accumulated token usage across all turns (for billing/statistics)
    var totalTokenUsage: TokenUsage

    /// Last turn's input tokens (represents current context window size for progress bar)
    var lastTurnInputTokens: Int

    /// Current model after any switches
    var currentModel: String?

    /// Current turn number
    var currentTurn: Int

    /// Session working directory
    var workingDirectory: String?

    /// Current reasoning level for extended thinking models
    var reasoningLevel: String?

    // MARK: - Extended State (Phase 2)

    /// File read/write/edit activity during the session
    var fileActivity: FileActivityState

    /// Git worktree activity during the session
    var worktree: WorktreeState

    /// Context compaction state
    var compaction: CompactionState

    /// Session metadata
    var metadata: MetadataState

    /// Session start/end information
    var sessionInfo: SessionInfo

    /// Session tags
    var tags: [String]

    // MARK: - Initialization

    init() {
        self.messages = []
        self.totalTokenUsage = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: nil, cacheCreationTokens: nil)
        self.lastTurnInputTokens = 0
        self.currentModel = nil
        self.currentTurn = 0
        self.workingDirectory = nil
        self.reasoningLevel = nil
        self.fileActivity = FileActivityState()
        self.worktree = WorktreeState()
        self.compaction = CompactionState()
        self.metadata = MetadataState()
        self.sessionInfo = SessionInfo()
        self.tags = []
    }
}

// MARK: - Nested Types

extension ReconstructedState {

    /// File read/write/edit activity during the session
    struct FileActivityState {
        var reads: [FileRead]
        var writes: [FileWrite]
        var edits: [FileEdit]

        struct FileRead {
            let path: String
            let timestamp: Date
            let linesStart: Int?
            let linesEnd: Int?
        }

        struct FileWrite {
            let path: String
            let timestamp: Date
            let size: Int
            let contentHash: String
        }

        struct FileEdit {
            let path: String
            let timestamp: Date
            let oldString: String
            let newString: String
            let diff: String?
        }

        init() {
            self.reads = []
            self.writes = []
            self.edits = []
        }

        /// All modified files (writes + edits)
        var modifiedFiles: [String] {
            let writeFiles = writes.map(\.path)
            let editFiles = edits.map(\.path)
            return Array(Set(writeFiles + editFiles))
        }

        /// All touched files (reads + writes + edits)
        var touchedFiles: [String] {
            let readFiles = reads.map(\.path)
            return Array(Set(readFiles + modifiedFiles))
        }
    }

    /// Git worktree activity during the session
    struct WorktreeState {
        var isAcquired: Bool
        var currentWorktree: String?
        var commits: [Commit]
        var merges: [Merge]

        struct Commit {
            let hash: String
            let message: String
            let timestamp: Date
        }

        struct Merge {
            let branch: String
            let timestamp: Date
        }

        init() {
            self.isAcquired = false
            self.currentWorktree = nil
            self.commits = []
            self.merges = []
        }
    }

    /// Context compaction state
    struct CompactionState {
        var boundaries: [Boundary]
        var summaries: [Summary]

        struct Boundary {
            let rangeFrom: String?
            let rangeTo: String?
            let originalTokens: Int
            let compactedTokens: Int
            let timestamp: Date
        }

        struct Summary {
            let summary: String
            let boundaryEventId: String
            let keyDecisions: [String]?
            let filesModified: [String]?
            let timestamp: Date
        }

        init() {
            self.boundaries = []
            self.summaries = []
        }

        /// Total compactions applied
        var compactionCount: Int { boundaries.count }

        /// Total tokens saved through compaction
        var tokensSaved: Int {
            boundaries.reduce(0) { $0 + ($1.originalTokens - $1.compactedTokens) }
        }
    }

    /// Session metadata
    struct MetadataState {
        var customData: [String: Any]
        var lastUpdated: Date?

        init() {
            self.customData = [:]
            self.lastUpdated = nil
        }
    }

    /// Session start information
    struct SessionInfo {
        var startTime: Date?
        var endTime: Date?
        var initialModel: String?
        var branchName: String?
        var forkSource: String?

        init() {
            self.startTime = nil
            self.endTime = nil
            self.initialModel = nil
            self.branchName = nil
            self.forkSource = nil
        }

        /// Whether the session is currently active (started but not ended)
        var isActive: Bool { startTime != nil && endTime == nil }

        /// Duration of the session (nil if not started)
        var duration: TimeInterval? {
            guard let start = startTime else { return nil }
            let end = endTime ?? Date()
            return end.timeIntervalSince(start)
        }
    }
}
