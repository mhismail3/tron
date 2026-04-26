import Foundation

/// Pure planner for forgetting a paired Mac from iOS Settings.
///
/// The UI owns side effects (settings.update, Keychain deletion, active-server
/// switching), while this helper pins the product contract in tests:
/// removing the active Mac either selects another saved Mac or returns the app
/// to onboarding when none remain.
enum ConnectionPresetRemoval {
    struct Plan: Equatable {
        let updatedPresets: [ConnectionPreset]
        let removedWasActive: Bool
        let nextActivePreset: ConnectionPreset?
        let shouldReturnToOnboarding: Bool
    }

    static func plan(
        removing preset: ConnectionPreset,
        from presets: [ConnectionPreset],
        activeHost: String,
        activePort: String
    ) -> Plan {
        let updated = presets.filter { $0.id != preset.id }
        let removedWasActive = preset.host == activeHost && String(preset.port) == activePort
        let nextActive = removedWasActive ? updated.first : nil

        return Plan(
            updatedPresets: updated,
            removedWasActive: removedWasActive,
            nextActivePreset: nextActive,
            shouldReturnToOnboarding: updated.isEmpty
        )
    }
}
