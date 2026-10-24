import SwiftUI
import TronMobileCore

/// Home's activation context is not a normal session's section-by-section summary.
/// Context remaining describes the current request; total tokens is cumulative usage.
struct HomeContextSummaryCard: View {
    let snapshot: SessionContextPresentation
    let read: HomeManageDTO

    private var usage: SessionContextUsagePresentation {
        guard let breakdown = read.context.breakdown else { return SessionContextUsagePresentation(snapshot.contextUsage) }
        return .available(used: breakdown.effectiveTokens, window: breakdown.contextWindow,
                          percent: breakdown.contextWindow > 0
                            ? min(100, Double(breakdown.effectiveTokens) / Double(breakdown.contextWindow) * 100) : 0)
    }

    var body: some View {
        TronGlassCard(accent: .tronPrimary) {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                HStack(spacing: TronSpacing.md) {
                    TronStatusPill(text: HomeStatusLinePresentation.state(read.status), accent: HomeSheet.statusAccent(read.status))
                        .accessibilityIdentifier("home-manage-state")
                    let workers = read.status.workers.running
                    TronStatusPill(text: "\(workers.formatted()) \(workers == 1 ? "worker" : "workers")",
                                   accent: HomeSheet.hostPressureAccent(read.status.hostPressure.level))
                        .accessibilityLabel("\(workers.formatted()) \(workers == 1 ? "worker" : "workers")")
                        .accessibilityValue("Host pressure \(read.status.hostPressure.level.rawValue)")
                        .accessibilityIdentifier("home-manage-workers")
                }
                HStack(spacing: TronSpacing.xl) {
                    SessionContextProgressRing(fraction: percent / 100, accent: .tronPrimary, diameter: TronSpacing.xlarge)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Context used")
                        .accessibilityValue("\(Int(percent.rounded())) percent")
                        .accessibilityIdentifier("home-context-ring")
                    VStack(alignment: .leading, spacing: TronSpacing.xxs) {
                        Text(headline).font(SessionSummaryTypography.headline)
                        Text(detail)
                            .font(SessionSummaryTypography.usageValue)
                            .foregroundStyle(Color.tronTextSecondary)
                            .accessibilityIdentifier("home-context-detail")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(TronSpacing.xxl)
        }
        .foregroundStyle(Color.tronTextPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(usage.accessibilityLabel)
        .accessibilityIdentifier("home-context-summary")
    }

    private var headline: String {
        if case .available(let used, let window, _) = usage {
            return "\(max(0, window - used).formatted(.number.notation(.compactName))) tokens left"
        }
        return "Context pending"
    }

    private var detail: String {
        let context = usage.usedSummary ?? SessionContextUsageRefreshPresentation(
            lastTranscriptKind: snapshot.lastTranscriptKind, assistantMessages: snapshot.stats.assistantMessages).detail
        let tokens = snapshot.stats.tokens
        let total = (tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite)
            .formatted(.number.notation(.compactName))
        let cache = snapshot.stats.latestCacheHitRate.map {
            "\($0.formatted(.number.precision(.fractionLength(1))))%"
        } ?? "—"
        return "\(context) · \(total)\u{00A0}total\u{00A0}tokens · \(cache)\u{00A0}cache\u{00A0}hit"
    }

    private var percent: Double {
        if case .available(_, _, let percent) = usage { return min(100, max(0, percent)) }
        return 0
    }
}
