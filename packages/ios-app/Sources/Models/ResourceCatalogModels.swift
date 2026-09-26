import Foundation

/// Where an available resource comes from, derived by the Gateway from Pi
/// sourceInfo. Pi built-ins carry no distribution, and `origin` keeps Pi's own
/// package/top-level meaning on the separate scope badge.
enum ResourceDistribution: String, Codable, Hashable, Sendable {
    case external
    case module
    case local
}

struct CommandInfo: Codable, Hashable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case `extension`, skill, prompt }
    enum ResourceScope: String, Codable, Sendable { case user, project, temporary }
    enum ResourceOrigin: String, Codable, Sendable { case package, topLevel = "top-level" }

    let name: String
    let description: String?
    let argumentHint: String?
    let source: Source
    let sourcePath: String?
    let resourceSource: String?
    let resourceScope: ResourceScope?
    let resourceOrigin: ResourceOrigin?
    var id: String { "\(source.rawValue):\(name)" }

    init(
        name: String,
        description: String?,
        argumentHint: String?,
        source: Source,
        sourcePath: String?,
        resourceSource: String? = nil,
        resourceScope: ResourceScope? = nil,
        resourceOrigin: ResourceOrigin? = nil
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.source = source
        self.sourcePath = sourcePath
        self.resourceSource = resourceSource
        self.resourceScope = resourceScope
        self.resourceOrigin = resourceOrigin
    }
}

struct CommandResourceDetail: Codable, Hashable, Sendable {
    let name: String
    let description: String?
    let argumentHint: String?
    let source: CommandInfo.Source
    let sourcePath: String?
    let resourceSource: String?
    let resourceScope: CommandInfo.ResourceScope?
    let resourceOrigin: CommandInfo.ResourceOrigin?
    let content: String?
    let contentBytes: Int?
    let contentTruncated: Bool?

    init(
        name: String,
        description: String?,
        argumentHint: String?,
        source: CommandInfo.Source,
        sourcePath: String?,
        resourceSource: String?,
        resourceScope: CommandInfo.ResourceScope?,
        resourceOrigin: CommandInfo.ResourceOrigin?,
        content: String?,
        contentBytes: Int?,
        contentTruncated: Bool?
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.source = source
        self.sourcePath = sourcePath
        self.resourceSource = resourceSource
        self.resourceScope = resourceScope
        self.resourceOrigin = resourceOrigin
        self.content = content
        self.contentBytes = contentBytes
        self.contentTruncated = contentTruncated
    }
}

enum CommandResourceDetailPolicy {
    static let maximumContentBytes = 96 * 1_024

    static func admit(_ detail: CommandResourceDetail, matching command: CommandInfo) throws -> CommandResourceDetail {
        let projectedBytes = detail.content?.utf8.count
        let metadata = [
            detail.name,
            detail.description,
            detail.argumentHint,
            detail.sourcePath,
            detail.resourceSource,
        ]
        guard detail.name == command.name,
              metadata.allSatisfy({ $0.map { $0.utf8.count <= CommandCatalogPolicy.maximumStringBytes } ?? true }),
              detail.source == command.source,
              projectedBytes.map({ $0 <= maximumContentBytes }) ?? true,
              detail.contentBytes.map({ $0 >= 0 }) ?? true,
              projectedBytes == nil || detail.contentBytes.map({ $0 >= projectedBytes! }) == true,
              (detail.contentTruncated == true
                ? detail.contentBytes.map({ $0 > maximumContentBytes }) == true
                : detail.contentBytes == projectedBytes) else {
            throw GatewayFailure(
                code: "invalid_response",
                message: "The selected command detail from the Mac is invalid or too large.",
                retryable: true,
                details: nil
            )
        }
        return detail
    }
}

enum CommandCatalogPolicy {
    static let maximumCommands = 1_000
    static let maximumNameBytes = 512
    static let maximumStringBytes = 8_192
    static let maximumEncodedBytes = 700_000

    static func admit(_ commands: [CommandInfo]) throws -> [CommandInfo] {
        guard commands.count <= maximumCommands else { throw invalidCatalog() }
        var identities = Set<String>()
        identities.reserveCapacity(commands.count)
        for command in commands {
            guard !command.name.isEmpty,
                  command.name.utf8.count <= maximumNameBytes,
                  !command.name.contains(where: \.isWhitespace),
                  command.description.map({ $0.utf8.count <= maximumStringBytes }) ?? true,
                  command.argumentHint.map({ $0.utf8.count <= maximumStringBytes }) ?? true,
                  command.sourcePath.map({ $0.utf8.count <= maximumStringBytes }) ?? true,
                  command.resourceSource.map({ $0.utf8.count <= maximumStringBytes }) ?? true,
                  identities.insert(command.id).inserted else {
                throw invalidCatalog()
            }
        }
        guard let encoded = try? JSONEncoder.gateway.encode(commands),
              encoded.count <= maximumEncodedBytes else {
            throw invalidCatalog()
        }
        return commands
    }

