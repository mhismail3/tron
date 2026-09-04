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
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var recordIndex = GatewayLogRecordIndex()
    @State private var selectedLog: GatewayProfileLogRecord?
    @State private var selectedLevel = "all"
    @State private var loading = false
    @State private var hasLoaded = false
    @State private var loadGeneration = 0
    @State private var copySucceeded = false

    private let levels = ["all", "info", "warning", "error"]

    private var visibleItems: [GatewayLogListItem] {
        recordIndex.items(for: selectedLevel)
    }

    private var automaticLoadID: GatewayLogsLoadID {
        GatewayLogsLoadID(
            readinessGeneration: model.diagnosticsReadinessGeneration,
            isReady: model.diagnosticsAreReady
        )
    }

    var body: some View {
        let rows = visibleItems
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                if hasLoaded || !recordIndex.isEmpty {
                    logSummary
                }
                if !hasLoaded && recordIndex.isEmpty {
                    TronLoadingState(
                        label: model.diagnosticsAreReady ? "Loading logs…" : "Loading local diagnostics…",
                        accent: .tronEmerald
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                } else if rows.isEmpty {
                    TronInfoCard(
                        icon: "doc.text.magnifyingglass",
                        text: emptyStateMessage,
                        accent: .tronSlate
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                } else {
                    ForEach(rows) { item in
                        Button { selectedLog = item.record } label: {
                            GatewayLogRow(record: item.record)
                                .equatable()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                            .overlay(Color.tronBorder.opacity(0.6))
                    }
                    .padding(.horizontal, 16)
                }
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
                Button { Task { await loadLogs(preserveExistingOnEmpty: false) } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(TronTypography.buttonSM)
                        .tronSettingsAccent()
                }
                .disabled(loading)
                .accessibilityLabel("Refresh logs")

                Button { copyVisibleLogs() } label: {
                    Image(systemName: copySucceeded ? "checkmark" : "doc.on.doc")
                        .font(TronTypography.buttonSM)
                        .tronSettingsAccent()
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
                .disabled(visibleItems.isEmpty)
                .accessibilityLabel("Copy visible logs")
            }
        }
        .sensoryFeedback(.success, trigger: copySucceeded)
        .task(id: PresentationActivityTaskID(
            source: automaticLoadID,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await loadLogs(preserveExistingOnEmpty: true)
        }
        .tronManagedSheet(
            item: $selectedLog,
            identity: { _ in "settings.gateway-log-detail" }
        ) { record in
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
        Text("\(visibleItems.count) entries · Newest entries first")
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
    }

    private var emptyStateMessage: String {
        if selectedLevel == "all" {
            return "No logs are available yet. Refresh after new Gateway activity."
        }
        return "No \(selectedLevel) logs match this filter. Try another level or refresh."
    }

    private func loadLogs(preserveExistingOnEmpty: Bool) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        defer {
            if generation == loadGeneration { loading = false }
        }
        let loaded = await model.loadGatewayLogsResult(limit: 1_000)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        recordIndex = GatewayLogRecordIndex(records: GatewayLogsLoadPolicy.mergedRecords(
            current: recordIndex.records,
            loaded: loaded,
            preserveExistingOnEmpty: preserveExistingOnEmpty,
            limit: 1_000
        ))
        hasLoaded = true
    }

    private func copyVisibleLogs() {
        UIPasteboard.general.string = visibleItems.map { item in
            let record = item.record
            let timestamp = record.record.timestamp
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

struct GatewayLogsLoadID: Hashable {
    let readinessGeneration: Int
    let isReady: Bool
}

enum GatewayLogsLoadPolicy {
    static func mergedRecords(
        current: [GatewayProfileLogRecord],
        loaded: GatewayLogsLoadResult,
        preserveExistingOnEmpty: Bool,
        limit: Int
    ) -> [GatewayProfileLogRecord] {
        var merged = loaded.records
        if !loaded.failedProfileIDs.isEmpty {
            merged.append(contentsOf: current.filter { loaded.failedProfileIDs.contains($0.profileID) })
        }
        if preserveExistingOnEmpty, merged.isEmpty, !current.isEmpty {
            return current
        }
        return Array(merged.sorted { $0.record.timestamp > $1.record.timestamp }.prefix(limit))
    }
}

struct GatewayLogListItem: Identifiable, Equatable {
    struct ID: Hashable {
        let recordID: String
        let occurrence: Int
    }

    let id: ID
    let record: GatewayProfileLogRecord
}

struct GatewayLogRecordIndex {
    private var all: [GatewayLogListItem] = []
    private var itemsByLevel: [String: [GatewayLogListItem]] = [:]

    init(records: [GatewayProfileLogRecord] = []) {
        var occurrences: [String: Int] = [:]
        all = records.map { record in
            let occurrence = occurrences[record.id, default: 0]
            occurrences[record.id] = occurrence + 1
            return GatewayLogListItem(
                id: .init(recordID: record.id, occurrence: occurrence),
                record: record
            )
        }
        itemsByLevel = Dictionary(grouping: all, by: { $0.record.record.level })
    }

    var isEmpty: Bool { all.isEmpty }
    var records: [GatewayProfileLogRecord] { all.map(\.record) }

    func items(for level: String) -> [GatewayLogListItem] {
        level == "all" ? all : itemsByLevel[level, default: []]
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

private struct GatewayLogRow: View, Equatable {
    let record: GatewayProfileLogRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(actionDescription)
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(1)
                    .layoutPriority(2)
                metadataSeparator
                Text(sourceDescription)
                    .foregroundStyle(Color.tronTextMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                metadataSeparator
                Text(record.record.levelTitle)
                    .foregroundStyle(record.record.accent)
                    .lineLimit(1)
                    .layoutPriority(1)
                metadataSeparator
                Text(timestampDescription)
                    .foregroundStyle(Color.tronTextMuted)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(TronTypography.caption2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(actionDescription), \(sourceDescription), \(record.record.levelTitle) log, \(timestampDescription)")

            Text(record.record.message)
                .font(TronTypography.codeContent)
                .foregroundStyle(Color.tronTextSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }

    private var metadataSeparator: some View {
        Text("·")
            .foregroundStyle(Color.tronTextMuted)
            .accessibilityHidden(true)
    }

    private var actionDescription: String {
        record.record.event ?? record.record.levelTitle
    }

    private var sourceDescription: String {
        record.profileLabel + (record.record.source.map { " · \($0)" } ?? "")
    }

    private var timestampDescription: String {
        record.record.date?.formatted(date: .omitted, time: .shortened) ?? record.record.timestamp
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
                        .tronGlassSurface(
                            accent: record.record.accent,
                            tintOpacity: 0.08,
                            respectsSettingsTheme: false
                        )
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Log Entry", accent: record.record.accent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").tronSettingsAccent()
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
