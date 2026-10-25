import SwiftUI
import TronMobileCore

/// Standard detail sections within the same sheet shell as tool descendants.
/// Counts and identity remain owned by the shared transcript projection.
struct ChatProviderErrorDetails: View {
    let run: ChatProviderErrorRun
    @State private var expanded: Set<String>
    private let accent = ChatNotificationTone.error.surfaceColor

    init(run: ChatProviderErrorRun) {
        self.run = run
        _expanded = State(initialValue: Set(run.occurrences.last.map { [$0.id] } ?? []))
    }

    var body: some View {
        TronSettingsSections(alignment: .leading, spacing: TronSpacing.section) {
            if run.occurrences.count == 1, let occurrence = run.occurrences.first {
                TronSettingsGroup("Details", accent: accent, surfaceStyle: surface(occurrence)) {
                    details(occurrence)
                }
            } else {
                let count = run.breakdown.count
                TronSettingsGroup(nil, accent: accent) {
                    TronSettingsRow(icon: "exclamationmark.triangle.fill",
                                    title: "\(run.occurrences.count) errors · \(count) distinct \(count == 1 ? "error" : "errors")",
                                    subtitle: timeRange, accent: accent)
                        .accessibilityIdentifier("chat-error-summary")
                }
                TronListGroup(sections: [TronListSection(title: "Breakdown", rows: run.breakdown, tint: accent)], hasLeading: true) { entry in
                    TronListRow(.init(leading: .icon("exclamationmark.triangle.fill", accent), title: entry.first.title,
                                      status: .init(text: "×\(entry.count)", tone: accent), subtext: entry.first.modelLabel))
                }
                TronSettingsGroup("Occurrences · newest first", accent: accent, surfaceStyle: .uncontained) {
                    VStack(spacing: TronSpacing.md) {
                        ForEach(run.occurrences.reversed()) { occurrence in
                            TronSettingsGroup(nil, accent: accent, surfaceStyle: surface(occurrence)) {
                                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(occurrence.id) }, set: { open in
                                    if open { expanded.insert(occurrence.id) } else { expanded.remove(occurrence.id) }
                                })) {
                                    TronSettingsDivider(accent: accent)
                                    details(occurrence)
                                } label: {
                                    TronSettingsRow(icon: nil, title: occurrence.title, subtitle: occurrence.timeLabel, accent: accent)
                                        .accessibilityIdentifier("chat-error-occurrence-\(occurrence.id)")
                                }
                                .tint(accent)
                                .padding(.trailing, TronSettingsLayoutPolicy.rowHorizontalPadding)
                            }
                        }
                    }
                }
            }
        }
        .environment(\.tronSettingsSecondaryTextSizeAdjustment, TronSettingsLayoutPolicy.metadataSizeAdjustment)
    }

    private var timeRange: String {
        guard let first = run.occurrences.first, let last = run.occurrences.last else { return "" }
        return "First \(first.timeLabel) · Last \(last.timeLabel)"
    }

    private func surface(_ occurrence: ChatProviderErrorOccurrence) -> TronSettingsGroupSurfaceStyle {
        occurrence.raw.count > TronLongContentPolicy.flatSurfaceCharacterThreshold ? .scrollOptimized : .glass
    }

    private func details(_ occurrence: ChatProviderErrorOccurrence) -> some View {
        VStack(spacing: 0) {
            TronSettingsRow(icon: "cpu", title: occurrence.modelLabel ?? "Provider error",
                            subtitle: [occurrence.info?.type, occurrence.timeLabel].compactMap { $0 }.joined(separator: " · "), accent: accent)
            if let requestID = occurrence.info?.requestId {
                TronSettingsDivider(accent: accent)
                TronSettingsRow(icon: "number", title: "Request ID", subtitle: requestID, accent: accent,
                                subtitleFont: TronTypography.secondaryCodeDescription)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("chat-error-request-id-\(occurrence.id)")
            }
            if let status = occurrence.info?.httpStatus {
                TronSettingsDivider(accent: accent)
                TronSettingsRow(icon: "network", title: "HTTP status", subtitle: "\(status)", accent: accent)
            }
            ToolDetailCodeBlock(text: occurrence.formatted, accent: accent)
                .accessibilityIdentifier("chat-error-body-\(occurrence.id)")
                .padding(TronSettingsLayoutPolicy.rowHorizontalPadding)
        }
    }
}
