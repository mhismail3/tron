import SwiftUI
import TronMobileCore

/// The memory browser: the lines Home's memory view holds, newest first. Recent
/// messages are their own lines; older ranges are summary lines that open into the
/// two halves they cover, down to single messages. A message opens its detail and
/// exact evidence. Rows are standard settings rows in Manage Home's accent.
extension HomeSheet {
    /// The chapter a memory browser is filtered to, when it was opened from a chapter.
    var memoryFilter: String? {
        switch destination {
        case .memory(let sessionID, _), .memorySummary(_, let sessionID): sessionID
        default: nil
        }
    }

    @ViewBuilder func memory(_ view: HomeMemoryViewDTO) -> some View {
        if case .memorySummary(let line, _) = destination {
            memorySummary(line, halves: view.lines)
        } else if view.lines.isEmpty {
            TronPlaceholderState(title: "No memory yet", detail: "Memory appears after Home admits conversation history.", icon: "brain")
        } else {
            memoryList(view)
        }
    }

    private func memoryList(_ view: HomeMemoryViewDTO) -> some View {
        let recent = view.lines.filter { !$0.isSummary }
        let summaries = view.lines.filter(\.isSummary)
        return VStack(alignment: .leading, spacing: 18) {
            if case .memory(.some, let ordinal) = destination {
                TronGlassCard(accent: .tronSessionTeal) {
                    TronSettingsRow(icon: "book.closed", title: ordinal.map { "Chapter \($0)" } ?? "This chapter",
                                    subtitle: "Only this chapter's memory", accent: .tronSessionTeal)
                }
            }
            if !recent.isEmpty {
                TronSettingsGroup("Recent messages", detail: "Home sees each of these whole.", accent: .tronSessionTeal) {
                    memoryLines(recent)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-memory-recent")
            }
            if !summaries.isEmpty {
                TronSettingsGroup("Summaries", detail: "Older conversation, as Home sees it. Open one to see what it covers.",
                                  accent: .tronSessionTeal) {
                    memoryLines(summaries)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-memory-summaries")
            }
            if let next = view.nextCursor {
                pageRow(title: "Older memory", icon: "arrow.down", id: "home-memory-next-page") {
                    request = HomeSheetRequest(query: .memory(sessionID: memoryFilter, continuation: .init(
                        cursor: next, revision: view.revision, homeId: view.homeId)))
                }
            }
            if case .memory(_, .some(_)) = request.query {
                pageRow(title: "Newest memory", icon: "arrow.up", id: "home-memory-first-page") { reload() }
            }
        }
    }

    func memoryLines(_ lines: [HomeMemoryViewDTO.Line]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if index > 0 { divider() }
                memoryLineRow(line)
            }
        }
    }

