import SwiftUI

// MARK: - Remember Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for the Remember tool.
/// Renders content based on action type: memory entries with relevance scores,
/// session listings, JSON event queries, database stats, and schema.
@available(iOS 26.0, *)
struct RememberToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .purple, colorScheme: colorScheme)
    }

    private var action: String {
        ToolArgumentParser.string("action", from: data.arguments) ?? ""
    }

    private var query: String {
        ToolArgumentParser.string("query", from: data.arguments) ?? ""
    }

    private var sessionId: String {
        ToolArgumentParser.string("session_id", from: data.arguments) ?? ""
    }

    private var limit: Int? {
        ToolArgumentParser.integer("limit", from: data.arguments)
    }

    private var category: RememberDetailParser.ActionCategory {
        RememberDetailParser.actionCategory(from: action)
    }

    private let accentColor = Color.purple

    var body: some View {
        NavigationStack {
            ZStack {
                contentBody
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = data.result ?? ""
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.purple.opacity(0.6))
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(accentColor)
                        Text("Remember")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.purple)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.purple)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.purple)
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    actionSection
                        .padding(.horizontal)
                    statusRow
                        .padding(.horizontal)

                    switch data.status {
                    case .success:
                        if let result = data.result {
                            if RememberDetailParser.isError(result) {
                                errorSection(result)
                                    .padding(.horizontal)
                            } else if RememberDetailParser.isNoResults(result) {
                                noResultsSection
                                    .padding(.horizontal)
                            } else {
                                resultContent(result)
                                    .padding(.horizontal)
                            }
                        } else {
                            noResultsSection
                                .padding(.horizontal)
                        }
                    case .error:
                        if let result = data.result {
                            errorSection(result)
                                .padding(.horizontal)
                        }
                    case .running:
                        runningSection
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
                .frame(width: geometry.size.width)
            }
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        ToolDetailSection(title: "Action", accent: accentColor, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: RememberDetailParser.actionIcon(action))
                        .font(.system(size: 16))
                        .foregroundStyle(accentColor)

                    Text(RememberDetailParser.actionDisplayName(action))
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(tint.name)

                    Spacer()

                    Text(action)
                        .font(TronTypography.pill)
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            Capsule()
                                .fill(.clear)
                                .glassEffect(.regular.tint(accentColor.opacity(0.2)), in: Capsule())
                        }
                }

                if !query.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(tint.subtle)
                        Text(query)
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                            .foregroundStyle(tint.body)
                            .lineLimit(3)
                    }
                }

                if !sessionId.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 11))
                            .foregroundStyle(tint.subtle)
                        Text(sessionId)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(tint.secondary)
                            .lineLimit(1)
                    }
                }

                filtersRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var filtersRow: some View {
        let filters = buildFilters()
        if !filters.isEmpty {
            HStack(spacing: 12) {
                ForEach(filters, id: \.label) { filter in
                    HStack(spacing: 4) {
                        Image(systemName: filter.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(tint.subtle)
                        Text(filter.label)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(tint.secondary)
                    }
                }
            }
        }
    }

    private func buildFilters() -> [(icon: String, label: String)] {
        var filters: [(icon: String, label: String)] = []
        if let limit {
            filters.append(("number", "limit: \(limit)"))
        }
        if let offset = ToolArgumentParser.integer("offset", from: data.arguments) {
            filters.append(("arrow.forward", "offset: \(offset)"))
        }
        if let type = ToolArgumentParser.string("type", from: data.arguments) {
            filters.append(("tag", "type: \(type)"))
        }
        if let level = ToolArgumentParser.string("level", from: data.arguments) {
            filters.append(("slider.horizontal.3", "level: \(level)"))
        }
        if let turn = ToolArgumentParser.integer("turn", from: data.arguments) {
            filters.append(("arrow.triangle.2.circlepath", "turn: \(turn)"))
        }
        return filters
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ToolStatusBadge(status: data.status)

                if let ms = data.durationMs {
                    ToolDurationBadge(durationMs: ms)
                }

                if let result = data.result, !RememberDetailParser.isError(result), !RememberDetailParser.isNoResults(result) {
                    let count = entryCount(result)
                    if count > 0 {
                        ToolInfoPill(icon: "text.line.first.and.arrowtriangle.forward", label: "\(count) \(count == 1 ? "entry" : "entries")", color: accentColor)
                    }
                }

                if data.isResultTruncated || (data.result?.contains("[Output truncated") == true) {
                    ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
                }
            }
        }
    }

    private func entryCount(_ result: String) -> Int {
        switch category {
        case .memorySearch:
            return RememberDetailParser.parseMemoryEntries(from: result).count
        case .sessionList:
            return RememberDetailParser.parseSessions(from: result).count
        case .eventQuery:
            return RememberDetailParser.parseJSONEntries(from: result).count
        default:
            return 0
        }
    }

    // MARK: - Result Content (routed by action category)

    @ViewBuilder
    private func resultContent(_ result: String) -> some View {
        switch category {
        case .memorySearch:
            memoryResultsSection(result)
        case .sessionList:
            sessionListSection(result)
        case .sessionDetail:
            sessionDetailSection(result)
        case .eventQuery:
            jsonEntriesSection(result)
        case .dbStats:
            statsSection(result)
        case .dbSchema, .blobRead:
            codeSection(result)
        }
    }

    // MARK: - Memory Results (recall, search, memory)

    private func memoryResultsSection(_ result: String) -> some View {
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = result
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.purple.opacity(0.6))
                }
            }

            if entries.isEmpty {
                rawContentSection(result)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        if index > 0 {
                            Divider()
                                .background(Color.purple.opacity(0.08))
                                .padding(.horizontal, 8)
                        }
                        memoryEntryRow(entry)
                    }
                }
                .sectionFill(.purple)
            }
        }
    }

    private func memoryEntryRow(_ entry: RememberMemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(entry.index).")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(tint.subtle)
                    .frame(width: 20, alignment: .trailing)

                Text(entry.content)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(tint.body)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let relevance = entry.relevance {
                HStack(spacing: 4) {
                    relevanceBar(relevance)
                    Text("\(relevance)%")
                        .font(TronTypography.pill)
                        .foregroundStyle(relevanceColor(relevance))
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
    }

    private func relevanceBar(_ score: Int) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.purple.opacity(0.1))
                Capsule()
                    .fill(relevanceColor(score))
                    .frame(width: geo.size.width * CGFloat(score) / 100)
            }
        }
        .frame(width: 60, height: 4)
    }

    private func relevanceColor(_ score: Int) -> Color {
        if score >= 75 { return .tronEmerald }
        if score >= 50 { return .tronAmber }
        return .purple
    }

    // MARK: - Session List (sessions)

    private func sessionListSection(_ result: String) -> some View {
        let sessions = RememberDetailParser.parseSessions(from: result)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Sessions")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(tint.heading)

            if sessions.isEmpty {
                rawContentSection(result)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
                        if index > 0 {
                            Divider()
                                .background(Color.purple.opacity(0.08))
                                .padding(.horizontal, 8)
                        }
                        sessionRow(session)
                    }
                }
                .sectionFill(.purple)
            }
        }
    }

    private func sessionRow(_ session: RememberSessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 12))
                    .foregroundStyle(accentColor)

                Text(session.title.isEmpty ? session.sessionId : session.title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.body)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Text(session.sessionId.count > 16 ? String(session.sessionId.prefix(16)) + "..." : session.sessionId)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(tint.subtle)

                if !session.date.isEmpty {
                    Text(RememberDetailParser.formatDate(session.date))
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.subtle)
                }
            }
            .padding(.leading, 20)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    // MARK: - Session Detail (session)

    private func sessionDetailSection(_ result: String) -> some View {
        ToolDetailSection(title: "Session", accent: accentColor, tint: tint) {
            Text(result)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - JSON Entries (events, messages, tools, logs)

    private func jsonEntriesSection(_ result: String) -> some View {
        let entries = RememberDetailParser.parseJSONEntries(from: result)
        let sectionTitle = action == "messages" ? "Messages" : action == "tools" ? "Tool Calls" : action == "logs" ? "Logs" : "Events"

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(sectionTitle)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = result
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.purple.opacity(0.6))
                }
            }

            if entries.isEmpty {
                rawContentSection(result)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: 3)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            if index > 0 {
                                Divider()
                                    .background(Color.purple.opacity(0.12))
                                    .padding(.horizontal, 4)
                            }
                            Text(entry)
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(tint.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
                .sectionFill(.purple)
            }
        }
    }

    // MARK: - Stats (stats)

    private func statsSection(_ result: String) -> some View {
        let stats = RememberDetailParser.parseStats(from: result)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Database Stats")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(tint.heading)

            if stats.isEmpty {
                rawContentSection(result)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(stats, id: \.key) { stat in
                        statCard(stat)
                    }
                }
            }
        }
    }

    private func statCard(_ stat: RememberStatEntry) -> some View {
        VStack(spacing: 6) {
            Image(systemName: stat.icon)
                .font(.system(size: 18))
                .foregroundStyle(accentColor)

            Text(stat.value)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(tint.body)

            Text(stat.label)
                .font(TronTypography.codeCaption)
                .foregroundStyle(tint.subtle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(accentColor.opacity(0.08)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Code Section (schema, read_blob)

    private func codeSection(_ result: String) -> some View {
        let title = action == "schema" ? "Schema" : "Content"

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = result
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.purple.opacity(0.6))
                }
            }

            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 3)

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(result)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .sectionFill(.purple)
        }
    }

    // MARK: - Raw Content Fallback

    private func rawContentSection(_ result: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)

            Text(result)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .sectionFill(.purple)
    }

    // MARK: - No Results

    private var noResultsSection: some View {
        ToolDetailSection(title: "Results", accent: .purple, tint: tint) {
            VStack(spacing: 10) {
                Image(systemName: "brain.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(tint.subtle)
                Text("No results found")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
                if !query.isEmpty {
                    Text("Query: \"\(query)\"")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.subtle.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Error Section

    private func errorSection(_ errorMessage: String) -> some View {
        let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)
        let errorInfo = RememberDetailParser.classifyError(errorMessage)

        return ToolDetailSection(title: "Error", accent: .tronError, tint: errorTint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: errorInfo.icon)
                        .font(.system(size: 20))
                        .foregroundStyle(.tronError)

                    Text(errorInfo.title)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronError)
                }

                if let code = errorInfo.code {
                    ToolInfoPill(icon: "exclamationmark.triangle", label: code, color: .tronError)
                }

                Text(errorInfo.suggestion)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(errorTint.subtle)
            }
        }
    }

    // MARK: - Running Section

    private var runningSection: some View {
        ToolDetailSection(title: "Results", accent: .purple, tint: tint) {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(accentColor)
                    .scaleEffect(1.1)
                Text(category == .memorySearch ? "Searching memory..." : "Querying database...")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }
}

