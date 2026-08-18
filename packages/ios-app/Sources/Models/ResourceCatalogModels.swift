import Foundation

struct CommandInfo: Codable, Hashable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case `extension`, skill, prompt }
    let name: String
    let description: String?
    let argumentHint: String?
    let source: Source
    let sourcePath: String?
    var id: String { "\(source.rawValue):\(name)" }
}

enum CommandCatalogPolicy {
    static let maximumCommands = 1_000
    static let maximumStringBytes = 8_192
    static let maximumEncodedBytes = 700_000

    static func admit(_ commands: [CommandInfo]) throws -> [CommandInfo] {
        guard commands.count <= maximumCommands else { throw invalidCatalog() }
        var identities = Set<String>()
        identities.reserveCapacity(commands.count)
        for command in commands {
            guard !command.name.isEmpty,
                  command.name.utf8.count <= maximumStringBytes,
                  command.description.map({ $0.utf8.count <= maximumStringBytes }) ?? true,
                  command.argumentHint.map({ $0.utf8.count <= maximumStringBytes }) ?? true,
                  command.sourcePath.map({ $0.utf8.count <= maximumStringBytes }) ?? true,
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
    var id: String { "\(scope.rawValue):\(source)" }
}

struct PackageInventory: Codable, Hashable, Sendable {
    let packages: [PackageSummary]
    let resources: JSONValue
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
    let authSource: String?
    let credentialType: String?
    let authMethods: [String]
    let modelCount: Int
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

    var ref: ModelRef { ModelRef(provider: provider, id: id) }
}

