import SwiftUI

enum SessionProcessButtonPolicy {
    static func isVisible(
        overview: SessionProcessOverview?,
        hasAdmittedActivity: Bool,
        localRecentExpired: Bool
    ) -> Bool {
        guard let overview, hasAdmittedActivity else { return false }
        return overview.visibility != .hidden
            && !(overview.visibility == .recent && localRecentExpired)
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
    let hasAdmittedActivity: Bool
    let glassNamespace: Namespace.ID
    let reduceMotion: Bool
    let onTap: () -> Void

    @State private var locallyExpiredRecentExpiry: String?

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
                .glassEffectTransition(.matchedGeometry)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .trailing)
                            .combined(with: .scale(scale: 0.82, anchor: .trailing))
                            .combined(with: .opacity)
                )
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
            )
        )
    }

    private var recentExpiryIdentity: String? {
        guard overview?.visibility == .recent else { return nil }
        return overview?.nearestExpiry
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
