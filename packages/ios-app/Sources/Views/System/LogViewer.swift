import SwiftUI

// MARK: - Log Viewer

struct LogViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var dependencies
    @State private var logs: [(Date, LogCategory, LogLevel, String)] = []
    @State private var isExporting = false
    @State private var exportSuccess = false
    @State private var exportResult: String?
    @State private var selectedLevel: LogLevel = .verbose
    @State private var selectedCategory: LogCategory?
    @State private var autoScroll = true
    @State private var searchText = ""
    @State private var sheetDetent: PresentationDetent = .large
    @State private var entryLimit: Int? = nil  // nil means no limit

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filters
                filterBar

                // Log list
                logList
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26.0, *) {
                        Button(role: .close) {
                            dismiss()
                        }
                    } else {
                        Button("Close", systemImage: "xmark") {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("Logs")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        exportLogsToServer()
                    } label: {
                        Image(systemName: exportSuccess ? "checkmark" : "square.and.arrow.up")
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                    .disabled(isExporting)
                }
            }
            .sensoryFeedback(.success, trigger: exportSuccess)
            .onAppear { refreshLogs() }
            .onReceive(timer) { _ in
                if autoScroll {
                    refreshLogs()
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $sheetDetent)
        .presentationSizing(.page)
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .preferredColorScheme(.dark)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 4) {
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
                .padding(.horizontal)
                .padding(.vertical, 3)
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
                .padding(.horizontal)
                .padding(.vertical, 3)
            }

            // Entry limit picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(
                        title: "All",
                        isSelected: entryLimit == nil,
                        color: .tronEmerald
                    ) {
                        entryLimit = nil
                    }

                    ForEach([50, 100, 250, 500], id: \.self) { limit in
                        FilterChip(
                            title: "Last \(limit)",
                            isSelected: entryLimit == limit,
                            color: .tronEmerald
                        ) {
                            entryLimit = limit
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 3)
            }

            // Auto-refresh toggle and entry count
            HStack(spacing: 8) {
                Toggle(isOn: $autoScroll) {
                    EmptyView()
                }
                .toggleStyle(SwitchToggleStyle(tint: .tronEmerald))
                .labelsHidden()
                .fixedSize()

                Text("Auto-refresh")
                    .font(TronTypography.caption)
                    .foregroundStyle(.gray)

                Spacer()

                Text("\(filteredLogs.count) entries")
                    .font(TronTypography.caption)
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal)
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
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
        var result = logs.filter { entry in
            if !searchText.isEmpty {
                return entry.3.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }

        // Apply entry limit if set
        if let limit = entryLimit {
            result = Array(result.suffix(limit))
        }

        return result
    }

    // MARK: - Helpers

    private func refreshLogs() {
        // Each category maintains its own buffer of 250 entries, so we can request more
        logs = logger.getRecentLogs(count: 1000, level: selectedLevel, category: selectedCategory)
    }

    private func exportLogsToServer() {
        guard !isExporting else { return }

        isExporting = true
        exportResult = nil

        // Show checkmark immediately for snappy feedback
        exportSuccess = true

        Task {
            defer { isExporting = false }

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"

            // Get ALL logs (not just filtered) for complete export
            let allLogs = logger.getRecentLogs(count: 10000, level: .verbose, category: nil)

            let logText = allLogs.map { entry in
                let timestamp = formatter.string(from: entry.0)
                let category = entry.1.rawValue
                let level = String(describing: entry.2).uppercased()
                let message = entry.3
                return "\(timestamp) [\(level)] [\(category)] \(message)"
            }.joined(separator: "\n")

            do {
                let rpcClient = dependencies.rpcClient

                let result = try await rpcClient.misc.exportLogs(content: logText)
                logger.info("Exported \(allLogs.count) log entries to server: \(result.path)", category: .general)
            } catch {
                logger.error("Failed to export logs to server: \(error.localizedDescription)", category: .general)
                exportResult = "Error: \(error.localizedDescription)"
            }

            // Reset checkmark after brief delay
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
                .font(TronTypography.caption)
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
        // Use Text concatenation so continuation lines wrap to leading edge
        // instead of being indented to align with message start
        (Text(formatTime(date))
            .font(TronTypography.pill)
            .foregroundColor(.gray)
        + Text(" ● ")
            .font(TronTypography.mono(size: TronTypography.sizeXS))
            .foregroundColor(levelColor)
        + Text("[\(category.rawValue)] ")
            .font(TronTypography.mono(size: TronTypography.sizeCaption))
            .foregroundColor(categoryColor)
        + Text(message)
            .font(TronTypography.codeCaption)
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
