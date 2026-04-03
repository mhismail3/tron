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

}
