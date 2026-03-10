import Testing
import SwiftUI
@testable import TronMobile

@Suite("Status Display Properties")
@MainActor
struct StatusDisplayTests {

    // MARK: - CommandToolStatus

    @Test("CommandToolStatus label returns expected values")
    func commandToolStatusLabel() {
        #expect(CommandToolStatus.running.label == "Running")
        #expect(CommandToolStatus.success.label == "Completed")
        #expect(CommandToolStatus.error.label == "Failed")
    }

    @Test("CommandToolStatus iconName returns expected values")
    func commandToolStatusIconName() {
        #expect(CommandToolStatus.running.iconName == "")
        #expect(CommandToolStatus.success.iconName == "checkmark.circle.fill")
        #expect(CommandToolStatus.error.iconName == "xmark.circle.fill")
    }

    // MARK: - SubagentStatus

    @Test("SubagentStatus color returns expected values")
    func subagentStatusColor() {
        #expect(SubagentStatus.running.color == .tronAmber)
        #expect(SubagentStatus.completed.color == .tronSuccess)
        #expect(SubagentStatus.failed.color == .tronError)
    }

    @Test("SubagentStatus label returns non-empty strings")
    func subagentStatusLabel() {
        #expect(!SubagentStatus.running.label.isEmpty)
        #expect(!SubagentStatus.completed.label.isEmpty)
        #expect(!SubagentStatus.failed.label.isEmpty)
    }

    @Test("SubagentStatus iconName returns expected values")
    func subagentStatusIconName() {
        #expect(SubagentStatus.running.iconName == "")
        #expect(SubagentStatus.completed.iconName == "checkmark.circle.fill")
        #expect(SubagentStatus.failed.iconName == "xmark.circle.fill")
    }

    // MARK: - NotifyAppStatus

    @Test("NotifyAppStatus color returns expected values")
    func notifyAppStatusColor() {
        #expect(NotifyAppStatus.sending.color == .tronAmber)
        #expect(NotifyAppStatus.sent.color == .tronSuccess)
        #expect(NotifyAppStatus.failed.color == .tronError)
    }

    @Test("NotifyAppStatus label returns expected values")
    func notifyAppStatusLabel() {
        #expect(NotifyAppStatus.sending.label == "Sending")
        #expect(NotifyAppStatus.sent.label == "Sent")
        #expect(NotifyAppStatus.failed.label == "Failed")
    }

    @Test("NotifyAppStatus iconName uses custom bell icons")
    func notifyAppStatusIconName() {
        #expect(NotifyAppStatus.sending.iconName == "")
        #expect(NotifyAppStatus.sent.iconName == "bell.badge.fill")
        #expect(NotifyAppStatus.failed.iconName == "bell.slash.fill")
    }

    // MARK: - QueryAgentStatus

    @Test("QueryAgentStatus color returns expected values")
    func queryAgentStatusColor() {
        #expect(QueryAgentStatus.querying.color == .tronIndigo)
        #expect(QueryAgentStatus.success.color == .tronIndigo)
        #expect(QueryAgentStatus.error.color == .tronError)
    }

    @Test("QueryAgentStatus label returns expected values")
    func queryAgentStatusLabel() {
        #expect(QueryAgentStatus.querying.label == "Querying")
        #expect(QueryAgentStatus.success.label == "Completed")
        #expect(QueryAgentStatus.error.label == "Failed")
    }

    // MARK: - WaitForAgentsStatus

    @Test("WaitForAgentsStatus color returns expected values")
    func waitForAgentsStatusColor() {
        #expect(WaitForAgentsStatus.waiting.color == .tronTeal)
        #expect(WaitForAgentsStatus.completed.color == .tronTeal)
        #expect(WaitForAgentsStatus.timedOut.color == .tronAmber)
        #expect(WaitForAgentsStatus.error.color == .tronError)
    }

    @Test("WaitForAgentsStatus label returns expected values")
    func waitForAgentsStatusLabel() {
        #expect(WaitForAgentsStatus.waiting.label == "Waiting")
        #expect(WaitForAgentsStatus.completed.label == "Completed")
        #expect(WaitForAgentsStatus.timedOut.label == "Timed Out")
        #expect(WaitForAgentsStatus.error.label == "Failed")
    }

    @Test("WaitForAgentsStatus iconName includes custom timeout icon")
    func waitForAgentsStatusIconName() {
        #expect(WaitForAgentsStatus.timedOut.iconName == "clock.badge.exclamationmark")
    }

    // MARK: - RenderAppUIStatus

    @Test("RenderAppUIStatus color returns expected values")
    func renderAppUIStatusColor() {
        #expect(RenderAppUIStatus.rendering.color == .tronAmber)
        #expect(RenderAppUIStatus.complete.color == .tronSuccess)
        #expect(RenderAppUIStatus.error.color == .tronError)
    }

    @Test("RenderAppUIStatus label returns expected values")
    func renderAppUIStatusLabel() {
        #expect(RenderAppUIStatus.rendering.label == "Rendering")
        #expect(RenderAppUIStatus.complete.label == "Completed")
        #expect(RenderAppUIStatus.error.label == "Failed")
    }

    // MARK: - TaskManagerChipStatus

    @Test("TaskManagerChipStatus label returns expected values")
    func taskManagerStatusLabel() {
        #expect(TaskManagerChipStatus.running.label == "Running")
        #expect(TaskManagerChipStatus.completed.label == "Completed")
    }

    @Test("TaskManagerChipStatus iconName returns expected values")
    func taskManagerStatusIconName() {
        #expect(TaskManagerChipStatus.running.iconName == "")
        #expect(TaskManagerChipStatus.completed.iconName == "checklist")
    }
}
