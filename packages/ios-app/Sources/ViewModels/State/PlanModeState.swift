import SwiftUI

/// Manages plan mode state for ChatViewModel
/// Extracted from ChatViewModel to reduce property sprawl
@Observable
@MainActor
final class PlanModeState {
    /// Whether plan mode is currently active
    private(set) var isActive = false

    /// Name of the skill that activated plan mode
    private(set) var skillName: String?

    init() {}

    /// Enter plan mode with the given skill name
    func enter(skillName: String) {
        isActive = true
        self.skillName = skillName
    }

    /// Exit plan mode and return the skill name that was active
    @discardableResult
    func exit() -> String? {
        let previousSkillName = skillName
        isActive = false
        skillName = nil
        return previousSkillName
    }
}
