import Foundation

package struct WorkspaceListing: Codable, Hashable, Sendable {
    package let path: String
    package let parent: String?
    package let entries: [WorkspaceEntry]
}

package struct WorkspaceEntry: Codable, Hashable, Identifiable, Sendable {
    package enum Kind: String, Codable, Sendable { case directory, file }
    package let name: String
    package let path: String
    package let kind: Kind
    package let hidden: Bool
    package var id: String { path }
}

package enum SessionWorkspaceEntryKind: String, Codable, Hashable, Sendable {
    case directory, file, symlink
}

package enum SessionWorkspaceChangeKind: String, Codable, Hashable, Sendable {
    case added, modified, deleted, renamed, copied, untracked, conflicted, typeChanged
}

package struct SessionWorkspaceChange: Codable, Hashable, Identifiable, Sendable {
    package let path: String
    package let originalPath: String?
    package let staged: Bool
    package let unstaged: Bool
    package let untracked: Bool
    package let conflicted: Bool
    package let kind: SessionWorkspaceChangeKind
    package var id: String { path }
}

package struct SessionWorkspaceRepository: Codable, Hashable, Sendable {
    package let root: String
    package let branch: String?
    package let head: String?
    package let detached: Bool
    package let unborn: Bool
    package let dirty: Bool
    package let changes: [SessionWorkspaceChange]

    private enum CodingKeys: String, CodingKey {
        case root, branch, head, detached, unborn, dirty, changes
    }

    package init(from decoder: Decoder) throws {
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

package struct SessionWorkspaceInspection: Codable, Hashable, Sendable {
    package let root: String
    package let revision: String
    package let repository: SessionWorkspaceRepository?
}

package struct SessionWorkspaceDirectoryEntry: Codable, Hashable, Identifiable, Sendable {
    package let name: String
    package let path: String
    package let kind: SessionWorkspaceEntryKind
    package let hidden: Bool
    package let size: Int?
    let modifiedAt: String?
    package var id: String { path }
}

package struct SessionWorkspaceDirectory: Codable, Hashable, Sendable {
    let root: String
    package let path: String
    package let parent: String?
    let revision: String
    package let entries: [SessionWorkspaceDirectoryEntry]

    private enum CodingKeys: String, CodingKey { case root, path, parent, revision, entries }

    package init(from decoder: Decoder) throws {
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

package struct SessionWorkspaceFile: Codable, Hashable, Sendable {
    package let blobId: String
    package let name: String
    package let mimeType: String
    let size: Int
    package let revision: String
}

package enum SessionWorkspaceDiffScope: String, Codable, CaseIterable, Hashable, Sendable {
    case current, staged, unstaged
}

package struct SessionWorkspaceDiff: Codable, Hashable, Sendable {
    package let path: String
    package let patch: String
    package let binary: Bool
    package let truncated: Bool
    package let revision: String
}

package enum SessionWorkspaceHistoryScope: String, Codable, CaseIterable, Hashable, Sendable {
    case currentBranch, allReferences
}

package struct SessionWorkspaceCommit: Codable, Hashable, Identifiable, Sendable {
    package let oid: String
    package let shortOid: String
    package let parents: [String]
    package let subject: String
    package let authorName: String
    package let authoredAt: String
    package let decorations: [String]
    package var id: String { oid }
}

package struct SessionWorkspaceHistoryPage: Codable, Hashable, Sendable {
    package let commits: [SessionWorkspaceCommit]
    package let nextCursor: String?
    package let revision: String

    private enum CodingKeys: String, CodingKey { case commits, nextCursor, revision }

    package init(from decoder: Decoder) throws {
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

package struct SessionWorkspaceCommitChange: Codable, Hashable, Identifiable, Sendable {
    package let path: String
    let originalPath: String?
    package let kind: SessionWorkspaceChangeKind
    package var id: String { "\(kind.rawValue):\(path):\(originalPath ?? "")" }
}

package struct SessionWorkspaceCommitDetail: Codable, Hashable, Sendable {
    package let oid: String
    package let shortOid: String
    let parents: [String]
    package let subject: String
    package let message: String
    package let authorName: String
    let authorEmail: String?
    package let authoredAt: String
    let decorations: [String]
    package let changes: [SessionWorkspaceCommitChange]
    let revision: String
}
