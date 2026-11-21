import SwiftUI
import TronMobileCore

struct ChatProviderErrorDetails: View {
    let run: ChatProviderErrorRun
    private let accent = ChatNotificationTone.error.surfaceColor

    var body: some View {
        TronSettingsSections(alignment: .leading, spacing: TronSpacing.section) {
            if run.occurrences.count == 1, let occurrence = run.occurrences.first {
                TronSettingsGroup(nil, accent: accent) {
                    TronSettingsRow(icon: "exclamationmark.triangle.fill", title: occurrence.title,
                                    subtitle: occurrence.timeLabel, accent: accent)
                }
                sections(occurrence, heading: "Details")
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
                ForEach(Array(run.occurrences.reversed().enumerated()), id: \.element.id) { index, occurrence in
                    sections(occurrence, heading: "Occurrence \(run.occurrences.count - index) · \(occurrence.timeLabel)")
                }
            }
        }
        .environment(\.tronSettingsSecondaryTextSizeAdjustment, TronSettingsLayoutPolicy.metadataSizeAdjustment)
    }

    private var timeRange: String {
        guard let first = run.occurrences.first, let last = run.occurrences.last else { return "" }
        return "First \(first.timeLabel) · Last \(last.timeLabel)"
    }

    @ViewBuilder
    private func sections(_ occurrence: ChatProviderErrorOccurrence, heading: String) -> some View {
        TronSettingsGroup(heading, accent: accent) {
            if run.occurrences.count > 1 {
                TronSettingsRow(icon: "exclamationmark.triangle.fill", title: occurrence.title, accent: accent)
                TronSettingsDivider(accent: accent)
            }
            TronSettingsRow(icon: "cpu", title: "Model", subtitle: occurrence.modelLabel ?? "Unknown", accent: accent)
            if let type = occurrence.info?.type {
                TronSettingsDivider(accent: accent)
                TronSettingsRow(icon: "tag", title: "Type", subtitle: type, accent: accent)
            }
            TronSettingsDivider(accent: accent)
            TronSettingsRow(icon: "clock", title: "Time", subtitle: occurrence.timeLabel, accent: accent)
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
        }
        TronSettingsGroup("Message", accent: accent, surfaceStyle: surface(occurrence)) {
            TronSettingsCodeRow(text: occurrence.formatted)
                .accessibilityIdentifier("chat-error-body-\(occurrence.id)")
        }
    }

    private func surface(_ occurrence: ChatProviderErrorOccurrence) -> TronSettingsGroupSurfaceStyle {
        occurrence.raw.count > TronLongContentPolicy.flatSurfaceCharacterThreshold ? .scrollOptimized : .glass
    }
}
