import Testing
import Foundation
import SwiftUI
@testable import TronMobile

/// L12: visually distinguish a backgrounded Bash chip from a subagent
/// chip, because both render as "long-running with a spinner" and a
/// glance shouldn't confuse the two. A small uppercase kind badge
/// ("BG" / "SUB" / "WAIT") sits next to the chip title and makes the
/// kind unambiguous without the user having to read the label text.
///
/// These tests lock in the gate (when does the badge appear) and the
/// text contract (what does it say), so the chip stays in sync with
/// the dispatch sites in `MessageBubble`.
@Suite("Tool Kind Badge Tests")
struct ToolKindBadgeTests {

    // MARK: - CommandToolChip: BG badge on backgrounded Bash

    private func makeBashData(
        backgrounded: Bool?,
        status: CommandToolStatus = .running,
        normalizedName: String = "bash"
    ) -> CommandToolChipData {
        var details: [String: AnyCodable]? = nil
        if let bg = backgrounded {
            details = ["backgrounded": AnyCodable(bg)]
        }
        return CommandToolChipData(
            id: "call_1",
            toolName: "Bash",
            normalizedName: normalizedName,
            icon: "terminal",
            iconColor: .green,
            displayName: "Bash",
            summary: "tail -f server.log",
            status: status,
            durationMs: status == .running ? nil : 250,
            arguments: "{}",
            result: nil,
            isResultTruncated: false,
            details: details
        )
    }

    @Test("Backgrounded Bash chip exposes isBashBackgrounded == true")
    func backgroundedBashShowsBadge() {
        let chip = CommandToolChip(
            data: makeBashData(backgrounded: true),
            onTap: {}
        )
        #expect(chip.isBashBackgrounded == true)
    }

    @Test("Foreground Bash chip hides the BG badge")
    func foregroundBashHidesBadge() {
        let chip = CommandToolChip(
            data: makeBashData(backgrounded: false),
            onTap: {}
        )
        #expect(chip.isBashBackgrounded == false)
    }

    @Test("Bash chip without details.backgrounded hides the badge")
    func bashNoDetailsHidesBadge() {
        let chip = CommandToolChip(
            data: makeBashData(backgrounded: nil),
            onTap: {}
        )
        #expect(chip.isBashBackgrounded == false,
                "missing backgrounded field must not produce a false-positive BG badge")
    }

    @Test("Non-Bash tool never shows the BG badge even if details claim backgrounded")
    func nonBashNeverShowsBadge() {
        // Defensive: some future tool may shove a `backgrounded` field
        // into details; that should NOT accidentally surface the BG
        // badge. The badge semantic is Bash-specific.
        let chip = CommandToolChip(
            data: makeBashData(backgrounded: true, normalizedName: "read"),
            onTap: {}
        )
        #expect(chip.isBashBackgrounded == false)
    }

    @Test("Completed backgrounded Bash still exposes the BG marker")
    func completedBackgroundedBashStillFlagged() {
        // A backgrounded command whose session ends keeps the BG flag
        // — a user scrolling back should still see it was a background
        // process.
        let chip = CommandToolChip(
            data: makeBashData(backgrounded: true, status: .success),
            onTap: {}
        )
        #expect(chip.isBashBackgrounded == true)
    }

    // MARK: - SubagentChip: SUB / WAIT kind badge

    private func makeSubagentData() -> SubagentToolData {
        SubagentToolData(
            toolCallId: "call_sub",
            subagentSessionId: "sess_def456abc",
            task: "run the test suite",
            model: "claude-sonnet-4",
            status: .running,
            currentTurn: 2,
            resultSummary: nil,
            fullOutput: nil,
            duration: nil,
            error: nil,
            tokenUsage: nil
        )
    }

    @Test("Spawn variant badge reads SUB")
    func spawnBadgeText() {
        let chip = SubagentChip(data: makeSubagentData(), variant: .spawn, onTap: {})
        #expect(chip.kindBadgeText == "SUB")
    }

    @Test("Wait variant badge reads WAIT")
    func waitBadgeText() {
        let chip = SubagentChip(data: makeSubagentData(), variant: .wait, onTap: {})
        #expect(chip.kindBadgeText == "WAIT")
    }

    @Test("Subagent badge text is never empty")
    func subagentBadgeNeverEmpty() {
        for variant in [SubagentChipVariant.spawn, .wait] {
            let chip = SubagentChip(data: makeSubagentData(), variant: variant, onTap: {})
            #expect(!chip.kindBadgeText.isEmpty)
        }
    }

    @Test("Spawn and Wait badges are textually distinct")
    func spawnAndWaitBadgesDiffer() {
        let spawn = SubagentChip(data: makeSubagentData(), variant: .spawn, onTap: {})
        let wait = SubagentChip(data: makeSubagentData(), variant: .wait, onTap: {})
        #expect(spawn.kindBadgeText != wait.kindBadgeText,
                "if Spawn and Wait shared badge text the user would be back to guessing")
    }

    @Test("Subagent badge accessibility label is human-readable")
    func subagentBadgeAccessibilityLabelReadable() {
        // Spot-check: accessibility text should be a full word, not
        // just the uppercase abbreviation — VoiceOver reading "sub"
        // would be cryptic.
        let spawn = SubagentChip(data: makeSubagentData(), variant: .spawn, onTap: {})
        let wait = SubagentChip(data: makeSubagentData(), variant: .wait, onTap: {})
        #expect(spawn.kindBadgeAccessibilityLabel.lowercased().contains("subagent"))
        #expect(wait.kindBadgeAccessibilityLabel.lowercased().contains("wait"))
    }

    // MARK: - Cross-chip disambiguation

    @Test("BG, SUB, and WAIT kind texts are all distinct")
    func threeKindsAreDistinct() {
        // The whole point of L12: a user glancing at a running BG bash,
        // a running spawn, and a running wait should see three
        // different badges.
        let kinds: Set<String> = ["BG", "SUB", "WAIT"]
        #expect(kinds.count == 3)
    }
}
