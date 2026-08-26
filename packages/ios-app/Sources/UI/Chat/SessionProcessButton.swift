import SwiftUI

enum SessionProcessButtonPolicy {
    static func isVisible(
        overview: SessionProcessOverview,
        localRecentExpired: Bool
    ) -> Bool {
        overview.visibility != .hidden
            && !(overview.visibility == .recent && localRecentExpired)
    }
}

struct SessionProcessButton: View {
    let overview: SessionProcessOverview
    let glassNamespace: Namespace.ID
    let reduceMotion: Bool
    let onTap: () -> Void

    @State private var localRecentExpired = false

    var body: some View {
        Group {
            if isVisible {
                Button(action: onTap) {
                    ProcessActivityOrb(
                        mode: overview.visibility == .active ? .solving : .breathing,
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
                .accessibilityLabel("Processes")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("Shows current and recent processes")
            }
        }
        .task(id: expiryTaskIdentity) {
            localRecentExpired = false
            guard overview.visibility == .recent,
                  let value = overview.nearestExpiry,
                  let expiry = GatewayTimestamp.parse(value) else { return }
            let milliseconds = max(0, Int(expiry.timeIntervalSinceNow * 1_000))
            guard milliseconds > 0 else {
                localRecentExpired = true
                return
            }
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            localRecentExpired = true
        }
    }

    private var isVisible: Bool {
        SessionProcessButtonPolicy.isVisible(
            overview: overview,
            localRecentExpired: localRecentExpired
        )
    }

    private var expiryTaskIdentity: String {
        "\(overview.revision):\(overview.visibility.rawValue):\(overview.nearestExpiry ?? "none")"
    }

    private var accessibilityValue: String {
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
