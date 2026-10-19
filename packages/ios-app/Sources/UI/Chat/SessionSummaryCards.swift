import SwiftUI
import TronMobileCore

/// Local type adjustments for Manage Session; headings retain the established
/// reading-family scale and other sheets keep their ordinary metadata sizes.
@MainActor
enum SessionSummaryTypography {
    static let metadataSizeAdjustment = TronSettingsLayoutPolicy.metadataSizeAdjustment
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

/// A context window divided into named sections: the bar's segments and the
/// compact legend under it. Manage Home supplies it from `home.context`.
struct SessionContextSegments: Equatable {
    struct Segment: Identifiable, Equatable {
        let id: String
        let label: String
        let tokens: Int
        let color: Color
        /// The section's count in words ("260 summaries"), for VoiceOver.
        let detail: String?
    }
    let used: Int
    let window: Int
    let segments: [Segment]
}

/// The stats card Manage Session and Manage Home show. Manage Home supplies an
/// accessory (its state pill and last activation), placed on a header row above
/// the usage, and segments, which replace the plain bar with one segment per
/// section and a compact legend above the metrics.
struct SessionContextUsageCard<Accessory: View>: View {
    let snapshot: SessionContextPresentation
    let accessory: Accessory?
    var segments: SessionContextSegments?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(snapshot: SessionContextPresentation, accessory: Accessory?, segments: SessionContextSegments? = nil) {
        self.snapshot = snapshot
        self.accessory = accessory
        self.segments = segments
    }

    var body: some View {
        let usage = segments.map { segments in
            SessionContextUsagePresentation.available(
                used: segments.used, window: segments.window,
                percent: segments.window > 0 ? min(100, Double(segments.used) / Double(segments.window) * 100) : 0)
        } ?? SessionContextUsagePresentation(snapshot.contextUsage)
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
            if let accessory {
                HStack(spacing: 0) {
                    accessory
                    Spacer(minLength: 0)
                }
            }
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
                if let segments {
                    SessionContextSegmentedBar(segments: segments)
                    SessionContextSegmentLegend(segments: segments)
                } else {
                    ProgressView(value: percent, total: 100)
                        .tint(Color.tronEmerald)
                        .accessibilityLabel("Context used")
                        .accessibilityValue("\(Int(percent.rounded())) percent")
                }
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

/// The usage bar split by section, in section order; the free remainder is the track.
struct SessionContextSegmentedBar: View {
    let segments: SessionContextSegments

    var body: some View {
        let window = CGFloat(max(segments.window, 1))
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(segments.segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: geometry.size.width * min(1, CGFloat(segment.tokens) / window))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6)
        .background(Capsule().fill(Color.tronSlate.opacity(0.18)))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context window: \(segments.used.formatted()) of \(segments.window.formatted()) tokens")
        .accessibilityIdentifier("context-segmented-bar")
    }
}

/// One compact line per section: its dot, its name and its size, two to a row.
/// The free remainder has no line; the header already says how much is left (#963).
struct SessionContextSegmentLegend: View {
    let segments: SessionContextSegments
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .leading),
                            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(segments.segments) { segment in
                item(Circle().fill(segment.color), label: segment.label, tokens: segment.tokens)
                    .accessibilityLabel([segment.label, segment.detail, "\(segment.tokens.formatted()) tokens"]
                        .compactMap { $0 }.joined(separator: ", "))
                    .accessibilityIdentifier("context-segment-\(segment.id)")
            }
        }
        .padding(.top, 2)
    }

    private func item(_ dot: some View, label: String, tokens: Int) -> some View {
        HStack(spacing: 7) {
            dot.frame(width: 8, height: 8).accessibilityHidden(true)
            Text(label)
                .font(SessionSummaryTypography.metricLabel)
                .foregroundStyle(Color.tronTextSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(tokens.formatted(.number.notation(.compactName)))
                .font(SessionSummaryTypography.usageValue)
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
    }
}

extension SessionContextUsageCard where Accessory == EmptyView {
    init(snapshot: SessionContextPresentation) {
        self.init(snapshot: snapshot, accessory: nil)
    }
}
