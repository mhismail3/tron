import SwiftUI

/// Local type adjustments for Manage Session; headings retain the established
/// reading-family scale and other sheets keep their ordinary metadata sizes.
@MainActor
enum SessionSummaryTypography {
    static let metadataSizeAdjustment: CGFloat = 0.5
    static var headline: Font { TronTypography.sans(size: TronTypography.sizeXL, weight: .bold) }
    static var detail: Font { TronTypography.sans(size: TronTypography.sizeSecondary + metadataSizeAdjustment) }
    static var usageValue: Font { TronTypography.code(size: TronTypography.sizeSecondary + metadataSizeAdjustment) }
    static var metric: Font { TronTypography.code(size: TronTypography.sizeSecondary + metadataSizeAdjustment, weight: .semibold) }
    static var metricLabel: Font { TronTypography.sans(size: TronTypography.sizeSecondary + metadataSizeAdjustment) }
}

/// Workspace inspection and navigation stay with the sheet; this row only
/// lays out the current branch beneath its title and the status as a value.
struct SessionWorkspaceSummaryRow: View {
    let presentation: SessionWorkspaceRowPresentation
    let accent: Color

    var body: some View {
        switch presentation {
        case .loading:
            TronSettingsRow(
                icon: "arrow.triangle.branch", title: "Current Branch",
                subtitle: "Checking workspace…", accent: accent
            ) {
                TronPulseLoadingIndicator(size: 18)
            }
        case .notRepository:
            TronSettingsRow(icon: "folder", title: "Current Branch", subtitle: "Browse workspace files", accent: accent) {
                Text("No Git")
                    .font(TronTypography.code(size: TronTypography.sizeCaption + SessionSummaryTypography.metadataSizeAdjustment))
                    .foregroundStyle(Color.tronTextSecondary)
            }
        case .loaded(let branch, let dirty, let changeCount):
            let workingTreeStatus = dirty
                ? "\(changeCount) uncommitted \(changeCount == 1 ? "change" : "changes")"
                : "Working tree clean"
            TronSettingsRow(
                icon: "arrow.triangle.branch", title: "Current Branch",
                subtitle: branch, subtitleLineLimit: 1, accent: accent
            ) {
                Text(workingTreeStatus)
                    .font(TronTypography.code(size: TronTypography.sizeBody2 + SessionSummaryTypography.metadataSizeAdjustment))
                    .foregroundStyle(Color.tronTextPrimary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
            }
        case .failed:
            TronSettingsRow(
                icon: "exclamationmark.triangle", title: "Current Branch",
                subtitle: "Tap to retry workspace inspection", accent: accent
            ) {
                Text("Unavailable")
                    .font(TronTypography.code(size: TronTypography.sizeCaption + SessionSummaryTypography.metadataSizeAdjustment))
                    .foregroundStyle(Color.tronTextSecondary)
            }
        }
    }
}

/// Value-only composition. SessionContextSheet keeps mutation admission,
/// pending selection, compaction progress, and failure presentation ownership.
struct SessionModelSummaryCard<Controls: View, CompactAction: View>: View {
    @Binding var selection: ModelRef?
    let catalog: [ModelSummary]
    let automaticCompactionEnabled: Bool?
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let compactAction: () -> CompactAction
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionLayout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SessionModelSelectionPresentation.modelName(selection, catalog: catalog))
                        .font(SessionSummaryTypography.headline)
                        .foregroundStyle(Color.tronTextPrimary)
                    if let provider = selection?.displayProviderName {
                        Text(provider)
                            .font(SessionSummaryTypography.detail)
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                TronProgressiveSheetLink(accessibilityLabel: "Switch Model", accent: .tronPurple) {
                    ModelPicker(selection: $selection, models: catalog.filter(\.available))
                        .tronNavigationTitle("Models", accent: .tronPurple)
                        .environment(\.tronSettingsSecondaryTextSizeAdjustment, 0)
                        .controlSize(.regular)
                } label: {
                    TronInlineActionLabel("Switch Model")
                }
            }
            .padding(14)
            TronSettingsDivider(accent: .tronPurple)
            controls()
            TronSettingsDivider(accent: .tronPurple)
            TronSettingsRow(
                icon: "rectangle.compress.vertical",
                title: "Automatic Compaction",
                subtitle: SessionCompactionControlPolicy.automaticStatus(automaticCompactionEnabled),
                accent: .tronPurple
            ) {
                compactAction()
            }
        }
        .controlSize(.small)
        .tronGlassSurface(accent: .tronPurple, tintOpacity: 0.14)
        .tronSettingsVisualTheme(accent: .tronPurple)
        .accessibilityIdentifier("session-model-summary")
    }

    private var actionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    }
}

