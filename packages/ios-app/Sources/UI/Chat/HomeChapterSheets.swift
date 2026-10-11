import SwiftUI
import TronMobileCore

/// The chapter ledger and one chapter's detail. The active chapter is the chat
/// the user is in, so only a sealed chapter offers its transcript.
extension HomeSheet {
    func chapters(_ list: HomeChapterListDTO) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Newest first. Sealed chapters stay readable and refuse changes.")
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextMuted)
            TronGlassCard(accent: .tronSessionTeal) {
                VStack(spacing: 0) {
                    ForEach(Array(list.chapters.reversed().enumerated()), id: \.element.id) { index, chapter in
                        if index > 0 { TronSettingsDivider(accent: .tronSessionTeal) }
                        chapterRow(chapter)
                    }
                }
            }
        }
    }

    private func chapterRow(_ chapter: HomeChapterListDTO.Chapter) -> some View {
        Button { present(.chapter(sessionID: chapter.sessionId)) } label: {
            TronSettingsRow(icon: chapter.state == .active ? "book" : "book.closed",
                            title: "Chapter \(chapter.ordinal)",
                            subtitle: HomeChapterPresentation.dateRange(chapter),
                            accent: .tronSessionTeal) {
                HStack(spacing: 8) {
                    TronStatusPill(text: HomeChapterPresentation.stateLabel(chapter.state), accent: Self.chapterAccent(chapter.state))
                    Image(systemName: "chevron.right")
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronSessionTeal)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-chapter-\(chapter.ordinal)")
    }

    @ViewBuilder func chapterDetail(sessionID: String, list: HomeChapterListDTO) -> some View {
        if let chapter = list.chapters.first(where: { $0.sessionId == sessionID }) {
            VStack(alignment: .leading, spacing: 14) {
                TronGlassCard(accent: .tronSessionTeal) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("Chapter \(chapter.ordinal)")
                                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                                .foregroundStyle(Color.tronTextPrimary)
                            TronStatusPill(text: HomeChapterPresentation.stateLabel(chapter.state), accent: Self.chapterAccent(chapter.state))
                        }
                        Text(HomeChapterPresentation.dateRange(chapter))
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                contentsCard(chapter)
                sizeCard(chapter, limits: list.limits)
                TronGlassCard(accent: .tronSessionTeal) {
                    VStack(spacing: 0) {
                        Button { present(.memory(sessionID: chapter.sessionId)) } label: {
                            TronSettingsRow(icon: "brain", title: "Browse this chapter's memory",
                                            subtitle: "Summaries and projections from this chapter", accent: .tronSessionTeal) {
                                Image(systemName: "chevron.right")
                                    .font(TronTypography.caption)
                                    .foregroundStyle(Color.tronSessionTeal)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-chapter-browse-memory")
                        if chapter.state == .sealed, chapter.sessionPresent, let onOpenSession {
                            TronSettingsDivider(accent: .tronSessionTeal)
                            Button { onOpenSession(chapter.sessionId) } label: {
                                TronSettingsRow(icon: "book.pages", title: "Open chapter transcript",
                                                subtitle: "Sealed history; changes are refused", accent: .tronSessionTeal) {
                                    Image(systemName: "chevron.right")
                                        .font(TronTypography.caption)
                                        .foregroundStyle(Color.tronSessionTeal)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("home-chapter-open-transcript")
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-chapter-detail")
        } else {
            TronPlaceholderState(title: "Chapter not found", detail: "This chapter is no longer in Home's ledger.", icon: "book.closed")
        }
    }

    /// What the chapter holds, from the Gateway's bounded ledger, with its topics.
    @ViewBuilder private func contentsCard(_ chapter: HomeChapterListDTO.Chapter) -> some View {
        if let contents = chapter.contents {
            let lines = HomeChapterPresentation.contentsLines(contents)
            let topics = contents.topics ?? []
            TronGlassCard(accent: .tronSessionTeal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        if index > 0 { TronSettingsDivider(accent: .tronSessionTeal) }
                        TronSettingsRow(icon: "text.bubble", title: line, accent: .tronSessionTeal)
                    }
                    if !topics.isEmpty {
                        if !lines.isEmpty { TronSettingsDivider(accent: .tronSessionTeal) }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Topics")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(Color.tronTextSecondary)
                            ForEach(Array(topics.enumerated()), id: \.offset) { _, topic in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(Color.tronSessionTeal)
                                    Text(topic)
                                        .font(TronTypography.body)
                                        .foregroundStyle(Color.tronTextPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Size against the soft rollover limit, as a small bar.
    private func sizeCard(_ chapter: HomeChapterListDTO.Chapter, limits: HomeChapterListDTO.Limits) -> some View {
        let percent = HomeChapterPresentation.softPercent(chapter, limits: limits)
        return TronGlassCard(accent: .tronSessionTeal) {
            VStack(alignment: .leading, spacing: 10) {
                Text(HomeChapterPresentation.sizeLine(chapter, limits: limits))
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let percent {
                    ProgressView(value: Double(min(percent, 100)), total: 100)
                        .tint(Color.tronSessionTeal)
                        .accessibilityLabel("Size against the soft limit")
                        .accessibilityValue("\(percent) percent")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func chapterAccent(_ state: HomeChapterListDTO.Chapter.State) -> Color {
        switch state {
        case .active: .tronEmerald
        case .sealed: .tronSlate
        case .reserved, .materializing: .tronWarning
        }
    }
}
