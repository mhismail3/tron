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
    /// Human-readable display name (from frontmatter, falls back to folder name)
    let displayName: String
    /// Short description (from frontmatter or first non-header line of SKILL.md)
    let description: String
    /// Where the skill was loaded from
    let source: SkillSource
    /// Tags for categorization
    let tags: [String]?

    var id: String { name }
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
    /// Where the skill was loaded from
    let source: SkillSource
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
            displayName: displayName,
            description: description,
            source: source,
            tags: tags
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

/// How a skill was added to the session context
enum SkillAddMethod: String, Codable {
    case mention   // Added via @skillname
    case explicit  // Added via skill sheet selection
}

/// Information about a skill that has been explicitly added to session context
/// Used in DetailedContextSnapshot response
struct AddedSkillInfo: Identifiable, Codable, Equatable {
    /// Skill name
    let name: String
    /// Where the skill was loaded from
    let source: SkillSource
    /// How the skill was added
    let addedVia: SkillAddMethod
    /// Event ID for removal tracking
    let eventId: String
    /// Actual token count (calculated from content length on agent side)
    let tokens: Int?

    var id: String { name }
}
