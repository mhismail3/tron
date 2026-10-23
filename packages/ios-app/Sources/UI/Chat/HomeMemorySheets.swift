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
                            subtitle: HomeMemoryPresentation.text(line), subtitleLineLimit: 3,
                            subtitleIsMarkdown: line.item?.isToolActivity != true, accent: accent) {
                Text(HomeMemoryPresentation.when(line) ?? "")
                    .font(TronTypography.settingsRowSubtext)
                    .foregroundStyle(Color.tronTextMuted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(line.isSummary ? "home-memory-summary-\(line.start)-\(line.span)" : "home-memory-row-\(line.start)")
    }

    /// One summary line: its text whole, then the two lines under it.
    private func memorySummary(_ line: HomeMemoryViewDTO.Line, halves: [HomeMemoryViewDTO.Line]) -> some View {
        TronSettingsSections(alignment: .leading, spacing: 18) {
            TronGlassCard(accent: accent) {
                VStack(alignment: .leading, spacing: 0) {
                    TronSettingsRow(icon: HomeMemoryPresentation.icon(line), title: HomeMemoryPresentation.title(line),
                                    subtitle: HomeSheetTime.range(line.firstAt, line.lastAt), accent: accent)
                    divider()
                    markdownText(HomeMemoryPresentation.text(line))
                }
            }
            TronSettingsGroup("Covers", detail: "The two halves this summary was made from.", accent: accent) {
                memoryLines(halves)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-memory-summary-detail")
    }

    /// A message: who said it and when, the message as Home recorded it, what Home
    /// remembers of it when that differs, and the canonical evidence behind it.
    func memoryDetail(_ item: HomeMemoryItemDTO) -> some View {
        let message = item.projection.text
        let remembered = item.summary.map { HomeMemoryPresentation.strip($0.text) }
            .flatMap { HomeMemoryPresentation.differs($0, from: message) ? $0 : nil }
        return TronSettingsSections(alignment: .leading, spacing: 18) {
            if let remembered {
                TronSettingsGroup("Summary", accent: accent) { markdownText(remembered) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("home-memory-remembered")
            }
            TronGlassCard(accent: accent) {
                VStack(alignment: .leading, spacing: 0) {
                    TronSettingsRow(icon: Self.attributionIcon(item.attribution), title: Self.attributionLabel(item.attribution),
                                    subtitle: HomeSheetTime.relative(item.timestamp), accent: accent)
                    divider()
                    if item.isToolActivity {
                        ToolDetailCodeBlock(text: message, accent: accent)
                            .padding(16)
                            .accessibilityIdentifier("home-memory-raw-output")
                    } else {
                        markdownText(message)
                    }
                    if item.projection.omitted || !item.projection.omissions.isEmpty {
                        TronCaption("Part of this message is left out of memory.")
                            .padding(.horizontal, 16).padding(.bottom, 14)
                    }
                }
            }
            TronGlassCard(accent: accent) {
                Button { present(.evidence(item.evidence)) } label: {
                    TronSettingsRow(icon: "doc.text.magnifyingglass", title: "View canonical transcript",
                                    subtitle: "The canonical text this memory came from", accent: accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-memory-canonical-transcript")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-memory-detail")
    }

    /// The canonical history of one memory entry, paged in bounded characters.
    func evidenceSheet(_ page: HomeMemoryEvidencePageDTO) -> some View {
        TronSettingsSections(alignment: .leading, spacing: 18) {
            Text(page.text)
                .font(TronFont.mono())
                .foregroundStyle(Color.tronTextPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("home-evidence-text")
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

    /// Only facts this browser actually carries; never imply a model or timestamp
    /// that the memory store did not record.
    var memoryMetadata: [TronTechnicalMetadataItem]? {
        switch destination {
        case .memoryItem(let item):
            var rows: [TronTechnicalMetadataItem] = [
                .init(title: "Kind", value: item.kind.rawValue, icon: "tag"),
                .init(title: "Message index", value: String(item.index), icon: "number"),
                .init(title: "Entry ID", value: item.evidence.entryId, icon: "text.alignleft"),
                .init(title: "Chapter session ID", value: item.evidence.sessionId, icon: "books.vertical"),
                .init(title: "Source digest", value: item.evidence.sourceDigest, icon: "number"),
                .init(title: "Level", value: "0", icon: "square.stack"),
                .init(title: "Projection bytes", value: String(item.projection.text.utf8.count), icon: "doc"),
                .init(title: "Projection characters", value: String(item.projection.text.utf16.count), icon: "textformat"),
                .init(title: "Omitted", value: item.projection.omitted ? "Yes" : "No", icon: "text.badge.minus"),
                .init(title: "Omitted parts", value: item.projection.omissions.isEmpty ? "None" : item.projection.omissions.joined(separator: ", "), icon: "text.badge.minus"),
            ]
            if let timestamp = item.timestamp { rows.append(.init(title: "Timestamp", value: timestamp, icon: "clock")) }
            if let tool = item.display?.toolName { rows.append(.init(title: "Tool", value: tool, icon: "wrench.adjustable")) }
            if let status = item.display?.status { rows.append(.init(title: "Status", value: status, icon: "checkmark.circle")) }
            if let summary = item.summary {
                rows.append(.init(title: "Summary truncated", value: summary.truncated ? "Yes" : "No", icon: "text.badge.minus"))
            }
            return rows
        case .memorySummary(let line, let sessionID):
            var rows: [TronTechnicalMetadataItem] = [
                .init(title: "Kind", value: "Summary", icon: "tag"),
                .init(title: "Message range", value: "\(line.start)–\(line.start + line.span - 1)", icon: "number"),
                .init(title: "Messages", value: String(line.span), icon: "text.alignleft"),
                .init(title: "Level", value: String(line.span.trailingZeroBitCount), icon: "square.stack"),
                .init(title: "Summary bytes", value: String((line.text ?? "").utf8.count), icon: "doc"),
                .init(title: "Summary truncated", value: line.truncated ? "Yes" : "No", icon: "text.badge.minus"),
            ]
            if let sessionID { rows.append(.init(title: "Chapter session ID", value: sessionID, icon: "books.vertical")) }
            if let first = line.firstAt { rows.append(.init(title: "First message", value: first, icon: "clock")) }
            if let last = line.lastAt { rows.append(.init(title: "Last message", value: last, icon: "clock")) }
            return rows
        default: return nil
        }
    }

    /// Memory text is Home's own words, often markdown: the chat renderer shows it.
    func markdownText(_ text: String) -> some View {
        TronMarkdownView(text: text, streaming: false)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    /// A standard action row for paging.
    func pageRow(title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        TronGlassCard(accent: accent) {
            Button(action: action) {
                TronSettingsRow(icon: icon, title: title, accent: accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
        }
    }

    nonisolated static func attributionIcon(_ attribution: HomeMemoryItemDTO.Attribution) -> String {
        switch attribution {
        case .user: "person.fill"
        case .assistant: "house.fill"
        case .tool: "wrench.and.screwdriver.fill"
        case .event: "checkmark.seal.fill"
        }
    }

    nonisolated static func attributionLabel(_ attribution: HomeMemoryItemDTO.Attribution) -> String {
        switch attribution {
        case .user: "You"
        case .assistant: "Home"
        case .tool: "Tool"
        case .event: "Result"
        }
    }
}

extension HomeMemoryItemDTO {
    var isToolActivity: Bool {
        kind == .echo || display?.kind == .toolCall || display?.kind == .toolResult
    }
}

/// One owner of the memory lines' derived text, so rows and details agree.
@MainActor
enum HomeMemoryPresentation {
    static func icon(_ line: HomeMemoryViewDTO.Line) -> String {
        guard let item = line.item else { return "text.append" }
        return HomeSheet.attributionIcon(item.attribution)
    }

    static func title(_ line: HomeMemoryViewDTO.Line) -> String {
        if let item = line.item { return HomeSheet.attributionLabel(item.attribution) }
        return "Summary of \(line.span.formatted()) \(line.span == 1 ? "message" : "messages")"
    }

    static func text(_ line: HomeMemoryViewDTO.Line) -> String {
        guard let item = line.item else { return line.text ?? "Not summarized yet" }
        if item.projection.omitted { return "Message left out of memory" }
        guard item.isToolActivity else { return line.text ?? "Not summarized yet" }
        let display = item.display
        let tool = display?.toolName.map { ToolDetailPresentation.displayTitle(for: $0) } ?? "Tool"
        if item.kind == .echo || display?.kind == .toolResult {
            let status = display?.status == "error" ? "Error" : display?.status == "ok" ? "Completed" : "Result"
            let size = ByteCountFormatter.string(fromByteCount: Int64(item.projection.text.utf8.count), countStyle: .file)
            return "\(tool) · \(status) · \(size) in memory"
        }
        let count = (display?.toolCount ?? 1) > 1 ? " + \((display?.toolCount ?? 1) - 1) more" : ""
        return [tool + count, display?.target].compactMap { $0 }.joined(separator: " · ")
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

    /// "Oct 13, 2026 at 10:30 PM · 2 days ago", for a detail row that names one instant.
    static func absolute(_ timestamp: String, now: Date = .now) -> String {
        guard let date = HomeChapterPresentation.parse(timestamp) else { return timestamp }
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return "\(when) · \(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now))"
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
