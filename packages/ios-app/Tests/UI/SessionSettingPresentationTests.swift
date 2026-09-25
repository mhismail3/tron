import Testing
@testable import TronMobile

@Suite("Session setting presentation")
struct SessionSettingPresentationTests {
    @Test("extra-high variants share a readable label without changing canonical values", arguments: [
        "xhigh", "Xhigh", "XHigh", "XHIGH", "x-high", "extra_high", "extra-high", "Extra High", " extra high "
    ])
    func extraHighLabels(_ level: String) {
        #expect(ThinkingLevelPresentation.title(level) == "Extra High")
        let item = TranscriptItem.thinkingChange(.init(
            id: "thinking", parentId: nil, timestamp: "2026-01-01T00:00:00Z", kind: .thinkingChange, level: level
        ))
        #expect(ChatNotificationPresentation.canonical(item, globalOrdinal: 0)?.detail == "Extra High")
        #expect(item.level == level)
    }

    @Test("history formats only typed thinking changes, not authored prompts or labels")
    func historyLabels() {
        func node(kind: String, label: String? = nil) -> SessionTreeNode {
            SessionTreeNode(id: "entry", parentId: nil, timestamp: "2026-01-01T00:00:00Z", kind: kind,
                            label: label, preview: "xhigh", role: nil, depth: 0, childCount: 0, isCurrentPath: true)
        }
        // The typed level is humanized for a thinking-level entry only.
        #expect(SessionHistoryPreview.title(node(kind: "thinkingChange")) == "Extra High")
        #expect(SessionHistoryPreview.preview(node(kind: "thinkingChange")) == "Extra High")
        #expect(SessionHistoryPreview.title(node(kind: "message")) == "xhigh")
        // A bookmark label is its own history-row line, so the typed preview stays
        // the title and authored label text is never rewritten by the
        // thinking-level formatter. (An earlier presentation put the label in the
        // title, which is why this case previously expected the label itself.)
        #expect(SessionHistoryPreview.title(node(kind: "thinkingChange", label: "xhigh")) == "Extra High")
        #expect(SessionHistoryPreview.title(node(kind: "thinkingChange", label: "investigate the flake"))
            == SessionHistoryPreview.title(node(kind: "thinkingChange")))
    }

    @Test("progress revisions are causal fences, not Manage Session visual changes")
    func progressRevisionDoesNotInvalidateSemanticPresentation() throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_810).openingTail(targetEncodedBytes: 4_096)
        snapshot.revision = 10
        let before = SessionContextPresentation(snapshot)
        snapshot.revision = 11
        let progress = SessionContextPresentation(snapshot)
        #expect(before == progress)
        #expect(snapshot.revision == 11)
        let pending = SessionPendingSetting("high", snapshot: before)
        #expect(pending.admitted(in: progress)?.value == "high")
    }

    @Test("deferred Thinking admission rejects replacement identity, busy phases and changed choices")
    func thinkingEditorAdmission() throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_816).openingTail(targetEncodedBytes: 4_096)
        snapshot.phase = .idle
        snapshot.availableThinkingLevels = ["off", "high", "xhigh"]
        let original = snapshot
        let scope = SessionThinkingEditScope(SessionContextPresentation(snapshot))
        #expect(scope.admits("xhigh", in: SessionContextPresentation(snapshot)))
        #expect(!scope.admits("medium", in: SessionContextPresentation(snapshot)))
        snapshot.revision += 1
        snapshot.thinkingLevel = "xhigh" // Receipt acknowledgement is not a new scope.
        #expect(scope == SessionThinkingEditScope(SessionContextPresentation(snapshot)))
        for phase in [SessionPhase.running, .compacting, .retrying] {
            snapshot.phase = phase
            #expect(!scope.admits("xhigh", in: SessionContextPresentation(snapshot)))
        }
        snapshot = original
        snapshot.model = ModelRef(provider: "other", id: "model")
        #expect(!scope.admits("xhigh", in: SessionContextPresentation(snapshot)))
        snapshot = original
        snapshot.runtimeGeneration = "new-runtime"
        #expect(!scope.admits("xhigh", in: SessionContextPresentation(snapshot)))
        snapshot = original
        snapshot.sessionId = "other-session"
        #expect(!scope.admits("xhigh", in: SessionContextPresentation(snapshot)))
        snapshot = original
        snapshot.availableThinkingLevels = ["off", "xhigh"]
        #expect(!scope.admits("xhigh", in: SessionContextPresentation(snapshot)))
    }

    @Test("a pending slider choice is visible before authority changes, then retires on confirmation")
    func immediateSelection() throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_811).openingTail(targetEncodedBytes: 4_096)
        snapshot.thinkingLevel = "high"
        let before = SessionContextPresentation(snapshot)
        let pending = SessionPendingSetting("xhigh", snapshot: before)
        #expect(pending.admitted(in: before)?.value == "xhigh")
        #expect(before.thinkingLevel == "high")
        #expect(pending.reconciled(authoritative: before.thinkingLevel, snapshot: before) == pending)

        snapshot.thinkingLevel = "xhigh"
        let confirmed = SessionContextPresentation(snapshot)
        #expect(pending.reconciled(authoritative: confirmed.thinkingLevel, snapshot: confirmed) == pending)
        #expect(pending.confirming(pending.id).reconciled(authoritative: confirmed.thinkingLevel, snapshot: confirmed) == nil)
        // Receipt and authoritative event may arrive in either order.
        let acknowledged = pending.confirming(pending.id)
        #expect(acknowledged.reconciled(authoritative: before.thinkingLevel, snapshot: before) == acknowledged)
    }

    @Test("reset-to-default is a pending choice, not the absence of one")
    func resetSelection() throws {
        let snapshot = SessionContextPresentation(try SessionScenarioBuilder(seed: 7_812).openingTail(targetEncodedBytes: 4_096))
        let pending = SessionPendingSetting<Int?>(nil, snapshot: snapshot)
        #expect(pending.admitted(in: snapshot) != nil)
        #expect(pending.value == nil)
        #expect(pending.reconciled(authoritative: 1_048_576, snapshot: snapshot) == pending)
        #expect(pending.confirming(pending.id).reconciled(authoritative: nil, snapshot: snapshot) == nil)
    }

    @Test("pending choices cannot outlive their model, runtime, or session projection")
    func scopeReplacement() throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_813).openingTail(targetEncodedBytes: 4_096)
        let before = SessionContextPresentation(snapshot)
        let pending = SessionPendingSetting<Int?>(500_000, snapshot: before)
        snapshot.model = ModelRef(provider: "different-provider", id: "different-model")
        let newModel = SessionContextPresentation(snapshot)
        #expect(pending.admitted(in: newModel) == nil)
        #expect(pending.reconciled(authoritative: nil, snapshot: newModel) == nil)
        snapshot.model = before.model
        snapshot.runtimeGeneration = "replacement-runtime"
        let newRuntime = SessionContextPresentation(snapshot)
        #expect(pending.admitted(in: newRuntime) == nil)
        #expect(pending.reconciled(authoritative: nil, snapshot: newRuntime) == nil)
        snapshot.runtimeGeneration = before.runtimeGeneration
        snapshot.sessionId = "replacement-session"
        let newSession = SessionContextPresentation(snapshot)
        #expect(pending.admitted(in: newSession) == nil)
        #expect(pending.reconciled(authoritative: nil, snapshot: newSession) == nil)
        #expect(pending.reconciled(authoritative: nil, snapshot: nil) == nil)
    }

    @Test("returning to the old value cannot be confirmed by an earlier command or unrelated snapshot")
    func returningToOldValue() throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_815).openingTail(targetEncodedBytes: 4_096)
        snapshot.thinkingLevel = "high"
        let before = SessionContextPresentation(snapshot)
        let first = SessionPendingSetting("xhigh", snapshot: before)
        let newest = SessionPendingSetting("high", snapshot: before)
        #expect(newest.reconciled(authoritative: "high", snapshot: before) == newest)
        #expect(newest.confirming(first.id).reconciled(authoritative: "high", snapshot: before) == newest)
        #expect(newest.confirming(newest.id).reconciled(authoritative: "high", snapshot: before) == nil)
    }

    @Test("failure rolls back only its exact request, including repeated values")
    func lateFailure() throws {
        let snapshot = SessionContextPresentation(try SessionScenarioBuilder(seed: 7_814).openingTail(targetEncodedBytes: 4_096))
        let first = SessionPendingSetting("xhigh", snapshot: snapshot)
        let second = SessionPendingSetting("low", snapshot: snapshot)
        let newest = SessionPendingSetting("xhigh", snapshot: snapshot)
        #expect(first.rejecting(first.id) == nil)
        #expect(second.rejecting(first.id) == second)
        #expect(newest.rejecting(first.id) == newest)
        #expect(newest.rejecting(newest.id) == nil)
    }
}
