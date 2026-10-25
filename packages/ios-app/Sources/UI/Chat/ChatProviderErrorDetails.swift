import SwiftUI
import TronMobileCore

/// Error content within the shared transcript notification sheet. Counts and
/// identity come from the shared transcript projection, never from view state.
struct ChatProviderErrorDetails: View {
    let run: ChatProviderErrorRun
    @State private var expanded: Set<String>
    private let accent = ChatNotificationTone.error.surfaceColor

    init(run: ChatProviderErrorRun) {
        self.run = run
        _expanded = State(initialValue: Set(run.occurrences.last.map { [$0.id] } ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if run.occurrences.count == 1, let occurrence = run.occurrences.first {
                details(occurrence)
            } else {
                let count = run.breakdown.count
                TronListRow(.init(title: "\(run.occurrences.count) errors · \(count) distinct \(count == 1 ? "error" : "errors")",
                                  subtext: timeRange))
                    .accessibilityIdentifier("chat-error-summary")
                sectionTitle("Breakdown")
                TronListGroup(sections: [TronListSection(title: nil, rows: run.breakdown, tint: accent)], hasLeading: true) { entry in
                    TronListRow(.init(leading: .icon("exclamationmark.triangle.fill", accent), title: entry.first.title,
                                      status: .init(text: "×\(entry.count)", tone: accent), subtext: entry.first.modelLabel))
                }
                sectionTitle("Occurrences · newest first")
                ForEach(run.occurrences.reversed()) { occurrence in
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(occurrence.id) }, set: { open in
                        if open { expanded.insert(occurrence.id) } else { expanded.remove(occurrence.id) }
                    })) {
                        details(occurrence)
                    } label: {
                        TronListRow(.init(title: occurrence.title, timestamp: occurrence.timeLabel))
                            .accessibilityIdentifier("chat-error-occurrence-\(occurrence.id)")
                    }
                    .tint(accent)
                }
            }
        }
    }

    private var timeRange: String {
        guard let first = run.occurrences.first, let last = run.occurrences.last else { return "" }
        return "First \(first.timeLabel) · Last \(last.timeLabel)"
    }
    private func sectionTitle(_ value: String) -> some View {
        Text(value).font(TronTypography.settingsRowSubtext).foregroundStyle(Color.tronTextMuted)
    }
    private func details(_ occurrence: ChatProviderErrorOccurrence) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TronListRow(.init(title: occurrence.modelLabel ?? "Provider error",
                              subtext: [occurrence.info?.type, occurrence.timeLabel].compactMap { $0 }.joined(separator: " · ")))
            if let requestID = occurrence.info?.requestId {
                TronListRow(.init(title: "Request ID", subtext: requestID, monoSubtext: true))
                    .accessibilityIdentifier("chat-error-request-id-\(occurrence.id)")
            }
            if let status = occurrence.info?.httpStatus {
                TronListRow(.init(title: "HTTP status", subtext: "\(status)"))
            }
            ToolDetailCodeBlock(text: occurrence.formatted, accent: accent)
                .accessibilityIdentifier("chat-error-body-\(occurrence.id)")
        }
    }
}
