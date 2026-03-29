import SwiftUI

struct MCPServersPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies

    @State private var servers: [MCPServerStatus] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showAddSheet = false
    @State private var actionInProgress: String?
    @State private var expandedServer: String?
    @State private var toolsByServer: [String: [MCPToolInfo]] = [:]
    @State private var toolsLoading: String?
    @State private var expandedTool: String?

    private var rpcClient: RPCClient { dependencies.rpcClient }

    var body: some View {
        NavigationStack {
            List {
                if isLoading && servers.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                                .tint(.tronEmerald)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                } else if let error = loadError, servers.isEmpty {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(TronTypography.caption)
                            .foregroundStyle(.tronTextMuted)
                    }
                } else if servers.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "server.rack")
                                .font(.title2)
                                .foregroundStyle(.tronTextMuted)
                            Text("No MCP servers configured")
                                .font(TronTypography.subheadline)
                                .foregroundStyle(.tronTextMuted)
                            Text("Add an MCP server to extend the agent with external tools.")
                                .font(TronTypography.caption2)
                                .foregroundStyle(.tronTextMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(servers) { server in
                        Section {
                            MCPServerRow(
                                server: server,
                                isExpanded: expandedServer == server.name,
                                actionInProgress: actionInProgress,
                                onTap: { toggleExpansion(server) },
                                onToggle: { toggleServer(server) },
                                onRestart: { restartServer(server.name) },
                                onRemove: { removeServer(server.name) }
                            )

                            if expandedServer == server.name {
                                MCPToolListSection(
                                    tools: toolsByServer[server.name],
                                    isLoading: toolsLoading == server.name,
                                    expandedTool: $expandedTool
                                )
                            }
                        } header: {
                            if server.id == servers.first?.id {
                                HStack {
                                    Text("Servers")
                                        .font(TronTypography.sans(size: TronTypography.sizeBody3))
                                    Spacer()
                                    Text("\(servers.count)")
                                        .font(TronTypography.caption2)
                                        .foregroundStyle(.tronTextMuted)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.tronBackground)
            .environment(\.defaultMinListRowHeight, 40)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAddSheet = true } label: {
                        Image(systemName: "plus")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("MCP Servers")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
            .task { await loadStatus() }
            .refreshable { await loadStatus() }
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
    }

    // MARK: - Actions

    private func loadStatus() async {
        isLoading = true
        loadError = nil
        do {
            servers = try await rpcClient.mcp.status()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func toggleExpansion(_ server: MCPServerStatus) {
        withAnimation {
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

// MARK: - Server Row

private struct MCPServerRow: View {
    let server: MCPServerStatus
    let isExpanded: Bool
    let actionInProgress: String?
    let onTap: () -> Void
    let onToggle: () -> Void
    let onRestart: () -> Void
    let onRemove: () -> Void

    private var isActioning: Bool {
        actionInProgress == server.name
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(healthColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronTextPrimary)
                HStack(spacing: 6) {
                    Text(server.health.rawValue)
                        .font(TronTypography.caption2)
                        .foregroundStyle(healthColor)
                    if server.toolCount > 0 {
                        Text("\(server.toolCount)")
                            .font(TronTypography.pillValue)
                            .countBadge(.tronEmerald)
                    }
                    if let error = server.lastError {
                        Text("· \(error)")
                            .font(TronTypography.caption2)
                            .foregroundStyle(.red.opacity(0.8))
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
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)

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
                        .font(.body)
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private var healthColor: Color {
        switch server.health {
        case .healthy: .green
        case .degraded: .orange
        case .failed: .red.opacity(0.7)
        }
    }
}

// MARK: - Tool List Section

private struct MCPToolListSection: View {
    let tools: [MCPToolInfo]?
    let isLoading: Bool
    @Binding var expandedTool: String?

    var body: some View {
        if isLoading {
            HStack {
                Spacer()
                ProgressView()
                    .tint(.tronEmerald)
                    .scaleEffect(0.7)
                Text("Loading tools...")
                    .font(TronTypography.caption2)
                    .foregroundStyle(.tronTextMuted)
                Spacer()
            }
            .padding(.vertical, 4)
        } else if let tools, !tools.isEmpty {
            ForEach(tools) { tool in
                // Tool header row — always one list row
                MCPToolHeaderRow(
                    tool: tool,
                    isExpanded: expandedTool == tool.id,
                    onTap: {
                        withAnimation {
                            expandedTool = expandedTool == tool.id ? nil : tool.id
                        }
                    }
                )

                // Param rows — required first, then optional
                if expandedTool == tool.id {
                    let sorted = tool.params.sorted { $0.required && !$1.required }
                    ForEach(sorted) { param in
                        MCPParamRow(param: param)
                    }
                }
            }
        } else if tools != nil {
            Text("No tools discovered")
                .font(TronTypography.caption2)
                .foregroundStyle(.tronTextMuted)
                .padding(.vertical, 4)
        }
    }
}

// MARK: - Tool Header Row (single list row, fixed height)

private struct MCPToolHeaderRow: View {
    let tool: MCPToolInfo
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                    .foregroundStyle(.tronEmerald.opacity(0.7))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.tool)
                        .font(TronTypography.caption)
                        .foregroundStyle(.tronTextPrimary)
                    if !tool.description.isEmpty {
                        Text(tool.description)
                            .font(TronTypography.caption2)
                            .foregroundStyle(.tronTextMuted)
                            .lineLimit(isExpanded ? nil : 2)
                    }
                }

                Spacer()

                if !tool.params.isEmpty {
                    Text("\(tool.params.count)")
                        .font(TronTypography.pillValue)
                        .countBadge(.tronSlate)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tronTextMuted.opacity(0.5))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Param Row (single list row, fixed height)

private struct MCPParamRow: View {
    let param: MCPToolParam

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(param.name)
                    .font(TronTypography.caption2.monospaced())
                    .foregroundStyle(.tronTextPrimary)
                Text(param.paramType)
                    .font(TronTypography.caption2)
                    .foregroundStyle(.tronTextMuted)
                if param.required {
                    Text("required")
                        .font(.system(size: 9))
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.tronEmerald.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            if !param.description.isEmpty {
                Text(param.description)
                    .font(.system(size: 10))
                    .foregroundStyle(.tronTextMuted.opacity(0.7))
            }
        }
        .padding(.leading, 40)
        .padding(.vertical, 2)
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

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Server name", text: $name)
                        .font(TronTypography.subheadline)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Command (e.g. npx, uvx)", text: $command)
                        .font(TronTypography.subheadline)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Arguments (space-separated)", text: $argsText)
                        .font(TronTypography.subheadline)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Server Configuration")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3))
                } footer: {
                    Text("Example: command \"npx\", args \"-y chrome-devtools-mcp@latest\"")
                        .font(TronTypography.caption2)
                }

                if let error = addError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(TronTypography.caption)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }
            }
            .listStyle(.insetGrouped)
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
