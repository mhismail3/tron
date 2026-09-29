import Foundation
import TronMobileCore

/// Where an available resource comes from, derived by the Gateway from Pi
/// sourceInfo. Pi built-ins carry no distribution, and `origin` keeps Pi's own
/// package/top-level meaning on the separate scope badge.
package enum ResourceDistribution: String, Codable, Hashable, Sendable {
    case external
    case module
    case local
}

package struct CommandInfo: Codable, Hashable, Identifiable, Sendable {
    package enum Source: String, Codable, Sendable { case `extension`, skill, prompt }
    package enum ResourceScope: String, Codable, Sendable { case user, project, temporary }
    package enum ResourceOrigin: String, Codable, Sendable { case package, topLevel = "top-level" }

    package let name: String
    package let description: String?
    package let argumentHint: String?
    package let source: Source
    package let sourcePath: String?
    package let resourceSource: String?
    package let resourceScope: ResourceScope?
    package let resourceOrigin: ResourceOrigin?
    package var id: String { "\(source.rawValue):\(name)" }

    package init(
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

package struct CommandResourceDetail: Codable, Hashable, Sendable {
    package let name: String
    package let description: String?
    package let argumentHint: String?
    let source: CommandInfo.Source
    package let sourcePath: String?
    package let resourceSource: String?
    package let resourceScope: CommandInfo.ResourceScope?
    package let resourceOrigin: CommandInfo.ResourceOrigin?
    package let content: String?
    package let contentBytes: Int?
    package let contentTruncated: Bool?

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

package enum CommandResourceDetailPolicy {
    static let maximumContentBytes = 96 * 1_024

    package static func admit(_ detail: CommandResourceDetail, matching command: CommandInfo) throws -> CommandResourceDetail {
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

package enum CommandCatalogPolicy {
    package static let maximumCommands = 1_000
    static let maximumNameBytes = 512
    static let maximumStringBytes = 8_192
    static let maximumEncodedBytes = 700_000

    package static func admit(_ commands: [CommandInfo]) throws -> [CommandInfo] {
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

package struct PackageSummary: Codable, Hashable, Identifiable, Sendable {
    package enum Scope: String, Codable, Sendable { case user, project }
    package let source: String
    package let scope: Scope
    package let filtered: Bool
    let installedPath: String?
    /// The names this install contributes, projected by the Gateway from the
    /// same resolution the package read already performs. Optional so a Gateway
    /// that predates the field still decodes its listing; the detail sheet then
    /// shows no Provides groups rather than an empty one.
    package var provides: PackageProvides? = nil
    package var id: String { "\(scope.rawValue):\(source)" }
    /// The scope word the installed row and its detail sheet both show.
    package var scopeLabel: String { scope == .project ? "Project" : "Global" }
}

/// The names one installed package provides, by kind. `packages.list` carries
/// them beside each package and they stay names only: the flat resolved
/// `resources` inventory remains authoritative for every path and status.
package struct PackageProvides: Codable, Hashable, Sendable {
    package let skills: [String]
    package let prompts: [String]
    package let themes: [String]
    package let subagents: [String]
    package let tools: [String]
    package let commands: [String]
}

package struct PackageInventory: Codable, Hashable, Sendable {
    package let packages: [PackageSummary]
    package let resources: JSONValue
    /// One bounded explanation for kinds `provides` could not resolve, so a
    /// failed attribution never fails the package read itself.
    package var providesDiagnostic: String? = nil
}

/// One built-in Tron extension from `modules.list`. The commands are empty for
/// every module today; they stay decoded because the Gateway reports them.
package struct TronModuleSummary: Codable, Hashable, Identifiable, Sendable {
    package let name: String
    package let purpose: String
    package let tools: [String]
    package let commands: [String]
    package var id: String { name }
}

/// One MCP connection a session would admit tools from. It names the source
/// only: individual MCP tool names exist inside that session's runtime.
package struct McpToolSource: Codable, Hashable, Identifiable, Sendable {
    package let id: String
    package let definitionId: String
    package let health: String
}

/// `modules.list`: the installed Tron modules and the MCP tool sources.
package struct TronModuleList: Codable, Hashable, Sendable {
    package let modules: [TronModuleSummary]
    package let connections: [McpToolSource]
}

package struct PackageUpdate: Codable, Hashable, Identifiable, Sendable {
    package let source: String
    let displayName: String
    let type: String
    package let scope: PackageSummary.Scope
    package var id: String { "\(scope.rawValue):\(source)" }
}

package enum PackageCatalogPolicy {
    private struct UpdateEnvelope: Encodable {
        let updates: [PackageUpdate]
    }

    static let maximumPackages = 256
    static let maximumUpdates = 256
    static let maximumStringBytes = 8_192
    static let maximumEncodedBytes = 768 * 1_024

    package static func admit(_ inventory: PackageInventory) throws -> PackageInventory {
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

    package static func admit(_ updates: [PackageUpdate]) throws -> [PackageUpdate] {
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

package struct ProviderSummary: Codable, Hashable, Identifiable, Sendable {
    package let id: String
    package let name: String
    package let configured: Bool
    /// Gateway-reported first-party usage support. Optional so a Gateway that
    /// predates the field simply reserves no usage placeholder.
    let usageSupported: Bool?
    /// Gateway-reported local-model provider: every advertised model (and the
    /// provider default) resolves to a loopback base URL, so account usage
    /// never applies. Optional so a Gateway that predates the field simply
    /// presents no local indicator.
    let localOnly: Bool?
    package let authSource: String?
    package let credentialType: String?
    package let authMethods: [String]
    let modelCount: Int

    package var supportsUsage: Bool { usageSupported == true }
    package var isLocalOnly: Bool { localOnly == true }
}

package struct ContextWindowLimits: Codable, Hashable, Sendable {
    package let minimum: Int
    package let maximum: Int
    package let `default`: Int
    package let longContextThreshold: Int?

    package init(minimum: Int, maximum: Int, default: Int, longContextThreshold: Int?) {
        self.minimum = minimum
        self.maximum = maximum
        self.default = `default`
        self.longContextThreshold = longContextThreshold
    }

    package func admits(_ value: Int) -> Bool {
        value >= minimum && value <= maximum
    }

    package func withMinimum(_ scopedMinimum: Int?) -> Self {
        guard let scopedMinimum, scopedMinimum > 0 else { return self }
        let adjustedMinimum = min(maximum, scopedMinimum)
        return Self(minimum: adjustedMinimum, maximum: maximum,
                    default: max(adjustedMinimum, `default`), longContextThreshold: longContextThreshold)
    }

    package var isValid: Bool {
        minimum > 0 && maximum >= minimum && maximum <= 100_000_000 && admits(`default`)
            && (longContextThreshold == nil || (longContextThreshold! > 0 && longContextThreshold! <= maximum))
    }
}

package struct ModelSummary: Codable, Hashable, Identifiable, Sendable {
    package let provider: String
    package let id: String
    package let name: String
    let reasoning: Bool
    package let input: [String]
    package let contextWindow: Int
    package let maxTokens: Int
    package let available: Bool
    package var contextWindowLimits: ContextWindowLimits? = nil
    /// Gateway canon release date (`YYYY-MM-DD`). Absent when the Gateway has no
    /// recorded release for the model, which keeps it out of the Latest rail.
    package var releaseDate: String? = nil
    /// USD per million tokens from the pinned SDK catalog. Absent when the
    /// Gateway has no price, which is not the same as free.
    package var cost: ModelTokenPrice? = nil

    package var ref: ModelRef { ModelRef(provider: provider, id: id) }
}

package struct ModelTokenPrice: Codable, Hashable, Sendable {
    let input: Double
    let output: Double
}

/// One Gateway-recorded recently used model. The Gateway owns this history;
/// iOS only projects it into the picker's Recent rail.
package struct RecentModelRef: Codable, Hashable, Sendable {
    package let provider: String
    package let id: String
    package let lastUsedAt: String

    package var ref: ModelRef { ModelRef(provider: provider, id: id) }
}

