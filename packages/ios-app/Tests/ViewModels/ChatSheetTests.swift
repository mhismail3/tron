import Testing
import Foundation
@testable import TronMobile

/// Tests for ChatSheet enum and SheetCoordinator
/// Verifies sheet identification, presentation, and dismissal logic
@Suite("ChatSheet Tests")
struct ChatSheetTests {

    // MARK: - ChatSheet Enum Identity Tests

    @Test("Safari sheets with different URLs have different ids")
    func testSafariDifferentURLsHaveDifferentIds() {
        let url1 = URL(string: "https://example.com")!
        let url2 = URL(string: "https://other.com")!

        let sheet1 = ChatSheet.safari(url1)
        let sheet2 = ChatSheet.safari(url2)

        #expect(sheet1.id != sheet2.id)
    }

    @Test("Safari sheets with same URL have same id")
    func testSafariSameURLHaveSameId() {
        let url = URL(string: "https://example.com")!

        let sheet1 = ChatSheet.safari(url)
        let sheet2 = ChatSheet.safari(url)

        #expect(sheet1.id == sheet2.id)
    }

    @Test("Browser sheet has consistent id")
    func testBrowserSheetId() {
        let sheet1 = ChatSheet.browser
        let sheet2 = ChatSheet.browser

        #expect(sheet1.id == sheet2.id)
        #expect(sheet1.id == "browser")
    }

    @Test("Settings sheet has consistent id")
    func testSettingsSheetId() {
        let sheet = ChatSheet.settings

        #expect(sheet.id == "settings")
    }

    @Test("Context audit sheet has consistent id")
    func testContextAuditSheetId() {
        let sheet = ChatSheet.contextAudit

        #expect(sheet.id == "contextAudit")
    }

    @Test("Session history sheet has consistent id")
    func testSessionHistorySheetId() {
        let sheet = ChatSheet.sessionHistory

        #expect(sheet.id == "sessionHistory")
    }

    @Test("Skill detail sheets with different skills have different ids")
    func testSkillDetailDifferentSkillsHaveDifferentIds() {
        let skill1 = Skill(
            name: "skill1",
            displayName: "Skill 1",
            description: "Test",
            source: .global,
            tags: nil
        )
        let skill2 = Skill(
            name: "skill2",
            displayName: "Skill 2",
            description: "Test",
            source: .global,
            tags: nil
        )

        let sheet1 = ChatSheet.skillDetail(skill1, .skill)
        let sheet2 = ChatSheet.skillDetail(skill2, .skill)

        #expect(sheet1.id != sheet2.id)
    }

    @Test("Skill detail same skill different modes have same id")
    func testSkillDetailSameSkillDifferentModes() {
        let skill = Skill(
            name: "test",
            displayName: "Test",
            description: "Test",
            source: .global,
            tags: nil
        )

        let sheet1 = ChatSheet.skillDetail(skill, .skill)
        let sheet2 = ChatSheet.skillDetail(skill, .spell)

        // Same skill = same id (mode doesn't affect identity)
        #expect(sheet1.id == sheet2.id)
    }

    @Test("Compaction detail has consistent id")
    func testCompactionDetailId() {
        let data1 = CompactionDetailData(tokensBefore: 100, tokensAfter: 50, reason: "test", summary: nil)
        let data2 = CompactionDetailData(tokensBefore: 200, tokensAfter: 100, reason: "other", summary: "sum")

        let sheet1 = ChatSheet.compactionDetail(data1)
        let sheet2 = ChatSheet.compactionDetail(data2)

        // All compaction sheets share same id (only one can show at a time)
        #expect(sheet1.id == sheet2.id)
        #expect(sheet1.id == "compaction")
    }

    @Test("Ask user question sheet has consistent id")
    func testAskUserQuestionId() {
        let sheet = ChatSheet.askUserQuestion

        #expect(sheet.id == "askUserQuestion")
    }

    @Test("Subagent detail sheet has consistent id")
    func testSubagentDetailId() {
        let sheet = ChatSheet.subagentDetail

        #expect(sheet.id == "subagent")
    }

    @Test("UI canvas sheet has consistent id")
    func testUICanvasId() {
        let sheet = ChatSheet.uiCanvas

        #expect(sheet.id == "uiCanvas")
    }

    @Test("Task list sheet has consistent id")
    func testTaskListId() {
        let sheet = ChatSheet.taskList

        #expect(sheet.id == "taskList")
    }