// MARK: - Remember Detail Parser

struct RememberMemoryEntry {
    let index: Int
    let content: String
    let relevance: Int?
}

struct RememberSessionEntry {
    let sessionId: String
    let title: String
    let date: String
}

struct RememberStatEntry {
    let key: String
    let label: String
    let value: String
    let icon: String
}

enum RememberDetailParser {

    enum ActionCategory {
        case memorySearch   // recall, search, memory
        case sessionList    // sessions
        case sessionDetail  // session
        case eventQuery     // events, messages, tools, logs
        case dbStats        // stats
        case dbSchema       // schema
        case blobRead       // read_blob
    }

    static func actionCategory(from action: String) -> ActionCategory {
        switch action {
        case "recall", "search", "memory": return .memorySearch
        case "sessions": return .sessionList
        case "session": return .sessionDetail
        case "events", "messages", "tools", "logs": return .eventQuery
        case "stats": return .dbStats
        case "schema": return .dbSchema
        case "read_blob": return .blobRead
        default: return .memorySearch
        }
    }

    static func actionIcon(_ action: String) -> String {
        switch action {
        case "recall": return "sparkles"
        case "search", "memory": return "magnifyingglass"
        case "sessions": return "rectangle.stack"
        case "session": return "rectangle.portrait"
        case "events": return "list.bullet.rectangle"
        case "messages": return "bubble.left.and.bubble.right"
        case "tools": return "wrench.and.screwdriver"
        case "logs": return "doc.text.magnifyingglass"
        case "stats": return "chart.bar"
        case "schema": return "tablecells"
        case "read_blob": return "doc.fill"
        default: return "brain.fill"
        }
    }

