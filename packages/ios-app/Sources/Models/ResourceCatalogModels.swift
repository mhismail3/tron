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

