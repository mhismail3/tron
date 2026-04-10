import Testing
import Foundation
@testable import TronMobile

@Suite("WorktreeInfo Tests")
struct WorktreeInfoTests {

    // MARK: - shortBranch

    @Test("shortBranch strips session/ and truncates sess_ hex part")
    func shortBranchFullSessionId() {
        let info = WorktreeInfo(
            isolated: true, branch: "session/sess_abc12345def67890",
            baseCommit: "abc", path: "/tmp", baseBranch: "main",
            repoRoot: nil, hasUncommittedChanges: nil, commitCount: nil, isMerged: nil
        )
        #expect(info.shortBranch == "abc12345")
    }

    @Test("shortBranch strips session/ for non-sess_ branch")
    func shortBranchFeatureBranch() {
        let info = WorktreeInfo(
            isolated: true, branch: "session/my-feature",
            baseCommit: "abc", path: "/tmp", baseBranch: "main",
            repoRoot: nil, hasUncommittedChanges: nil, commitCount: nil, isMerged: nil
        )
        #expect(info.shortBranch == "my-feature")
    }

    @Test("shortBranch returns plain branch name unchanged")
    func shortBranchPlain() {
        let info = WorktreeInfo(
            isolated: true, branch: "main",
            baseCommit: "abc", path: "/tmp", baseBranch: nil,
            repoRoot: nil, hasUncommittedChanges: nil, commitCount: nil, isMerged: nil
        )
        #expect(info.shortBranch == "main")
    }

    @Test("shortBranch sess_ without session/ prefix")
    func shortBranchSessOnly() {
        let info = WorktreeInfo(
            isolated: true, branch: "sess_abc12345def",
            baseCommit: "abc", path: "/tmp", baseBranch: nil,
            repoRoot: nil, hasUncommittedChanges: nil, commitCount: nil, isMerged: nil
        )
        #expect(info.shortBranch == "abc12345")
    }

    @Test("shortBranch short hex part")
    func shortBranchShortHex() {
        let info = WorktreeInfo(
            isolated: true, branch: "session/sess_abc",
            baseCommit: "abc", path: "/tmp", baseBranch: nil,
            repoRoot: nil, hasUncommittedChanges: nil, commitCount: nil, isMerged: nil
        )
        #expect(info.shortBranch == "abc")
    }
}

@Suite("SessionBranchInfo Tests")
struct SessionBranchInfoTests {

    @Test("shortBranch strips session/ prefix")
    func shortBranch() {
        let json = #"{"branch":"session/main","isActive":true,"commitCount":5,"lastCommitHash":"abc","lastCommitMessage":"test","lastCommitDate":"2026-04-01","baseBranch":"main"}"#
        let info = try! JSONDecoder().decode(SessionBranchInfo.self, from: json.data(using: .utf8)!)
        #expect(info.shortBranch == "main")
    }

    @Test("shortBranch no prefix unchanged")
    func shortBranchNoPrefix() {
        let json = #"{"branch":"feature-x","isActive":false,"commitCount":0,"lastCommitHash":"def","lastCommitMessage":"init","lastCommitDate":"2026-04-01"}"#
        let info = try! JSONDecoder().decode(SessionBranchInfo.self, from: json.data(using: .utf8)!)
        #expect(info.shortBranch == "feature-x")
    }
}

@Suite("CommittedFileEntry Tests")
struct CommittedFileEntryTests {

    private func makeEntry(path: String = "/src/main.rs", status: String = "M") -> CommittedFileEntry {
        CommittedFileEntry(path: path, status: status, diff: nil, additions: 10, deletions: 5)
    }

    // MARK: - fileChangeStatus

    @Test("status A maps to added")
    func statusAdded() { #expect(makeEntry(status: "A").fileChangeStatus == .added) }

    @Test("status M maps to modified")
    func statusModified() { #expect(makeEntry(status: "M").fileChangeStatus == .modified) }

    @Test("status D maps to deleted")
    func statusDeleted() { #expect(makeEntry(status: "D").fileChangeStatus == .deleted) }

    @Test("status R maps to renamed")
    func statusRenamed() { #expect(makeEntry(status: "R").fileChangeStatus == .renamed) }

    @Test("status C maps to copied")
    func statusCopied() { #expect(makeEntry(status: "C").fileChangeStatus == .copied) }

    @Test("unknown status defaults to modified")
    func statusUnknown() { #expect(makeEntry(status: "X").fileChangeStatus == .modified) }

    @Test("empty status defaults to modified")
    func statusEmpty() { #expect(makeEntry(status: "").fileChangeStatus == .modified) }

    // MARK: - fileName / fileExtension

    @Test("fileName extracts last path component")
    func fileName() { #expect(makeEntry(path: "/src/main.rs").fileName == "main.rs") }

    @Test("fileExtension extracts lowercased extension")
    func fileExtension() { #expect(makeEntry(path: "/src/main.rs").fileExtension == "rs") }

    @Test("fileName root level file")
    func fileNameRoot() { #expect(makeEntry(path: "/Cargo.toml").fileName == "Cargo.toml") }

    @Test("fileExtension no extension")
    func fileExtensionNone() { #expect(makeEntry(path: "/Makefile").fileExtension == "") }

    @Test("commitEntry shortHash")
    func commitShortHash() {
        let json = #"{"hash":"abc1234567890","message":"test","date":"2026-04-01"}"#
        let entry = try! JSONDecoder().decode(CommitEntry.self, from: json.data(using: .utf8)!)
        #expect(entry.shortHash == "abc1234")
    }
}
