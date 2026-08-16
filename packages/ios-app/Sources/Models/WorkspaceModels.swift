import Foundation

struct WorkspaceListing: Codable, Hashable, Sendable {
    let path: String
    let parent: String?
    let entries: [WorkspaceEntry]
}

struct WorkspaceEntry: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case directory, file }
    let name: String
    let path: String
    let kind: Kind
    let hidden: Bool
    var id: String { path }
}
