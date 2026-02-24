import Testing
import Foundation
@testable import TronMobile

@Suite("DiffFileEntry")
struct DiffFileEntryTests {

    @Test("fileName extracts last path component")
    func fileNameExtractsLastComponent() {
        let entry = DiffFileEntry(
            path: "src/views/Main.swift",
            status: "modified",
            diff: nil,
            additions: 0,
            deletions: 0
        )
        #expect(entry.fileName == "Main.swift")
    }

    @Test("fileExtension extracts extension lowercase")
    func fileExtensionIsLowercase() {
        let entry = DiffFileEntry(
            path: "README.MD",
            status: "modified",
            diff: nil,
            additions: 0,
            deletions: 0
        )
        #expect(entry.fileExtension == "md")
    }

    @Test("fileChangeStatus maps known statuses")
    func fileChangeStatusMapsKnown() {
        let cases: [(String, FileChangeStatus)] = [
            ("modified", .modified),
            ("added", .added),
            ("deleted", .deleted),
            ("renamed", .renamed),
            ("untracked", .untracked),
            ("unmerged", .unmerged),
            ("copied", .copied),
        ]
        for (raw, expected) in cases {
            let entry = DiffFileEntry(path: "f", status: raw, diff: nil, additions: 0, deletions: 0)
            #expect(entry.fileChangeStatus == expected)
        }
    }

    @Test("fileChangeStatus defaults to modified for unknown")
    func fileChangeStatusDefaultsToModified() {
        let entry = DiffFileEntry(path: "f", status: "unknown_status", diff: nil, additions: 0, deletions: 0)
        #expect(entry.fileChangeStatus == .modified)
    }

    @Test("id is the path")
    func idIsPath() {
        let entry = DiffFileEntry(path: "src/main.rs", status: "modified", diff: nil, additions: 0, deletions: 0)
        #expect(entry.id == "src/main.rs")
    }
}

@Suite("WorktreeGetDiffResult Decoding")
struct WorktreeGetDiffResultDecodingTests {

    @Test("Decodes complete response")
    func decodesComplete() throws {
        let json = """
        {
            "isGitRepo": true,
            "branch": "feature/xyz",
            "files": [
                {
                    "path": "src/main.rs",
                    "status": "modified",
                    "diff": "@@ -1,3 +1,4 @@\\n-old\\n+new",
                    "additions": 1,
                    "deletions": 1
                }
            ],
            "summary": {
                "totalFiles": 1,
                "totalAdditions": 1,
                "totalDeletions": 1
            }
        }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(WorktreeGetDiffResult.self, from: json)
        #expect(result.isGitRepo == true)
        #expect(result.branch == "feature/xyz")
        #expect(result.files?.count == 1)
        #expect(result.files?[0].path == "src/main.rs")
        #expect(result.summary?.totalFiles == 1)
    }

    @Test("Decodes isGitRepo=false response")
    func decodesNotGitRepo() throws {
        let json = """
        { "isGitRepo": false }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(WorktreeGetDiffResult.self, from: json)
        #expect(result.isGitRepo == false)
        #expect(result.branch == nil)
        #expect(result.files == nil)
        #expect(result.summary == nil)
    }

    @Test("Decodes response with null branch (detached HEAD)")
    func decodesNullBranch() throws {
        let json = """
        {
            "isGitRepo": true,
            "branch": null,
            "files": [],
            "summary": { "totalFiles": 0, "totalAdditions": 0, "totalDeletions": 0 }
        }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(WorktreeGetDiffResult.self, from: json)
        #expect(result.isGitRepo == true)
        #expect(result.branch == nil)
    }

    @Test("Decodes response with empty files array")
    func decodesEmptyFiles() throws {
        let json = """
        {
            "isGitRepo": true,
            "branch": "main",
            "files": [],
            "summary": { "totalFiles": 0, "totalAdditions": 0, "totalDeletions": 0 }
        }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(WorktreeGetDiffResult.self, from: json)
        #expect(result.files?.isEmpty == true)
    }

    @Test("Decodes file with null diff (untracked)")
    func decodesNullDiff() throws {
        let json = """
        {
            "isGitRepo": true,
            "branch": "main",
            "files": [
                {
                    "path": "new.txt",
                    "status": "untracked",
                    "diff": null,
                    "additions": 0,
                    "deletions": 0
                }
            ],
            "summary": { "totalFiles": 1, "totalAdditions": 0, "totalDeletions": 0 }
        }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(WorktreeGetDiffResult.self, from: json)
        let file = try #require(result.files?.first)
        #expect(file.status == "untracked")
        #expect(file.diff == nil)
    }
}
