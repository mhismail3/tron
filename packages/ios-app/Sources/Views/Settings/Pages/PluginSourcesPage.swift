import SwiftUI

// ARCHITECTURE: ~585 lines — server list, add/edit sheet, status polling, and
// enable/disable/restart actions. The inline AddServerSheet struct accounts for
// ~150 lines. Pragmatic trigger: extract AddServerSheet to its own file if the
// page exceeds ~700 lines.

struct PluginSourcesPage: View {
    @Environment(\.dependencies) var dependencies
    @Bindable var settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    @State private var servers: [PluginSourceStatus] = []
    @State private var loadError: String?
    @State private var showAddSheet = false
    @State private var actionInProgress: String?
    @State private var expandedServer: String?
    @State private var toolsByServer: [String: [PluginCapabilityInfo]] = [:]
    @State private var toolsLoading: String?
    @State private var expandedTool: String?

    private var engineClient: EngineClient { dependencies.engineClient }

    /// Display a refresh TTL as seconds, or "Disabled" when 0.
    private var schemaRefreshDisplay: String {
        if settingsState.mcpSchemaRefreshTtlMs == 0 {
            return "Disabled"
        }
        let seconds = Double(settingsState.mcpSchemaRefreshTtlMs) / 1000.0
        return String(format: "%.0fs", seconds)
    }

    private var schemaRefreshSeconds: Binding<Int> {
        Binding(
            get: { Int(settingsState.mcpSchemaRefreshTtlMs / 1000) },
            set: { newValue in
                let clamped = max(0, min(600, newValue))
                settingsState.mcpSchemaRefreshTtlMs = UInt64(clamped) * 1000
            }
        )
    }

    var body: some View {
        SettingsPageContainer(title: "Plugin Sources") {
            Button { showAddSheet = true } label: {
                Image(systemName: "plus")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(.tronEmerald)
            }
        } content: {
            schemaRefreshCard

            if servers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 32))
                        .foregroundStyle(.tronTextMuted)
                    Text("No plugin sources configured")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                    Text("Add a plugin source to expose external capabilities.")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                HStack {
                    Text("Sources")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                    if !servers.isEmpty {
                        Text("\(servers.count)")
                            .font(TronTypography.pillValue)
                            .countBadge(.tronEmerald)
                    }
                    Spacer()
                }

