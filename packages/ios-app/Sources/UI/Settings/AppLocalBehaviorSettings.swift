import Foundation
import Observation

/// Preferences owned by the iOS app presentation, never by a Gateway session.
@MainActor
@Observable
final class AppLocalBehaviorSettings {
    static let shared = AppLocalBehaviorSettings(defaults: .standard)

    static let subagentRecentFinishedRetentionKey = "subagentRecentFinishedRetentionMinutes.v1"
    static let defaultSubagentRecentFinishedRetentionMinutes = 5
    static let subagentRecentFinishedRetentionRange = 0...5

    static let dashboardChatsPerProjectKey = "dashboardChatsPerProject.v1"
    nonisolated static let defaultDashboardChatsPerProject = 10
    nonisolated static let dashboardChatsPerProjectRange = 1...100

    nonisolated static func boundedDashboardChatsPerProject(_ value: Int) -> Int {
        dashboardChatsPerProjectRange.clamp(value)
    }

    private let defaults: UserDefaults

    var dashboardChatsPerProject: Int {
        didSet {
            let bounded = Self.boundedDashboardChatsPerProject(dashboardChatsPerProject)
            if bounded != dashboardChatsPerProject { dashboardChatsPerProject = bounded }
            defaults.set(bounded, forKey: Self.dashboardChatsPerProjectKey)
        }
    }

    var subagentRecentFinishedRetentionMinutes: Int {
        didSet {
            let bounded = Self.subagentRecentFinishedRetentionRange.clamp(subagentRecentFinishedRetentionMinutes)
            if bounded != subagentRecentFinishedRetentionMinutes {
                subagentRecentFinishedRetentionMinutes = bounded
            }
            defaults.set(bounded, forKey: Self.subagentRecentFinishedRetentionKey)
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        dashboardChatsPerProject = Self.boundedDashboardChatsPerProject(
            (defaults.object(forKey: Self.dashboardChatsPerProjectKey) as? Int)
                ?? Self.defaultDashboardChatsPerProject
        )
        let stored = defaults.object(forKey: Self.subagentRecentFinishedRetentionKey) as? Int
        subagentRecentFinishedRetentionMinutes = Self.subagentRecentFinishedRetentionRange.clamp(
            stored ?? Self.defaultSubagentRecentFinishedRetentionMinutes
        )
    }
}

private extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int { Swift.min(upperBound, Swift.max(lowerBound, value)) }
}
