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

enum SessionWorkspaceEntryKind: String, Codable, Hashable, Sendable {
    case directory, file, symlink
}

enum SessionWorkspaceChangeKind: String, Codable, Hashable, Sendable {
    case added, modified, deleted, renamed, copied, untracked, conflicted, typeChanged
}

struct SessionWorkspaceChange: Codable, Hashable, Identifiable, Sendable {
    let path: String
    let originalPath: String?
    let staged: Bool
    let unstaged: Bool
    let untracked: Bool
    let conflicted: Bool
    let kind: SessionWorkspaceChangeKind
    var id: String { path }
}

struct SessionWorkspaceRepository: Codable, Hashable, Sendable {
    let root: String
    let branch: String?
    let head: String?
    let detached: Bool
    let unborn: Bool
    let dirty: Bool
    let changes: [SessionWorkspaceChange]

    private enum CodingKeys: String, CodingKey {
        case root, branch, head, detached, unborn, dirty, changes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        root = try values.decode(String.self, forKey: .root)
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        head = try values.decodeIfPresent(String.self, forKey: .head)
        detached = try values.decode(Bool.self, forKey: .detached)
        unborn = try values.decode(Bool.self, forKey: .unborn)
        dirty = try values.decode(Bool.self, forKey: .dirty)
        changes = try Self.decodeBounded(
            from: values.superDecoder(forKey: .changes),
            maximum: 5_000,
            label: "Workspace changes"
        )
    }

    private static func decodeBounded<T: Decodable>(
        from decoder: Decoder,
        maximum: Int,
        label: String
    ) throws -> [T] {
        var values = try decoder.unkeyedContainer()
        var result: [T] = []
        result.reserveCapacity(min(values.count ?? 0, maximum))
        while !values.isAtEnd {
            guard result.count < maximum else {
                throw DecodingError.dataCorruptedError(
                    in: values,
                    debugDescription: "\(label) exceeds its bounded capacity"
                )
            }
            result.append(try values.decode(T.self))
        }
        return result
    }
}

struct SessionWorkspaceInspection: Codable, Hashable, Sendable {
    let root: String
    let revision: String
    let repository: SessionWorkspaceRepository?
}

struct SessionWorkspaceDirectoryEntry: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let path: String
    let kind: SessionWorkspaceEntryKind
    let hidden: Bool
    let size: Int?
    let modifiedAt: String?
    var id: String { path }
}

struct SessionWorkspaceDirectory: Codable, Hashable, Sendable {
    let root: String
    let path: String
    let parent: String?
    let revision: String
    let entries: [SessionWorkspaceDirectoryEntry]

    private enum CodingKeys: String, CodingKey { case root, path, parent, revision, entries }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        root = try values.decode(String.self, forKey: .root)
        path = try values.decode(String.self, forKey: .path)
        parent = try values.decodeIfPresent(String.self, forKey: .parent)
        revision = try values.decode(String.self, forKey: .revision)
        var rows = try values.superDecoder(forKey: .entries).unkeyedContainer()
        var result: [SessionWorkspaceDirectoryEntry] = []
        result.reserveCapacity(min(rows.count ?? 0, 1_000))
        while !rows.isAtEnd {
            guard result.count < 1_000 else {
                throw DecodingError.dataCorruptedError(in: rows, debugDescription: "Workspace directory exceeds its bounded capacity")
            }
            result.append(try rows.decode(SessionWorkspaceDirectoryEntry.self))
        }
        entries = result
    }
}

struct SessionWorkspaceFile: Codable, Hashable, Sendable {
    let blobId: String
    let name: String
    let mimeType: String
    let size: Int
    let revision: String
}

enum SessionWorkspaceDiffScope: String, Codable, CaseIterable, Hashable, Sendable {
    case current, staged, unstaged
}

struct SessionWorkspaceDiff: Codable, Hashable, Sendable {
    let path: String
    let patch: String
    let binary: Bool
    let truncated: Bool
    let revision: String
}

enum SessionWorkspaceHistoryScope: String, Codable, CaseIterable, Hashable, Sendable {
    case currentBranch, allReferences
}

struct SessionWorkspaceCommit: Codable, Hashable, Identifiable, Sendable {
    let oid: String
    let shortOid: String
    let parents: [String]
    let subject: String
    let authorName: String
    let authoredAt: String
    let decorations: [String]
    var id: String { oid }
}

struct SessionWorkspaceHistoryPage: Codable, Hashable, Sendable {
    let commits: [SessionWorkspaceCommit]
    let nextCursor: String?
    let revision: String

    private enum CodingKeys: String, CodingKey { case commits, nextCursor, revision }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        revision = try values.decode(String.self, forKey: .revision)
        var rows = try values.superDecoder(forKey: .commits).unkeyedContainer()
        var result: [SessionWorkspaceCommit] = []
        result.reserveCapacity(min(rows.count ?? 0, 100))
        while !rows.isAtEnd {
            guard result.count < 100 else {
                throw DecodingError.dataCorruptedError(in: rows, debugDescription: "Workspace history page exceeds its bounded capacity")
            }
            result.append(try rows.decode(SessionWorkspaceCommit.self))
        }
        commits = result
    }
}

struct SessionWorkspaceCommitChange: Codable, Hashable, Identifiable, Sendable {
    let path: String
    let originalPath: String?
    let kind: SessionWorkspaceChangeKind
    var id: String { "\(kind.rawValue):\(path):\(originalPath ?? "")" }
}

struct SessionWorkspaceCommitDetail: Codable, Hashable, Sendable {
    let oid: String
    let shortOid: String
    let parents: [String]
    let subject: String
    let message: String
    let authorName: String
    let authorEmail: String?
    let authoredAt: String
    let decorations: [String]
    let changes: [SessionWorkspaceCommitChange]
    let revision: String
}
