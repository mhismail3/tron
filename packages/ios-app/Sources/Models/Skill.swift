import Foundation

// MARK: - Skill Source

/// Where a skill was loaded from
enum SkillSource: String, Codable {
    case global  // ~/.tron/skills/
    case project // .tron/skills/ (relative to project)
}

// MARK: - Skill Model

/// Skill information for listing
struct Skill: Identifiable, Codable, Equatable {
    /// Skill name (folder name, used as @reference)
    let name: String
    /// Short description (first non-header line of SKILL.md)
    let description: String
    /// Where the skill was loaded from
    let source: SkillSource
    /// Whether this skill auto-injects into every prompt (Rules)
    let autoInject: Bool
    /// Tags for categorization
    let tags: [String]?

    var id: String { name }

    // Coding keys for JSON decoding
    private enum CodingKeys: String, CodingKey {
        case name, description, source, autoInject, tags
    }
}

// MARK: - Skill Metadata (Full Details)

/// Full skill metadata including content
struct SkillMetadata: Identifiable, Codable, Equatable {
    /// Skill name (folder name, used as @reference)
    let name: String
    /// Short description (first non-header line of SKILL.md)
    let description: String
    /// Where the skill was loaded from
    let source: SkillSource
    /// Whether this skill auto-injects into every prompt (Rules)
    let autoInject: Bool
    /// Tags for categorization
    let tags: [String]?
    /// Full SKILL.md content (after frontmatter stripped)
    let content: String
    /// Absolute path to skill folder
    let path: String
    /// List of additional files in the skill folder
    let additionalFiles: [String]

    var id: String { name }

    /// Convert to basic Skill info
    var asSkill: Skill {
        Skill(
            name: name,
            description: description,
            source: source,
            autoInject: autoInject,
            tags: tags
        )
    }
}

// MARK: - RPC Response Types

/// Response from skill.list RPC call
struct SkillListResponse: Codable {
    let skills: [Skill]
    let totalCount: Int
    let autoInjectCount: Int
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
