import SwiftUI
import TronMobileCore

/// A history row carries its canonical record; opening it admits no second read.
struct HomeTaskCheckinSheet: View {
    let item: HomeTaskHistoryPageDTO.Item
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                if let checkin = item.checkin {
                    TronSettingsGroup("Check-in", accent: .tronPrimary) {
                        HomeTaskCheckinView(checkin: checkin, identifier: "home-history-checkin",
                                            context: "\(item.operationLabel) · \(item.stateLabel)")
                    }.padding(18)
                }
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Check-in", accent: .tronPrimary) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronPrimary) }
                        .accessibilityLabel("Done").accessibilityIdentifier("home-sheet-done-checkin")
                }
            }
        }
    }
}

/// Literal canonical text, never markdown or a whitespace-reconstructed sentence.
/// The same rows render the latest snapshot and every paged history event.
struct HomeTaskCheckinView: View {
    let checkin: HomeTaskCheckinDTO
    let identifier: String
    var context: String? = nil
    var heading: String? = nil
    @Environment(\.tronSettingsVisualTheme) private var theme
    @PresentationState private var showingTime = false
    private var accent: Color { theme?.accent ?? .tronPrimary }

    var body: some View {
        VStack(spacing: 0) {
            if let heading {
                TronSettingsRow(icon: "text.bubble", title: heading, accent: accent)
            }
            TronSettingsRow(icon: nil, title: checkin.step, subtitle: metadata,
                            subtitleLineLimit: nil, accent: accent)
                .tronListMarkers("\(identifier)-summary")
            Button { showingTime = true } label: {
                TronSettingsRow(icon: "clock", title: HomeSheetTime.relative(checkin.at) ?? checkin.at, accent: accent,
                                titleFont: TronTypography.settingsRowSubtext, titleColor: .tronTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(HomeSheetTime.relative(checkin.at) ?? checkin.at), \(absoluteTime)")
            .accessibilityHint("Show the exact check-in time and operation")
            .accessibilityIdentifier("\(identifier)-time")
            .popover(isPresented: $showingTime) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: absoluteTime).font(TronTypography.subheadline)
                    Text(verbatim: "Operation: \(checkin.operationId)").font(TronTypography.settingsRowSubtext)
                }
                .padding(16)
                .accessibilityIdentifier("\(identifier)-absolute-time")
                .presentationCompactAdaptation(.popover)
            }
            section("Done", text: checkin.done, suffix: "done")
            section("Next", text: checkin.next, suffix: "next")
            if let blocker = checkin.blocker { section("Blocked", text: blocker, suffix: "blocked") }
            if let refs = checkin.refs {
                let values = [("Issue", refs.issue), ("Branch", refs.branch), ("Commit", refs.commit)]
                ForEach(values.compactMap { name, value in value.map { (name, $0) } }, id: \.0) { name, value in
                    section(name, text: value, suffix: name.lowercased())
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var absoluteTime: String {
        HomeChapterPresentation.parse(checkin.at)?.formatted(date: .complete, time: .standard) ?? checkin.at
    }
    private var metadata: String? {
        var facts = context.map { [$0] } ?? []
        if checkin.needsAttention == true { facts.append("Needs attention") }
        if let attention = checkin.attention, attention != "none" {
            let label = switch attention {
            case "requested": "Attention requested"
            case "pending": "Attention pending"
            case "rate-limited": "Attention rate-limited"
            default: attention
            }
            facts.append(label)
        }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
    }
    private func section(_ title: String, text: String, suffix: String) -> some View {
        TronSettingsRow(icon: nil, title: title, subtitle: text, subtitleLineLimit: nil,
                        accent: accent, subtitleFont: TronTypography.subheadline)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(identifier)-\(suffix)")
            .tronListMarkers("\(identifier)-\(suffix)")
    }
}
