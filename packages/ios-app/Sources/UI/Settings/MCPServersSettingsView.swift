import SwiftUI
import TronMobileCore

private struct MCPServerList: Decodable {
    struct Server: Decodable, Identifiable {
        let name: String
        let status: String?
        let toolCount: Int?
        let tools: [String]?
        let exposure: String?
        let error: String?
        let stderr: String?
        var id: String { name }
    }
    let servers: [Server]
    let errors: [JSONValue]?
}

/// MCP configuration is owned by Pi's mcp.json; this screen is only an
/// explicitly refreshed projection and sends accepted commands through RPC.
struct MCPServersSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    let projectCWD: String?
    @State private var servers: [MCPServerList.Server] = []
    @State private var serverErrors: [JSONValue] = []
    @State private var selectedScope = "global"
    @State private var loading = false
    @State private var error: String?
    @State private var generation = 0
    @State private var showingAdd = false
    @State private var serverName = ""
    @State private var transport = "http"
    @State private var url = ""
    @State private var command = ""
    @State private var args = ""
    @State private var tokenServer: String?
    @State private var token = ""
    @State private var working = false
    @State private var authOperationID: String?

    private var cwd: String? { selectedScope == "project" ? projectCWD : nil }
    private var requestID: String { "\(model.profileRevision):\(model.foregroundReconciliationGeneration):\(generation):\(selectedScope):\(projectCWD ?? "")" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if projectCWD != nil {
                    TronSettingsGroup("Configuration", accent: .tronCyan) {
                        Picker("Scope", selection: $selectedScope) {
                            Text("Global").tag("global")
                            Text("Trusted Project").tag("project")
                        }.pickerStyle(.segmented).padding(12)
                    }
                }
                if let error { TronSettingsNotice(message: error, retry: reload) }
                TronSettingsGroup("MCP Servers", detail: selectedScope == "global" ? "Global configuration" : "Trusted project configuration", accent: .tronCyan, surfaceStyle: .scrollOptimized) {
                    if loading && servers.isEmpty { ProgressView("Loading MCP servers…").padding() }
                    else if servers.isEmpty { TronPlaceholderState(title: "No MCP servers", detail: "Add a stdio or HTTP server to your configuration.", icon: "server.rack") }
                    ForEach(Array(serverErrors.enumerated()), id: \.offset) { _, item in
                        Text(item.objectValue?["message"]?.stringValue ?? item.stringValue ?? "MCP server reported an error")
                            .font(TronTypography.caption).foregroundStyle(Color.tronError).padding(12).textSelection(.enabled)
                    }
                    ForEach(servers) { server in
                        serverRow(server)
                        if server.id != servers.last?.id { TronSettingsDivider(accent: .tronCyan) }
                    }
                    if !servers.isEmpty { TronSettingsDivider(accent: .tronCyan) }
                    HStack {
                        Button("Add Server", systemImage: "plus") { showingAdd = true }
                        Spacer()
                        Button("Reload", systemImage: "arrow.clockwise") { reload() }
                    }.padding(12)
                }
                TronSettingsCaption("Server changes are loaded by new sessions or after /reload. Sign-in tokens stay on your Mac; bearer tokens are stored in the Mac Keychain.")
            }.padding(.horizontal, 20).padding(.vertical, 18)
        }
        .tronScrollEdgeChrome().tronNavigationTitle("MCP Servers").tronSettingsLayout()
        .task(id: PresentationActivityTaskID(source: requestID, presentationActive: activity.allowsPresentationPublication)) { await load() }
        .onChange(of: model.profileRevision) { _, _ in generation &+= 1; servers = []; error = nil }
        .onChange(of: activity.allowsPresentationPublication) { _, active in if !active { generation &+= 1; loading = false } }
        .tronSettingsVisualTheme(accent: .tronCyan)
        .tronManagedSheet(isPresented: $showingAdd, identity: "settings.mcp.add") {
            MCPAddServerForm(
                serverName: $serverName,
                transport: $transport,
                url: $url,
                command: $command,
                args: $args,
                working: working,
                onAdd: { Task { await addServer() } }
            )
        }
        .tronManagedSheet(isPresented: Binding(get: { authOperationID != nil }, set: { if !$0 { authOperationID = nil } }), identity: "settings.mcp.auth") {
            if let operationID = authOperationID {
                MCPAuthSheet(operationID: operationID) { authOperationID = nil }
                    .environment(model)
                    .tronSettingsVisualTheme(accent: .tronCyan)
            }
        }
        .tronManagedSheet(isPresented: Binding(get: { tokenServer != nil }, set: { if !$0 { tokenServer = nil; token = "" } }), identity: "settings.mcp.token") {
            NavigationStack {
                VStack(spacing: 16) {
                    TronSettingsGroup("Bearer Token", accent: .tronCyan) {
                        SecureField("Token", text: $token).textContentType(.password).padding(12)
                    }
                    Button("Store in Keychain") { Task { await setToken() } }.buttonStyle(TronActionButtonStyle(role: .primary)).disabled(working || token.isEmpty)
                    Spacer(minLength: 0)
                }.padding(18).tronNavigationTitle("MCP Token").tronPresentation().presentationDetents([.medium]).presentationDragIndicator(.hidden)
            }.tronSettingsVisualTheme(accent: .tronCyan)
        }
    }

    @ViewBuilder private func serverRow(_ server: MCPServerList.Server) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary)
                    Text("\(statusTitle(server.status)) · \(server.toolCount ?? server.tools?.count ?? 0) tools · \(server.exposure ?? "codemode")")
                        .font(TronTypography.caption).foregroundStyle(statusColor(server))
                }
                Spacer()
                Menu {
                    Button("Enable") { Task { await update(server.name, enabled: true) } }
                    Button("Disable") { Task { await update(server.name, enabled: false) } }
                    Menu("Exposure") {
                        ForEach(["codemode", "codemode-deferred", "deferred", "direct", "hidden"], id: \.self) { value in
                            Button(value) { Task { await update(server.name, exposure: value) } }
                        }
                    }
                    Button("Set Bearer Token") { tokenServer = server.name }
                    Button("Sign In") { Task { await startAuth(server.name) } }
                    Button("Sign Out") { Task { await mutate("mcp.logout", ["server": .string(server.name)]) } }
                    Button("Remove", role: .destructive) { Task { await mutate("mcp.remove", ["server": .string(server.name)]) } }
                } label: { Image(systemName: "ellipsis.circle") }.disabled(working)
            }
            if let error = server.error { Text(error).font(TronTypography.caption).foregroundStyle(Color.tronError).textSelection(.enabled) }
            if let stderr = server.stderr, !stderr.isEmpty { Text(stderr).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted).lineLimit(4).textSelection(.enabled) }
        }.padding(12)
    }

    private func statusTitle(_ status: String?) -> String {
        switch status?.lowercased() {
        case "connected": "Connected"
        case "needs sign-in": "Needs sign-in"
        case "failed": "Failed"
        case "configured": "Configured"
        case let value?: value.prefix(1).uppercased() + value.dropFirst()
        case nil: "Configured"
        }
    }

    private func statusColor(_ server: MCPServerList.Server) -> Color {
        let status = server.status?.lowercased() ?? ""
        if status.contains("sign") || status.contains("auth") { return .tronWarning }
        if status.contains("fail") || server.error != nil { return .tronError }
        if status.contains("connect") { return .tronEmerald }
        return .tronTextSecondary
    }

    private func reload() { generation &+= 1 }
    private func load() async {
        guard activity.allowsPresentationPublication else { return }
        let ticket = generation; let identity = model.knowledgePresentationIdentity
        loading = true; error = nil
        defer { if current(ticket, identity) { loading = false } }
        do {
            struct Params: Encodable { let scope: String; let cwd: String? }
            let loaded: MCPServerList = try await model.client.request("mcp.list", Params(scope: selectedScope, cwd: cwd))
            guard current(ticket, identity) else { return }; servers = loaded.servers; serverErrors = loaded.errors ?? []
        } catch {
            guard current(ticket, identity) else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    private func current(_ ticket: Int, _ identity: KnowledgePresentationIdentity) -> Bool {
        !Task.isCancelled && activity.allowsPresentationPublication && generation == ticket && identity == model.knowledgePresentationIdentity
    }
    private func mutate(_ method: String, _ fields: [String: JSONValue]) async {
        guard !working else { return }; working = true; defer { working = false }
        do {
            var params = fields
            if method != "mcp.auth.start" {
                params["scope"] = .string(selectedScope)
                if let cwd { params["cwd"] = .string(cwd) }
            }
            let _: JSONValue = try await model.mutateMCPAdmin(method, parameters: params)
            generation &+= 1
        } catch { self.error = error.localizedDescription }
    }
    private func update(_ server: String, enabled: Bool? = nil, exposure: String? = nil) async {
        var fields: [String: JSONValue] = ["server": .string(server)]
        if let enabled { fields["enabled"] = .bool(enabled) }; if let exposure { fields["exposure"] = .string(exposure) }
        await mutate("mcp.update", fields)
    }
    private func addServer() async {
        var fields: [String: JSONValue] = ["server": .string(serverName), "transport": .string(transport)]
        if transport == "http" { fields["url"] = .string(url) }
        else { fields["command"] = .string(command); fields["args"] = .array(args.split(whereSeparator: \.isWhitespace).map { .string(String($0)) }) }
        await mutate("mcp.add", fields)
        if error == nil { serverName = ""; url = ""; command = ""; args = ""; showingAdd = false }
    }
    private func setToken() async {
        guard let name = tokenServer else { return }
        await mutate("mcp.token.set", ["server": .string(name), "token": .string(token)])
        tokenServer = nil; token = ""
    }
    private func startAuth(_ server: String) async {
        do {
            // MCP OAuth is owned by a live Pi session; this screen deliberately
            // reports the missing session rather than inventing a parallel flow.
            guard let session = model.selectedSessionID else { throw GatewayFailure(code: "needs_session", message: "Open the session that uses this MCP server to sign in.", retryable: false, details: nil) }
            let response = try await model.mutateMCPAdmin("mcp.auth.start", parameters: ["sessionId": .string(session), "server": .string(server)])
            guard let operationID = response.objectValue?["operationId"]?.stringValue else {
                throw GatewayFailure(code: "invalid_response", message: "The MCP sign-in operation could not be started.", retryable: true, details: nil)
            }
            authOperationID = operationID
        } catch { self.error = error.localizedDescription }
    }
}

/// Shared by the production managed sheet and hosted presentation evidence.
struct MCPAddServerForm: View {
    @Binding var serverName: String
    @Binding var transport: String
    @Binding var url: String
    @Binding var command: String
    @Binding var args: String
    let working: Bool
    let onAdd: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TronSettingsGroup("Server", accent: .tronCyan) {
                        TextField("Server name", text: $serverName).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12)
                        Picker("Transport", selection: $transport) { Text("HTTP").tag("http"); Text("stdio").tag("stdio") }.padding(12)
                    }
                    TronSettingsGroup(transport == "http" ? "HTTP Endpoint" : "Local Process", accent: .tronCyan) {
                        if transport == "http" { TextField("https://…", text: $url).textInputAutocapitalization(.never).keyboardType(.URL).padding(12) }
                        else {
                            TextField("Command", text: $command).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12)
                            TextField("Arguments (space separated)", text: $args).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12)
                        }
                    }
                    Button("Add Server", action: onAdd).buttonStyle(TronActionButtonStyle(role: .primary)).disabled(working || serverName.isEmpty)
                }.padding(18)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Add MCP Server")
            .tronPresentation()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .tronSettingsVisualTheme(accent: .tronCyan)
    }
}
