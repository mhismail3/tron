import Foundation

/// Coordinator for handling iOS 26 Menu workaround notifications.
/// Menu button actions that mutate @State break gesture handling in iOS 26,
/// so we use NotificationCenter to decouple the action from state mutation.
enum ChatNotificationCoordinator {

    // MARK: - Menu Action Handler

    /// Handle chat menu action notification
    /// - Parameters:
    ///   - action: The action string ("history", "context", "tasks", "settings")
    ///   - showSessionHistory: Binding to session history sheet visibility
    ///   - showContextAudit: Binding to context audit sheet visibility
    ///   - showTodoSheet: Binding to todo sheet visibility
    ///   - showSettings: Binding to settings sheet visibility
    static func handleChatMenuAction(
        _ action: String,
        showSessionHistory: inout Bool,
        showContextAudit: inout Bool,
        showTodoSheet: inout Bool,
        showSettings: inout Bool
    ) {
        switch action {
        case "history":
            showSessionHistory = true
        case "context":
            showContextAudit = true
        case "tasks":
            showTodoSheet = true
        case "settings":
            showSettings = true
        default:
            break
        }
    }

    // MARK: - Reasoning Level Action Handler

    /// Handle reasoning level change notification
    /// - Parameters:
    ///   - newLevel: The new reasoning level
    ///   - currentLevel: The current reasoning level (will be updated)
    ///   - persistLevel: Closure to persist the level (e.g., to UserDefaults)
    ///   - onLevelChanged: Closure called when level actually changes (previous, new)
    static func handleReasoningLevelAction(
        _ newLevel: String,
        currentLevel: inout String,
        persistLevel: (String) -> Void,
        onLevelChanged: (_ previous: String, _ new: String) -> Void
    ) {
        let previousLevel = currentLevel
        currentLevel = newLevel
        persistLevel(newLevel)

        if previousLevel != newLevel {
            onLevelChanged(previousLevel, newLevel)
        }
    }

    // MARK: - Draft Plan Request Handler

    /// Handle "Draft a Plan" request by adding plan skill to selection
    /// - Parameters:
    ///   - availableSkills: List of available skills to search
    ///   - selectedSkills: Current selection (will be updated)
    static func handleDraftPlanRequest(
        availableSkills: [Skill],
        selectedSkills: inout [Skill]
    ) {
        // Find the "plan" skill (case insensitive)
        guard let planSkill = availableSkills.first(where: { $0.name.lowercased() == "plan" }) else {
            return
        }

        // Only add if not already selected
        if !selectedSkills.contains(where: { $0.id == planSkill.id }) {
            selectedSkills.append(planSkill)
        }
    }
}
