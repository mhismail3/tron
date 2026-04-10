import SwiftUI

// ARCHITECTURE: ~585 lines — server list, add/edit sheet, status polling, and
// enable/disable/restart actions. The inline AddServerSheet struct accounts for
// ~150 lines. Pragmatic trigger: extract AddServerSheet to its own file if the
// page exceeds ~700 lines.

struct MCPServersPage: View {
    @Environment(\.dependencies) var dependencies

    @State private var servers: [MCPServerStatus] = []
    @State private var loadError: String?
    @State private var showAddSheet = false
    @State private var actionInProgress: String?
    @State private var expandedServer: String?
    @State private var toolsByServer: [String: [MCPToolInfo]] = [:]
    @State private var toolsLoading: String?
    @State private var expandedTool: String?

    private var rpcClient: RPCClient { dependencies.rpcClient }

    var body: some View {
        SettingsPageContainer(title: "MCP Servers") {
            Button { showAddSheet = true } label: {
                Image(systemName: "plus")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(.tronEmerald)
            }
        } content: {
            if servers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 32))
                        .foregroundStyle(.tronTextMuted)
                    Text("No MCP servers configured")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                    Text("Add an MCP server to extend the agent with external tools.")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                HStack {
                    Text("Servers")
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                    if !servers.isEmpty {
                        Text("\(servers.count)")
                            .font(TronTypography.pillValue)
                            .countBadge(.tronEmerald)
                    }
                    Spacer()
                }

                ForEach(servers) { server in
                    MCPServerCard(
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
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
                    .padding(.horizontal, 4)
            }
        }
        .task { await loadStatus() }
        .sheet(isPresented: $showAddSheet) {
            AddMCPServerSheet(onAdd: { params in
                await addServer(params)
            })
            .adaptivePresentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mcpStatusChanged)) { _ in
            Task { await loadStatus() }
        }
    }

    // MARK: - Actions

    private func loadStatus() async {
        loadError = nil
        do {
            servers = try await rpcClient.mcp.status()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func toggleExpansion(_ server: MCPServerStatus) {
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
                let tools = try await rpcClient.mcp.listTools(server: serverName)
                toolsByServer[serverName] = tools
            } catch {
                toolsByServer[serverName] = []
            }
            toolsLoading = nil
        }
    }

    private func addServer(_ params: MCPAddServerParams) async {
        actionInProgress = params.name
        do {
            let _ = try await rpcClient.mcp.addServer(params)
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
                try await rpcClient.mcp.removeServer(name: name)
                toolsByServer.removeValue(forKey: name)
                if expandedServer == name { expandedServer = nil }
                await loadStatus()
            } catch {
                loadError = error.localizedDescription
            }
            actionInProgress = nil
        }
    }

    private func toggleServer(_ server: MCPServerStatus) {
        actionInProgress = server.name
        Task {
            do {
                if server.isConnected {
                    try await rpcClient.mcp.disableServer(name: server.name)
                    toolsByServer.removeValue(forKey: server.name)
                } else {
                    try await rpcClient.mcp.enableServer(name: server.name)
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
                let _ = try await rpcClient.mcp.restartServer(name: name)
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

private struct MCPServerCard: View {
    let server: MCPServerStatus
    let isExpanded: Bool
    let actionInProgress: String?
    let tools: [MCPToolInfo]?
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
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
                    HStack(spacing: 6) {
                        Text(server.health.rawValue)
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(healthColor)
                        if server.toolCount > 0 {
                            Text("\(server.toolCount)")
                                .font(TronTypography.pillValue)
                                .countBadge(.tronEmerald)
                        }
                        if let error = server.lastError {
                            Text(error)
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
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

            // Expanded: tools
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if toolsLoading {
                        HStack(spacing: 6) {
                            ProgressView()
                                .tint(.tronEmerald)
                                .scaleEffect(0.6)
                            Text("Loading tools...")
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    } else if let tools, !tools.isEmpty {
                        ForEach(tools) { tool in
                            MCPToolRow(
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
                        Text("No tools discovered")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
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

private struct MCPToolRow: View {
    let tool: MCPToolInfo
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
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .padding(.horizontal, 8)
                    }

                    let sorted = tool.params.sorted { $0.required && !$1.required }
                    ForEach(sorted) { param in
                        MCPParamRow(param: param)
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

private struct MCPParamRow: View {
    let param: MCPToolParam

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(param.name)
                    .font(TronTypography.code(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextPrimary)
                Text(param.paramType)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                if param.required {
                    Text("required")
                        .font(TronTypography.mono(size: TronTypography.sizeXS))
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.tronEmerald.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            if !param.description.isEmpty {
                Text(param.description)
                    .font(TronTypography.mono(size: TronTypography.sizeXS))
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - Add Server Sheet

private struct AddMCPServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var argsText = ""
    @State private var isAdding = false
    @State private var addError: String?

    let onAdd: (MCPAddServerParams) async -> Void

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
                                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            Spacer()
                            TextField("Server name", text: $name)
                                .font(TronTypography.mono(size: TronTypography.sizeBody))
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
                                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            Spacer()
                            TextField("npx, uvx", text: $command)
                                .font(TronTypography.mono(size: TronTypography.sizeBody))
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
                                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            Spacer()
                            TextField("space-separated", text: $argsText)
                                .font(TronTypography.mono(size: TronTypography.sizeBody))
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

                    SettingsCaption(text: "Example: command \"npx\", args \"-y chrome-devtools-mcp@latest\"")

                    if let error = addError {
                        Text(error)
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
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
                    Text("Add MCP Server")
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

        let params = MCPAddServerParams(
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
