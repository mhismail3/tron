import Foundation

extension CommandInfo: Identifiable {
    package var id: String { "\(source.rawValue):\(name)" }
}

package enum CommandResourceDetailPolicy {
    static let maximumContentBytes = 96 * 1_024

    package static func admit(_ detail: CommandDetail, matching command: CommandInfo) throws -> CommandDetail {
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
        guard ("[" + commands.map { $0.encode() }.joined(separator: ",") + "]").utf8.count <= maximumEncodedBytes else {
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

extension PackageSummary: Identifiable {
    package var id: String { "\(scope.rawValue):\(source)" }
    package var isBundled: Bool { source.hasPrefix("tron:") }
    package var scopeLabel: String { isBundled ? "Bundled with Tron" : scope == .project ? "Project" : "Global" }
}

extension PackageNodeRequirement {
    package var tag: String? {
        switch status {
        case .satisfied: nil
        case .invalid: "Unreadable Node range"
        case .unsatisfied: "Needs Node \(range)"
        }
    }

    package var notice: String? {
        switch status {
        case .satisfied:
            return nil
        case .invalid:
            return "This package declares Node “\(range)”, which isn’t a valid version range, so Tron can’t check it against Node \(runtime) on this Mac. The package is still loaded."
        case .unsatisfied:
            return "This package needs Node \(range), but this Mac runs Node \(runtime). It is still loaded, but it may fail until Tron ships a Node it supports."
        }
    }
}

extension TronModuleSummary: Identifiable {
    package var id: String { name }
}

extension PackageUpdate: Identifiable {
    package var id: String { "\(scope.rawValue):\(source)" }
}

package enum PackageCatalogPolicy {
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
        try validateResources(JSONValue(inventory.resources))
        guard inventory.encode().utf8.count <= maximumEncodedBytes else {
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
                  !update.`type`.isEmpty,
                  update.`type`.utf8.count <= maximumStringBytes,
                  identities.insert(update.id).inserted else {
                throw invalidCatalog("an update entry is empty, oversized, or duplicated")
            }
        }
        guard PackageUpdates(updates: updates).encode().utf8.count <= maximumEncodedBytes else {
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

extension ContextWindowLimits {
    package func admits(_ value: Int) -> Bool {
        value >= minimum && value <= maximum
    }

    package var isValid: Bool {
        minimum > 0 && maximum >= minimum && maximum <= 100_000_000 && admits(`default`)
            && (longContextThreshold == nil || (longContextThreshold! > 0 && longContextThreshold! <= maximum))
    }
}

extension ModelSummary: Identifiable {
    package var ref: ModelRef { ModelRef(provider: provider, id: id) }
}

package struct RecentModelRef: Codable, Hashable, Sendable {
    package let provider: String
    package let id: String
    package let lastUsedAt: String

    package var ref: ModelRef { ModelRef(provider: provider, id: id) }
}

