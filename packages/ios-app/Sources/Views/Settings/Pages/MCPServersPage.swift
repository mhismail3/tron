import SwiftUI

struct MCPServersPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies

    @State private var servers: [MCPServerStatus] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showAddSheet = false
    @State private var actionInProgress: String?

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
                    Section {
                        ForEach(servers) { server in
                            MCPServerRow(
                                server: server,
                                actionInProgress: actionInProgress,
                                onToggle: { toggleServer(server) },
                                onRestart: { restartServer(server.name) },
                                onRemove: { removeServer(server.name) }
                            )
                        }
                    } header: {
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
            .listStyle(.insetGrouped)
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
                await loadStatus()
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
    let actionInProgress: String?
    let onToggle: () -> Void
    let onRestart: () -> Void
    let onRemove: () -> Void

    private var isActioning: Bool {
        actionInProgress == server.name
    }

    var body: some View {
        HStack(spacing: 12) {
            // Health indicator
            Circle()
                .fill(healthColor)
                .frame(width: 8, height: 8)

            // Server info
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronTextPrimary)
                HStack(spacing: 6) {
                    Text(server.health.rawValue)
                        .font(TronTypography.caption2)
                        .foregroundStyle(healthColor)
                    if server.toolCount > 0 {
                        Text("· \(server.toolCount) tool\(server.toolCount == 1 ? "" : "s")")
                            .font(TronTypography.caption2)
                            .foregroundStyle(.tronTextMuted)
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
                    Image(systemName: "ellipsis.circle")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(.tronTextMuted)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var healthColor: Color {
        switch server.health {
        case .healthy: .green
        case .degraded: .orange
        case .failed: .red.opacity(0.7)
        }
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
