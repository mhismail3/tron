import SwiftUI

private extension GatewayLogRecord {
    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }
    var levelTitle: String { level.capitalized }
    var icon: String {
        switch level { case "error": "exclamationmark.octagon.fill"; case "warning": "exclamationmark.triangle.fill"; default: "info.circle.fill" }
    }
    var accent: Color {
        switch level { case "error": .tronError; case "warning": .tronAmber; default: .tronCyan }
    }
}

struct GatewayDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [GatewayLogRecord] = []
    @State private var logLevel = "all"
    @State private var loadingLogs = false
    @State private var selectedLog: GatewayLogRecord?
    @State private var confirmingRestart = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Status") {
                    VStack(spacing: 0) {
                        TronValueRow(icon: statusIcon, title: statusLabel, detail: model.profiles.selected.map { "\($0.host):\($0.port)" }, accent: statusColor)
                        if let info = model.gatewayInfo {
                            TronSettingsDivider()
                            diagnosticValue("network", "Gateway", info.gatewayVersion)
                            TronSettingsDivider()
                            diagnosticValue("cpu", "Agent runtime", info.piVersion)
                        }
                    }
                }
                TronSettingsGroup("Recent Logs", detail: "Newest entries first", accent: .tronSlate) {
                    VStack(spacing: 0) {
                        TronValueRow(icon: "line.3.horizontal.decrease.circle", title: "Level", accent: .tronSlate) {
                            TronInlineMenu(logLevel.capitalized, accent: .tronSlate) {
                                Button("All") { logLevel = "all" }
                                Button("Info") { logLevel = "info" }
                                Button("Warnings") { logLevel = "warning" }
                                Button("Errors") { logLevel = "error" }
                            }
                        }
                        if visibleRecords.isEmpty {
                            TronSettingsDivider(accent: .tronSlate)
                            TronSettingsRow(
                                icon: loadingLogs ? "arrow.clockwise" : "text.page.badge.magnifyingglass",
                                title: loadingLogs ? "Loading logs…" : "No matching logs",
                                subtitle: loadingLogs ? nil : "Try another level or refresh.",
                                accent: .tronSlate
                            ) {
                                if loadingLogs { ProgressView().controlSize(.small).tint(Color.tronSlate) }
                            }
                        } else {
                            ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                                TronSettingsDivider(accent: .tronSlate)
                                Button { selectedLog = record } label: {
                                    TronSettingsRow(
                                        icon: record.icon,
                                        title: record.levelTitle,
                                        subtitle: record.message,
                                        accent: record.accent
                                    ) {
                                        Text(logTimestamp(record))
                                            .font(TronTypography.caption2)
                                            .foregroundStyle(Color.tronTextMuted)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button(loadingLogs ? "Refreshing…" : "Refresh Logs") { Task { await load() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(loadingLogs)
                Button("Restart Gateway", role: .destructive) { confirmingRestart = true }
                    .buttonStyle(TronActionButtonStyle(role: .destructive))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Diagnostics")
        .task { await load() }
        .sheet(item: $selectedLog) { record in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Label(record.levelTitle, systemImage: record.icon)
                                .foregroundStyle(record.accent)
                            Spacer()
                            Text(record.date?.formatted(date: .abbreviated, time: .standard) ?? record.timestamp)
                                .foregroundStyle(Color.tronTextMuted)
                        }
                        .font(TronTypography.bodySM)
                        Text(record.message)
                            .font(TronTypography.codeContent)
                            .foregroundStyle(Color.tronTextPrimary)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tronGlassSurface(accent: record.accent, tintOpacity: 0.08)
                    }
                    .padding(18)
                }
                .tronScrollEdgeChrome()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { TronSheetTitle(title: "Log Entry", accent: record.accent) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { selectedLog = nil } label: {
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
        .confirmationDialog("Restart Tron Gateway?", isPresented: $confirmingRestart) {
            Button("Restart", role: .destructive) { Task { try? await model.restartGateway() } }
        } message: { Text("Accepted agent runs finish before Tron restarts. Active terminal sessions must be closed first; the app reconnects automatically.") }
    }

    private var statusLabel: String {
        switch model.connectionState {
        case .unpaired: "Not paired"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .unauthorized: "Pairing expired"
        case .offline(let message): "Offline · \(message)"
        }
    }
    private var statusIcon: String {
        model.connectionState == .connected ? "checkmark.circle.fill" : "network"
    }
    private var statusColor: Color {
        switch model.connectionState {
        case .connected: .tronEmerald
        case .connecting, .reconnecting: .tronAmber
        case .unpaired, .unauthorized, .offline: .tronError
        }
    }
    private func diagnosticValue(_ icon: String, _ title: String, _ value: String) -> some View {
        TronValueRow(icon: icon, title: title) {
            Text(value).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary)
        }
    }
    private var visibleRecords: [GatewayLogRecord] {
        records.filter { logLevel == "all" || $0.level == logLevel }
    }

    private func logTimestamp(_ record: GatewayLogRecord) -> String {
        record.date?.formatted(date: .omitted, time: .shortened) ?? record.timestamp
    }

    private func load() async {
        loadingLogs = true
        defer { loadingLogs = false }
        records = (try? await model.gatewayDiagnostics.logs(limit: 300)) ?? []
    }
}
