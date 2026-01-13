import SwiftUI
import Charts

// MARK: - Session Analytics Sheet

/// Modal sheet showing comprehensive session analytics
/// Following Apple's Human Interface Guidelines for Sheets
struct SessionAnalyticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var eventStoreManager: EventStoreManager

    let sessionId: String

    @State private var events: [SessionEvent] = []
    @State private var isLoading = true

    private var session: CachedSession? {
        eventStoreManager.sessions.first { $0.id == sessionId }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading analytics...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            // Session info header
                            if let session = session {
                                SessionInfoHeader(session: session)
                            }

                            // Summary stats
                            SummaryStatsRow(analytics: analytics)

                            // Turn breakdown
                            if !analytics.turns.isEmpty {
                                TurnBreakdownSection(turns: analytics.turns)
                            }

                            // Tool usage
                            if !analytics.toolUsage.isEmpty {
                                ToolUsageSection(tools: analytics.toolUsage)
                            }

                            // Model usage
                            if analytics.modelUsage.count > 1 {
                                ModelUsageSection(models: analytics.modelUsage)
                            }

                            // Errors
                            if !analytics.errors.isEmpty {
                                ErrorLogSection(errors: analytics.errors)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Session Analytics")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .task {
            await loadEvents()
        }
    }

    private func loadEvents() async {
        do {
            events = try eventStoreManager.getSessionEvents(sessionId)
        } catch {
            // Events will remain empty, showing zeros
        }
        isLoading = false
    }

    private var analytics: SessionAnalytics {
        SessionAnalytics(from: events)
    }
}

// MARK: - Analytics Data Model

struct SessionAnalytics {
    struct TurnData: Identifiable {
        let id = UUID()
        let turn: Int
        let inputTokens: Int
        let outputTokens: Int
        let cost: Double
        var totalTokens: Int { inputTokens + outputTokens }
    }

    struct ToolData: Identifiable {
        let id = UUID()
        let name: String
        var count: Int
        var totalDuration: Int
        var avgDuration: Int { count > 0 ? totalDuration / count : 0 }
        var errorCount: Int
    }

    struct ModelData: Identifiable {
        let id = UUID()
        let model: String
        var tokenCount: Int
    }

    struct ErrorData: Identifiable {
        let id = UUID()
        let timestamp: Date
        let type: String
        let message: String
        let isRecoverable: Bool
    }

    let turns: [TurnData]
    let toolUsage: [ToolData]
    let modelUsage: [ModelData]
    let errors: [ErrorData]

    var totalTurns: Int { turns.count }
    var totalTokens: Int { turns.reduce(0) { $0 + $1.totalTokens } }
    var totalErrors: Int { errors.count }
    var avgLatency: Int