    static func actionDisplayName(_ action: String) -> String {
        switch action {
        case "recall": return "Semantic Recall"
        case "search": return "Keyword Search"
        case "memory": return "Memory Search"
        case "sessions": return "Session List"
        case "session": return "Session Detail"
        case "events": return "Event Query"
        case "messages": return "Messages"
        case "tools": return "Tool Calls"
        case "logs": return "Log Query"
        case "stats": return "Database Stats"
        case "schema": return "Database Schema"
        case "read_blob": return "Read Blob"
        default: return action.capitalized
        }
    }

    // MARK: - Memory Entry Parsing

    static func parseMemoryEntries(from result: String) -> [RememberMemoryEntry] {
        var entries: [RememberMemoryEntry] = []

        // Split by double newline to separate entries
        let blocks = result.components(separatedBy: "\n\n")

        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Match: "1. content (relevance: 92%)" or "1. content"
            if let match = trimmed.firstMatch(of: /^(\d+)\.\s+(.+)/) {
                let index = Int(match.1) ?? 0
                var content = String(match.2)
                var relevance: Int?

                // Extract relevance from end
                if let relMatch = content.firstMatch(of: /\(relevance:\s*(\d+)%\)\s*$/) {
                    relevance = Int(relMatch.1)
                    content = content.replacingOccurrences(
                        of: "\\s*\\(relevance:\\s*\\d+%\\)\\s*$",
                        with: "",
                        options: .regularExpression
                    )
                }

                // Extract readable text from JSON array entries (e.g. thinking blocks with signatures)
                content = extractReadableContent(from: content)

                // Strip <mark> highlight tags from search results
                content = stripHTMLTags(content)

                // Strip line-number prefixes like "31->" from file content
                content = stripLineNumbers(content)

                // Trim very long content for display
                let displayContent = content.count > 500 ? String(content.prefix(500)) + "..." : content

                entries.append(RememberMemoryEntry(
                    index: index,
                    content: displayContent.trimmingCharacters(in: .whitespacesAndNewlines),
                    relevance: relevance
                ))
            }
        }

