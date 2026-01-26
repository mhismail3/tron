import Foundation

// MARK: - Filesystem Methods

struct FilesystemListDirParams: Encodable {
    let path: String?
    let showHidden: Bool?
}

struct DirectoryEntry: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool?
    let size: Int?
    let modifiedAt: String?

    var id: String { path }
}

struct DirectoryListResult: Decodable {
    let path: String
    let parent: String?
    let entries: [DirectoryEntry]
}

struct HomeResult: Decodable {
    let homePath: String
    let suggestedPaths: [SuggestedPath]?
}

struct SuggestedPath: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let exists: Bool?

    var id: String { path }
}

// MARK: - Create Directory

struct FilesystemCreateDirParams: Encodable {
    let path: String
    let recursive: Bool?

    init(path: String, recursive: Bool? = nil) {
        self.path = path
        self.recursive = recursive
    }
}

struct FilesystemCreateDirResult: Decodable {
    let created: Bool
    let path: String
}

// MARK: - Git Clone

struct GitCloneParams: Encodable {
    let url: String
    let targetPath: String
}

struct GitCloneResult: Decodable {
    let success: Bool
    let path: String
    let repoName: String
    let error: String?
}

// MARK: - Memory Methods

struct MemorySearchParams: Encodable {
    let searchText: String?
    let type: String?
    let source: String?
    let limit: Int?
}

struct MemoryEntry: Decodable, Identifiable {
    let id: String
    let type: String
    let content: String
    let source: String
    let relevance: Double?
    let timestamp: String?
}

struct MemorySearchResult: Decodable {
    let entries: [MemoryEntry]
    let totalCount: Int
}

struct HandoffsParams: Encodable {
    let workingDirectory: String?
    let limit: Int?
}

struct Handoff: Decodable, Identifiable {
    let id: String
    let sessionId: String
    let summary: String
    let createdAt: String
}

struct HandoffsResult: Decodable {
    let handoffs: [Handoff]
}
