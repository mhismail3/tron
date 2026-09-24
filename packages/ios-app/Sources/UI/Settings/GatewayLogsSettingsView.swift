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
    @Environment(\.scenePhase) private var scenePhase
    @State private var recordIndex = GatewayLogRecordIndex()
    @State private var selectedLog: GatewayProfileLogRecord?
    @State private var selectedLevel = "all"
    @State private var loading = false
    @State private var hasLoaded = false
    @State private var loadGeneration = 0
    @State private var copySucceeded = false
    @State private var exportInFlight = false
    @State private var exportGeneration = 0
    @State private var shareURL: DiagnosticShareFile?
    @State private var exportArtifactURL: URL?
    @State private var captureMetadata = GatewayLogCaptureMetadata.empty
    @State private var loadCoordinator = GatewayLogsLoadCoordinator()

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
                    TronSettingsCaption(emptyStateMessage)
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
        // Native pull-to-refresh needs bounce even when there are no rows; it
        // does not add a fake content height or change the reader's offset.
        .scrollBounceBehavior(.always)
        .refreshable {
            await loadLogs(preserveExistingOnEmpty: false)
        }
        .tronScrollEdgeChrome()
        .safeAreaInset(edge: .top, spacing: 0) {
            levelFilterBar
        }
        .tronNavigationTitle("Logs", accent: .tronEmerald)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button { copyVisibleLogs() } label: {
                    Image(systemName: copySucceeded ? "checkmark" : "doc.on.doc")
                        .font(TronTypography.buttonSM)
                        .tronSettingsAccent()
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
                .disabled(visibleItems.isEmpty)
                .accessibilityLabel("Copy visible logs")

                Button { exportDiagnostics() } label: {
                    Group {
                        if exportInFlight { ProgressView().controlSize(.small) }
                        else { Image(systemName: "square.and.arrow.up") }
                    }
                    .font(TronTypography.buttonSM)
                    .tronSettingsAccent()
                }
                .disabled(visibleItems.isEmpty || exportInFlight)
                .accessibilityLabel("Export Diagnostics")
            }
        }
        .sensoryFeedback(.success, trigger: copySucceeded)
        .sheet(item: $shareURL, onDismiss: {
            if let url = exportArtifactURL {
                exportArtifactURL = nil
                Task { await model.discardExportArtifact(url) }
            }
        }) { file in DiagnosticActivitySheet(url: file.url) }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            guard !active else { return }
            loadGeneration &+= 1
            loadCoordinator.cancel()
            loading = false
            exportGeneration &+= 1
            exportInFlight = false
        }
        .onDisappear {
            loadGeneration &+= 1
            loadCoordinator.cancel()
            loading = false
            exportGeneration &+= 1
            exportInFlight = false
        }
        .task(id: PresentationActivityTaskID(
            source: automaticLoadID,
            presentationActive: presentationActivity.allowsPresentationPublication
                && scenePhase == .active
        )) {
            guard presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            await loadLogs(preserveExistingOnEmpty: true)
            while !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active {
                // Interval is measured after the prior load settles, avoiding
                // overlapping requests and catch-up storms after a slow read.
                do {
                    try await Task.sleep(for: .seconds(GatewayLogsLoadPolicy.refreshInterval))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      presentationActivity.allowsPresentationPublication,
                      scenePhase == .active else { return }
                await loadLogs(preserveExistingOnEmpty: true)
            }
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
        VStack(alignment: .leading, spacing: 4) {
            Text("\(visibleItems.count) entries · Newest entries first")
        }
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
    }

    private func exportDiagnostics() {
        guard !exportInFlight, presentationActivity.allowsPresentationPublication,
              !visibleItems.isEmpty else { return }
        exportGeneration &+= 1
        let generation = exportGeneration
        let activity = presentationActivity
        let records = recordIndex.records
        let metadata = captureMetadata
        exportInFlight = true
        Task { @MainActor in
            defer { if generation == exportGeneration { exportInFlight = false } }
            do {
                let appRecords = await model.appLog.snapshot()
                let text = GatewayLogExport.uploadText(GatewayLogExport.jsonLines(
                    records: records, metadata: metadata, appRecords: appRecords
                ))
                switch try await model.exportDiagnostics(text) {
                case .saved(let path):
                    guard generation == exportGeneration, presentationActivity == activity,
                          activity.allowsPresentationPublication else { return }
                    UIPasteboard.general.string = path
                    model.postNotice("Diagnostics saved on Mac · path copied", role: .success, lifetime: .standard, priority: .low)
                case .share(let url):
                    guard generation == exportGeneration, presentationActivity == activity,
                          activity.allowsPresentationPublication else {
                        await model.discardExportArtifact(url)
                        return
                    }
                    exportArtifactURL = url
                    shareURL = DiagnosticShareFile(url: url)
                }
            } catch {
                guard generation == exportGeneration, presentationActivity == activity,
                      activity.allowsPresentationPublication else { return }
                model.postNotice("Diagnostics could not be exported. Try again.", role: .error, lifetime: .standard, priority: .normal)
            }
        }
    }

    private var emptyStateMessage: String {
        if selectedLevel == "all" {
            return "No logs are available yet. Refresh after new Gateway activity."
        }
        return "No \(selectedLevel) logs match this filter. Try another level or refresh."
    }

    private func loadLogs(preserveExistingOnEmpty: Bool) async {
        let activity = presentationActivity
        guard activity.allowsPresentationPublication, scenePhase == .active else { return }
        let lease = loadCoordinator.acquire()
        let generation: Int
        if lease.owner {
            loadGeneration &+= 1
            generation = loadGeneration
            loading = true
        } else {
            generation = loadGeneration
        }
        defer {
            loadCoordinator.release(lease)
            if lease.owner {
                // A dismissed/replaced Logs surface must not clear the
                // successor's loading state after its read settles.
                if generation == loadGeneration, presentationActivity == activity {
                    loading = false
                }
            }
        }
        // Publish local evidence first even when a ready socket's remote log
        // read is stalled. The coordinator shares each phase with joiners.
        guard let local = await loadCoordinator.local(for: lease, operation: {
            await model.loadGatewayLogsResult(limit: 1_000, includeRemote: false)
        }) else { return }
        guard generation == loadGeneration, presentationActivity == activity,
              activity.allowsPresentationPublication, scenePhase == .active,
              !Task.isCancelled else { return }
        recordIndex = GatewayLogRecordIndex(records: GatewayLogsLoadPolicy.mergedRecords(
            current: recordIndex.records, loaded: local, preserveExistingOnEmpty: true, limit: 1_000
        ))
        captureMetadata = local.metadata
        hasLoaded = true
        guard let loaded = await loadCoordinator.remote(for: lease, operation: {
            await model.loadGatewayLogsResult(limit: 1_000)
        }) else { return }
        guard generation == loadGeneration,
              presentationActivity == activity,
              activity.allowsPresentationPublication,
              scenePhase == .active,
              !Task.isCancelled else { return }
        recordIndex = GatewayLogRecordIndex(records: GatewayLogsLoadPolicy.mergedRecords(
            current: recordIndex.records,
            loaded: loaded,
            preserveExistingOnEmpty: preserveExistingOnEmpty,
            limit: 1_000
        ))
        captureMetadata = loaded.metadata.withBounds(records: recordIndex.records)
        hasLoaded = true
    }

    private func copyVisibleLogs() {
        UIPasteboard.general.string = GatewayLogExport.text(
            records: visibleItems.map(\.record), metadata: captureMetadata
        )
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

private struct DiagnosticShareFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct DiagnosticActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct GatewayLogsLoadID: Hashable {
    let readinessGeneration: Int
    let isReady: Bool
}

/// Owns one in-flight Logs read across the automatic loop and pull gesture.
/// Separate local/remote tasks preserve the fast local projection while both
/// callers join the same underlying request rather than polling or duplicating
/// Gateway work.
@MainActor
final class GatewayLogsLoadCoordinator {
    struct Lease: Sendable {
        fileprivate let token: UInt64
        let owner: Bool
    }

    private var nextToken: UInt64 = 0
    private var activeToken: UInt64?
    private var activeUsers = 0
    private var localTask: Task<GatewayLogsLoadResult?, Never>?
    private var remoteTask: Task<GatewayLogsLoadResult?, Never>?

    func acquire() -> Lease {
        if let activeToken {
            activeUsers += 1
            return Lease(token: activeToken, owner: false)
        }
        nextToken &+= 1
        activeToken = nextToken
        activeUsers = 1
        return Lease(token: nextToken, owner: true)
    }

    func local(
        for lease: Lease,
        operation: @escaping @MainActor () async -> GatewayLogsLoadResult
    ) async -> GatewayLogsLoadResult? {
        guard activeToken == lease.token else { return nil }
        if localTask == nil {
            localTask = Task { @MainActor in
                guard !Task.isCancelled else { return nil }
                let result = await operation()
                return Task.isCancelled ? nil : result
            }
        }
        guard let task = localTask else { return nil }
        let result = await task.value
        guard activeToken == lease.token, !Task.isCancelled else { return nil }
        return result
    }

    func remote(
        for lease: Lease,
        operation: @escaping @MainActor () async -> GatewayLogsLoadResult
    ) async -> GatewayLogsLoadResult? {
        guard activeToken == lease.token else { return nil }
        if remoteTask == nil {
            remoteTask = Task { @MainActor in
                guard !Task.isCancelled else { return nil }
                let result = await operation()
                return Task.isCancelled ? nil : result
            }
        }
        guard let task = remoteTask else { return nil }
        let result = await task.value
        guard activeToken == lease.token, !Task.isCancelled else { return nil }
        return result
    }

    func release(_ lease: Lease) {
        guard activeToken == lease.token else { return }
        activeUsers = max(0, activeUsers - 1)
        guard activeUsers == 0 else { return }
        activeToken = nil
        localTask = nil
        remoteTask = nil
    }

    func cancel() {
        localTask?.cancel()
        remoteTask?.cancel()
        localTask = nil
        remoteTask = nil
        activeToken = nil
        activeUsers = 0
    }
}

enum GatewayLogsLoadPolicy {
    static let refreshInterval: Int = 15

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
        return Array(merged.sorted { gatewayLogRecordIsNewer($0, than: $1) }.prefix(limit))
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