struct SessionContextUsageCard: View {
    let snapshot: SessionContextPresentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let usage = SessionContextUsagePresentation(snapshot.contextUsage)
        let cacheValue = snapshot.stats.latestCacheHitRate.map {
            "\($0.formatted(.number.precision(.fractionLength(1))))%"
        } ?? "—"
        let statistics = [
            (cacheValue, "Cache Hit"),
            ("\(snapshot.stats.tokens.cacheRead.formatted(.number.notation(.compactName))) / \(snapshot.stats.tokens.cacheWrite.formatted(.number.notation(.compactName)))", "Read / Write"),
            (snapshot.stats.tokens.input.formatted(.number.notation(.compactName)), "Input"),
            (snapshot.stats.tokens.output.formatted(.number.notation(.compactName)), "Output"),
            (snapshot.stats.cost.formatted(.currency(code: "USD")), "Cost"),
        ]

        VStack(alignment: .leading, spacing: 9) {
            switch usage {
            case .available(let used, let window, let percent):
                let headline = "\(max(0, window - used).formatted(.number.notation(.compactName))) tokens left"
                let detail = usage.usedSummary ?? ""
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(headline).font(SessionSummaryTypography.headline).fixedSize()
                        Spacer(minLength: 0)
                        Text(detail).font(SessionSummaryTypography.usageValue).fixedSize()
                            .foregroundStyle(Color.tronTextPrimary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headline).font(SessionSummaryTypography.headline)
                        Text(detail).font(SessionSummaryTypography.detail)
                            .foregroundStyle(Color.tronTextPrimary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                ProgressView(value: percent, total: 100)
                    .tint(Color.tronEmerald)
                    .accessibilityLabel("Context used")
                    .accessibilityValue("\(Int(percent.rounded())) percent")
            case .unavailable:
                Text("0% used")
                    .font(SessionSummaryTypography.headline)
                Text(SessionContextUsageRefreshPresentation(
                    lastTranscriptKind: snapshot.lastTranscriptKind,
                    assistantMessages: snapshot.stats.assistantMessages
                ).detail)
                    .font(SessionSummaryTypography.detail)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: 0, total: 100)
                    .tint(Color.tronEmerald)
                    .accessibilityLabel("Context estimate pending")
                    .accessibilityValue("Displayed as zero percent until refreshed")
            }
            // The usage line is also the separator; no duplicate divider or
            // compaction status belongs between this header and its metrics.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 6) {
                    ForEach(statistics.indices, id: \.self) { index in
                        metric(statistics[index].0, statistics[index].1)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(statistics.indices, id: \.self) { index in
                        metric(statistics[index].0, statistics[index].1)
                    }
                }
            }
        }
        .foregroundStyle(Color.tronTextPrimary)
        .padding(14)
        .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(usage.accessibilityLabel)
        .accessibilityIdentifier("session-usage-summary")
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(SessionSummaryTypography.metric)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(SessionSummaryTypography.metricLabel)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(Color.tronTextSecondary)
        .frame(maxWidth: .infinity, minHeight: 42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}
