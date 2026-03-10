import SwiftUI

// MARK: - Remember Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for the Remember tool.
/// Renders content based on action type: memory entries with relevance scores,
/// session listings, JSON event queries, database stats, and schema.
///
/// Subviews are in `RememberSubviews.swift` (extension).
/// Parser and model types are in `RememberDetailParser.swift`.
@available(iOS 26.0, *)
struct RememberToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    var tint: TintedColors {
        TintedColors(accent: .purple, colorScheme: colorScheme)
    }

    var action: String {
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

    let accentColor = Color.purple

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Remember",
            iconName: "brain.fill",
            accent: .purple,
            copyContent: data.result ?? ""
        ) {
            contentBody
        }
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
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
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        ToolDetailSection(title: "Action", accent: accentColor, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: RememberDetailParser.actionIcon(action))
                        .font(TronTypography.sans(size: TronTypography.sizeTitle))
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
                            .font(TronTypography.sans(size: TronTypography.sizeBody2))
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
                            .font(TronTypography.sans(size: TronTypography.sizeBody2))
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
                            .font(TronTypography.sans(size: TronTypography.sizeBody2))
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
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
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

    // MARK: - No Results

    private var noResultsSection: some View {
        ToolDetailSection(title: "Results", accent: .purple, tint: tint) {
            VStack(spacing: 10) {
                Image(systemName: "brain.fill")
                    .font(TronTypography.sans(size: 28))
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
        ToolClassifiedErrorSection(
            errorMessage: errorMessage,
            classification: RememberDetailParser.classifyError(errorMessage),
            colorScheme: colorScheme
        )
    }

    // MARK: - Running Section

    private var runningSection: some View {
        ToolRunningSpinner(
            title: "Results",
            accent: .purple,
            tint: tint,
            actionText: category == .memorySearch ? "Searching memory..." : "Querying database..."
        )
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