        return entries
    }

    /// Extracts readable text from JSON array entries that contain thinking/signature blocks.
    /// Raw format: `[{"signature":"...","thinking":"actual text","type":"thinking"},{"name":"Tool",...}]`
    private static func extractReadableContent(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[{") || trimmed.hasPrefix("[\\n{") else { return content }

        guard let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return content
        }

        var parts: [String] = []
        for item in array {
            // Extract thinking text (most useful content)
            if let thinking = item["thinking"] as? String, !thinking.isEmpty {
                parts.append(thinking)
            }
            // Extract text blocks
            else if let text = item["text"] as? String, !text.isEmpty {
                parts.append(text)
            }
        }

        return parts.isEmpty ? content : parts.joined(separator: "\n")
    }

    private static func stripHTMLTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func stripLineNumbers(_ text: String) -> String {
        text.replacingOccurrences(of: "(?m)^\\s*\\d+->", with: "", options: .regularExpression)
    }

    // MARK: - Session Parsing

    static func parseSessions(from result: String) -> [RememberSessionEntry] {
        var sessions: [RememberSessionEntry] = []

        for line in result.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }

            let content = String(trimmed.dropFirst(2))
            let parts = content.components(separatedBy: " | ")

            if parts.count >= 1 {
                sessions.append(RememberSessionEntry(
                    sessionId: parts[0].trimmingCharacters(in: .whitespaces),
                    title: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "",
                    date: parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
                ))
            }
        }

        return sessions
    }

    // MARK: - JSON Entry Parsing

    static func parseJSONEntries(from result: String) -> [String] {
        result.components(separatedBy: "\n---\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Stats Parsing

    static func parseStats(from result: String) -> [RememberStatEntry] {
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var stats: [RememberStatEntry] = []

        if let sessions = json["sessions"] {
            stats.append(RememberStatEntry(key: "sessions", label: "Sessions", value: "\(sessions)", icon: "rectangle.stack"))
        }
        if let events = json["events"] {
            stats.append(RememberStatEntry(key: "events", label: "Events", value: "\(events)", icon: "list.bullet.rectangle"))
        }
        if let tokens = json["totalTokens"] {
            stats.append(RememberStatEntry(key: "tokens", label: "Tokens", value: formatNumber(tokens), icon: "number"))
        }
        if let cost = json["totalCost"] {
            stats.append(RememberStatEntry(key: "cost", label: "Total Cost", value: "\(cost)", icon: "dollarsign.circle"))
        }

        return stats
    }

    // MARK: - Date Formatting

    static func formatDate(_ isoDate: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoDate) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoDate) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        return isoDate
    }

    // MARK: - Error Detection

    static func isError(_ result: String) -> Bool {
        let lower = result.lowercased()
        return lower.hasPrefix("error:") || lower.hasPrefix("invalid action") ||
               lower.contains("\"error\"") || lower.hasPrefix("missing required") ||
               lower.hasPrefix("failed to")
    }

    static func isNoResults(_ result: String) -> Bool {
        result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no results found." ||
        result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no results found"
    }

    static func classifyError(_ message: String) -> (icon: String, title: String, code: String?, suggestion: String) {
        let lower = message.lowercased()

        if lower.contains("invalid action") {
            return ("exclamationmark.triangle.fill", "Invalid Action", "INVALID_ACTION",
                    "The action is not recognized. Valid actions: recall, search, sessions, session, events, messages, tools, logs, stats, schema, read_blob.")
        }
        if lower.contains("missing required") || lower.contains("missing") && lower.contains("session_id") {
            return ("questionmark.circle", "Missing Parameter", "MISSING_PARAM",
                    "A required parameter was not provided. Check the action's required parameters.")
        }
        if lower.contains("not found") {
            return ("magnifyingglass", "Not Found", nil,
                    "The requested resource was not found in the database.")
        }
        if lower.contains("not available") {
            return ("xmark.circle", "Not Available", nil,
                    "This feature is not available in the current backend.")
        }

        return ("exclamationmark.triangle.fill", "Query Failed", nil,
                "An error occurred while querying the database.")
    }

    // MARK: - Helpers

    private static func formatNumber(_ value: Any) -> String {
        if let num = value as? Int {
            if num >= 1_000_000 { return String(format: "%.1fM", Double(num) / 1_000_000) }
            if num >= 1_000 { return String(format: "%.1fK", Double(num) / 1_000) }
            return "\(num)"
        }
        return "\(value)"
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("Remember - Recall Results") {
    RememberToolDetailSheet(
        data: CommandToolChipData(
            id: "call_rem1",
            toolName: "Remember",
            normalizedName: "remember",
            icon: "brain.fill",
            iconColor: .purple,
            displayName: "Remember",
            summary: "recall",
            status: .success,
            durationMs: 125,
            arguments: "{\"action\": \"recall\", \"query\": \"Swift concurrency patterns\", \"limit\": 5}",
            result: "1. [{\"signature\":\"EqwECkYICxgCKkDZP5UvwJgJLM\",\"thinking\":\"The user is asking about <mark>Swift</mark> <mark>concurrency</mark> <mark>patterns</mark>. I should explain async/await, structured concurrency, and actor isolation.\",\"type\":\"thinking\"}] (relevance: 94%)\n\n2. <mark>Structured</mark> <mark>concurrency</mark> in <mark>Swift</mark> ensures child tasks complete before parent scope exits. Use withTaskGroup for dynamic parallelism. (relevance: 87%)\n\n3. Actor isolation prevents data races. Use @MainActor for UI updates, custom actors for shared mutable state. Sendable conformance required for cross-actor transfers. (relevance: 72%)",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Remember - Sessions") {
    RememberToolDetailSheet(
        data: CommandToolChipData(
            id: "call_rem2",
            toolName: "Remember",
            normalizedName: "remember",
            icon: "brain.fill",
            iconColor: .purple,
            displayName: "Remember",
            summary: "sessions",
            status: .success,
            durationMs: 45,
            arguments: "{\"action\": \"sessions\", \"limit\": 5}",
            result: "- sess_abc123 | TypeScript Refactor | 2026-02-15T10:30:00Z\n- sess_def456 | Bug Fix Investigation | 2026-02-14T14:22:00Z\n- sess_ghi789 | API Documentation | 2026-02-13T09:15:00Z",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Remember - Stats") {
    RememberToolDetailSheet(
        data: CommandToolChipData(
            id: "call_rem3",
            toolName: "Remember",
            normalizedName: "remember",
            icon: "brain.fill",
            iconColor: .purple,
            displayName: "Remember",
            summary: "stats",
            status: .success,
            durationMs: 30,
            arguments: "{\"action\": \"stats\"}",
            result: "{\"sessions\": 127, \"events\": 4235, \"totalTokens\": 892150, \"totalCost\": \"$2.35\"}",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Remember - Events") {
    RememberToolDetailSheet(
        data: CommandToolChipData(
            id: "call_rem4",
            toolName: "Remember",
            normalizedName: "remember",
            icon: "brain.fill",
            iconColor: .purple,
            displayName: "Remember",
            summary: "events",
            status: .success,
            durationMs: 80,
            arguments: "{\"action\": \"events\", \"session_id\": \"sess_abc123\", \"type\": \"tool.result\", \"limit\": 3}",
            result: "{\"id\": \"evt_1\", \"type\": \"tool.result\", \"timestamp\": \"2026-02-15T10:31:45Z\", \"turn\": 2, \"toolName\": \"Bash\"}\n---\n{\"id\": \"evt_2\", \"type\": \"tool.result\", \"timestamp\": \"2026-02-15T10:32:10Z\", \"turn\": 3, \"toolName\": \"Read\"}\n---\n{\"id\": \"evt_3\", \"type\": \"tool.result\", \"timestamp\": \"2026-02-15T10:33:20Z\", \"turn\": 4, \"toolName\": \"Remember\"}",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Remember - No Results") {
    RememberToolDetailSheet(
        data: CommandToolChipData(
            id: "call_rem5",
            toolName: "Remember",
            normalizedName: "remember",
            icon: "brain.fill",
            iconColor: .purple,
            displayName: "Remember",
            summary: "recall",
            status: .success,
            durationMs: 60,
            arguments: "{\"action\": \"recall\", \"query\": \"xyznonexistent\"}",
            result: "No results found.",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Remember - Error") {
    RememberToolDetailSheet(
        data: CommandToolChipData(
            id: "call_rem6",
            toolName: "Remember",
            normalizedName: "remember",
            icon: "brain.fill",
            iconColor: .purple,
            displayName: "Remember",
            summary: "invalid",
            status: .error,
            durationMs: 5,
            arguments: "{\"action\": \"invalid\"}",
            result: "Invalid action: \"invalid\". Valid actions: recall, search, memory, sessions, session, events, messages, tools, logs, stats, schema, read_blob",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Remember - Running") {
    RememberToolDetailSheet(
        data: CommandToolChipData(
            id: "call_rem7",
            toolName: "Remember",
            normalizedName: "remember",
            icon: "brain.fill",
            iconColor: .purple,
            displayName: "Remember",
            summary: "recall",
            status: .running,
            durationMs: nil,
            arguments: "{\"action\": \"recall\", \"query\": \"project context\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Remember - Schema") {
    RememberToolDetailSheet(
        data: CommandToolChipData(
            id: "call_rem8",
            toolName: "Remember",
            normalizedName: "remember",
            icon: "brain.fill",
            iconColor: .purple,
            displayName: "Remember",
            summary: "schema",
            status: .success,
            durationMs: 15,
            arguments: "{\"action\": \"schema\"}",
            result: "CREATE TABLE sessions (\n  id TEXT PRIMARY KEY,\n  model TEXT,\n  title TEXT,\n  created_at TEXT,\n  archived INTEGER DEFAULT 0\n)\n\nCREATE TABLE events (\n  id TEXT PRIMARY KEY,\n  session_id TEXT NOT NULL,\n  type TEXT NOT NULL,\n  timestamp TEXT NOT NULL,\n  payload TEXT NOT NULL\n)",
            isResultTruncated: false
        )
    )
}
#endif
