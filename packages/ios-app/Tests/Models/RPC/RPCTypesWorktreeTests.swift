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

@Suite("WorktreeCommitParams Tests")
struct WorktreeCommitParamsTests {

    private func encode(_ params: WorktreeCommitParams) -> [String: Any] {
        let data = try! JSONEncoder().encode(params)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test("required fields always encoded")
    func requiredFieldsOnly() {
        let params = WorktreeCommitParams(sessionId: "s1", message: "hi")
        let dict = encode(params)
        #expect(dict["sessionId"] as? String == "s1")
        #expect(dict["message"] as? String == "hi")
    }

    @Test("flag-less call preserves legacy server defaults")
    func legacyCallPreservesServerDefaults() {
        // Critical regression guard: older iOS clients that upgrade must
        // continue to commit everything (stage_all = true by default on
        // the server). If we accidentally emit `stageAll: false` when the
        // caller passed nil, the server would silently start committing
        // only the index — a destructive behavior change.
        let params = WorktreeCommitParams(sessionId: "s1", message: "hi")
        let dict = encode(params)
        // Either absent, or present as NSNull — both route to
        // `opt_bool(...).unwrap_or(true)` on the server.
        if let raw = dict["stageAll"] {
            #expect(raw is NSNull, "stageAll should be absent or null, got \(raw)")
        }
        if let raw = dict["amend"] {
            #expect(raw is NSNull)
        }
        if let raw = dict["signoff"] {
            #expect(raw is NSNull)
        }
    }

    @Test("all flags encoded when explicitly set")
    func allFlagsEncoded() {
        let params = WorktreeCommitParams(
            sessionId: "s1",
            message: "body",
            amend: true,
            signoff: true,
            stageAll: false
        )
        let dict = encode(params)
        #expect(dict["amend"] as? Bool == true)
        #expect(dict["signoff"] as? Bool == true)
        #expect(dict["stageAll"] as? Bool == false)
    }

    @Test("multi-line message preserved through encoding")
    func multiLineMessageRoundTrip() {
        let msg = "subject\n\nbody line 1\nbody line 2"
        let params = WorktreeCommitParams(sessionId: "s1", message: msg)
        let dict = encode(params)
        #expect(dict["message"] as? String == msg)
    }

    @Test("message starting with dash treated as string not flag")
    func dashPrefixedMessage() {
        let params = WorktreeCommitParams(sessionId: "s1", message: "-x do thing")
        let dict = encode(params)
        #expect(dict["message"] as? String == "-x do thing")
    }
}

@Suite("WorktreeCommitResult Tests")
struct WorktreeCommitResultTests {

    @Test("decodes full server response with stats")
    func decodesWithStats() {
        let json = #"""
        {
          "success": true,
          "commitHash": "abc1234",
          "filesChanged": ["a.rs", "b.rs"],
          "insertions": 5,
          "deletions": 2
        }
        """#
        let result = try! JSONDecoder().decode(
            WorktreeCommitResult.self,
            from: json.data(using: .utf8)!
        )
        #expect(result.success == true)
        #expect(result.commitHash == "abc1234")
        #expect(result.filesChanged == ["a.rs", "b.rs"])
        #expect(result.insertions == 5)
        #expect(result.deletions == 2)
        #expect(result.error == nil)
    }

    @Test("decodes response without stats (backwards compat)")
    func decodesWithoutStats() {
        // Older servers (pre-stats) omit insertions/deletions entirely.
        // The client must still decode cleanly — treating missing stats as
        // unknown rather than zero keeps the UI honest.
        let json = #"""
        {"success": true, "commitHash": "abc1234", "filesChanged": []}
        """#
        let result = try! JSONDecoder().decode(
            WorktreeCommitResult.self,
            from: json.data(using: .utf8)!
        )
        #expect(result.success == true)
        #expect(result.insertions == nil)
        #expect(result.deletions == nil)
    }

    @Test("decodes nothing-to-commit response")
    func decodesNothingToCommit() {
        // Server returns success=true but commitHash=null when the tree
        // was clean and no amend was requested.
        let json = #"""
        {"success": true, "commitHash": null, "message": "nothing to commit"}
        """#
        let result = try! JSONDecoder().decode(
            WorktreeCommitResult.self,
            from: json.data(using: .utf8)!
        )
        #expect(result.success == true)
        #expect(result.commitHash == nil)
    }

    @Test("decodes failure response")
    func decodesFailure() {
        let json = #"""
        {"success": false, "error": "Cannot amend: no previous commit exists"}
        """#
        let result = try! JSONDecoder().decode(
            WorktreeCommitResult.self,
            from: json.data(using: .utf8)!
        )
        #expect(result.success == false)
        #expect(result.error?.contains("amend") == true)
    }
}
