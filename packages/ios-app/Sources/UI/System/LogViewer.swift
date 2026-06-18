import SwiftUI

// MARK: - Log Viewer

struct LogViewer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logs: [(Date, LogCategory, LogLevel, String)] = []
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
                    Button(role: .close) { dismiss() }
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
                    Button { copyLogsToClipboard() } label: {
                        Image(systemName: copySuccess ? "checkmark" : "doc.on.doc")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                }
            }
            .sensoryFeedback(.success, trigger: copySuccess)
            .onAppear { refreshLogs() }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
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

            Text("\(filteredLogs.count) local entries • Server sync runs while connected")
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
        case .engine: return .purple
        case .session: return .orange
        case .chat: return .green
        case .ui: return .pink
        case .network: return .cyan
        case .events: return .yellow
        case .general: return .gray
        case .notification: return .red
        case .database: return .indigo
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
        Text(Self.attributedString(date: date, category: category, level: level, message: message))
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
    }

    @MainActor
    static func attributedString(date: Date, category: LogCategory, level: LogLevel, message: String) -> AttributedString {
        var result = AttributedString()
        result.append(segment(DateParser.formatLogTimestamp(date), font: .system(.caption2, design: .monospaced), color: .gray))
        result.append(segment(" \u{25CF} ", font: .system(size: 6, design: .monospaced), color: level.color))
        result.append(segment("[\(category.rawValue)] ", font: .system(.caption, design: .monospaced), color: category.color))
        result.append(segment(message, font: .system(.caption, design: .monospaced), color: level.color))
        return result
    }

    private static func segment(_ text: String, font: Font, color: Color) -> AttributedString {
        var segment = AttributedString(text)
        segment.font = font
        segment.foregroundColor = color
        return segment
    }

}

private extension LogLevel {
    var color: Color {
        switch self {
        case .verbose: return .gray
        case .debug: return .cyan
        case .info: return .green
        case .warning: return .yellow
        case .error: return .red
        case .none: return .gray
        }
    }
}

private extension LogCategory {
    var color: Color {
        switch self {
        case .websocket: return .blue
        case .engine: return .purple
        case .session: return .orange
        case .chat: return .green
        case .ui: return .pink
        case .network: return .cyan
        case .events: return .yellow
        case .general: return .gray
        case .notification: return .red
        case .database: return .indigo
        }
    }
}

// MARK: - Preview

#Preview {
    LogViewer()
}
