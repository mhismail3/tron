import Foundation

// MARK: - Skill Source

/// Where a skill was loaded from — global (under any service's `$HOME` dir) or project-local.
enum SkillSource: String, Codable, Sendable {
    case global
    case project
}

// MARK: - Skill Service

/// Which service folder produced the skill.
///
/// Orthogonal to [`SkillSource`]: a skill can be a claude global
/// (`~/.claude/skills/foo`) or a claude project-local
/// (`{working_dir}/.claude/skills/foo`). Mirrors the server's
/// `SKILL_SERVICE_DIRS` list.
enum SkillService: String, Sendable {
    case tron
    case claude
    /// Forward-compatibility bucket: a service the server knows about but
    /// this client build doesn't. Rendered without a per-service badge.
    case unknown
}

// MARK: - Skill Model

/// Skill information for listing
struct Skill: Identifiable, Codable, Equatable, Sendable {
    /// Skill name (folder name, used as @reference)
    let name: String
    /// Human-readable display name (from frontmatter, falls back to folder name)
    let displayName: String
    /// Short description (from frontmatter or first non-header line of SKILL.md)
    let description: String
    /// Where the skill was loaded from (global vs project)
    let source: SkillSource
    /// Which service folder produced the skill. Raw value (`"tron"`, `"claude"`, …);
    /// use [`Skill.serviceTag`] for a typed view.
    let service: String
    /// Tags for categorization
    let tags: [String]?
    /// Relative path from project root to the package containing this skill.
    /// Nil for root-level skills. E.g. "packages/ios-app".
    let scopeDir: String?

    var id: String { name }

    /// Typed view of [`service`] for switchable UI logic.
    var serviceTag: SkillService {
        SkillService(rawValue: service) ?? .unknown
    }

    init(
        name: String,
        displayName: String,
        description: String,
        source: SkillSource,
        tags: [String]?,
        scopeDir: String? = nil,
        service: String = SkillService.tron.rawValue
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.source = source
        self.service = service
        self.tags = tags
        self.scopeDir = scopeDir
    }
}

// MARK: - Skill Metadata (Full Details)

/// Full skill metadata including content
struct SkillMetadata: Identifiable, Codable, Equatable {
    /// Skill name (folder name, used as @reference)
    let name: String
    /// Human-readable display name (from frontmatter, falls back to folder name)
    let displayName: String
    /// Short description (from frontmatter or first non-header line of SKILL.md)
    let description: String
    /// Where the skill was loaded from (global vs project)
    let source: SkillSource
    /// Which service folder produced the skill. Raw string (`"tron"`, `"claude"`, …).
    let service: String
    /// Tags for categorization
    let tags: [String]?
    /// Full SKILL.md content (after frontmatter stripped)
    let content: String
    /// Absolute path to skill folder
    let path: String
    /// List of additional files in the skill folder
    let additionalFiles: [String]
    /// Relative path from project root to the package containing this skill.
    let scopeDir: String?

    var id: String { name }

    /// Typed view of [`service`].
    var serviceTag: SkillService {
        SkillService(rawValue: service) ?? .unknown
    }

    /// Convert to basic Skill info
    var asSkill: Skill {
        Skill(
            name: name,
            displayName: displayName,
            description: description,
            source: source,
            tags: tags,
            scopeDir: scopeDir,
            service: service
        )
    }
}

// MARK: - RPC Response Types

/// Response from skill.list RPC call
struct SkillListResponse: Codable {
    let skills: [Skill]
    var totalCount: Int { skills.count }

    private enum CodingKeys: String, CodingKey {
        case skills
    }
}

/// Response from skill.get RPC call
struct SkillGetResponse: Codable {
    let skill: SkillMetadata?
    let found: Bool
}

/// Response from skill.refresh RPC call
struct SkillRefreshResponse: Codable {
    let success: Bool
    let skillCount: Int
}

/// Response from skill.remove RPC call
struct SkillRemoveResponse: Codable {
    let success: Bool
    let error: String?
}

// MARK: - Skill Tracking Types

/// Information about a skill that has been explicitly added to session context
/// Used in DetailedContextSnapshot response
struct AddedSkillInfo: Identifiable, Codable, Equatable {
    /// Skill name
    let name: String
    /// Where the skill was loaded from
    let source: SkillSource
    /// Which service folder produced the skill (enriched server-side from the
    /// registry; `"unknown"` when the skill was activated but is no longer on
    /// disk, so older sessions still decode cleanly).
    let service: String
    /// Event ID for removal tracking
    let eventId: String
    /// Actual token count (calculated from content length on agent side)
    let tokens: Int?

    var id: String { name }

    /// Typed view of [`service`].
    var serviceTag: SkillService {
        SkillService(rawValue: service) ?? .unknown
    }
}