    init(from events: [SessionEvent]) {
        var turnData: [Int: (input: Int, output: Int, cost: Double)] = [:]
        var toolData: [String: (count: Int, duration: Int, errors: Int)] = [:]
        var modelData: [String: Int] = [:]
        var errorList: [ErrorData] = []
        var latencySum = 0
        var latencyCount = 0

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for event in events {
            switch event.eventType {
            case .messageAssistant:
                // Track turn token usage (tokens only, cost comes from streamTurnEnd)
                if let turn = event.payload["turn"]?.value as? Int,
                   let tokenUsage = event.payload["tokenUsage"]?.value as? [String: Any],
                   let input = tokenUsage["inputTokens"] as? Int,
                   let output = tokenUsage["outputTokens"] as? Int {
                    let existing = turnData[turn] ?? (input: 0, output: 0, cost: 0)
                    turnData[turn] = (input: existing.input + input, output: existing.output + output, cost: existing.cost)
                }

                // Track model usage
                if let model = event.payload["model"]?.value as? String {
                    let shortModel = model.shortModelName
                    if let tokenUsage = event.payload["tokenUsage"]?.value as? [String: Any],
                       let input = tokenUsage["inputTokens"] as? Int,
                       let output = tokenUsage["outputTokens"] as? Int {
                        modelData[shortModel, default: 0] += input + output
                    }
                }

                // Track latency
                if let latency = event.payload["latency"]?.value as? Int {
                    latencySum += latency
                    latencyCount += 1
                }

            case .streamTurnEnd:
                // Primary source for turn data with cost
                if let turn = event.payload["turn"]?.value as? Int {
                    let existing = turnData[turn] ?? (input: 0, output: 0, cost: 0)
                    var input = existing.input
                    var output = existing.output

                    // Get token usage if available
                    if let tokenUsage = event.payload["tokenUsage"]?.value as? [String: Any] {
                        if let i = tokenUsage["inputTokens"] as? Int, existing.input == 0 {
                            input = i
                        }
                        if let o = tokenUsage["outputTokens"] as? Int, existing.output == 0 {
                            output = o
                        }
                    }

                    // Get cost from server
                    let cost = event.payload["cost"]?.value as? Double ?? existing.cost

                    turnData[turn] = (input: input, output: output, cost: cost)
                }

            case .toolCall:
                let name = (event.payload["name"]?.value as? String) ?? "unknown"
                let existing = toolData[name] ?? (count: 0, duration: 0, errors: 0)
                toolData[name] = (count: existing.count + 1, duration: existing.duration, errors: existing.errors)

            case .toolResult:
                // Match back to tool call by toolCallId if available
                let isError = (event.payload["isError"]?.value as? Bool) ?? false
                let duration = (event.payload["duration"]?.value as? Int) ?? 0

                // We need to track tool results - for simplicity, update the most recent tool
                // In a real implementation, we'd match by toolCallId
                if let toolName = Self.findToolNameForResult(event, in: events) {
                    let existing = toolData[toolName] ?? (count: 0, duration: 0, errors: 0)
                    toolData[toolName] = (
                        count: existing.count,
                        duration: existing.duration + duration,
                        errors: existing.errors + (isError ? 1 : 0)
                    )
                }

            case .errorAgent:
                let error = (event.payload["error"]?.value as? String) ?? "Unknown error"
                let recoverable = (event.payload["recoverable"]?.value as? Bool) ?? false
                let timestamp = isoFormatter.date(from: event.timestamp) ?? Date()
                errorList.append(ErrorData(timestamp: timestamp, type: "agent", message: error, isRecoverable: recoverable))

            case .errorProvider:
                let error = (event.payload["error"]?.value as? String) ?? "Provider error"
                let retryable = (event.payload["retryable"]?.value as? Bool) ?? false
                let timestamp = isoFormatter.date(from: event.timestamp) ?? Date()
                errorList.append(ErrorData(timestamp: timestamp, type: "provider", message: error, isRecoverable: retryable))

            case .errorTool:
                let error = (event.payload["error"]?.value as? String) ?? "Tool error"
                let toolName = (event.payload["toolName"]?.value as? String) ?? "tool"
                let timestamp = isoFormatter.date(from: event.timestamp) ?? Date()
                errorList.append(ErrorData(timestamp: timestamp, type: "tool", message: "\(toolName): \(error)", isRecoverable: false))

            default:
                break
            }
        }

        // Convert to arrays
        self.turns = turnData.sorted { $0.key < $1.key }.map {
            TurnData(turn: $0.key, inputTokens: $0.value.input, outputTokens: $0.value.output, cost: $0.value.cost)
        }

        self.toolUsage = toolData.map {
            ToolData(name: $0.key, count: $0.value.count, totalDuration: $0.value.duration, errorCount: $0.value.errors)
        }.sorted { $0.count > $1.count }

        self.modelUsage = modelData.map {
            ModelData(model: $0.key, tokenCount: $0.value)
        }.sorted { $0.tokenCount > $1.tokenCount }

        self.errors = errorList.sorted { $0.timestamp < $1.timestamp }

        self.avgLatency = latencyCount > 0 ? latencySum / latencyCount : 0
    }

    private static func findToolNameForResult(_ resultEvent: SessionEvent, in events: [SessionEvent]) -> String? {
        guard let toolCallId = resultEvent.payload["toolCallId"]?.value as? String else { return nil }

        for event in events {
            if event.eventType == .toolCall,
               event.payload["toolCallId"]?.value as? String == toolCallId {
                return event.payload["name"]?.value as? String
            }
        }
        return nil
    }
}

// MARK: - Summary Stats Row

struct SummaryStatsRow: View {
    let analytics: SessionAnalytics

    var body: some View {
        HStack(spacing: 0) {
            StatCard(value: "\(analytics.totalTurns)", label: "turns")
            StatCard(value: formatLatency(analytics.avgLatency), label: "avg latency")
            StatCard(value: "\(analytics.totalErrors)", label: "errors")
            StatCard(value: TokenFormatter.format(analytics.totalTokens, style: .uppercase), label: "tokens")
        }
        .padding(.vertical, 16)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms == 0 { return "-" }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}

struct StatCard: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(.tronEmerald)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Turn Breakdown Section

struct TurnBreakdownSection: View {
    let turns: [SessionAnalytics.TurnData]

