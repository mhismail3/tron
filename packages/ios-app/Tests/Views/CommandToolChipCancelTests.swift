import Testing
import Foundation
import SwiftUI
@testable import TronMobile

/// Tests for the cancel-button affordance on `CommandToolChip`.
///
/// H14d wired per-tool abort into the chip: a running tool exposes a
/// tappable cancel button that invokes `onCancel`, which the call-site
/// routes to `agent.abortTool(toolCallId:)`. These tests lock in the
/// visibility contract (running-only, opt-in via `onCancel`) and the
/// enum-plumbing contract so the chip stays in sync with the
/// `MessageBubbleTapAction.cancelCommandTool` dispatch.
@Suite("CommandToolChip Cancel Button Tests")
struct CommandToolChipCancelTests {

    private func makeData(status: CommandToolStatus, id: String = "call_xyz") -> CommandToolChipData {
        CommandToolChipData(
            id: id,
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .green,
            displayName: "Bash",
            summary: "npm install",
            status: status,
            durationMs: status == .running ? nil : 250,
            arguments: "{}",
            result: status == .running ? nil : "ok",
            isResultTruncated: false
        )
    }

    // MARK: - Visibility

    @Test("Running chip with onCancel shows the cancel button")
    func runningChipWithOnCancelShowsButton() {
        let chip = CommandToolChip(
            data: makeData(status: .running),
            onTap: {},
            onCancel: {}
        )
        #expect(chip.showsCancelButton == true)
    }

    @Test("Success chip hides the cancel button even when onCancel provided")
    func successChipHidesCancelButton() {
        let chip = CommandToolChip(
            data: makeData(status: .success),
            onTap: {},
            onCancel: {}
        )
        #expect(chip.showsCancelButton == false)
    }

    @Test("Error chip hides the cancel button even when onCancel provided")
    func errorChipHidesCancelButton() {
        let chip = CommandToolChip(
            data: makeData(status: .error),
            onTap: {},
            onCancel: {}
        )
        #expect(chip.showsCancelButton == false)
    }

    @Test("Running chip without onCancel hides the cancel button")
    func runningChipWithoutOnCancelHidesButton() {
        let chip = CommandToolChip(
            data: makeData(status: .running),
            onTap: {}
        )
        #expect(chip.showsCancelButton == false)
    }

    // MARK: - Enum plumbing contract

    /// `MessageBubble.swift` constructs a cancel closure that produces
    /// `.cancelCommandTool(toolCallId: chipData.id)`. If the enum case
    /// ever changes shape, this test breaks so the call-site can be
    /// updated in lockstep.
    @Test("cancelCommandTool carries the toolCallId payload")
    func cancelCommandToolCarriesToolCallId() {
        let action: MessageBubbleTapAction = .cancelCommandTool(toolCallId: "call_abc123")
        switch action {
        case .cancelCommandTool(let id):
            #expect(id == "call_abc123")
        default:
            Issue.record("expected .cancelCommandTool payload")
        }
    }

    /// `.cancelCommandTool` must be distinct from `.commandTool` so the
    /// ChatView dispatcher doesn't accidentally open the detail sheet
    /// when the user hits cancel.
    @Test("cancelCommandTool is distinct from commandTool")
    func cancelCommandToolDistinctFromCommandTool() {
        let data = makeData(status: .running)
        let open: MessageBubbleTapAction = .commandTool(data)
        let cancel: MessageBubbleTapAction = .cancelCommandTool(toolCallId: data.id)

        switch (open, cancel) {
        case (.commandTool, .cancelCommandTool):
            // distinct cases — good
            break
        default:
            Issue.record("open vs cancel should be distinct MessageBubbleTapAction cases")
        }
    }
}
