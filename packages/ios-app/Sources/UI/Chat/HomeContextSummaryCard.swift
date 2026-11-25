import SwiftUI
import TronMobileCore

struct HomeContextSummaryCard: View {
    let snapshot: SessionContextPresentation?
    let read: HomeManageDTO?

    private var usage: SessionContextUsagePresentation {
        guard let breakdown = read?.context.breakdown else { return SessionContextUsagePresentation(snapshot?.contextUsage) }
        return .available(used: breakdown.effectiveTokens, window: breakdown.contextWindow,
                          percent: breakdown.contextWindow > 0
                            ? min(100, Double(breakdown.effectiveTokens) / Double(breakdown.contextWindow) * 100) : 0)
    }

    var body: some View {
        TronGlassCard(accent: .tronPrimary) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: TronSpacing.xl) {
                    identity
                    statistics(alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: TronSpacing.md) {
                    identity
                    statistics(alignment: .leading)
                        .padding(.leading, TronSettingsLayoutPolicy.iconSize + TronSpacing.xl)
                }
            }
            .padding(TronSpacing.xxl)
        }
        .foregroundStyle(Color.tronTextPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(usage.accessibilityLabel)
        .accessibilityIdentifier("home-context-summary")
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: TronSpacing.xl) {
            SessionContextProgressRing(fraction: percent / 100, accent: .tronPrimary, diameter: Self.ringDiameter)
                .overlay {
                    Text("\(Int(percent.rounded()))%")
                        .font(TronTypography.code(size: TronTypography.sizeSM, weight: .semibold))
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(TronSpacing.xs)
                }
                .frame(width: TronSettingsLayoutPolicy.iconSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Context used")
                .accessibilityValue("\(Int(percent.rounded())) percent")
                .accessibilityIdentifier("home-context-ring")
            VStack(alignment: .leading, spacing: TronSpacing.sm) {
                Group {
                    if snapshot != nil {
                        Text(headline).transition(.opacity)
                    } else {
                        TronLoadingPlaceholder(label: "Loading Home context") { Text("000K tokens left") }
                            .accessibilityIdentifier("home-manage-placeholder")
                    }
                }
                .font(SessionSummaryTypography.headline)
                .fixedSize(horizontal: false, vertical: true)
                pills
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var pills: some View {
        if let read {
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
            .transition(.opacity)
        } else {
            TronLoadingPlaceholder(label: "Loading Home status") {
                HStack(spacing: TronSpacing.md) {
                    TronStatusPill(text: "Ready", accent: .tronSlate)
                    TronStatusPill(text: "0 workers", accent: .tronSlate)
                }
            }
            .accessibilityIdentifier("home-manage-placeholder")
        }
    }

    @ViewBuilder private func statistics(alignment: HorizontalAlignment) -> some View {
        if let snapshot {
            statisticLines(details(snapshot), alignment: alignment)
                .accessibilityIdentifier("home-context-detail")
                .transition(.opacity)
        } else {
            TronLoadingPlaceholder(label: "Loading Home context") {
                statisticLines(["00K/0M", "0.0M total tokens", "00.0% cache hit"], alignment: alignment)
            }
            .accessibilityIdentifier("home-manage-placeholder")
        }
    }

    private func statisticLines(_ lines: [String], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: TronSpacing.xxs) {
            ForEach(lines, id: \.self) { Text($0).lineLimit(1) }
        }
        .font(SessionSummaryTypography.usageValue)
        .foregroundStyle(Color.tronTextSecondary)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if case .available(let used, let window, _) = usage {
            return "\(max(0, window - used).formatted(.number.notation(.compactName))) tokens left"
        }
        return "Context pending"
    }

    private func details(_ snapshot: SessionContextPresentation) -> [String] {
        let context: String
        if case .available(let used, let window, _) = usage {
            context = "\(used.formatted(.number.notation(.compactName)))/\(window.formatted(.number.notation(.compactName)))"
        } else {
            context = "—"
        }
        let tokens = snapshot.stats.tokens
        let total = (tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite)
            .formatted(.number.notation(.compactName))
        let cache = snapshot.stats.latestCacheHitRate.map {
            "\($0.formatted(.number.precision(.fractionLength(1))))%"
        } ?? "—"
        return [context, "\(total) total tokens", "\(cache) cache hit"]
    }

    private static let ringDiameter: CGFloat = 30

    private var percent: Double {
        if case .available(_, _, let percent) = usage { return min(100, max(0, percent)) }
        return 0
    }
}