    private var maxTokens: Int {
        turns.map(\.totalTokens).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Turn Breakdown")
                .font(.headline)
                .foregroundStyle(.tronTextPrimary)

            VStack(spacing: 8) {
                ForEach(turns) { turn in
                    HStack(spacing: 12) {
                        Text("Turn \(turn.turn)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tronTextSecondary)
                            .frame(width: 50, alignment: .leading)

                        GeometryReader { geo in
                            HStack(spacing: 0) {
                                // Input tokens (darker)
                                Rectangle()
                                    .fill(Color.tronEmerald.opacity(0.6))
                                    .frame(width: geo.size.width * ratio(turn.inputTokens))

                                // Output tokens (lighter)
                                Rectangle()
                                    .fill(Color.tronEmerald)
                                    .frame(width: geo.size.width * ratio(turn.outputTokens))
                            }
                        }
                        .frame(height: 16)
                        .background(Color.tronSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(TokenFormatter.format(turn.totalTokens, style: .uppercase))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)
                            .frame(width: 50, alignment: .trailing)

                        Text(formatCost(turn.cost))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronAmber)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func ratio(_ tokens: Int) -> CGFloat {
        guard maxTokens > 0 else { return 0 }
        return CGFloat(tokens) / CGFloat(maxTokens)
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.001 { return "$0.00" }
        if cost < 0.01 { return String(format: "$%.3f", cost) }
        return String(format: "$%.2f", cost)
    }
}

// MARK: - Tool Usage Section

struct ToolUsageSection: View {
    let tools: [SessionAnalytics.ToolData]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tool Usage")
                .font(.headline)
                .foregroundStyle(.tronTextPrimary)

            VStack(spacing: 8) {
                ForEach(tools) { tool in
                    HStack(spacing: 12) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 12))
                            .foregroundStyle(.tronCyan)

                        Text(tool.name)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronTextPrimary)

                        Spacer()

                        Text("×\(tool.count)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tronTextSecondary)

                        Text("avg \(tool.avgDuration)ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)

                        if tool.errorCount > 0 {
                            Text("\(tool.errorCount) err")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tronError)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(16)
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Model Usage Section

struct ModelUsageSection: View {
    let models: [SessionAnalytics.ModelData]

    private var totalTokens: Int {
        models.reduce(0) { $0 + $1.tokenCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model Usage")
                .font(.headline)
                .foregroundStyle(.tronTextPrimary)

            VStack(spacing: 8) {
                ForEach(models) { model in
                    HStack(spacing: 12) {
                        Text(model.model)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronTextPrimary)
                            .frame(width: 80, alignment: .leading)

                        GeometryReader { geo in
                            Rectangle()
                                .fill(Color.tronPurple)
                                .frame(width: geo.size.width * percentage(model.tokenCount))
                        }
                        .frame(height: 12)
                        .background(Color.tronSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                        Text("\(percentageString(model.tokenCount))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func percentage(_ tokens: Int) -> CGFloat {
        guard totalTokens > 0 else { return 0 }
        return CGFloat(tokens) / CGFloat(totalTokens)
    }

    private func percentageString(_ tokens: Int) -> Int {
        guard totalTokens > 0 else { return 0 }
        return Int(round(Double(tokens) / Double(totalTokens) * 100))
    }
}

// MARK: - Error Log Section

struct ErrorLogSection: View {
    let errors: [SessionAnalytics.ErrorData]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Errors")
                .font(.headline)
                .foregroundStyle(.tronTextPrimary)

            VStack(spacing: 8) {
                ForEach(errors) { error in
                    HStack(spacing: 12) {
                        Image(systemName: error.isRecoverable
                            ? "exclamationmark.triangle.fill"
                            : "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(error.isRecoverable ? .tronAmber : .tronError)

                        Text(formatTime(error.timestamp))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)

                        Text(error.type.capitalized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)

                        Text(error.message)
                            .font(.system(size: 12))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Session Info Header

struct SessionInfoHeader: View {
    let session: CachedSession

    @State private var showCopied = false

    var body: some View {
        VStack(spacing: 12) {
            // Session ID row (compact, tap to copy)
            HStack {
                Image(systemName: "number.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.tronTextMuted)

                Text(showCopied ? "Copied!" : session.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(showCopied ? .tronEmerald : .tronTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .animation(.easeInOut(duration: 0.15), value: showCopied)

                Spacer()

                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.tronTextMuted)

                // Token usage badge
                Text(TokenFormatter.format(session.inputTokens + session.outputTokens, style: .withSuffix))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronEmerald.opacity(0.15))
                    .clipShape(Capsule())
            }
            .contentShape(Rectangle())
            .onTapGesture {
                UIPasteboard.general.string = session.id
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showCopied = false
                }
            }

            Divider()
                .background(Color.tronBorder.opacity(0.5))

            // Info grid
            HStack(spacing: 0) {
                InfoColumn(
                    icon: "folder",
                    label: "Workspace",
                    value: workspaceName
                )

                InfoColumn(
                    icon: "calendar",
                    label: "Created",
                    value: session.humanReadableCreatedAt
                )

                InfoColumn(
                    icon: "clock",
                    label: "Activity",
                    value: session.humanReadableLastActivity
                )

                InfoColumn(
                    icon: "message",
                    label: "Messages",
                    value: "\(session.messageCount)"
                )
            }
        }
        .padding(16)
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var workspaceName: String {
        // Get last path component
        let path = session.workingDirectory
        if let lastComponent = path.split(separator: "/").last {
            return String(lastComponent)
        }
        return path
    }

}

struct InfoColumn: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.tronTextMuted)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