                ForEach(servers) { server in
                    PluginSourceCard(
                        server: server,
                        isExpanded: expandedServer == server.name,
                        actionInProgress: actionInProgress,
                        tools: toolsByServer[server.name],
                        toolsLoading: toolsLoading == server.name,
                        expandedTool: $expandedTool,
                        onTap: { toggleExpansion(server) },
                        onToggle: { toggleServer(server) },
                        onRestart: { restartServer(server.name) },
                        onRemove: { removeServer(server.name) }
                    )
                }
            }

            if let error = loadError {
                Text(error)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
                    .padding(.horizontal, 4)
            }
        }
        .task { await loadStatus() }
        .sheet(isPresented: $showAddSheet) {
            AddPluginSourceSheet(onAdd: { params in
                await addServer(params)
            })
            .adaptivePresentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mcpStatusChanged)) { _ in
            Task { await loadStatus() }
        }
    }

    // MARK: - Schema Refresh

    /// Server-authoritative `pluginSources.schemaRefreshTtlMs`. Controls proactive
    /// refresh of each plugin source source's `tools/list` metadata so generated
    /// capability implementations stay aligned with upstream schemas.
    private var schemaRefreshCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Schema Refresh")

            SettingsCard {
                SettingsRow(icon: "arrow.triangle.2.circlepath", label: "Refresh interval") {
                    Text(schemaRefreshDisplay)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 80, alignment: .trailing)
                    TronStepper(
                        value: schemaRefreshSeconds,
                        range: 0...600,
                        step: 5
                    )
                }
                .onChange(of: settingsState.mcpSchemaRefreshTtlMs) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(pluginSources: .init(schemaRefreshTtlMs: newValue))
                    }
                }
            }

            SettingsCaption(text: "How often to re-fetch tool schemas from each server. 0 disables automatic refresh.")
        }
    }

    // MARK: - Actions

    private func loadStatus() async {
        loadError = nil
        do {
            servers = try await engineClient.pluginSources.status()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func toggleExpansion(_ server: PluginSourceStatus) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            expandedTool = nil
            if expandedServer == server.name {
                expandedServer = nil
            } else {
                expandedServer = server.name
                if toolsByServer[server.name] == nil && server.isConnected {
                    loadTools(for: server.name)
                }
            }
        }
    }

    private func loadTools(for serverName: String) {
        toolsLoading = serverName
        Task {
            do {
                let tools = try await engineClient.pluginSources.listTools(server: serverName)
                toolsByServer[serverName] = tools
            } catch {
                toolsByServer[serverName] = []
            }
            toolsLoading = nil
        }
    }

    private func addServer(_ params: PluginSourceAddParams) async {
        actionInProgress = params.name
        do {
            let _ = try await engineClient.pluginSources.addServer(
                params,
                idempotencyKey: .userAction("pluginSources.addServer")
            )
            await loadStatus()
        } catch {
            loadError = error.localizedDescription
        }
        actionInProgress = nil
    }

    private func removeServer(_ name: String) {
        actionInProgress = name
        Task {
            do {
                try await engineClient.pluginSources.removeServer(
                    name: name,
                    idempotencyKey: .userAction("pluginSources.removeServer")
                )
                toolsByServer.removeValue(forKey: name)
                if expandedServer == name { expandedServer = nil }
                await loadStatus()
            } catch {
                loadError = error.localizedDescription
            }
            actionInProgress = nil
        }
    }

    private func toggleServer(_ server: PluginSourceStatus) {
        actionInProgress = server.name
        Task {
            do {
                if server.isConnected {
                    try await engineClient.pluginSources.disableServer(
                        name: server.name,
                        idempotencyKey: .userAction("pluginSources.disableServer")
                    )
                    toolsByServer.removeValue(forKey: server.name)
                } else {
                    try await engineClient.pluginSources.enableServer(
                        name: server.name,
                        idempotencyKey: .userAction("pluginSources.enableServer")
                    )
                }
                await loadStatus()
            } catch {
                loadError = error.localizedDescription
            }
            actionInProgress = nil
        }
    }

    private func restartServer(_ name: String) {
        actionInProgress = name
        Task {
            do {
                let _ = try await engineClient.pluginSources.restartServer(
                    name: name,
                    idempotencyKey: .userAction("pluginSources.restartServer")
                )
                toolsByServer.removeValue(forKey: name)
                await loadStatus()
                if expandedServer == name {
                    loadTools(for: name)
                }
            } catch {
                loadError = error.localizedDescription
            }
            actionInProgress = nil
        }
    }
}

// MARK: - Server Card

private struct PluginSourceCard: View {
    let server: PluginSourceStatus
    let isExpanded: Bool
    let actionInProgress: String?
    let tools: [PluginCapabilityInfo]?
    let toolsLoading: Bool
    @Binding var expandedTool: String?
    let onTap: () -> Void
    let onToggle: () -> Void
    let onRestart: () -> Void
    let onRemove: () -> Void

    private var isActioning: Bool { actionInProgress == server.name }