    private static func invalidCatalog() -> GatewayFailure {
        GatewayFailure(
            code: "invalid_response",
            message: "The command catalog from the Mac is invalid or too large.",
            retryable: true,
            details: nil
        )
    }
}

struct PackageSummary: Codable, Hashable, Identifiable, Sendable {
    enum Scope: String, Codable, Sendable { case user, project }
    let source: String
    let scope: Scope
    let filtered: Bool
    let installedPath: String?
    /// The names this install contributes, projected by the Gateway from the
    /// same resolution the package read already performs. Optional so a Gateway
    /// that predates the field still decodes its listing; the detail sheet then
    /// shows no Provides groups rather than an empty one.
    var provides: PackageProvides? = nil
    var id: String { "\(scope.rawValue):\(source)" }
    /// The scope word the installed row and its detail sheet both show.
    var scopeLabel: String { scope == .project ? "Project" : "Global" }
}

/// The names one installed package provides, by kind. `packages.list` carries
/// them beside each package and they stay names only: the flat resolved
/// `resources` inventory remains authoritative for every path and status.
struct PackageProvides: Codable, Hashable, Sendable {
    let skills: [String]
    let prompts: [String]
    let themes: [String]
    let subagents: [String]
    let tools: [String]
    let commands: [String]
}

struct PackageInventory: Codable, Hashable, Sendable {
    let packages: [PackageSummary]
    let resources: JSONValue
    /// One bounded explanation for kinds `provides` could not resolve, so a
    /// failed attribution never fails the package read itself.
    var providesDiagnostic: String? = nil
}

/// One built-in Tron extension from `modules.list`. The commands are empty for
/// every module today; they stay decoded because the Gateway reports them.
struct TronModuleSummary: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let purpose: String
    let tools: [String]
    let commands: [String]
    var id: String { name }
}

/// One MCP connection a session would admit tools from. It names the source
/// only: individual MCP tool names exist inside that session's runtime.
struct McpToolSource: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let definitionId: String
    let health: String
}

/// `modules.list`: the installed Tron modules and the MCP tool sources.
struct TronModuleList: Codable, Hashable, Sendable {
    let modules: [TronModuleSummary]
    let connections: [McpToolSource]
}

struct PackageUpdate: Codable, Hashable, Identifiable, Sendable {
    let source: String
    let displayName: String
    let type: String
    let scope: PackageSummary.Scope
    var id: String { "\(scope.rawValue):\(source)" }
}

enum PackageCatalogPolicy {
    private struct UpdateEnvelope: Encodable {
        let updates: [PackageUpdate]
    }

    static let maximumPackages = 256
    static let maximumUpdates = 256
    static let maximumStringBytes = 8_192
    static let maximumEncodedBytes = 768 * 1_024

    static func admit(_ inventory: PackageInventory) throws -> PackageInventory {
        guard inventory.packages.count <= maximumPackages else {
            throw invalidCatalog("it contains more than \(maximumPackages) packages")
        }
        var identities = Set<String>()
        identities.reserveCapacity(inventory.packages.count)
        for package in inventory.packages {
            guard !package.source.isEmpty,
                  package.source.utf8.count <= maximumStringBytes,
                  package.id.utf8.count <= maximumStringBytes,
                  package.installedPath.map({ $0.utf8.count <= maximumStringBytes }) ?? true,
                  identities.insert(package.id).inserted else {
                throw invalidCatalog("a package entry is empty, oversized, or duplicated")
            }
        }
        try validateResources(inventory.resources)
        guard let encoded = try? JSONEncoder().encode(inventory), encoded.count <= maximumEncodedBytes else {
            throw invalidCatalog("it exceeds the \(maximumEncodedBytes / 1_024) KiB response limit")
        }
        return inventory
    }

    static func admit(_ updates: [PackageUpdate]) throws -> [PackageUpdate] {
        guard updates.count <= maximumUpdates else {
            throw invalidCatalog("it contains more than \(maximumUpdates) updates")
        }
        var identities = Set<String>()
        identities.reserveCapacity(updates.count)
        for update in updates {
            guard !update.source.isEmpty,
                  update.source.utf8.count <= maximumStringBytes,
                  update.id.utf8.count <= maximumStringBytes,
                  !update.displayName.isEmpty,
                  update.displayName.utf8.count <= maximumStringBytes,
                  !update.type.isEmpty,
                  update.type.utf8.count <= maximumStringBytes,
                  identities.insert(update.id).inserted else {
                throw invalidCatalog("an update entry is empty, oversized, or duplicated")
            }
        }
        guard let encoded = try? JSONEncoder().encode(UpdateEnvelope(updates: updates)),
              encoded.count <= maximumEncodedBytes else {
            throw invalidCatalog("it exceeds the \(maximumEncodedBytes / 1_024) KiB response limit")
        }
        return updates
    }

