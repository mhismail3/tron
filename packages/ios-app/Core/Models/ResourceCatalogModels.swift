import Foundation

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
    package let title: String?
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
        resourceOrigin: ResourceOrigin? = nil,
        title: String? = nil
    ) {
        self.name = name
        self.title = title
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
                  command.title.map({ $0.utf8.count <= maximumStringBytes }) ?? true,
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
    package var provides: PackageProvides? = nil
    package var conflict: PackageConflict? = nil
    package var nodeRequirement: PackageNodeRequirement? = nil
    package var id: String { "\(scope.rawValue):\(source)" }
    package var isBundled: Bool { source.hasPrefix("tron:") }
    package var scopeLabel: String { isBundled ? "Bundled with Tron" : scope == .project ? "Project" : "Global" }
}

package struct PackageNodeRequirement: Codable, Hashable, Sendable {
    package let range: String
    package let runtime: String
    package let status: String

    package var tag: String? {
        switch status {
        case "satisfied": nil
        case "invalid": "Unreadable Node range"
        default: "Needs Node \(range)"
        }
    }

    package var notice: String? {
        switch status {
        case "satisfied":
            return nil
        case "invalid":
            return "This package declares Node “\(range)”, which isn’t a valid version range, so Tron can’t check it against Node \(runtime) on this Mac. The package is still loaded."
        default:
            return "This package needs Node \(range), but this Mac runs Node \(runtime). It is still loaded, but it may fail until Tron ships a Node it supports."
        }
    }
}

package struct PackageConflict: Codable, Hashable, Sendable {
    package let code: String
    package let message: String
}

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
    package var providesDiagnostic: String? = nil
}

package struct TronModuleSummary: Codable, Hashable, Identifiable, Sendable {
    package let name: String
    package let purpose: String
    package let tools: [String]
    package let commands: [String]
    package var id: String { name }
}

package struct TronModuleList: Codable, Hashable, Sendable {
    package let modules: [TronModuleSummary]
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
    let usageSupported: Bool?
    let localOnly: Bool?
    package let usageLentTo: String?
    package let authSource: String?
    package let credentialType: String?
    package let authMethods: [String]
    let modelCount: Int

    package init(id: String, name: String, configured: Bool, usageSupported: Bool?, localOnly: Bool?, authSource: String?, credentialType: String?, authMethods: [String], modelCount: Int, usageLentTo: String? = nil) {
        self.id = id
        self.name = name
        self.configured = configured
        self.usageSupported = usageSupported
        self.localOnly = localOnly
        self.usageLentTo = usageLentTo
        self.authSource = authSource
        self.credentialType = credentialType
        self.authMethods = authMethods
        self.modelCount = modelCount
    }

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
    package var releaseDate: String? = nil
    package var cost: ModelTokenPrice? = nil
    package var virtual: Bool? = nil

    package var ref: ModelRef { ModelRef(provider: provider, id: id) }
}

package struct ModelTokenPrice: Codable, Hashable, Sendable {
    let input: Double
    let output: Double
}

package struct RecentModelRef: Codable, Hashable, Sendable {
    package let provider: String
    package let id: String
    package let lastUsedAt: String

    package var ref: ModelRef { ModelRef(provider: provider, id: id) }
}

