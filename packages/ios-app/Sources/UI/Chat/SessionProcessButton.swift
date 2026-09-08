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
        let interval = TimeInterval(retentionMinutes * 60)
        let mountedExpiries = (activities ?? [])
            .filter { $0.kind == .subagent && $0.visibility == .recent && SessionProcessAdmissionPolicy.admits($0) }
            .compactMap { activity -> Date? in
                guard let terminalAt = activity.lifecycle.terminalAt,
                      let terminal = GatewayTimestamp.parse(terminalAt) else { return nil }
                return terminal.addingTimeInterval(interval)
            }
        // The overview expiry remains the authoritative fallback when Gateway
        // omitted rows from the bounded mounted subset.
        let gatewayExpiry = overview?.nearestExpiry.flatMap(GatewayTimestamp.parse)
        guard let expiry = (mountedExpiries + [gatewayExpiry].compactMap { $0 }).min() else { return nil }
        return GatewayTimestamp.preciseString(from: expiry)
    }

    static func isLocallyExpired(
        recentExpiry: String?,
        expiredRecentExpiry: String?
    ) -> Bool {
        guard let recentExpiry else { return false }
        return expiredRecentExpiry == recentExpiry
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
            hasAdmittedActivity: hasAdmittedActivity,
            localRecentExpired: SessionProcessButtonPolicy.isLocallyExpired(
                recentExpiry: recentExpiryIdentity,
                expiredRecentExpiry: locallyExpiredRecentExpiry
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

    private func accessibilityValue(overview: SessionProcessOverview) -> String {
        var parts: [String] = []
        if overview.activeCount > 0 {
            parts.append("\(overview.activeCount) active")
        }
        if overview.recentCount > 0 {
            parts.append("\(overview.recentCount) recently finished")
        }
        if overview.problemCount > 0 {
            parts.append("\(overview.problemCount) with problems")
        }
        return parts.joined(separator: ", ")
    }
}
