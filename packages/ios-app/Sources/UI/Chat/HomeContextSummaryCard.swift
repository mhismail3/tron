import SwiftUI
import TronMobileCore

/// Home's activation context is not a normal session's section-by-section summary.
/// Context remaining describes the current request; total tokens is cumulative usage.
struct HomeContextSummaryCard: View {
    let snapshot: SessionContextPresentation
    let read: HomeManageDTO

    // Temporary native review alternative; removed once the maintainer chooses.
    private var insetMetrics: Bool {
        #if HOSTED_TEST
        ProcessInfo.processInfo.arguments.contains("-home-summary-inset-metrics")
        #else
        false
        #endif
    }

    private var usage: SessionContextUsagePresentation {
        guard let breakdown = read.context.breakdown else { return SessionContextUsagePresentation(snapshot.contextUsage) }
        return .available(used: breakdown.effectiveTokens, window: breakdown.contextWindow,
                          percent: breakdown.contextWindow > 0
                            ? min(100, Double(breakdown.effectiveTokens) / Double(breakdown.contextWindow) * 100) : 0)
    }

    var body: some View {
        TronGlassCard(accent: .tronEmerald) {
            VStack(alignment: .leading, spacing: TronSpacing.xl) {
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
                    Gauge(value: percent, in: 0...100) { Text("Context used") }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(Color.tronEmerald)
                        .labelsHidden()
                        .accessibilityLabel("Context used")
                        .accessibilityValue("\(Int(percent.rounded())) percent")
                        .accessibilityIdentifier("home-context-ring")
                    VStack(alignment: .leading, spacing: TronSpacing.xxs) {
                        switch usage {
                        case .available(let used, let window, _):
                            Text("\(max(0, window - used).formatted(.number.notation(.compactName))) tokens left")
                                .font(SessionSummaryTypography.headline)
                            Text(usage.usedSummary ?? "")
                                .font(SessionSummaryTypography.usageDetail)
                                .foregroundStyle(Color.tronTextSecondary)
                        case .unavailable:
                            Text("Context pending").font(SessionSummaryTypography.headline)
                            Text(SessionContextUsageRefreshPresentation(lastTranscriptKind: snapshot.lastTranscriptKind,
                                                                       assistantMessages: snapshot.stats.assistantMessages).detail)
                                .font(SessionSummaryTypography.detail)
                                .foregroundStyle(Color.tronTextSecondary)
                        }
                        if insetMetrics { metrics.padding(.top, TronSpacing.md) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !insetMetrics { metrics }
            }
            .padding(TronSpacing.xxl)
        }
        .foregroundStyle(Color.tronTextPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(usage.accessibilityLabel)
        .accessibilityIdentifier("home-context-summary")
    }

    private var percent: Double {
        if case .available(_, _, let percent) = usage { return min(100, max(0, percent)) }
        return 0
    }

    private var metrics: some View {
        HStack(spacing: TronSpacing.md) {
            SessionSummaryMetric(value: snapshot.stats.tokens.total.formatted(.number.notation(.compactName)), label: "Total tokens")
            SessionSummaryMetric(value: snapshot.stats.latestCacheHitRate.map {
                "\($0.formatted(.number.precision(.fractionLength(1))))%"
            } ?? "—", label: "Cache hit %")
        }
    }
}
