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

    // MARK: - isOnBaseBranch

    /// Helper that constructs a `WorktreeInfo` with the fields relevant to
    /// `isOnBaseBranch` and sensible defaults for everything else.
    private func worktree(
        branch: String,
        baseBranch: String?,
        isolated: Bool = true
    ) -> WorktreeInfo {
        WorktreeInfo(
            isolated: isolated, branch: branch,
            baseCommit: "abc", path: "/tmp", baseBranch: baseBranch,
            repoRoot: nil, hasUncommittedChanges: nil, commitCount: nil, isMerged: nil
        )
    }

    @Test("isOnBaseBranch true when isolated on main and base is main")
    func isOnBaseBranchIsolatedOnBase() {
        #expect(worktree(branch: "main", baseBranch: "main").isOnBaseBranch == true)
    }

    @Test("isOnBaseBranch false when on a session branch")
    func isOnBaseBranchSessionBranch() {
        #expect(worktree(branch: "session/sess_abc12345", baseBranch: "main").isOnBaseBranch == false)
    }

    @Test("isOnBaseBranch false when isolated and baseBranch is nil (conservative)")
    func isOnBaseBranchIsolatedNilBase() {
        // We cannot prove the current branch is the base branch when the
        // server didn't record one — default to showing the icon.
        #expect(worktree(branch: "main", baseBranch: nil).isOnBaseBranch == false)
    }

    @Test("isOnBaseBranch false on follow-up branch after finalize")
    func isOnBaseBranchFollowUp() {
        // Post-finalize with rebranch=true — the session moves to a new
        // `<old>-follow-up` branch on an isolated worktree, which IS a
        // distinct session branch. The toolbar icon must keep showing.
        let info = worktree(branch: "session/sess_abc12345-follow-up", baseBranch: "main")
        #expect(info.isOnBaseBranch == false)
    }

    @Test("isOnBaseBranch true for isolated non-main base branch (e.g. develop)")
    func isOnBaseBranchNonMainBase() {
        #expect(worktree(branch: "develop", baseBranch: "develop").isOnBaseBranch == true)
    }

    @Test("isOnBaseBranch is case sensitive (git refs are case sensitive)")
    func isOnBaseBranchCaseSensitive() {
        #expect(worktree(branch: "Main", baseBranch: "main").isOnBaseBranch == false)
    }

    // MARK: - Passthrough mode (isolated == false)

    @Test("isOnBaseBranch true for passthrough session (post-finalize server state)")
    func isOnBaseBranchPassthroughPostFinalize() {
        // After worktree.finalizeSession releases the worktree, the server's
        // passthrough_status hardcodes base_branch=None and returns
        // isolated=false. No session-specific branch exists — toolbar chip
        // must hide. This is the bug the user reported: icon lingered on
        // merged sessions despite the sheet showing "main".
        let info = worktree(branch: "main", baseBranch: nil, isolated: false)
        #expect(info.isOnBaseBranch == true)
    }

    @Test("isOnBaseBranch true for fresh passthrough session on main")
    func isOnBaseBranchPassthroughFresh() {
        // A fresh session that never acquired isolation also arrives as
        // isolated=false, baseBranch=nil. Same UI treatment.
        let info = worktree(branch: "main", baseBranch: nil, isolated: false)
        #expect(info.isOnBaseBranch == true)
    }

    @Test("isOnBaseBranch true for passthrough on non-main branch")
    func isOnBaseBranchPassthroughNonMain() {
        // Even if the user's repo is checked out on a feature branch when
        // a passthrough session starts, passthrough sessions have no notion
        // of a session-specific branch. Chip should hide regardless of name.
        let info = worktree(branch: "feature-x", baseBranch: nil, isolated: false)
        #expect(info.isOnBaseBranch == true)
    }

    @Test("isOnBaseBranch true for passthrough on detached HEAD")
    func isOnBaseBranchPassthroughDetached() {
        // Server's passthrough_status falls back to short commit hash when
        // current_branch fails (detached HEAD). Still no session branch.
        let info = worktree(branch: "abc1234", baseBranch: nil, isolated: false)
        #expect(info.isOnBaseBranch == true)
    }

    @Test("canQueryRepoMetadata requires source-control checkout and repo root")
    func canQueryRepoMetadataRequiresWorktreeRepoRoot() {
        let info = WorktreeInfo(
            isolated: true,
            branch: "session/sess_abc12345",
            baseCommit: "abc",
            path: "/tmp/session",
            baseBranch: "main",
            repoRoot: "/tmp/repo",
            hasUncommittedChanges: nil,
            commitCount: nil,
            isMerged: nil
        )
        #expect(WorktreeGetStatusResult(hasWorktree: true, worktree: info).canQueryRepoMetadata == true)
        #expect(WorktreeGetStatusResult(hasWorktree: false, worktree: info).canQueryRepoMetadata == false)

        let passthrough = WorktreeInfo(
            isolated: false,
            branch: "main",
            baseCommit: "abc",
            path: "/tmp/repo",
            baseBranch: nil,
            repoRoot: "/tmp/repo",
            hasUncommittedChanges: nil,
            commitCount: nil,
            isMerged: nil
        )
        #expect(WorktreeGetStatusResult(hasWorktree: true, worktree: passthrough).canQueryRepoMetadata == true)

        let missingRepo = WorktreeInfo(
            isolated: true,
            branch: "session/sess_abc12345",
            baseCommit: "abc",
            path: "/tmp/session",
            baseBranch: "main",
            repoRoot: nil,
            hasUncommittedChanges: nil,
            commitCount: nil,
            isMerged: nil
        )
        #expect(WorktreeGetStatusResult(hasWorktree: true, worktree: missingRepo).canQueryRepoMetadata == false)

        let emptyRepo = WorktreeInfo(
            isolated: true,
            branch: "session/sess_abc12345",
            baseCommit: "abc",
            path: "/tmp/session",
            baseBranch: "main",
            repoRoot: "   ",
            hasUncommittedChanges: nil,
            commitCount: nil,
            isMerged: nil
        )
        #expect(WorktreeGetStatusResult(hasWorktree: true, worktree: emptyRepo).canQueryRepoMetadata == false)
    }
}

