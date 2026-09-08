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

/// Permanently mounted composer owner for every process-projection visibility
/// path. Keeping this wrapper alive lets its child transition run when a final
/// Gateway removal, projection loss, or the local recent deadline hides the orb.
struct SessionProcessButton: View {
    let overview: SessionProcessOverview?
    let processActivities: [SessionProcessActivity]?
    let hasAdmittedActivity: Bool
    let glassNamespace: Namespace.ID
    let reduceMotion: Bool
    let onTap: () -> Void

    @State private var locallyExpiredRecentExpiry: String?
    @State private var appBehaviorSettings = AppLocalBehaviorSettings.shared

    var body: some View {
        Group {
            if let overview, isVisible {
                Button(action: onTap) {
                    ProcessActivityOrb(
                        mode: overview.visibility == .active ? .solving : .thinking,
                        isVisible: isVisible
                    )
                    .frame(
                        width: ComposerControlMetrics.hitTarget,
                        height: ComposerControlMetrics.hitTarget
                    )
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(),
                    in: .circle
                )
                .glassEffectID("chat-processes", in: glassNamespace)
                // Liquid Glass owns the geometry morph from the composer. A
                // second move/scale transition makes the material and its
                // continuously rendered Canvas follow competing paths.
                .glassEffectTransition(.matchedGeometry)
                .transition(.opacity)
                .accessibilityLabel("Subagents")
                .accessibilityValue(accessibilityValue(overview: overview))
                .accessibilityHint("Shows current and recently finished subagents")
            }
        }
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .spring(response: 0.32, dampingFraction: 0.82),
            value: isVisible
        )
        .task(id: recentExpiryIdentity) {
            guard let recentExpiryIdentity,
                  let expiry = GatewayTimestamp.parse(recentExpiryIdentity) else { return }
            let milliseconds = max(0, Int(expiry.timeIntervalSinceNow * 1_000))
            if milliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
            guard !Task.isCancelled else { return }
            // Store the deadline identity rather than a shared Boolean. A task
            // canceled by newer process evidence can never hide that evidence.
            locallyExpiredRecentExpiry = recentExpiryIdentity
        }
    }

    private var isVisible: Bool {
        SessionProcessButtonPolicy.isVisible(
            overview: overview,
            hasAdmittedActivity: hasAdmittedActivity && !visibleActivities.isEmpty,
            localRecentExpired: SessionProcessButtonPolicy.isLocallyExpired(
                recentExpiry: recentExpiryIdentity,
                expiredRecentExpiry: locallyExpiredRecentExpiry,
                now: .now
            ),
            recentFinishedRetentionMinutes: appBehaviorSettings.subagentRecentFinishedRetentionMinutes
        )
    }

    private var recentExpiryIdentity: String? {
        SessionProcessButtonPolicy.preferredRecentExpiry(
            overview: overview,
            activities: processActivities,
            retentionMinutes: appBehaviorSettings.subagentRecentFinishedRetentionMinutes
        )
    }

    private var visibleActivities: [SessionProcessActivity] {
        SessionProcessButtonPolicy.visibleActivities(
            processActivities ?? [],
            retentionMinutes: appBehaviorSettings.subagentRecentFinishedRetentionMinutes,
            now: .now
        )
    }

    private func accessibilityValue(overview: SessionProcessOverview) -> String {
        let activities = visibleActivities
        let active = activities.filter { $0.visibility == .active }.count
        let recent = activities.filter { $0.visibility == .recent }.count
        let problems = activities.filter { $0.lifecycle.state.isProblem }.count
        var parts: [String] = []
        if active > 0 {
            parts.append("\(active) active")
        }
        if recent > 0 {
            parts.append("\(recent) recently finished")
        }
        if problems > 0 {
            parts.append("\(problems) with problems")
        }
        return parts.joined(separator: ", ")
    }
}
