import SwiftUI
import TronMobileCore

enum SessionProcessButtonPolicy {
    static func isVisible(
        overview: PresentedProcessOverview?,
        hasAdmittedActivity: Bool,
        localRecentExpired: Bool,
        recentFinishedRetentionMinutes: Int = 5
    ) -> Bool {
        guard let overview, hasAdmittedActivity else { return false }
        return overview.visibility != .hidden
            && !(overview.visibility == .recent && (recentFinishedRetentionMinutes <= 0 || localRecentExpired))
    }

    static func preferredRecentExpiry(
        overview: PresentedProcessOverview?,
        activities: [PresentedProcessActivity]?,
        retentionMinutes: Int
    ) -> String? {
        guard overview?.visibility == .recent else { return nil }
        guard retentionMinutes > 0 else { return nil }
        guard let expiry = (activities ?? [])
            .compactMap({ recentExpiry(for: $0, retentionMinutes: retentionMinutes) }).max() else { return nil }
        return GatewayTimestamp.preciseString(from: expiry)
    }

    static func recentExpiry(for activity: PresentedProcessActivity, retentionMinutes: Int) -> Date? {
        guard retentionMinutes > 0, activity.kind == .subagent,
              activity.visibility == .recent, SessionProcessAdmissionPolicy.admits(activity),
              let terminal = activity.lifecycle.terminalAt.flatMap(GatewayTimestamp.parse) else { return nil }
        let preferred = terminal.addingTimeInterval(TimeInterval(min(retentionMinutes, 5) * 60))
        return activity.lifecycle.recentUntil.flatMap(GatewayTimestamp.parse).map { min($0, preferred) } ?? preferred
    }

    static func visibleActivities(
        _ activities: [PresentedProcessActivity], retentionMinutes: Int, now: Date
    ) -> [PresentedProcessActivity] {
        activities.filter { activity in
            guard activity.kind == .subagent, SessionProcessAdmissionPolicy.admits(activity) else { return false }
            if activity.visibility == .active { return true }
            return recentExpiry(for: activity, retentionMinutes: retentionMinutes).map { $0 > now } == true
        }
    }

}
