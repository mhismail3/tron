import SwiftUI
import TronMobileCore

@MainActor
enum SessionSummaryTypography {
    static let metadataSizeAdjustment = TronSettingsLayoutPolicy.metadataSizeAdjustment
    static var headline: Font { TronTypography.sans(size: TronTypography.sizeXL, weight: .bold) }
    static var detail: Font { TronTypography.sans(size: TronTypography.sizeSecondary + metadataSizeAdjustment) }
    static var usageValue: Font { TronTypography.code(size: TronTypography.sizeSecondary + metadataSizeAdjustment) }
    static var metric: Font { TronTypography.code(size: TronTypography.sizeSecondary + metadataSizeAdjustment, weight: .semibold) }
    static var metricLabel: Font { TronTypography.sans(size: TronTypography.sizeSecondary + metadataSizeAdjustment) }
}

struct SessionWorkspaceSummaryRow: View {
    let presentation: SessionWorkspaceRowPresentation
    let accent: Color

    var body: some View {
        switch presentation {
        case .loading:
            TronSettingsRow(
                icon: "arrow.triangle.branch", title: WorkspaceInspectorSheet.title,
                subtitle: "Checking workspace…", accent: accent
            ) {
                TronPulseLoadingIndicator(size: 18)
            }
        case .notRepository:
            TronSettingsRow(icon: "folder", title: WorkspaceInspectorSheet.title, subtitle: "Browse workspace files", accent: accent) {
                Text("No Git")
                    .font(TronTypography.settingsRowSubtext)
                    .foregroundStyle(Color.tronTextSecondary)
            }
        case .loaded(let branch, let dirty, let changeCount):
            let workingTreeStatus = dirty
                ? "\(changeCount) uncommitted \(changeCount == 1 ? "change" : "changes")"
                : "Working tree clean"
            TronSettingsRow(
                icon: "arrow.triangle.branch", title: WorkspaceInspectorSheet.title,
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
                icon: "exclamationmark.triangle", title: WorkspaceInspectorSheet.title,
                subtitle: "Tap to retry workspace inspection", accent: accent
            ) {
                Text("Unavailable")
                    .font(TronTypography.settingsRowSubtext)
                    .foregroundStyle(Color.tronTextSecondary)
            }
        }
    }
}

struct SessionContextSegments: Equatable {
    struct Segment: Identifiable, Equatable {
        let id: String
        let label: String
        let tokens: Int
        let color: Color
        let detail: String?
    }
    let used: Int
    let window: Int
    let segments: [Segment]
}

struct SessionContextUsageCard<Accessory: View, Action: View>: View {
    let snapshot: SessionContextPresentation
    let accessory: Accessory?
    let action: Action?
    var segments: SessionContextSegments?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(snapshot: SessionContextPresentation, accessory: Accessory?, action: Action?, segments: SessionContextSegments? = nil) {
        self.snapshot = snapshot
        self.accessory = accessory
        self.action = action
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
                header {
                    Text(headline).font(SessionSummaryTypography.headline)
                        .accessibilityIdentifier("session-usage-headline")
                    Text(detail).font(TronTypography.settingsRowSubtext)
                        .foregroundStyle(Color.tronTextPrimary)
                        .accessibilityIdentifier("session-usage-detail")
                }
                if let segments {
                    SessionContextSegmentedBar(segments: segments)
                    SessionContextSegmentLegend(segments: segments)
                } else {
                    ProgressView(value: percent, total: 100)
                        .tint(Color.tronPrimary)
                        .accessibilityLabel("Context used")
                        .accessibilityValue("\(Int(percent.rounded())) percent")
                }
            case .unavailable:
                header {
                    Text("0% used")
                        .font(SessionSummaryTypography.headline)
                        .accessibilityIdentifier("session-usage-headline")
                    Text(SessionContextUsageRefreshPresentation(
                        lastTranscriptKind: snapshot.lastTranscriptKind,
                        assistantMessages: snapshot.stats.assistantMessages
                    ).detail)
                        .font(SessionSummaryTypography.detail)
                        .foregroundStyle(Color.tronTextSecondary)
                        .accessibilityIdentifier("session-usage-detail")
                }
                ProgressView(value: 0, total: 100)
                    .tint(Color.tronPrimary)
                    .accessibilityLabel("Context estimate pending")
                    .accessibilityValue("Displayed as zero percent until refreshed")
            }
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
        .tronGlassSurface(accent: .tronPrimary, tintOpacity: 0.14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(usage.accessibilityLabel)
        .accessibilityIdentifier("session-usage-summary")
    }

    private func header(@ViewBuilder lines: () -> some View) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 2) { lines() }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action { action }
        }
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

extension SessionContextUsageCard where Action == EmptyView {
    init(snapshot: SessionContextPresentation, accessory: Accessory?, segments: SessionContextSegments? = nil) {
        self.init(snapshot: snapshot, accessory: accessory, action: nil, segments: segments)
    }
}

extension SessionContextUsageCard where Accessory == EmptyView {
    init(snapshot: SessionContextPresentation, action: Action?) {
        self.init(snapshot: snapshot, accessory: nil, action: action)
    }
}
