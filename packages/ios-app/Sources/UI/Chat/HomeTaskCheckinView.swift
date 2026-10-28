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
        // This is one record, not a stack of independently padded settings rows.
        // Keep the shared list's outer insets and inter-block rhythm exactly once.
        VStack(alignment: .leading, spacing: TronListMetrics.headerGap) {
            HStack(alignment: .firstTextBaseline, spacing: TronListMetrics.slotGap) {
                if let heading {
                    HStack(spacing: TronListMetrics.slotGap) {
                        Image(systemName: "text.bubble").foregroundStyle(accent)
                        Text(heading).foregroundStyle(Color.tronTextPrimary)
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    Spacer(minLength: 0)
                }
                Button { showingTime = true } label: {
                    HStack(spacing: TronListMetrics.lineGap) {
                        Image(systemName: "clock")
                        Text(HomeSheetTime.relative(checkin.at) ?? checkin.at)
                            .tronListMarker(.title)
                    }
                        .font(TronTypography.settingsRowSubtext)
                        .foregroundStyle(Color.tronTextSecondary)
                        .tronListMarkers("\(identifier)-timestamp")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(HomeSheetTime.relative(checkin.at) ?? checkin.at), \(absoluteTime)")
                .accessibilityHint("Show the exact check-in time and operation")
                .accessibilityIdentifier("\(identifier)-time")
                .popover(isPresented: $showingTime) {
                    VStack(alignment: .leading, spacing: TronListMetrics.headerGap) {
                        Text(verbatim: absoluteTime).font(TronTypography.subheadline)
                        Text(verbatim: "Operation: \(checkin.operationId)").font(TronTypography.settingsRowSubtext)
                    }
                    .padding(16)
                    .accessibilityIdentifier("\(identifier)-absolute-time")
                    .presentationCompactAdaptation(.popover)
                }
            }
            VStack(alignment: .leading, spacing: TronListMetrics.lineGap) {
                Text(verbatim: checkin.step)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .tronListMarker(.title)
                if let metadata {
                    Text(verbatim: metadata)
                        .font(TronTypography.settingsRowSubtext)
                        .foregroundStyle(Color.tronTextSecondary)
                        .tronListMarker(.subtext)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .tronListMarkers("\(identifier)-summary")
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
        .padding(.horizontal, TronListMetrics.horizontalPadding)
        .padding(.vertical, TronListMetrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: TronListMetrics.lineGap) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .tronListMarker(.title)
            Text(verbatim: text)
                .font(TronTypography.subheadline)
                .foregroundStyle(Color.tronTextPrimary)
                .tronListMarker(.subtext)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(identifier)-\(suffix)")
        .tronListMarkers("\(identifier)-\(suffix)")
    }
}