    /// One line of the view: a message with its speaker and time, or a summary with
    /// the number of messages it covers and their dates.
    func memoryLineRow(_ line: HomeMemoryViewDTO.Line) -> some View {
        Button {
            if let item = line.item { present(.memoryItem(item)) }
            else { present(.memorySummary(line, sessionID: memoryFilter)) }
        } label: {
            TronSettingsRow(icon: HomeMemoryPresentation.icon(line), title: HomeMemoryPresentation.title(line),
                            subtitle: HomeMemoryPresentation.text(line), subtitleLineLimit: 3, accent: .tronSessionTeal) {
                Text(HomeMemoryPresentation.when(line) ?? "")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(line.isSummary ? "home-memory-summary-\(line.start)-\(line.span)" : "home-memory-row-\(line.start)")
    }

    /// One summary line: its text whole, then the two lines under it.
    private func memorySummary(_ line: HomeMemoryViewDTO.Line, halves: [HomeMemoryViewDTO.Line]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TronGlassCard(accent: .tronSessionTeal) {
                VStack(alignment: .leading, spacing: 0) {
                    TronSettingsRow(icon: HomeMemoryPresentation.icon(line), title: HomeMemoryPresentation.title(line),
                                    subtitle: HomeSheetTime.range(line.firstAt, line.lastAt), accent: .tronSessionTeal)
                    divider()
                    readingText(HomeMemoryPresentation.text(line))
                }
            }
            TronSettingsGroup("Covers", detail: "The two halves this summary was made from.", accent: .tronSessionTeal) {
                memoryLines(halves)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-memory-summary-detail")
    }

    /// A message: who said it and when, the message as Home recorded it, what Home
    /// remembers of it when that differs, and the canonical evidence behind it.
    func memoryDetail(_ item: HomeMemoryItemDTO) -> some View {
        let origin = HomeMemoryOrigin(attribution: item.attribution, timestamp: item.timestamp)
        let message = item.projection.text
        let remembered = item.summary.map { HomeMemoryPresentation.strip($0.text) }
            .flatMap { HomeMemoryPresentation.differs($0, from: message) ? $0 : nil }
        return VStack(alignment: .leading, spacing: 18) {
            TronGlassCard(accent: .tronSessionTeal) {
                VStack(alignment: .leading, spacing: 0) {
                    TronSettingsRow(icon: Self.attributionIcon(item.attribution), title: Self.attributionLabel(item.attribution),
                                    subtitle: HomeSheetTime.relative(item.timestamp), accent: .tronSessionTeal)
                    divider()
                    readingText(message)
                    if item.projection.omitted || !item.projection.omissions.isEmpty {
                        TronCaption("Part of this message is left out of memory.")
                            .padding(.horizontal, 16).padding(.bottom, 14)
                    }
                }
            }
            if let remembered {
                TronSettingsGroup("Home remembers", accent: .tronSessionTeal) { readingText(remembered) }
                    .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-memory-remembered")
            }
            TronGlassCard(accent: .tronSessionTeal) {
                Button { present(.evidence(item.evidence, origin: origin)) } label: {
                    TronSettingsRow(icon: "doc.text.magnifyingglass", title: "Exact evidence",
                                    subtitle: "The canonical text this memory came from", accent: .tronSessionTeal)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-memory-exact-evidence")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-memory-detail")
    }

    /// The canonical history of one memory entry, paged in bounded characters.
    func evidenceSheet(_ page: HomeMemoryEvidencePageDTO, origin: HomeMemoryOrigin) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TronGlassCard(accent: .tronSessionTeal) {
                VStack(alignment: .leading, spacing: 0) {
                    TronSettingsRow(icon: Self.attributionIcon(origin.attribution), title: Self.attributionLabel(origin.attribution),
                                    subtitle: HomeSheetTime.relative(origin.timestamp), accent: .tronSessionTeal)
                    divider()
                    Text("\(page.evidence.sessionId) · \(page.evidence.entryId)")
                        .font(TronTypography.code(size: TronTypography.sizeCaption))
                        .foregroundStyle(Color.tronTextMuted)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .accessibilityIdentifier("home-evidence-reference")
                }
            }
            TronSettingsGroup("Canonical history",
                              detail: "Characters \(page.offset)–\(page.offset + page.text.utf16.count) of \(page.totalCharacters)",
                              accent: .tronSessionTeal) {
                readingText(page.text).accessibilityIdentifier("home-evidence-text")
            }
            if let previous = page.previousOffset {
                pageRow(title: "Previous evidence page", icon: "arrow.up", id: "home-evidence-previous") {
                    request = HomeSheetRequest(query: .evidence(page.evidence, offset: previous))
                }
            }
            if let next = page.nextOffset {
                pageRow(title: "Next evidence page", icon: "arrow.down", id: "home-evidence-next") {
                    request = HomeSheetRequest(query: .evidence(page.evidence, offset: next))
                }
            }
        }
    }

    func readingText(_ text: String) -> some View {
        Text(text)
            .font(TronTypography.body)
            .lineSpacing(4)
            .foregroundStyle(Color.tronTextPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    /// A standard action row for paging.
    func pageRow(title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        TronGlassCard(accent: .tronSessionTeal) {
            Button(action: action) {
                TronSettingsRow(icon: icon, title: title, accent: .tronSessionTeal)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
        }
    }

    static func attributionIcon(_ attribution: HomeMemoryItemDTO.Attribution) -> String {
        switch attribution {
        case .user: "person.fill"
        case .assistant: "house.fill"
        case .tool: "wrench.and.screwdriver.fill"
        case .event: "checkmark.seal.fill"
        }
    }

    static func attributionLabel(_ attribution: HomeMemoryItemDTO.Attribution) -> String {
        switch attribution {
        case .user: "You"
        case .assistant: "Home"
        case .tool: "Tool"
        case .event: "Result"
        }
    }
}

/// One owner of the memory lines' derived text, so rows and details agree.
enum HomeMemoryPresentation {
    static func icon(_ line: HomeMemoryViewDTO.Line) -> String {
        guard let item = line.item else { return "text.append" }
        return HomeSheet.attributionIcon(item.attribution)
    }

    static func title(_ line: HomeMemoryViewDTO.Line) -> String {
        if let item = line.item { return HomeSheet.attributionLabel(item.attribution) }
        return "Summary of \(line.span.formatted()) messages"
    }

    static func text(_ line: HomeMemoryViewDTO.Line) -> String {
        line.text ?? "Not summarized yet"
    }

    /// A message's relative time; a summary's date range.
    static func when(_ line: HomeMemoryViewDTO.Line, now: Date = .now) -> String? {
        line.isSummary ? HomeSheetTime.range(line.firstAt, line.lastAt) : HomeSheetTime.relative(line.firstAt, now: now)
    }

    /// Memory node text without the `user:`/`talk:`/`echo:`/`event:` kind prefix on each line.
    static func strip(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            for prefix in ["user: ", "talk: ", "echo: ", "event: "] where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
            return String(line)
        }.joined(separator: " ")
    }

    /// Whether a remembered line says something the message itself does not.
    static func differs(_ remembered: String, from message: String) -> Bool {
        let normalize = { (value: String) in value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let a = normalize(remembered), b = normalize(message)
        return !a.isEmpty && a != b && !b.hasPrefix(a.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")))
    }
}

/// Relative time for the Home rows, from the Gateway's ISO timestamps.
enum HomeSheetTime {
    static func relative(_ timestamp: String?, now: Date = .now) -> String? {
        guard let timestamp, let date = HomeChapterPresentation.parse(timestamp) else { return nil }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }

    /// "Mar 3 – Mar 9", or one date when the range is a single day.
    static func range(_ first: String?, _ last: String?) -> String? {
        let dates = [first, last].compactMap { $0.flatMap(HomeChapterPresentation.parse) }
        guard let start = dates.first else { return nil }
        let style = Date.FormatStyle().month(.abbreviated).day()
        let end = dates.last ?? start
        return Calendar.current.isDate(start, inSameDayAs: end)
            ? start.formatted(style) : "\(start.formatted(style)) – \(end.formatted(style))"
    }
}