    @Test("Notify app sheets with different data have different ids")
    func testNotifyAppDifferentDataHaveDifferentIds() {
        let data1 = NotifyAppChipData(
            toolCallId: "tool1",
            title: "Title 1",
            body: "Body",
            sheetContent: nil,
            status: .sending
        )
        let data2 = NotifyAppChipData(
            toolCallId: "tool2",
            title: "Title 2",
            body: "Body",
            sheetContent: nil,
            status: .sending
        )

        let sheet1 = ChatSheet.notifyApp(data1)
        let sheet2 = ChatSheet.notifyApp(data2)

        #expect(sheet1.id != sheet2.id)
    }

    @Test("Thinking detail has consistent id regardless of content")
    func testThinkingDetailId() {
        let sheet1 = ChatSheet.thinkingDetail("content 1")
        let sheet2 = ChatSheet.thinkingDetail("content 2")

        #expect(sheet1.id == sheet2.id)
        #expect(sheet1.id == "thinking")
    }

    @Test("Task detail sheet has unique id per tool call")
    func testTaskDetailId() {
        let data1 = TaskManagerChipData(
            toolCallId: "call_1",
            action: "create",
            taskTitle: "Task 1",
            chipSummary: "Created \"Task 1\"",
            fullResult: "Created task task_1: Task 1 [pending]",
            arguments: "{}",
            entityDetail: nil,
            status: .completed
        )
        let data2 = TaskManagerChipData(
            toolCallId: "call_2",
            action: "list",
            taskTitle: nil,
            chipSummary: "3 tasks",
            fullResult: "Tasks (3/3):",
            arguments: "{}",
            entityDetail: nil,
            status: .completed
        )

        let sheet1 = ChatSheet.taskDetail(data1)
        let sheet2 = ChatSheet.taskDetail(data2)

        #expect(sheet1.id != sheet2.id)
        #expect(sheet1.id == "taskDetail-call_1")
    }

    @Test("All sheet cases have unique base ids")
    func testAllCasesHaveUniqueBaseIds() {
        let skill = Skill(
            name: "test",
            displayName: "Test",
            description: "Test",
            source: .global,
            tags: nil
        )
        let compactionData = CompactionDetailData(tokensBefore: 100, tokensAfter: 50, reason: "test", summary: nil)
        let notifyData = NotifyAppChipData(
            toolCallId: "tool",
            title: "Title",
            body: "Body",
            sheetContent: nil,
            status: .sending
        )
        let commandToolData = CommandToolChipData(
            id: "cmd_tool",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .green,
            displayName: "Read",
            summary: "file.swift",
            status: .success,
            durationMs: 10,
            arguments: "{}",
            result: nil,
            isResultTruncated: false
        )
        let taskData = TaskManagerChipData(
            toolCallId: "task_tool",
            action: "create",
            taskTitle: "Test",
            chipSummary: "Created \"Test\"",
            fullResult: "Created task task_1: Test [pending]",
            arguments: "{}",
            entityDetail: nil,
            status: .completed
        )

        let sheets: [ChatSheet] = [
            .safari(URL(string: "https://example.com")!),
            .browser,
            .settings,
            .contextAudit,
            .sessionHistory,
            .skillDetail(skill, .skill),
            .compactionDetail(compactionData),
            .askUserQuestion,
            .subagentDetail,
            .uiCanvas,
            .taskList,
            .taskDetail(taskData),
            .notifyApp(notifyData),
            .thinkingDetail("content"),
            .commandToolDetail(commandToolData),
            .modelPicker
        ]

        // Extract base ids (before any dynamic suffix)
        var baseIds = Set<String>()
        for sheet in sheets {
            let id = sheet.id
            // For ids with dynamic parts, get the prefix
            let baseId = id.components(separatedBy: "-").first ?? id
            baseIds.insert(baseId)
        }

        // Each case should have a unique base id
        #expect(baseIds.count == sheets.count)
    }

    // MARK: - CompactionDetailData Tests

    @Test("CompactionDetailData stores all fields")
    func testCompactionDetailDataFields() {
        let data = CompactionDetailData(
            tokensBefore: 100000,
            tokensAfter: 50000,
            reason: "Context limit reached",
            summary: "Summary text"
        )

        #expect(data.tokensBefore == 100000)
        #expect(data.tokensAfter == 50000)
        #expect(data.reason == "Context limit reached")
        #expect(data.summary == "Summary text")
    }