    private var healthColor: Color {
        switch server.health {
        case .healthy: .tronSuccess
        case .degraded: .tronAmber
        case .failed: .tronError
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
                    HStack(spacing: 6) {
                        Text(server.health.rawValue)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(healthColor)
                        if server.toolCount > 0 {
                            Text("\(server.toolCount)")
                                .font(TronTypography.pillValue)
                                .countBadge(.tronEmerald)
                        }
                        if let error = server.lastError {
                            Text(error)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronError)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                if isActioning {
                    ProgressView()
                        .tint(.tronEmerald)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "chevron.down")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronEmerald.opacity(0.6))
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)

                    Menu {
                        if server.isConnected {
                            Button { onRestart() } label: {
                                Label("Restart", systemImage: "arrow.clockwise")
                            }
                            Button { onToggle() } label: {
                                Label("Disable", systemImage: "pause.circle")
                            }
                        } else {
                            Button { onToggle() } label: {
                                Label("Enable", systemImage: "play.circle")
                            }
                        }
                        Divider()
                        Button(role: .destructive) { onRemove() } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                }
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { onTap() }

            // Expanded: generated capabilities
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if toolsLoading {
                        HStack(spacing: 6) {
                            ProgressView()
                                .tint(.tronEmerald)
                                .scaleEffect(0.6)
                            Text("Loading capabilities...")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    } else if let tools, !tools.isEmpty {
                        ForEach(tools) { tool in
                            PluginCapabilityRow(
                                tool: tool,
                                isExpanded: expandedTool == tool.id,
                                onTap: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        expandedTool = expandedTool == tool.id ? nil : tool.id
                                    }
                                }
                            )
                        }
                    } else if tools != nil {
                        Text("No capabilities discovered")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .clipped()
        .sectionFill(.tronEmerald)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Tool Row

private struct PluginCapabilityRow: View {
    let tool: PluginCapabilityInfo
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 14)

                Text(tool.tool)
                    .font(TronTypography.code(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)

                Spacer()

                if !tool.params.isEmpty {
                    Text("\(tool.params.count)")
                        .font(TronTypography.pillValue)
                        .countBadge(.tronSlate)
                }

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture { onTap() }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !tool.description.isEmpty {
                        Text(tool.description)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .padding(.horizontal, 8)
                    }

                    let sorted = tool.params.sorted { $0.required && !$1.required }
                    ForEach(sorted) { param in
                        PluginCapabilityParamRow(param: param)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
        }
        .clipped()
        .sectionFill(.tronEmerald, cornerRadius: 8, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Param Row

private struct PluginCapabilityParamRow: View {
    let param: PluginCapabilityParam

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(param.name)
                    .font(TronTypography.code(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextPrimary)
                Text(param.paramType)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                if param.required {
                    Text("required")
                        .font(TronTypography.sans(size: TronTypography.sizeXS))
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.tronEmerald.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            if !param.description.isEmpty {
                Text(param.description)
                    .font(TronTypography.sans(size: TronTypography.sizeXS))
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - Add Plugin Source Sheet

private struct AddPluginSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var argsText = ""
    @State private var isAdding = false
    @State private var addError: String?

    let onAdd: (PluginSourceAddParams) async -> Void

    @FocusState private var focusedField: Field?

    private enum Field { case name, command, args }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    SettingsSectionHeader(title: "Server Configuration")

                    SettingsCard {
                        HStack {
                            Image(systemName: "server.rack")
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronEmerald)
                                .frame(width: 18)
                            Text("Name")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            Spacer()
                            TextField("Server name", text: $name)
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .name)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                        .onTapGesture { focusedField = .name }

                        SettingsRowDivider()

                        HStack {
                            Image(systemName: "terminal")
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronEmerald)
                                .frame(width: 18)
                            Text("Command")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            Spacer()
                            TextField("npx, uvx", text: $command)
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .command)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                        .onTapGesture { focusedField = .command }

                        SettingsRowDivider()

                        HStack {
                            Image(systemName: "text.word.spacing")
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronEmerald)
                                .frame(width: 18)
                            Text("Args")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            Spacer()
                            TextField("space-separated", text: $argsText)
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .args)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                        .onTapGesture { focusedField = .args }
                    }

                    SettingsCaption(text: "Example: command \"npx\", args \"-y chrome-devtools-pluginSources@latest\"")

                    if let error = addError {
                        Text(error)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronError)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(.tronTextMuted)
                }
                ToolbarItem(placement: .principal) {
                    Text("Add Plugin Source")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isAdding {
                        ProgressView()
                            .tint(.tronEmerald)
                            .scaleEffect(0.7)
                    } else {
                        Button("Add") { addServer() }
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(isValid ? .tronEmerald : .tronTextMuted)
                            .disabled(!isValid)
                    }
                }
            }
        }
    }

    private func addServer() {
        guard isValid else { return }
        isAdding = true
        addError = nil

        let args = argsText
            .split(separator: " ")
            .map(String.init)

        let params = PluginSourceAddParams(
            name: name.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            args: args.isEmpty ? nil : args,
            env: nil,
            url: nil,
            enabled: true
        )

        Task {
            await onAdd(params)
            isAdding = false
            dismiss()
        }
    }
}
