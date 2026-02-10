import Testing
import Foundation
@testable import TronMobile

/// Tests for SheetState
/// Verifies sheet visibility flags and presentation helpers
@Suite("SheetState Tests")
struct SheetStateTests {

    // MARK: - Initial State Tests

    @Test("Initial state has all sheets hidden")
    func testInitialState_allSheetsHidden() {
        let state = SheetState()

        #expect(!state.showContextAudit)
        #expect(!state.showSessionHistory)
        #expect(!state.showSkillDetailSheet)
        #expect(!state.showCompactionDetail)
        #expect(state.skillForDetailSheet == nil)
        #expect(state.compactionDetailData == nil)
        #expect(state.notifyAppSheetData == nil)
        #expect(state.thinkingSheetContent == nil)
    }

    @Test("Initial skill detail mode is skill")
    func testInitialState_skillDetailModeIsSkill() {
        let state = SheetState()

        #expect(state.skillDetailMode == .skill)
    }

    // MARK: - Context Audit Sheet Tests

    @Test("Show context audit sets flag")
    func testShowContextAudit_setsFlag() {
        var state = SheetState()

        state.showContextAudit = true

        #expect(state.showContextAudit)
    }

    // MARK: - Session History Sheet Tests

    @Test("Show session history sets flag")
    func testShowSessionHistory_setsFlag() {
        var state = SheetState()

        state.showSessionHistory = true

        #expect(state.showSessionHistory)
    }

    // MARK: - Skill Detail Sheet Tests

    @Test("Present skill detail sets skill and mode")
    func testPresentSkillDetail_setsSkillAndMode() {
        var state = SheetState()
        let skill = Skill(
            name: "test-skill",
            displayName: "Test Skill",
            description: "Test description",
            source: .global,
            tags: nil
        )

        state.presentSkillDetail(skill, mode: .spell)

        #expect(state.skillForDetailSheet?.name == "test-skill")
        #expect(state.skillDetailMode == .spell)
        #expect(state.showSkillDetailSheet)
    }

    @Test("Present skill detail with skill mode")
    func testPresentSkillDetail_withSkillMode() {
        var state = SheetState()
        let skill = Skill(
            name: "another-skill",
            displayName: "Another Skill",
            description: "Another description",
            source: .project,
            tags: nil
        )

        state.presentSkillDetail(skill, mode: .skill)

        #expect(state.skillDetailMode == .skill)
        #expect(state.showSkillDetailSheet)
    }

    // MARK: - Compaction Detail Sheet Tests

    @Test("Present compaction detail sets data")
    func testPresentCompactionDetail_setsData() {
        var state = SheetState()

        state.presentCompactionDetail(
            tokensBefore: 100000,
            tokensAfter: 50000,
            reason: "Context limit reached",
            summary: "Summary of compaction"
        )

        #expect(state.compactionDetailData?.tokensBefore == 100000)
        #expect(state.compactionDetailData?.tokensAfter == 50000)
        #expect(state.compactionDetailData?.reason == "Context limit reached")
        #expect(state.compactionDetailData?.summary == "Summary of compaction")
        #expect(state.showCompactionDetail)
    }

    @Test("Present compaction detail with nil summary")
    func testPresentCompactionDetail_withNilSummary() {
        var state = SheetState()

        state.presentCompactionDetail(
            tokensBefore: 80000,
            tokensAfter: 40000,
            reason: "Manual trigger",
            summary: nil
        )

        #expect(state.compactionDetailData?.summary == nil)
        #expect(state.showCompactionDetail)
    }

    // MARK: - Notify App Sheet Tests

    @Test("Present notify app sets data")
    func testPresentNotifyApp_setsData() {
        var state = SheetState()
        let data = NotifyAppChipData(
            toolCallId: "tool-123",
            title: "Notification Title",
            body: "Notification body text",
            sheetContent: nil,
            status: .sending
        )

        state.presentNotifyApp(data)

        #expect(state.notifyAppSheetData?.toolCallId == "tool-123")
        #expect(state.notifyAppSheetData?.title == "Notification Title")
    }

    // MARK: - Thinking Detail Sheet Tests

    @Test("Present thinking detail sets content")
    func testPresentThinkingDetail_setsContent() {
        var state = SheetState()
        let thinkingContent = "This is the agent's thinking process..."

        state.presentThinkingDetail(thinkingContent)

        #expect(state.thinkingSheetContent == thinkingContent)
    }

