import Foundation

struct WorkspaceListDirectoryParams: Encodable {
    let path: String?
    let showHidden: Bool?
}

struct WorkspaceCreateDirectoryParams: Encodable {
    let path: String
    let recursive: Bool?
}

struct WorkspaceHomeResult: Decodable, Equatable {
    let homePath: String
    let suggestedPaths: [WorkspaceSuggestedPath]
}

struct WorkspaceSuggestedPath: Decodable, Equatable, Identifiable, Hashable {
    let name: String
    let path: String
    let exists: Bool

    var id: String { path }
}

struct WorkspaceDirectoryListResult: Decodable, Equatable {
    let path: String
    let parent: String?
    let entries: [WorkspaceDirectoryEntry]
    let truncated: Bool
}

struct WorkspaceDirectoryEntry: Decodable, Equatable, Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64?
    let modifiedAt: String?

    var id: String { path }
}

struct WorkspaceCreateDirectoryResult: Decodable, Equatable {
    let created: Bool
    let path: String
}
