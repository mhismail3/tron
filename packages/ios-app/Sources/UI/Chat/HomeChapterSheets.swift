import SwiftUI
import TronMobileCore

extension HomeSheet {
    func chapters(_ list: HomeChapterListDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TronSettingsCaption("Newest first. Sealed chapters stay readable and refuse changes.").containerValue(\.tronSettingsSection, false)
            TronListGroup(Array(list.chapters.reversed()), identifier: "home-chapter-list") { chapter in
                TronListButton(HomeChapterPresentation.rowContent(chapter, accent: Self.chapterAccent(chapter.state)),
                               identifier: "home-chapter-\(chapter.ordinal)") {
                    present(.chapter(chapter, limits: list.limits))
                }
            }
        }
    }

    func chapterDetail(_ chapter: HomeChapterListDTO.Chapter, limits: HomeChapterListDTO.Limits) -> some View {
        TronSettingsSections(alignment: .leading, spacing: 18) {
            chapterHeader(chapter, limits: limits)
            if let contents = chapter.contents {
                if let topics = contents.topics, !topics.isEmpty {
                    TronSettingsGroup("Topics", accent: accent) {
                        VStack(spacing: 0) {
                            ForEach(Array(topics.enumerated()), id: \.offset) { index, topic in
                                if index > 0 { divider() }
                                Button { reading = HomeTextReading(id: "topic-\(index)", title: "Topic", text: topic) } label: {
                                    TronSettingsRow(icon: nil, title: HomeChapterPresentation.topicPreview(topic), accent: accent,
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
            TronGlassCard(accent: accent) {
                VStack(spacing: 0) {
                    Button { present(.memory(sessionID: chapter.sessionId, chapterOrdinal: chapter.ordinal)) } label: {
                        TronSettingsRow(icon: "brain", title: "Browse memory",
                                        subtitle: "What Home remembers from this chapter", accent: accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-chapter-browse-memory")
                    if chapter.state == .sealed, chapter.sessionPresent, let onOpenSession {
                        divider()
                        Button { onOpenSession(chapter.sessionId) } label: {
                            TronSettingsRow(icon: "book.pages", title: "Open chapter transcript",
                                            subtitle: "Read-only; sealed history refuses changes", accent: accent)
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
                    .tint(accent)
                    .accessibilityLabel("Size against the rollover limit")
                    .accessibilityValue("\(percent) percent")
            }
            Text(HomeChapterPresentation.sizeLine(chapter, limits: limits))
                .font(SessionSummaryTypography.usageValue)
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("home-chapter-size")
            if let contents = chapter.contents {
                ToolChipFlowLayout(spacing: TronSpacing.sm) {
                    ForEach(HomeChapterPresentation.contentsLines(contents).map { $0.text }, id: \.self) { stat in
                        TronListTagPill(tag: TronListTag(text: stat))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-chapter-stats")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: accent, tintOpacity: 0.14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-chapter-header")
    }

    static func chapterAccent(_ state: HomeChapterListDTO.Chapter.State) -> Color {
        switch state {
        case .active: .tronEmerald
        case .sealed: .tronSlate
        case .reserved, .materializing: .tronAmber
        }
    }
}

extension HomeChapterPresentation {
    static func rowContent(_ chapter: HomeChapterListDTO.Chapter, accent: Color) -> TronListRowContent {
        let contents = chapter.contents
        let tags = [contents?.userMessages.map { "\($0.formatted()) \($0 == 1 ? "message" : "messages")" },
                    contents?.tasksDelegated.map { "\($0.formatted()) \($0 == 1 ? "task" : "tasks")" }]
            .compactMap { $0 }.map { TronListTag(text: $0) }
        return TronListRowContent(
            title: "Chapter \(chapter.ordinal)",
            status: TronListStatus(text: stateLabel(chapter.state), tone: accent, live: chapter.state == .active),
            subtext: contents?.topics?.first.map { topicPreview($0) },
            tags: tags, timestamp: shortRange(chapter))
    }

    static func shortRange(_ chapter: HomeChapterListDTO.Chapter) -> String? {
        guard let start = GatewayTimestamp.parse(chapter.createdAt) else { return nil }
        let style = Date.FormatStyle().month(.abbreviated).day()
        guard let sealed = chapter.sealedAt.flatMap(GatewayTimestamp.parse) else { return "\(start.formatted(style)) – now" }
        return HomeSheetTime.range(chapter.createdAt, chapter.sealedAt) ?? sealed.formatted(style)
    }
}
