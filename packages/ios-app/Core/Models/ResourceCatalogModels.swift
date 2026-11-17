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

