#if DEBUG || BETA
import SwiftUI

// MARK: - Log Viewer

struct LogViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var dependencies
    @State private var logs: [(Date, LogCategory, LogLevel, String)] = []
    @State private var isExporting = false
    @State private var exportSuccess = false
    @State private var copySuccess = false
    @State private var selectedLevel: LogLevel = .info
    @State private var selectedCategory: LogCategory?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                logList
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26.0, *) {
                        Button(role: .close) { dismiss() }
                    } else {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("Logs")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button { refreshLogs() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button { exportLogsToServer() } label: {
                        Image(systemName: exportSuccess ? "checkmark" : "square.and.arrow.up")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                    .disabled(isExporting)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button { copyLogsToClipboard() } label: {
                        Image(systemName: copySuccess ? "checkmark" : "doc.on.doc")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                }
            }
            .sensoryFeedback(.success, trigger: exportSuccess)
            .sensoryFeedback(.success, trigger: copySuccess)
            .onAppear { refreshLogs() }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 6) {
            // Level picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LogLevel.allCases.filter { $0 != .none }, id: \.self) { level in
                        FilterChip(
                            title: String(describing: level).capitalized,
                            isSelected: selectedLevel == level,
                            color: colorForLevel(level)
                        ) {
                            selectedLevel = level
                            refreshLogs()
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            // Category picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(
                        title: "All",
                        isSelected: selectedCategory == nil,
                        color: .gray
                    ) {
                        selectedCategory = nil
                        refreshLogs()
                    }

                    ForEach(LogCategory.allCases, id: \.self) { category in
                        FilterChip(
                            title: category.rawValue,
                            isSelected: selectedCategory == category,
                            color: colorForCategory(category)
                        ) {
                            selectedCategory = category
                            refreshLogs()
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            // Entry count
            Text("\(filteredLogs.count) entries")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(.tronTextMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(filteredLogs.enumerated()), id: \.offset) { _, entry in
                    LogRow(entry: entry)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private var filteredLogs: [(Date, LogCategory, LogLevel, String)] {
        logs
    }

    // MARK: - Helpers

    private func refreshLogs() {
        logs = logger.getRecentLogs(count: 1000, level: selectedLevel, category: selectedCategory)
    }

    private func copyLogsToClipboard() {
        let allLogs = logger.getRecentLogs(count: 10000, level: .verbose, category: nil)

        let logText = allLogs.map { entry in
            let timestamp = DateParser.formatLogTimestamp(entry.0)
            let category = entry.1.rawValue
            let level = String(describing: entry.2).uppercased()
            let message = entry.3
            return "\(timestamp) [\(level)] [\(category)] \(message)"
        }.joined(separator: "\n")

        UIPasteboard.general.string = logText
        copySuccess = true

        Task {
            try? await Task.sleep(for: .seconds(0.6))
            copySuccess = false
        }
    }

    private func exportLogsToServer() {
        guard !isExporting else { return }

        isExporting = true
        exportSuccess = true

        Task {
            defer { isExporting = false }

            let allLogs = logger.getRecentLogs(count: 10000, level: .verbose, category: nil)

            let entries = allLogs.map { entry in
                ClientLogEntry(
                    timestamp: DateParser.formatISO8601WithMillis(entry.0),
                    level: String(describing: entry.2).lowercased(),
                    category: entry.1.rawValue,
                    message: entry.3
                )
            }

            do {
                let rpcClient = dependencies.rpcClient
                let result = try await rpcClient.misc.ingestLogs(entries: entries)
                logger.info("Ingested \(result.inserted) of \(entries.count) log entries into server", category: .general)
            } catch {
                logger.error("Failed to ingest logs to server: \(error.localizedDescription)", category: .general)
            }

            try? await Task.sleep(for: .seconds(0.6))
            exportSuccess = false
        }
    }

    private func colorForLevel(_ level: LogLevel) -> Color {
        switch level {
        case .verbose: return .gray
        case .debug: return .cyan
        case .info: return .green
        case .warning: return .yellow
        case .error: return .red
        case .none: return .gray
        }
    }

    private func colorForCategory(_ category: LogCategory) -> Color {
        switch category {
        case .websocket: return .blue
        case .rpc: return .purple
        case .session: return .orange
        case .chat: return .green
        case .ui: return .pink
        case .network: return .cyan
        case .events: return .yellow
        case .general: return .gray
        case .notification: return .red
        case .database: return .indigo
        case .audio: return .mint
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? color : .tronTextSecondary)
                .background(isSelected ? color.opacity(0.15) : Color.tronEmerald.opacity(0.06))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Log Row

struct LogRow: View {
    let entry: (Date, LogCategory, LogLevel, String)

    private var date: Date { entry.0 }
    private var category: LogCategory { entry.1 }
    private var level: LogLevel { entry.2 }
    private var message: String { entry.3 }

    var body: some View {
        (Text(formatTime(date))
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.gray)
        + Text(" \u{25CF} ")
            .font(.system(size: 6, design: .monospaced))
            .foregroundColor(levelColor)
        + Text("[\(category.rawValue)] ")
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(categoryColor)
        + Text(message)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(levelColor))
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
    }

    private var levelColor: Color {
        switch level {
        case .verbose: return .gray
        case .debug: return .cyan
        case .info: return .green
        case .warning: return .yellow
        case .error: return .red
        case .none: return .gray
        }
    }

    private var categoryColor: Color {
        switch category {
        case .websocket: return .blue
        case .rpc: return .purple
        case .session: return .orange
        case .chat: return .green
        case .ui: return .pink
        case .network: return .cyan
        case .events: return .yellow
        case .general: return .gray
        case .notification: return .red
        case .database: return .indigo
        case .audio: return .mint
        }
    }

    private func formatTime(_ date: Date) -> String {
        DateParser.formatLogTimestamp(date)
    }
}

// MARK: - Preview

#Preview {
    LogViewer()
}
#endif
