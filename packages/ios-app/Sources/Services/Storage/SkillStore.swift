import Foundation

// MARK: - Skill Store

// NOTE: Uses global `logger` from TronLogger.swift (TronLogger.shared)

@MainActor
class SkillStore: ObservableObject {
    // MARK: - Constants

    /// Minimum interval between automatic refreshes (in seconds)
    /// Skills are rescanned from disk when this interval has passed
    private static let refreshInterval: TimeInterval = 30

    // MARK: - Published Properties

    @Published private(set) var skills: [Skill] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var lastRefresh: Date?

    // MARK: - Computed Properties

    /// Skills that auto-inject (Rules)
    var autoInjectSkills: [Skill] {
        skills.filter { $0.autoInject }
    }

    /// Skills that don't auto-inject (regular skills)
    var regularSkills: [Skill] {
        skills.filter { !$0.autoInject }
    }

    /// Global skills
    var globalSkills: [Skill] {
        skills.filter { $0.source == .global }
    }

    /// Project skills
    var projectSkills: [Skill] {
        skills.filter { $0.source == .project }
    }

    /// Total skill count
    var totalCount: Int {
        skills.count
    }

    /// Auto-inject skill count
    var autoInjectCount: Int {
        autoInjectSkills.count
    }

    // MARK: - Dependencies

    private weak var rpcClient: RPCClient?

    // MARK: - Initialization

    init() {}

    func configure(rpcClient: RPCClient) {
        self.rpcClient = rpcClient
    }

    // MARK: - RPC Methods

    /// Load skills from the server's cache (does not rescan disk)
    /// For detecting disk changes, use `refreshAndLoadSkills` instead
    func loadSkills(sessionId: String? = nil, source: SkillSource? = nil) async {
        guard let rpcClient = rpcClient else {
            logger.warning("SkillStore: No RPC client configured", category: .rpc)
            return
        }

        isLoading = true
        error = nil

        do {
            let result = try await rpcClient.misc.listSkills(
                sessionId: sessionId,
                source: source?.rawValue
            )
            skills = result.skills
            // Note: Don't update lastRefresh here - this just loads from server cache
            // lastRefresh is only updated when we actually rescan from disk
            logger.debug("Loaded \(result.totalCount) skills (\(result.autoInjectCount) auto-inject)", category: .rpc)
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to load skills: \(error.localizedDescription)", category: .rpc)
        }

        isLoading = false
    }

    /// Get a skill by name
    func getSkill(name: String, sessionId: String? = nil) async -> SkillMetadata? {
        guard let rpcClient = rpcClient else {
            logger.warning("SkillStore: No RPC client configured", category: .rpc)
            return nil
        }

        do {
            let result = try await rpcClient.misc.getSkill(name: name, sessionId: sessionId)
            if result.found, let skill = result.skill {
                return skill
            }
            return nil
        } catch {
            logger.error("Failed to get skill '\(name)': \(error.localizedDescription)", category: .rpc)
            return nil
        }
    }

    /// Refresh skills cache on the server (rescans disk for changes)
    func refreshSkills(sessionId: String? = nil) async {
        guard let rpcClient = rpcClient else {
            logger.warning("SkillStore: No RPC client configured", category: .rpc)
            return
        }

        isLoading = true
        error = nil

        do {
            let result = try await rpcClient.misc.refreshSkills(sessionId: sessionId)
            if result.success {
                // Reload the skills list after refresh
                await loadSkills(sessionId: sessionId)
                // Update lastRefresh after successful disk rescan
                lastRefresh = Date()
                logger.debug("Refreshed \(result.skillCount) skills", category: .rpc)
            }
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to refresh skills: \(error.localizedDescription)", category: .rpc)
        }

        isLoading = false
    }

    /// Refresh and load skills - use this on session resume to detect disk changes
    /// This rescans the disk for new/modified/deleted skills, then loads the updated list
    func refreshAndLoadSkills(sessionId: String? = nil) async {
        logger.debug("Refreshing skills from disk for session resume", category: .rpc)
        await refreshSkills(sessionId: sessionId)
    }

    /// Check if skills need to be refreshed from disk
    /// Returns true if never refreshed or if refresh interval has passed
    func needsRefresh() -> Bool {
        guard let lastRefresh = lastRefresh else {
            return true // Never refreshed
        }
        let elapsed = Date().timeIntervalSince(lastRefresh)
        return elapsed >= Self.refreshInterval
    }

    /// Refresh skills if needed (only if refresh interval has passed)
    /// Use this for periodic refresh checks without forcing a refresh every time
    func refreshIfNeeded(sessionId: String? = nil) async {
        if needsRefresh() {
            await refreshAndLoadSkills(sessionId: sessionId)
        } else {
            // Just load from cache if refresh not needed
            await loadSkills(sessionId: sessionId)
        }
    }

    // MARK: - Search & Filter

    /// Search skills by name or description
    func search(query: String) -> [Skill] {
        guard !query.isEmpty else { return skills }

        let lowercased = query.lowercased()
        return skills.filter { skill in
            skill.name.lowercased().contains(lowercased) ||
            skill.description.lowercased().contains(lowercased) ||
            (skill.tags?.contains { $0.lowercased().contains(lowercased) } ?? false)
        }
    }

    /// Find a skill by exact name
    func find(name: String) -> Skill? {
        skills.first { $0.name == name }
    }

    /// Check if a skill exists
    func exists(name: String) -> Bool {
        find(name: name) != nil
    }

    // MARK: - Reference Helpers

    /// Extract @skill-name references from text
    func extractReferences(from text: String) -> [String] {
        // Match @skillname, @skill-name, @skill_name
        let pattern = #"(?<!\`|\w)@([a-zA-Z][a-zA-Z0-9_-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        return matches.compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[nameRange])
        }
    }

    /// Get skills referenced in text (only existing skills)
    func getReferencedSkills(from text: String) -> [Skill] {
        let names = extractReferences(from: text)
        return names.compactMap { find(name: $0) }
    }

    /// Check if text contains any skill references
    func hasSkillReferences(_ text: String) -> Bool {
        !extractReferences(from: text).isEmpty
    }
}
