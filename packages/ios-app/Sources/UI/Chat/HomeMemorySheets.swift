import SwiftUI
import TronMobileCore

/// The memory browser, its row detail, and exact evidence. Rows follow the
/// Knowledge rows: a role glyph, a title from the summary, and one secondary line.
extension HomeSheet {
    /// The chapter a memory browser is filtered to, when it was opened from a chapter.
    var memoryFilter: String? {
        if case .memory(let sessionID) = destination { sessionID } else { nil }
    }

    @ViewBuilder func memory(_ page: HomeMemoryPageDTO, chapterOrdinals: [String: Int]) -> some View {
        let filter = memoryFilter
        if page.items.isEmpty {
            TronPlaceholderState(title: "No memory yet", detail: "Memory appears after Home admits conversation history.", icon: "brain")
        } else {
            if let filter {
                TronGlassCard(accent: .tronKnowledge) {
                    TronSettingsRow(icon: "book", title: chapterOrdinals[filter].map { "Chapter \($0)" } ?? "This chapter",
                                    subtitle: "Showing only this chapter's memory", accent: .tronKnowledge)
                }
            }
            TronGlassCard(accent: .tronKnowledge) {
                VStack(spacing: 0) {
                    ForEach(Array(page.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { TronSettingsDivider(accent: .tronKnowledge) }
                        memoryRow(item, chapterOrdinal: chapterOrdinals[item.evidence.sessionId])
                    }
                }
            }
        }
        if let next = page.nextCursor, let last = page.items.last {
            pageRow(title: "Next memory page", id: "home-memory-next-page") {
                request = HomeSheetRequest(query: .memory(sessionID: filter, continuation: .init(
                    cursor: next, revision: page.revision, homeId: page.homeId, afterIndex: last.index)))
            }
        }
        if case .memory(_, .some(_)) = request.query {
            pageRow(title: "First memory page", id: "home-memory-first-page") { reload() }
        }
    }

    func memoryRow(_ item: HomeMemoryPageDTO.Item, chapterOrdinal: Int?) -> some View {
        let title = item.summary?.text ?? item.projection.text
        let secondary = [HomeSheetTime.relative(item.timestamp), chapterOrdinal.map { "chapter \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        return Button { present(.memoryItem(item, chapterOrdinal: chapterOrdinal)) } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: Self.attributionIcon(item.attribution))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(Color.tronKnowledge)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(2)
                    if !secondary.isEmpty {
                        Text(secondary)
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronKnowledge)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-memory-row-\(item.index)")
    }

    /// The detail a memory row opens: its summary, its projection, and the one
    /// standard row to the canonical evidence behind it.
    func memoryDetail(_ item: HomeMemoryPageDTO.Item, chapterOrdinal: Int?) -> some View {
        let origin = HomeMemoryOrigin(attribution: item.attribution, timestamp: item.timestamp, chapterOrdinal: chapterOrdinal)
        return VStack(alignment: .leading, spacing: 14) {
            TronGlassCard(accent: .tronKnowledge) {
                TronSettingsRow(icon: Self.attributionIcon(item.attribution),
                                title: Self.attributionLabel(item.attribution),
                                subtitle: [HomeSheetTime.relative(item.timestamp), chapterOrdinal.map { "Chapter \($0)" }]
                                    .compactMap { $0 }.joined(separator: " · "),
                                accent: .tronKnowledge)
            }
            if let summary = item.summary {
                readingCard(caption: summary.truncated ? "Summary · truncated" : "Summary", text: summary.text)
            }
            readingCard(caption: item.projection.omitted ? "Projection · omitted from view" : "Projection", text: item.projection.text)
            if !item.projection.omissions.isEmpty {
                Text("Omitted: \(item.projection.omissions.joined(separator: ", "))")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextMuted)
            }
            TronGlassCard(accent: .tronKnowledge) {
                Button { present(.evidence(item.evidence, origin: origin)) } label: {
                    TronSettingsRow(icon: "doc.text.magnifyingglass", title: "Exact evidence",
                                    subtitle: "The canonical text this memory came from", accent: .tronKnowledge) {
                        Image(systemName: "chevron.right")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronKnowledge)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-memory-exact-evidence")
            }
        }
        .accessibilityIdentifier("home-memory-detail")
    }

    /// The canonical history of one memory entry, paged in bounded characters.
    func evidenceSheet(_ page: HomeMemoryEvidencePageDTO, origin: HomeMemoryOrigin) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TronGlassCard(accent: .tronKnowledge) {
                VStack(spacing: 0) {
                    TronValueRow(icon: Self.attributionIcon(origin.attribution), title: "Role",
                                 value: Self.attributionLabel(origin.attribution))
                    if let time = HomeSheetTime.relative(origin.timestamp) {
                        TronSettingsDivider(accent: .tronKnowledge)
                        TronValueRow(icon: "clock", title: "Time", value: time)
                    }
                    if let ordinal = origin.chapterOrdinal {
                        TronSettingsDivider(accent: .tronKnowledge)
                        TronValueRow(icon: "book", title: "Chapter", value: "\(ordinal)")
                    }
                    TronSettingsDivider(accent: .tronKnowledge)
                    Text("\(page.evidence.sessionId) · \(page.evidence.entryId)")
                        .font(TronTypography.code(size: TronTypography.sizeCaption))
                        .foregroundStyle(Color.tronTextMuted)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .accessibilityIdentifier("home-evidence-reference")
                }
            }
            Text("Canonical history, not the memory projection")
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextMuted)
            TronGlassCard(accent: .tronKnowledge) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(page.text)
                        .font(TronTypography.body)
                        .lineSpacing(5)
                        .foregroundStyle(Color.tronTextPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("home-evidence-text")
                    Text("Characters \(page.offset)–\(page.offset + page.text.utf16.count) of \(page.totalCharacters)")
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                }
                .padding(16)
            }
            if let previous = page.previousOffset {
                pageRow(title: "Previous evidence page", id: "home-evidence-previous") {
                    request = HomeSheetRequest(query: .evidence(page.evidence, offset: previous))
                }
            }
            if let next = page.nextOffset {
                pageRow(title: "Next evidence page", id: "home-evidence-next") {
                    request = HomeSheetRequest(query: .evidence(page.evidence, offset: next))
                }
            }
        }
    }

    private func readingCard(caption: String, text: String) -> some View {
        TronGlassCard(accent: .tronKnowledge) {
            VStack(alignment: .leading, spacing: 8) {
                Text(caption)
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
                Text(text)
                    .font(TronTypography.body)
                    .lineSpacing(4)
                    .foregroundStyle(Color.tronTextPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
    }

    /// A standard action row for paging: one chevron row, not a large button.
    func pageRow(title: String, id: String, action: @escaping () -> Void) -> some View {
        TronGlassCard(accent: .tronKnowledge) {
            Button(action: action) {
                TronSettingsRow(icon: "chevron.down", title: title, accent: .tronKnowledge)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
        }
    }

    static func attributionIcon(_ attribution: HomeMemoryPageDTO.Item.Attribution) -> String {
        switch attribution {
        case .user: "person.fill"
        case .assistant: "house.fill"
        case .tool: "wrench.and.screwdriver.fill"
        case .event: "checkmark.seal.fill"
        }
    }

    static func attributionLabel(_ attribution: HomeMemoryPageDTO.Item.Attribution) -> String {
        switch attribution {
        case .user: "You"
        case .assistant: "Home"
        case .tool: "Tool"
        case .event: "Result"
        }
    }
}

/// Relative time for the Home rows, from the Gateway's ISO timestamps.
enum HomeSheetTime {
    static func relative(_ timestamp: String?, now: Date = .now) -> String? {
        guard let timestamp, let date = HomeChapterPresentation.parse(timestamp) else { return nil }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }
}
