import Foundation

// MARK: - Rules Level

/// Level of a rules file in the hierarchy
enum RulesLevel: String, Codable {
    case global
    case project
    case directory

    /// Icon to display for this level
    var icon: String {
        switch self {
        case .global: return "globe"
        case .project: return "folder.fill"
        case .directory: return "folder"
        }
    }

    /// Human-readable label
    var label: String {
        switch self {
        case .global: return "Global"
        case .project: return "Project"
        case .directory: return "Directory"
        }
    }
}

// MARK: - Rules File

/// Information about a single loaded rules file
struct RulesFile: Identifiable, Codable, Equatable {
    /// Use path as unique identifier
    var id: String { path }

    /// Absolute path to the file
    let path: String

    /// Path relative to working directory
    let relativePath: String

    /// Level in the hierarchy
    let level: RulesLevel

    /// Depth from project root (-1 for global)
    let depth: Int

    /// File size in bytes (optional for display)
    let sizeBytes: Int?

    init(path: String, relativePath: String, level: RulesLevel, depth: Int, sizeBytes: Int? = nil) {
        self.path = path
        self.relativePath = relativePath
        self.level = level
        self.depth = depth
        self.sizeBytes = sizeBytes
    }

    // MARK: - Convenience Properties

    /// Icon for this file's level (convenience accessor)
    var icon: String { level.icon }

    /// Label for this file's level (convenience accessor)
    var label: String { level.label }

    /// Display path formatted for UI - shows ~/.tron/<file> for global rules
    var displayPath: String {
        switch level {
        case .global:
            // Extract filename from path and show as ~/.tron/<filename>
            let filename = (path as NSString).lastPathComponent
            return "~/.tron/\(filename)"
        case .project, .directory:
            // Use relativePath for project/directory level
            return relativePath
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case path
        case relativePath
        case level
        case depth
        case sizeBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        depth = try container.decode(Int.self, forKey: .depth)
        sizeBytes = try container.decodeIfPresent(Int.self, forKey: .sizeBytes)

        // Handle level as string from server
        let levelString = try container.decode(String.self, forKey: .level)
        level = RulesLevel(rawValue: levelString) ?? .directory
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(level.rawValue, forKey: .level)
        try container.encode(depth, forKey: .depth)
        try container.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
    }
}

// MARK: - Loaded Rules

/// Snapshot of all loaded rules for a session
struct LoadedRules: Codable, Equatable {
    /// List of loaded rules files
    let files: [RulesFile]

    /// Total number of rules files
    let totalFiles: Int

    /// Estimated token count for merged rules content
    let tokens: Int

    init(files: [RulesFile], totalFiles: Int, tokens: Int) {
        self.files = files
        self.totalFiles = totalFiles
        self.tokens = tokens
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case files
        case totalFiles
        case tokens
    }

    /// Create empty rules (for sessions without rules files)
    static var empty: LoadedRules {
        LoadedRules(files: [], totalFiles: 0, tokens: 0)
    }
}

// MARK: - Rules Loaded Payload

/// Payload for rules.loaded event from server
struct RulesLoadedPayload {
    let files: [RulesFile]
    let totalFiles: Int
    let mergedTokens: Int

    init?(from payload: [String: AnyCodable]) {
        guard let totalFiles = payload.int("totalFiles"),
              let mergedTokens = payload.int("mergedTokens") else {
            return nil
        }

        self.totalFiles = totalFiles
        self.mergedTokens = mergedTokens

        // Parse files array from payload
        var parsedFiles: [RulesFile] = []
        if let filesValue = payload["files"],
           let filesArray = filesValue.value as? [[String: Any]] {
            for fileDict in filesArray {
                guard let path = fileDict["path"] as? String,
                      let relativePath = fileDict["relativePath"] as? String,
                      let levelStr = fileDict["level"] as? String,
                      let depth = fileDict["depth"] as? Int else {
                    continue
                }
                let level = RulesLevel(rawValue: levelStr) ?? .directory
                let sizeBytes = fileDict["sizeBytes"] as? Int
                parsedFiles.append(RulesFile(
                    path: path,
                    relativePath: relativePath,
                    level: level,
                    depth: depth,
                    sizeBytes: sizeBytes
                ))
            }
        }
        self.files = parsedFiles
    }

    /// Convert to LoadedRules for UI display
    func toLoadedRules() -> LoadedRules {
        LoadedRules(files: files, totalFiles: totalFiles, tokens: mergedTokens)
    }
}