@Suite("RepoDivergence Tests")
struct RepoDivergenceTests {

    @Test("hasOrigin is required by the current engine contract")
    func hasOriginIsRequired() {
        let missingHasOrigin = Data(#"{"aheadMain":0,"behindMain":0,"aheadOrigin":0,"behindOrigin":0}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RepoDivergence.self, from: missingHasOrigin)
        }
    }

    @Test("hasOrigin decodes explicit false")
    func hasOriginExplicitFalse() throws {
        let data = Data(#"{"aheadMain":0,"behindMain":0,"aheadOrigin":null,"behindOrigin":null,"hasOrigin":false}"#.utf8)
        let divergence = try JSONDecoder().decode(RepoDivergence.self, from: data)
        #expect(divergence.hasOrigin == false)
        #expect(divergence.aheadOrigin == nil)
        #expect(divergence.behindOrigin == nil)
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
        // I7: stageAll is a required field on the wire. A minimal call
        // still carries it explicitly — there is no server-side default.
        let params = WorktreeCommitParams(sessionId: "s1", message: "hi", stageAll: true)
        let dict = encode(params)
        #expect(dict["sessionId"] as? String == "s1")
        #expect(dict["message"] as? String == "hi")
        #expect(dict["stageAll"] as? Bool == true)
    }

    @Test("stageAll=true is encoded explicitly")
    func stageAllTrueEncoded() {
        // I7: omitting the flag on the wire is no longer legal. Even the
        // "commit everything" case must put `stageAll: true` in the JSON
        // so the server's require_bool check passes.
        let params = WorktreeCommitParams(sessionId: "s1", message: "hi", stageAll: true)
        let dict = encode(params)
        #expect(dict["stageAll"] as? Bool == true,
                "stageAll:true must be present, not omitted")
    }

    @Test("stageAll=false is encoded explicitly")
    func stageAllFalseEncoded() {
        let params = WorktreeCommitParams(sessionId: "s1", message: "hi", stageAll: false)
        let dict = encode(params)
        #expect(dict["stageAll"] as? Bool == false)
    }

    @Test("optional flags omitted when nil")
    func optionalFlagsOmittedWhenNil() {
        // amend and signoff remain opt-in — callers that don't care skip
        // them entirely so the server sees a lean payload.
        let params = WorktreeCommitParams(sessionId: "s1", message: "hi", stageAll: true)
        let dict = encode(params)
        if let raw = dict["amend"] {
            #expect(raw is NSNull, "amend should be absent or NSNull when not set, got \(raw)")
        }
        if let raw = dict["signoff"] {
            #expect(raw is NSNull, "signoff should be absent or NSNull when not set, got \(raw)")
        }
    }

    @Test("all flags encoded when explicitly set")
    func allFlagsEncoded() {
        let params = WorktreeCommitParams(
            sessionId: "s1",
            message: "body",
            stageAll: false,
            amend: true,
            signoff: true
        )
        let dict = encode(params)
        #expect(dict["amend"] as? Bool == true)
        #expect(dict["signoff"] as? Bool == true)
        #expect(dict["stageAll"] as? Bool == false)
    }

    @Test("multi-line message preserved through encoding")
    func multiLineMessageRoundTrip() {
        let msg = "subject\n\nbody line 1\nbody line 2"
        let params = WorktreeCommitParams(sessionId: "s1", message: msg, stageAll: true)
        let dict = encode(params)
        #expect(dict["message"] as? String == msg)
    }

    @Test("message starting with dash treated as string not flag")
    func dashPrefixedMessage() {
        let params = WorktreeCommitParams(sessionId: "s1", message: "-x do thing", stageAll: true)
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
        #expect(result.commitHash == "abc1234")
        #expect(result.filesChanged == ["a.rs", "b.rs"])
        #expect(result.insertions == 5)
        #expect(result.deletions == 2)
    }

    @Test("decodes response without stats when current server cannot compute them")
    func decodesWithoutStats() {
        // Some server paths (e.g. amending a root commit) cannot compute
        // line stats and omit insertions/deletions entirely. The client
        // must still decode cleanly — treating missing stats as unknown
        // rather than zero keeps the UI honest.
        let json = #"""
        {"commitHash": "abc1234", "filesChanged": []}
        """#
        let result = try! JSONDecoder().decode(
            WorktreeCommitResult.self,
            from: json.data(using: .utf8)!
        )
        #expect(result.commitHash == "abc1234")
        #expect(result.insertions == nil)
        #expect(result.deletions == nil)
    }

    @Test("decodes nothing-to-commit response")
    func decodesNothingToCommit() {
        // Server returns commitHash=null when the tree was clean and no
        // amend was requested. Failures throw a typed EngineProtocolError instead.
        let json = #"""
        {"commitHash": null, "message": "nothing to commit"}
        """#
        let result = try! JSONDecoder().decode(
            WorktreeCommitResult.self,
            from: json.data(using: .utf8)!
        )
        #expect(result.commitHash == nil)
    }
}
