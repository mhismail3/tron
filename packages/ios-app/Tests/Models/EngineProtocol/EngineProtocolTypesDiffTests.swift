import Testing
import Foundation
@testable import TronMobile

@Suite("DiffFileEntry")
struct DiffFileEntryTests {

    @Test("fileName extracts last path component")
    func fileNameExtractsLastComponent() {
        let entry = DiffFileEntry(
            path: "src/views/Main.swift",
            status: .modified,
            stagingArea: .unstaged,
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
            status: .modified,
            stagingArea: .unstaged,
            diff: nil,
            additions: 0,
            deletions: 0
        )
        #expect(entry.fileExtension == "md")
    }

    @Test("fileChangeStatus returns decoded status")
    func fileChangeStatusReturnsDecodedStatus() {
        let cases: [FileChangeStatus] = [
            .modified,
            .added,
            .deleted,
            .renamed,
            .untracked,
            .unmerged,
            .copied,
        ]
        for status in cases {
            let entry = DiffFileEntry(path: "f", status: status, stagingArea: .unstaged, diff: nil, additions: 0, deletions: 0)
            #expect(entry.fileChangeStatus == status)
        }
    }

    @Test("id is the path")
    func idIsPath() {
        let entry = DiffFileEntry(path: "src/main.rs", status: .modified, stagingArea: .unstaged, diff: nil, additions: 0, deletions: 0)
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
                    "stagingArea": "unstaged",
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
                    "stagingArea": "unstaged",
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
        #expect(file.status == .untracked)
        #expect(file.diff == nil)
    }

    @Test("Decodes file with stagingArea=staged")
    func decodesStagingAreaStaged() throws {
        let json = """
        {
            "isGitRepo": true,
            "branch": "main",
            "files": [
                {
                    "path": "foo.rs",
                    "status": "modified",
                    "stagingArea": "staged",
                    "diff": "+new line",
                    "additions": 1,
                    "deletions": 0
                }
            ],
            "summary": { "totalFiles": 1, "totalAdditions": 1, "totalDeletions": 0 }
        }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(WorktreeGetDiffResult.self, from: json)
        let file = try #require(result.files?.first)
        #expect(file.stagingArea == .staged)
        #expect(file.fileStagingArea == .staged)
    }

    @Test("Decodes file with stagingArea=unstaged")
    func decodesStagingAreaUnstaged() throws {
        let json = """
        {
            "isGitRepo": true,
            "branch": "main",
            "files": [
                {
                    "path": "bar.rs",
                    "status": "modified",
                    "stagingArea": "unstaged",
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
        #expect(file.fileStagingArea == .unstaged)
    }

    @Test("Decodes file with stagingArea=both")
    func decodesStagingAreaBoth() throws {
        let json = """
        {
            "isGitRepo": true,
            "branch": "main",
            "files": [
                {
                    "path": "both.rs",
                    "status": "modified",
                    "stagingArea": "both",
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
        #expect(file.fileStagingArea == .both)
    }

    @Test("Missing stagingArea fails decoding")
    func missingStagingAreaFailsDecoding() throws {
        let json = """
        {
            "isGitRepo": true,
            "branch": "main",
            "files": [
                {
                    "path": "old.rs",
                    "status": "modified",
                    "diff": null,
                    "additions": 0,
                    "deletions": 0
                }
            ],
            "summary": { "totalFiles": 1, "totalAdditions": 0, "totalDeletions": 0 }
        }
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WorktreeGetDiffResult.self, from: json)
        }
    }

    @Test("Unknown status fails decoding")
    func unknownStatusFailsDecoding() throws {
        let json = """
        {
            "isGitRepo": true,
            "branch": "main",
            "files": [
                {
                    "path": "old.rs",
                    "status": "mystery",
                    "stagingArea": "unstaged",
                    "diff": null,
                    "additions": 0,
                    "deletions": 0
                }
            ],
            "summary": { "totalFiles": 1, "totalAdditions": 0, "totalDeletions": 0 }
        }
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WorktreeGetDiffResult.self, from: json)
        }
    }

    @Test("Mixed staging areas in single response")
    func decodesMixedStagingAreas() throws {
        let json = """
        {
            "isGitRepo": true,
            "branch": "main",
            "files": [
                { "path": "a.rs", "status": "modified", "stagingArea": "staged", "diff": null, "additions": 0, "deletions": 0 },
                { "path": "b.rs", "status": "added", "stagingArea": "unstaged", "diff": null, "additions": 0, "deletions": 0 },
                { "path": "c.rs", "status": "modified", "stagingArea": "both", "diff": null, "additions": 0, "deletions": 0 }
            ],
            "summary": { "totalFiles": 3, "totalAdditions": 0, "totalDeletions": 0 }
        }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(WorktreeGetDiffResult.self, from: json)
        let files = try #require(result.files)
        #expect(files.count == 3)
        #expect(files[0].fileStagingArea == .staged)
        #expect(files[1].fileStagingArea == .unstaged)
        #expect(files[2].fileStagingArea == .both)
    }
}

@Suite("WorktreeGetDiffSummaryResult Decoding")
struct WorktreeGetDiffSummaryResultDecodingTests {
    @Test("Decodes summary response without file entries")
    func decodesSummaryResponse() throws {
        let json = """
        {
            "isGitRepo": true,
            "branch": "feature/xyz",
            "summary": {
                "totalFiles": 2,
                "totalAdditions": 12,
                "totalDeletions": 1
            }
        }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(WorktreeGetDiffSummaryResult.self, from: json)
        #expect(result.isGitRepo == true)
        #expect(result.branch == "feature/xyz")
        #expect(result.summary?.totalFiles == 2)
        #expect(result.summary?.totalAdditions == 12)
        #expect(result.summary?.totalDeletions == 1)
    }

    @Test("Decodes non-git summary response")
    func decodesNonGitSummaryResponse() throws {
        let json = """
        { "isGitRepo": false }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(WorktreeGetDiffSummaryResult.self, from: json)
        #expect(result.isGitRepo == false)
        #expect(result.branch == nil)
        #expect(result.summary == nil)
    }
}

@Suite("StagingArea Enum")
struct StagingAreaTests {

    @Test("All raw values are correct")
    func rawValues() {
        #expect(StagingArea.staged.rawValue == "staged")
        #expect(StagingArea.unstaged.rawValue == "unstaged")
        #expect(StagingArea.both.rawValue == "both")
    }

    @Test("Decodes from raw string")
    func decodesFromString() {
        #expect(StagingArea(rawValue: "staged") == .staged)
        #expect(StagingArea(rawValue: "unstaged") == .unstaged)
        #expect(StagingArea(rawValue: "both") == .both)
        #expect(StagingArea(rawValue: "invalid") == nil)
    }
}

@Suite("WorktreeFileOperationResult")
struct WorktreeFileOperationResultTests {

    @Test("Decodes success=true")
    func decodesSuccess() throws {
        let json = """
        { "success": true }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(WorktreeFileOperationResult.self, from: json)
        #expect(result.success == true)
    }

    @Test("Decodes success=false")
    func decodesFailure() throws {
        let json = """
        { "success": false }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(WorktreeFileOperationResult.self, from: json)
        #expect(result.success == false)
    }
}
