import SwiftUI

// MARK: - Log Viewer

struct LogViewer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logs: [(Date, LogCategory, LogLevel, String)] = []
    @State private var selectedLevel: LogLevel = .verbose
    @State private var selectedCategory: LogCategory?
    @State private var autoScroll = true
    @State private var searchText = ""

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filters
                filterBar

                // Log list
                logList
            }
            .background(Color.black)
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Copy All Logs") {
                            UIPasteboard.general.string = log.exportLogs()
                        }

                        Button("Clear Logs") {
                            log.clearBuffer()
                            refreshLogs()
                        }

                        Divider()

                        ForEach(LogLevel.allCases.filter { $0 != .none }, id: \.self) { level in
                            Button {
                                log.setLevel(level)
                                refreshLogs()
                            } label: {
                                if log.minimumLevel == level {
                                    Label("Level: \(level)", systemImage: "checkmark")
                                } else {
                                    Text("Level: \(level)")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear { refreshLogs() }
            .onReceive(timer) { _ in
                if autoScroll {
                    refreshLogs()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 8) {
            // Level picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
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
                .padding(.horizontal)
            }

            // Category picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
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
                .padding(.horizontal)
            }

            // Auto-scroll toggle
            HStack {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .font(.caption)
                    .foregroundStyle(.gray)

                Spacer()

                Text("\(logs.count) entries")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(white: 0.1))
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(filteredLogs.enumerated()), id: \.offset) { index, entry in
                        LogRow(entry: entry)
                            .id(index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: logs.count) { _, _ in
                if autoScroll {
                    withAnimation {
                        proxy.scrollTo(filteredLogs.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var filteredLogs: [(Date, LogCategory, LogLevel, String)] {
        logs.filter { entry in
            if !searchText.isEmpty {
                return entry.3.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
    }

    // MARK: - Helpers

    private func refreshLogs() {
        logs = log.getRecentLogs(count: 500, level: selectedLevel, category: selectedCategory)
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
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color.opacity(0.3) : Color(white: 0.2))
                .foregroundStyle(isSelected ? color : .gray)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? color : Color.clear, lineWidth: 1)
                )
        }
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
        HStack(alignment: .top, spacing: 4) {
            // Timestamp
            Text(formatTime(date))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.gray)

            // Level indicator
            Circle()
                .fill(levelColor)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            // Category
            Text("[\(category.rawValue)]")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(categoryColor)

            // Message
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(levelColor)
                .lineLimit(nil)
        }
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
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    LogViewer()
}