    // MARK: - Dismiss Tests

    @Test("Dismiss all resets all flags and data")
    func testDismissAll_resetsAllFlagsAndData() {
        var state = SheetState()

        // Set everything
        state.showContextAudit = true
        state.showSessionHistory = true
        state.presentSkillDetail(
            Skill(
                name: "test",
                displayName: "Test",
                description: "test",
                source: .global,
                tags: nil
            ),
            mode: .spell
        )
        state.presentCompactionDetail(
            tokensBefore: 100,
            tokensAfter: 50,
            reason: "test",
            summary: "test"
        )
        state.presentNotifyApp(NotifyAppChipData(
            toolCallId: "test",
            title: "test",
            body: "test",
            sheetContent: nil,
            status: .sending
        ))
        state.presentThinkingDetail("test thinking")

        // Dismiss all
        state.dismissAll()

        // Verify all reset
        #expect(!state.showContextAudit)
        #expect(!state.showSessionHistory)
        #expect(!state.showSkillDetailSheet)
        #expect(!state.showCompactionDetail)
        #expect(state.skillForDetailSheet == nil)
        #expect(state.compactionDetailData == nil)
        #expect(state.notifyAppSheetData == nil)
        #expect(state.thinkingSheetContent == nil)
    }

    @Test("Dismiss all resets skill detail mode to skill")
    func testDismissAll_resetsSkillDetailModeToSkill() {
        var state = SheetState()
        state.skillDetailMode = .spell

        state.dismissAll()

        #expect(state.skillDetailMode == .skill)
    }

    // MARK: - Binding Helper Tests

    @Test("Skill detail sheet binding getter returns showSkillDetailSheet")
    func testSkillDetailSheetBinding_getter() {
        var state = SheetState()
        state.showSkillDetailSheet = true

        #expect(state.skillDetailSheetPresented)
    }

    @Test("Skill detail sheet binding setter clears skill when dismissed")
    func testSkillDetailSheetBinding_setterClearsOnDismiss() {
        var state = SheetState()
        let skill = Skill(
            name: "test",
            displayName: "Test",
            description: "test",
            source: .global,
            tags: nil
        )
        state.presentSkillDetail(skill, mode: .skill)

        state.skillDetailSheetPresented = false

        #expect(!state.showSkillDetailSheet)
        #expect(state.skillForDetailSheet == nil)
    }

    @Test("Compaction detail sheet binding getter")
    func testCompactionDetailSheetBinding_getter() {
        var state = SheetState()
        state.showCompactionDetail = true

        #expect(state.compactionDetailPresented)
    }

    @Test("Compaction detail sheet binding setter clears data when dismissed")
    func testCompactionDetailSheetBinding_setterClearsOnDismiss() {
        var state = SheetState()
        state.presentCompactionDetail(
            tokensBefore: 100,
            tokensAfter: 50,
            reason: "test",
            summary: nil
        )

        state.compactionDetailPresented = false

        #expect(!state.showCompactionDetail)
        #expect(state.compactionDetailData == nil)
    }

    @Test("Notify app sheet binding getter returns non-nil check")
    func testNotifyAppSheetBinding_getter() {
        var state = SheetState()
        state.presentNotifyApp(NotifyAppChipData(
            toolCallId: "test",
            title: "test",
            body: "test",
            sheetContent: nil,
            status: .sending
        ))

        #expect(state.notifyAppSheetPresented)
    }

    @Test("Notify app sheet binding setter clears data when dismissed")
    func testNotifyAppSheetBinding_setterClearsOnDismiss() {
        var state = SheetState()
        state.presentNotifyApp(NotifyAppChipData(
            toolCallId: "test",
            title: "test",
            body: "test",
            sheetContent: nil,
            status: .sending
        ))

        state.notifyAppSheetPresented = false

        #expect(state.notifyAppSheetData == nil)
    }

    @Test("Thinking sheet binding getter returns non-nil check")
    func testThinkingSheetBinding_getter() {
        var state = SheetState()
        state.presentThinkingDetail("thinking content")

        #expect(state.thinkingSheetPresented)
    }

    @Test("Thinking sheet binding setter clears content when dismissed")
    func testThinkingSheetBinding_setterClearsOnDismiss() {
        var state = SheetState()
        state.presentThinkingDetail("thinking content")

        state.thinkingSheetPresented = false

        #expect(state.thinkingSheetContent == nil)
    }
}
