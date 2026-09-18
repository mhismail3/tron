import SwiftUI

enum SessionProcessButtonPolicy {
    static func isVisible(
        overview: SessionProcessOverview?,
        hasAdmittedActivity: Bool,
        localRecentExpired: Bool,
        recentFinishedRetentionMinutes: Int = 5
    ) -> Bool {
        guard let overview, hasAdmittedActivity else { return false }
        return overview.visibility != .hidden
            && !(overview.visibility == .recent && (recentFinishedRetentionMinutes <= 0 || localRecentExpired))
    }

    static func preferredRecentExpiry(
        overview: SessionProcessOverview?,
        activities: [SessionProcessActivity]?,
        retentionMinutes: Int
    ) -> String? {
        guard overview?.visibility == .recent else { return nil }
        guard retentionMinutes > 0 else { return nil }
        // The button outlives the last eligible row, not the first one. The
        // overview's nearestExpiry is a refresh boundary, not an all-done date.
        guard let expiry = (activities ?? [])
            .compactMap({ recentExpiry(for: $0, retentionMinutes: retentionMinutes) }).max() else { return nil }
        return GatewayTimestamp.preciseString(from: expiry)
    }

    static func recentExpiry(for activity: SessionProcessActivity, retentionMinutes: Int) -> Date? {
        guard retentionMinutes > 0, activity.kind == .subagent,
              activity.visibility == .recent, SessionProcessAdmissionPolicy.admits(activity),
              let terminal = activity.lifecycle.terminalAt.flatMap(GatewayTimestamp.parse) else { return nil }
        let preferred = terminal.addingTimeInterval(TimeInterval(min(retentionMinutes, 5) * 60))
        return activity.lifecycle.recentUntil.flatMap(GatewayTimestamp.parse).map { min($0, preferred) } ?? preferred
    }

    static func visibleActivities(
        _ activities: [SessionProcessActivity], retentionMinutes: Int, now: Date
    ) -> [SessionProcessActivity] {
        activities.filter { activity in
            guard activity.kind == .subagent, SessionProcessAdmissionPolicy.admits(activity) else { return false }
            if activity.visibility == .active { return true }
            return recentExpiry(for: activity, retentionMinutes: retentionMinutes).map { $0 > now } == true
        }
    }

    static func isLocallyExpired(
        recentExpiry: String?,
        expiredRecentExpiry: String?,
        now: Date? = nil
    ) -> Bool {
        guard let recentExpiry else { return false }
        return expiredRecentExpiry == recentExpiry
            || now.map { reference in
                GatewayTimestamp.parse(recentExpiry).map { $0 <= reference } == true
            } == true
    }
}
