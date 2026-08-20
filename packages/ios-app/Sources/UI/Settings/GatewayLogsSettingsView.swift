import SwiftUI
import UIKit

extension GatewayLogRecord {
    var date: Date? { GatewayTimestamp.parse(timestamp) }
    var levelTitle: String { level.capitalized }

    var icon: String {
        switch level {
        case "error": "exclamationmark.octagon.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    var accent: Color {
        switch level {
        case "error": .tronError
        case "warning": .tronAmber
        default: .tronCyan
        }
    }
}

struct GatewayLogsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [GatewayProfileLogRecord] = []
    @State private var selectedLog: GatewayProfileLogRecord?
    @State private var selectedLevel = "all"
    @State private var loading = false
    @State private var loadGeneration = 0
    @State private var copySucceeded = false

    private let levels = ["all", "info", "warning", "error"]

    private var visibleRecords: [GatewayProfileLogRecord] {
        guard selectedLevel != "all" else { return records }
        return records.filter { $0.record.level == selectedLevel }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                logSummary
                logRows
            }
            .padding(.bottom, 24)
        }
        .tronScrollEdgeChrome()
        .safeAreaInset(edge: .top, spacing: 0) {
            levelFilterBar
        }
        .tronNavigationTitle("Logs", accent: .tronEmerald)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button { Task { await loadLogs() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronEmerald)
                }
                .disabled(loading)
                .accessibilityLabel("Refresh logs")

                Button { copyVisibleLogs() } label: {
                    Image(systemName: copySucceeded ? "checkmark" : "doc.on.doc")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronEmerald)
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
                .disabled(visibleRecords.isEmpty)
                .accessibilityLabel("Copy visible logs")
            }
        }
        .sensoryFeedback(.success, trigger: copySucceeded)
        .task { await loadLogs() }
        .sheet(item: $selectedLog) { record in
            GatewayLogDetailView(record: record)
        }
        .tronTopBlur(.logs)
    }

    private var levelFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(levels, id: \.self) { level in
                    GatewayLogFilterChip(
                        title: level == "all" ? "All" : level.capitalized,
                        isSelected: selectedLevel == level,
                        accent: accent(for: level)
                    ) {
                        selectedLevel = level
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 3)
        }
        .scrollClipDisabled()
        .padding(.vertical, 7)
    }

    private var logSummary: some View {
        Text("\(visibleRecords.count) entries · Newest entries first")
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private var logRows: some View {
        if loading && records.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(Color.tronEmerald)
                Text("Loading logs…")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        } else if visibleRecords.isEmpty {
            ContentUnavailableView {
                Label("No Matching Logs", systemImage: "text.page.badge.magnifyingglass")
            } description: {
                Text("Try another level or refresh.")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        } else {
            ForEach(Array(visibleRecords.enumerated()), id: \.offset) { _, record in
                Button { selectedLog = record } label: {
                    GatewayLogRow(record: record)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
                    .overlay(Color.tronBorder.opacity(0.6))
                    .padding(.leading, 54)
            }
            .padding(.horizontal, 16)
        }
    }

    private func loadLogs() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        defer {
            if generation == loadGeneration { loading = false }
        }
        let loaded = await model.loadGatewayLogs(limit: 1_000)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        records = loaded
    }

    private func copyVisibleLogs() {
        UIPasteboard.general.string = visibleRecords.map { record in
            let timestamp = record.record.date?.formatted(.iso8601) ?? record.record.timestamp
            let source = record.record.source.map { " [\($0)]" } ?? ""
            let event = record.record.event.map { " [\($0)]" } ?? ""
            return "\(timestamp) [\(record.profileLabel)] [\(record.record.level.uppercased())]\(source)\(event) \(record.record.message)"
        }.joined(separator: "\n")
        copySucceeded = true
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            copySucceeded = false
        }
    }

    private func accent(for level: String) -> Color {
        switch level {
        case "error": .tronError
        case "warning": .tronAmber
        case "info": .tronCyan
        default: .tronSlate
        }
    }
}

private struct GatewayLogFilterChip: View {
    let title: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(isSelected ? accent : Color.tronTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    ZStack {
                        Capsule().fill(Color.tronSurface)
                        if isSelected { Capsule().fill(accent.opacity(0.16)) }
                    }
                }
                .overlay {
                    Capsule().stroke(isSelected ? accent.opacity(0.45) : Color.tronBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct GatewayLogRow: View {
    let record: GatewayProfileLogRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.record.icon)
                .font(TronTypography.bodySM)
                .foregroundStyle(record.record.accent)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(record.record.event ?? record.record.levelTitle)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(record.record.date?.formatted(date: .omitted, time: .shortened) ?? record.record.timestamp)
                        .font(TronTypography.caption2)
                        .foregroundStyle(Color.tronTextMuted)
                        .lineLimit(1)
                }

                Text(record.profileLabel + (record.record.source.map { " · \($0)" } ?? ""))
                    .font(TronTypography.caption2)
                    .foregroundStyle(Color.tronTextMuted)
                    .lineLimit(1)

                Text(record.record.message)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 10)
    }
}

struct GatewayLogDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let record: GatewayProfileLogRecord

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Label(record.record.event ?? record.record.levelTitle, systemImage: record.record.icon)
                            .foregroundStyle(record.record.accent)
                        Spacer()
                        Text(record.profileLabel)
                            .foregroundStyle(Color.tronTextMuted)
                        Text(record.record.date?.formatted(date: .abbreviated, time: .standard) ?? record.record.timestamp)
                            .foregroundStyle(Color.tronTextMuted)
                    }
                    .font(TronTypography.bodySM)
                    if let source = record.record.source {
                        Text("Source: \(source)")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextMuted)
                    }
                    Text(record.record.message)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(Color.tronTextPrimary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: record.record.accent, tintOpacity: 0.08)
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Log Entry", accent: record.record.accent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
