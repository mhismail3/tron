import Testing
import Foundation
@testable import TronMobile

/// Tests for ChatNotificationCoordinator
/// Verifies notification handler routing for iOS 26 Menu workarounds
@Suite("ChatNotificationCoordinator Tests")
struct ChatNotificationCoordinatorTests {

    // MARK: - Menu Action Tests

    @Test("Handle menu action 'history' sets showSessionHistory")
    func testHandleMenuAction_history_setsShowSessionHistory() {
        var showSessionHistory = false
        var showContextAudit = false
        var showTodoSheet = false
        var showSettings = false

        ChatNotificationCoordinator.handleChatMenuAction(
            "history",
            showSessionHistory: &showSessionHistory,
            showContextAudit: &showContextAudit,
            showTodoSheet: &showTodoSheet,
            showSettings: &showSettings
        )

        #expect(showSessionHistory)
        #expect(!showContextAudit)
        #expect(!showTodoSheet)
        #expect(!showSettings)
    }

    @Test("Handle menu action 'context' sets showContextAudit")
    func testHandleMenuAction_context_setsShowContextAudit() {
        var showSessionHistory = false
        var showContextAudit = false
        var showTodoSheet = false
        var showSettings = false

        ChatNotificationCoordinator.handleChatMenuAction(
            "context",
            showSessionHistory: &showSessionHistory,
            showContextAudit: &showContextAudit,
            showTodoSheet: &showTodoSheet,
            showSettings: &showSettings
        )

        #expect(!showSessionHistory)
        #expect(showContextAudit)
        #expect(!showTodoSheet)
        #expect(!showSettings)
    }

    @Test("Handle menu action 'tasks' sets showTodoSheet")
    func testHandleMenuAction_tasks_setsTodoSheet() {
        var showSessionHistory = false
        var showContextAudit = false
        var showTodoSheet = false
        var showSettings = false

        ChatNotificationCoordinator.handleChatMenuAction(
            "tasks",
            showSessionHistory: &showSessionHistory,
            showContextAudit: &showContextAudit,
            showTodoSheet: &showTodoSheet,
            showSettings: &showSettings
        )

        #expect(!showSessionHistory)
        #expect(!showContextAudit)
        #expect(showTodoSheet)
        #expect(!showSettings)
    }

    @Test("Handle menu action 'settings' sets showSettings")
    func testHandleMenuAction_settings_setsShowSettings() {
        var showSessionHistory = false
        var showContextAudit = false
        var showTodoSheet = false
        var showSettings = false

        ChatNotificationCoordinator.handleChatMenuAction(
            "settings",
            showSessionHistory: &showSessionHistory,
            showContextAudit: &showContextAudit,
            showTodoSheet: &showTodoSheet,
            showSettings: &showSettings
        )

        #expect(!showSessionHistory)
        #expect(!showContextAudit)
        #expect(!showTodoSheet)
        #expect(showSettings)
    }

    @Test("Handle menu action with unknown action does nothing")
    func testHandleMenuAction_unknown_doesNothing() {
        var showSessionHistory = false
        var showContextAudit = false
        var showTodoSheet = false
        var showSettings = false

        ChatNotificationCoordinator.handleChatMenuAction(
            "unknown_action",
            showSessionHistory: &showSessionHistory,
            showContextAudit: &showContextAudit,
            showTodoSheet: &showTodoSheet,
            showSettings: &showSettings
        )

        #expect(!showSessionHistory)
        #expect(!showContextAudit)
        #expect(!showTodoSheet)
        #expect(!showSettings)
    }

    // MARK: - Reasoning Level Action Tests

    @Test("Handle reasoning level action updates level")
    func testHandleReasoningLevelAction_updatesLevel() {
        var currentLevel = "low"
        var persistedLevel: String? = nil
        var changeNotificationCalled = false
        var previousLevelSent: String? = nil
        var newLevelSent: String? = nil

        ChatNotificationCoordinator.handleReasoningLevelAction(
            "high",
            currentLevel: &currentLevel,
            persistLevel: { level in persistedLevel = level },
            onLevelChanged: { prev, new in
                changeNotificationCalled = true
                previousLevelSent = prev
                newLevelSent = new
            }
        )

        #expect(currentLevel == "high")
        #expect(persistedLevel == "high")
        #expect(changeNotificationCalled)
        #expect(previousLevelSent == "low")
        #expect(newLevelSent == "high")
    }

    @Test("Handle reasoning level action same level does not trigger change notification")
    func testHandleReasoningLevelAction_sameLevel_noNotification() {
        var currentLevel = "medium"
        var persistedLevel: String? = nil
        var changeNotificationCalled = false

        ChatNotificationCoordinator.handleReasoningLevelAction(
            "medium",
            currentLevel: &currentLevel,
            persistLevel: { level in persistedLevel = level },
            onLevelChanged: { _, _ in changeNotificationCalled = true }
        )

        #expect(currentLevel == "medium")
        #expect(persistedLevel == "medium")
        #expect(!changeNotificationCalled)
    }

    // MARK: - Draft Plan Request Tests

    @Test("Handle draft plan request adds plan skill when available")
    func testHandleDraftPlanRequest_addsPlanSkill() {
        let planSkill = Skill(
            name: "plan",
            displayName: "Plan",
            description: "Create a plan",
            source: .global,
            autoInject: false,
            tags: nil
        )
        let otherSkill = Skill(
            name: "other",
            displayName: "Other",
            description: "Other skill",
            source: .global,
            autoInject: false,
            tags: nil
        )
        let availableSkills = [otherSkill, planSkill]
        var selectedSkills: [Skill] = []

        ChatNotificationCoordinator.handleDraftPlanRequest(
            availableSkills: availableSkills,
            selectedSkills: &selectedSkills
        )

        #expect(selectedSkills.count == 1)
        #expect(selectedSkills.first?.name == "plan")
    }

    @Test("Handle draft plan request does not add if already selected")
    func testHandleDraftPlanRequest_alreadySelected_noChange() {
        let planSkill = Skill(
            name: "plan",
            displayName: "Plan",
            description: "Create a plan",
            source: .global,
            autoInject: false,
            tags: nil
        )
        let availableSkills = [planSkill]
        var selectedSkills = [planSkill]

        ChatNotificationCoordinator.handleDraftPlanRequest(
            availableSkills: availableSkills,
            selectedSkills: &selectedSkills
        )

        #expect(selectedSkills.count == 1)
    }

    @Test("Handle draft plan request does nothing if no plan skill")
    func testHandleDraftPlanRequest_noPlanSkill_noChange() {
        let otherSkill = Skill(
            name: "other",
            displayName: "Other",
            description: "Other skill",
            source: .global,
            autoInject: false,
            tags: nil
        )
        let availableSkills = [otherSkill]
        var selectedSkills: [Skill] = []

        ChatNotificationCoordinator.handleDraftPlanRequest(
            availableSkills: availableSkills,
            selectedSkills: &selectedSkills
        )

        #expect(selectedSkills.isEmpty)
    }

    @Test("Handle draft plan request case insensitive match")
    func testHandleDraftPlanRequest_caseInsensitive() {
        let planSkill = Skill(
            name: "Plan",
            displayName: "Plan",
            description: "Create a plan",
            source: .global,
            autoInject: false,
            tags: nil
        )
        let availableSkills = [planSkill]
        var selectedSkills: [Skill] = []

        ChatNotificationCoordinator.handleDraftPlanRequest(
            availableSkills: availableSkills,
            selectedSkills: &selectedSkills
        )

        #expect(selectedSkills.count == 1)
        #expect(selectedSkills.first?.name == "Plan")
    }
}