    @Test("CompactionDetailData with nil summary")
    func testCompactionDetailDataNilSummary() {
        let data = CompactionDetailData(
            tokensBefore: 80000,
            tokensAfter: 40000,
            reason: "Manual",
            summary: nil
        )

        #expect(data.summary == nil)
    }

    @Test("CompactionDetailData equatable")
    func testCompactionDetailDataEquatable() {
        let data1 = CompactionDetailData(tokensBefore: 100, tokensAfter: 50, reason: "test", summary: nil)
        let data2 = CompactionDetailData(tokensBefore: 100, tokensAfter: 50, reason: "test", summary: nil)
        let data3 = CompactionDetailData(tokensBefore: 100, tokensAfter: 50, reason: "different", summary: nil)

        #expect(data1 == data2)
        #expect(data1 != data3)
    }
}

// MARK: - SheetCoordinator Tests

@Suite("SheetCoordinator Tests")
@MainActor
struct SheetCoordinatorTests {

    // MARK: - Initial State

    @Test("Initial state has no active sheet")
    func testInitialStateNoActiveSheet() {
        let coordinator = SheetCoordinator()

        #expect(coordinator.activeSheet == nil)
    }

    @Test("Initial state has no dismiss callback")
    func testInitialStateNoDismissCallback() {
        let coordinator = SheetCoordinator()

        #expect(coordinator.onDismiss == nil)
    }

    // MARK: - Present Tests

    @Test("Present sets active sheet")
    func testPresentSetsActiveSheet() {
        let coordinator = SheetCoordinator()

        coordinator.present(.settings)

        #expect(coordinator.activeSheet == .settings)
    }

    @Test("Present with onDismiss stores callback")
    func testPresentWithOnDismissStoresCallback() {
        let coordinator = SheetCoordinator()
        var callbackCalled = false

        coordinator.present(.settings) {
            callbackCalled = true
        }

        // Callback should be stored
        #expect(coordinator.onDismiss != nil)

        // Call it to verify
        coordinator.onDismiss?()
        #expect(callbackCalled)
    }

    @Test("Present replaces current sheet")
    func testPresentReplacesCurrentSheet() {
        let coordinator = SheetCoordinator()

        coordinator.present(.settings)
        coordinator.present(.contextAudit)

        #expect(coordinator.activeSheet == .contextAudit)
    }

    @Test("Present replaces onDismiss callback")
    func testPresentReplacesOnDismissCallback() {
        let coordinator = SheetCoordinator()
        var firstCalled = false
        var secondCalled = false

        coordinator.present(.settings) { firstCalled = true }
        coordinator.present(.contextAudit) { secondCalled = true }

        coordinator.onDismiss?()

        #expect(!firstCalled)
        #expect(secondCalled)
    }

    // MARK: - Dismiss Tests

