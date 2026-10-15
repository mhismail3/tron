import SwiftUI
import TronMobileCore

/// The chapter ledger and one chapter's detail. The active chapter is the chat
/// the user is in, so only a sealed chapter offers its transcript. A chapter's
/// detail comes from the row the ledger already loaded; it never reads again.
extension HomeSheet {
    func chapters(_ list: HomeChapterListDTO) -> some View {
        // The sheet's title already names the list: one intro line, then the rows.
        VStack(alignment: .leading, spacing: 10) {
            TronSettingsCaption("Newest first. Sealed chapters stay readable and refuse changes.")
            TronGlassCard(accent: .tronSessionTeal) {
                VStack(spacing: 0) {
                    ForEach(Array(list.chapters.reversed().enumerated()), id: \.element.id) { index, chapter in
                        if index > 0 { divider() }
                        Button { present(.chapter(chapter, limits: list.limits)) } label: {
                            TronSettingsRow(icon: chapter.state == .active ? "book" : "book.closed",
                                            title: "Chapter \(chapter.ordinal)",
                                            subtitle: HomeChapterPresentation.dateRange(chapter),
                                            accent: .tronSessionTeal) {
                                TronStatusPill(text: HomeChapterPresentation.stateLabel(chapter.state), accent: Self.chapterAccent(chapter.state))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-chapter-\(chapter.ordinal)")
                    }
                }
            }
        }
    }

    func chapterDetail(_ chapter: HomeChapterListDTO.Chapter, limits: HomeChapterListDTO.Limits) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            chapterHeader(chapter, limits: limits)
            if let contents = chapter.contents {
                let lines = HomeChapterPresentation.contentsLines(contents)
                if !lines.isEmpty {
                    TronGlassCard(accent: .tronSessionTeal) {
                        VStack(spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                if index > 0 { divider() }
                                TronSettingsRow(icon: line.icon, title: line.text, accent: .tronSessionTeal)
                            }
                        }
                    }
                }
                if let topics = contents.topics, !topics.isEmpty {
                    TronSettingsGroup("Topics", detail: "From Home's summaries of this chapter.", accent: .tronSessionTeal) {
                        VStack(spacing: 0) {
                            ForEach(Array(topics.enumerated()), id: \.offset) { index, topic in
                                if index > 0 { divider() }
                                Button { reading = HomeTextReading(id: "topic-\(index)", title: "Topic", text: topic) } label: {
                                    TronSettingsRow(icon: nil, title: HomeChapterPresentation.topicPreview(topic), accent: .tronSessionTeal,
                                                    titleFont: TronTypography.sans(size: TronTypography.sizeBody))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home-chapter-topic-\(index)")
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-chapter-topics")
                }
            }
            TronGlassCard(accent: .tronSessionTeal) {
                VStack(spacing: 0) {
                    Button { present(.memory(sessionID: chapter.sessionId, chapterOrdinal: chapter.ordinal)) } label: {
                        TronSettingsRow(icon: "brain", title: "Browse memory",
                                        subtitle: "What Home remembers from this chapter", accent: .tronSessionTeal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-chapter-browse-memory")
                    // The active chapter is the chat this sheet was opened from.
                    if chapter.state == .sealed, chapter.sessionPresent, let onOpenSession {
                        divider()
                        Button { onOpenSession(chapter.sessionId) } label: {
                            TronSettingsRow(icon: "book.pages", title: "Open chapter transcript",
                                            subtitle: "Read-only; sealed history refuses changes", accent: .tronSessionTeal)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-chapter-open-transcript")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-chapter-detail")
    }

    /// The chapter's name, state and dates, with its size against the rollover limit.
    private func chapterHeader(_ chapter: HomeChapterListDTO.Chapter, limits: HomeChapterListDTO.Limits) -> some View {
        let percent = HomeChapterPresentation.limitPercent(chapter, limits: limits)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Chapter \(chapter.ordinal)")
                    .font(SessionSummaryTypography.headline)
                    .foregroundStyle(Color.tronTextPrimary)
                Spacer(minLength: 0)
                TronStatusPill(text: HomeChapterPresentation.stateLabel(chapter.state), accent: Self.chapterAccent(chapter.state))
            }
            Text(HomeChapterPresentation.dateRange(chapter))
                .font(SessionSummaryTypography.detail)
                .foregroundStyle(Color.tronTextSecondary)
            if let percent {
                ProgressView(value: Double(min(percent, 100)), total: 100)
                    .tint(Color.tronSessionTeal)
                    .accessibilityLabel("Size against the rollover limit")
                    .accessibilityValue("\(percent) percent")
            }
            Text(HomeChapterPresentation.sizeLine(chapter, limits: limits))
                .font(SessionSummaryTypography.usageValue)
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("home-chapter-size")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronSessionTeal, tintOpacity: 0.14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-chapter-header")
    }

    static func chapterAccent(_ state: HomeChapterListDTO.Chapter.State) -> Color {
        switch state {
        case .active: .tronEmerald
        case .sealed: .tronSlate
        case .reserved, .materializing: .tronWarning
        }
    }
}