    private static func validateResources(_ resources: JSONValue) throws {
        // The Gateway may add projected resource categories over time. Validate
        // every category this client consumes, but do not reject additive keys.
        guard case .object(let root) = resources else {
            throw invalidCatalog("its resource projection is not an object")
        }
        for kind in ["extensions", "skills", "prompts", "themes"] {
            guard case .array(let values)? = root[kind], values.count <= 1_000 else {
                throw invalidCatalog("its \(kind) resources are missing or exceed 1,000 items")
            }
            var paths = Set<String>()
            paths.reserveCapacity(values.count)
            for value in values {
                guard case .object(let item) = value,
                      case .string(let path)? = item["path"],
                      !path.isEmpty,
                      path.utf8.count <= maximumStringBytes,
                      case .object(let metadata)? = item["metadata"],
                      case .string(let source)? = metadata["source"],
                      !source.isEmpty,
                      source.utf8.count <= maximumStringBytes,
                      paths.insert(path).inserted else {
                    throw invalidCatalog("a \(kind) resource entry is malformed, oversized, or duplicated")
                }
                // Resource metadata is a Gateway projection. Keep its
                // structural/string bounds, but do not reject newer scope or
                // origin values that this client only displays as raw JSON.
                if let enabled = item["enabled"] {
                    guard case .bool = enabled else {
                        throw invalidCatalog("a \(kind) resource enabled flag is malformed")
                    }
                }
                for key in ["scope", "origin"] {
                    if let value = metadata[key] {
                        guard case .string(let value) = value,
                              value.utf8.count <= maximumStringBytes else {
                            throw invalidCatalog("a \(kind) resource metadata value is malformed or oversized")
                        }
                    }
                }
                if let baseDir = metadata["baseDir"] {
                    guard baseDir == .null || (baseDir.stringValue?.utf8.count ?? .max) <= maximumStringBytes else {
                        throw invalidCatalog("a \(kind) resource base directory is malformed or oversized")
                    }
                }
            }
        }
    }

    private static func invalidCatalog(_ reason: String) -> GatewayFailure {
        GatewayFailure(
            code: "invalid_response",
            message: "The package catalog from the Mac was rejected: \(reason).",
            retryable: true,
            details: nil
        )
    }
}

struct ProviderSummary: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let configured: Bool
    /// Gateway-reported first-party usage support. Optional so a Gateway that
    /// predates the field simply reserves no usage placeholder.
    let usageSupported: Bool?
    /// Gateway-reported local-model provider: every advertised model (and the
    /// provider default) resolves to a loopback base URL, so account usage
    /// never applies. Optional so a Gateway that predates the field simply
    /// presents no local indicator.
    let localOnly: Bool?
    let authSource: String?
    let credentialType: String?
    let authMethods: [String]
    let modelCount: Int

    var supportsUsage: Bool { usageSupported == true }
    var isLocalOnly: Bool { localOnly == true }
}

struct ContextWindowLimits: Codable, Hashable, Sendable {
    let minimum: Int
    let maximum: Int
    let `default`: Int
    let longContextThreshold: Int?

    func admits(_ value: Int) -> Bool {
        value >= minimum && value <= maximum
    }

    func withMinimum(_ scopedMinimum: Int?) -> Self {
        guard let scopedMinimum, scopedMinimum > 0 else { return self }
        let adjustedMinimum = min(maximum, scopedMinimum)
        return Self(minimum: adjustedMinimum, maximum: maximum,
                    default: max(adjustedMinimum, `default`), longContextThreshold: longContextThreshold)
    }

    var isValid: Bool {
        minimum > 0 && maximum >= minimum && maximum <= 100_000_000 && admits(`default`)
            && (longContextThreshold == nil || (longContextThreshold! > 0 && longContextThreshold! <= maximum))
    }
}

struct ModelSummary: Codable, Hashable, Identifiable, Sendable {
    let provider: String
    let id: String
    let name: String
    let reasoning: Bool
    let input: [String]
    let contextWindow: Int
    let maxTokens: Int
    let available: Bool
    var contextWindowLimits: ContextWindowLimits? = nil

    var ref: ModelRef { ModelRef(provider: provider, id: id) }
}