    @Test("Dismiss clears active sheet")
    func testDismissClearsActiveSheet() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)

        coordinator.dismiss()

        #expect(coordinator.activeSheet == nil)
    }

    @Test("Dismiss when no sheet is no-op")
    func testDismissWhenNoSheetIsNoOp() {
        let coordinator = SheetCoordinator()

        coordinator.dismiss()

        #expect(coordinator.activeSheet == nil)
    }

    @Test("Dismiss does not clear onDismiss callback")
    func testDismissDoesNotClearOnDismissCallback() {
        let coordinator = SheetCoordinator()
        var callbackCalled = false

        coordinator.present(.settings) { callbackCalled = true }
        coordinator.dismiss()

        // Callback should still be available (SwiftUI calls it)
        #expect(coordinator.onDismiss != nil)
    }

    // MARK: - Convenience Method Tests

    @Test("showSafari creates safari sheet")
    func testShowSafariCreatesSafariSheet() {
        let coordinator = SheetCoordinator()
        let url = URL(string: "https://example.com")!

        coordinator.showSafari(url)

        if case .safari(let sheetUrl) = coordinator.activeSheet {
            #expect(sheetUrl == url)
        } else {
            Issue.record("Expected safari sheet")
        }
    }

    @Test("showBrowser creates browser sheet")
    func testShowBrowserCreatesBrowserSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showBrowser()

        #expect(coordinator.activeSheet == .browser)
    }

    @Test("showSettings creates settings sheet")
    func testShowSettingsCreatesSettingsSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showSettings()

        #expect(coordinator.activeSheet == .settings)
    }

    @Test("showContextAudit creates context audit sheet")
    func testShowContextAuditCreatesContextAuditSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showContextAudit()

        #expect(coordinator.activeSheet == .contextAudit)
    }

    @Test("showSessionHistory creates session history sheet")
    func testShowSessionHistoryCreatesSessionHistorySheet() {
        let coordinator = SheetCoordinator()

        coordinator.showSessionHistory()

        #expect(coordinator.activeSheet == .sessionHistory)
    }

    @Test("showSkillDetail creates skill detail sheet with correct data")
    func testShowSkillDetailCreatesCorrectSheet() {
        let coordinator = SheetCoordinator()
        let skill = Skill(
            name: "test",
            displayName: "Test",
            description: "Test",
            source: .global,
            tags: nil
        )

        coordinator.showSkillDetail(skill, mode: .spell)

        if case .skillDetail(let sheetSkill, let mode) = coordinator.activeSheet {
            #expect(sheetSkill.name == "test")
            #expect(mode == .spell)
        } else {
            Issue.record("Expected skillDetail sheet")
        }
    }

    @Test("showCompactionDetail creates compaction sheet with data")
    func testShowCompactionDetailCreatesCorrectSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showCompactionDetail(
            tokensBefore: 100000,
            tokensAfter: 50000,
            reason: "Context limit",
            summary: "Summary"
        )

        if case .compactionDetail(let data) = coordinator.activeSheet {
            #expect(data.tokensBefore == 100000)
            #expect(data.tokensAfter == 50000)
            #expect(data.reason == "Context limit")
            #expect(data.summary == "Summary")
        } else {
            Issue.record("Expected compactionDetail sheet")
        }
    }

    @Test("showAskUserQuestion creates ask user question sheet")
    func testShowAskUserQuestionCreatesSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showAskUserQuestion()

        #expect(coordinator.activeSheet == .askUserQuestion)
    }

    @Test("showSubagentDetail creates subagent detail sheet")
    func testShowSubagentDetailCreatesSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showSubagentDetail()

        #expect(coordinator.activeSheet == .subagentDetail)
    }

    @Test("showUICanvas creates UI canvas sheet")
    func testShowUICanvasCreatesSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showUICanvas()

        #expect(coordinator.activeSheet == .uiCanvas)
    }

    @Test("showTaskList creates task list sheet")
    func testShowTaskListCreatesSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showTaskList()

        #expect(coordinator.activeSheet == .taskList)
    }

    @Test("showTaskDetail creates task detail sheet with chip data")
    func testShowTaskDetailCreatesCorrectSheet() {
        let coordinator = SheetCoordinator()
        let data = TaskManagerChipData(
            toolCallId: "call_123",
            action: "create",
            taskTitle: "Fix bug",
            chipSummary: "Created \"Fix bug\"",
            fullResult: "Created task task_abc: Fix bug [pending]",
            arguments: "{\"action\":\"create\",\"title\":\"Fix bug\"}",
            entityDetail: nil,
            status: .completed
        )

        coordinator.showTaskDetail(data)

        if case .taskDetail(let sheetData) = coordinator.activeSheet {
            #expect(sheetData.toolCallId == "call_123")
            #expect(sheetData.action == "create")
            #expect(sheetData.fullResult == "Created task task_abc: Fix bug [pending]")
        } else {
            Issue.record("Expected taskDetail sheet")
        }
    }

    @Test("showNotifyApp creates notify app sheet with data")
    func testShowNotifyAppCreatesCorrectSheet() {
        let coordinator = SheetCoordinator()
        let data = NotifyAppChipData(
            toolCallId: "tool123",
            title: "Notification",
            body: "Body text",
            sheetContent: nil,
            status: .sending
        )

        coordinator.showNotifyApp(data)

        if case .notifyApp(let sheetData) = coordinator.activeSheet {
            #expect(sheetData.toolCallId == "tool123")
            #expect(sheetData.title == "Notification")
        } else {
            Issue.record("Expected notifyApp sheet")
        }
    }

    @Test("showThinkingDetail creates thinking sheet with content")
    func testShowThinkingDetailCreatesCorrectSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showThinkingDetail("Thinking content here")

        if case .thinkingDetail(let content) = coordinator.activeSheet {
            #expect(content == "Thinking content here")
        } else {
            Issue.record("Expected thinkingDetail sheet")
        }
    }

    // MARK: - Binding Helper Tests

    @Test("isPresented returns true when sheet active")
    func testIsPresentedTrueWhenActive() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)

        #expect(coordinator.isPresented)
    }

    @Test("isPresented returns false when no sheet")
    func testIsPresentedFalseWhenNoSheet() {
        let coordinator = SheetCoordinator()

        #expect(!coordinator.isPresented)
    }
}
