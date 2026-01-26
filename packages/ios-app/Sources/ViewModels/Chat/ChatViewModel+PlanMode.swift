import Foundation

// MARK: - Plan Mode Methods

extension ChatViewModel {

    /// Enter plan mode (called from event handler)
    func enterPlanMode(skillName: String, blockedTools: [String]) {
        planModeState.enter(skillName: skillName)

        // Add notification message to chat
        let notification = ChatMessage(
            role: .system,
            content: .planModeEntered(skillName: skillName, blockedTools: blockedTools)
        )
        messages.append(notification)

        logger.info("Entered plan mode: skill=\(skillName), blocked=\(blockedTools.joined(separator: ", "))", category: .session)
    }

    /// Exit plan mode (called from event handler)
    func exitPlanMode(reason: String, planPath: String?) {
        let skillName = planModeState.skillName
        planModeState.exit()

        // Add notification message to chat
        let notification = ChatMessage(
            role: .system,
            content: .planModeExited(reason: reason, planPath: planPath)
        )
        messages.append(notification)

        logger.info("Exited plan mode: reason=\(reason), skill=\(skillName ?? "unknown")", category: .session)
    }
}
