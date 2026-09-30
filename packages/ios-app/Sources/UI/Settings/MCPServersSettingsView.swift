import SwiftUI
import TronMobileCore

struct MCPServerList: Decodable {
    struct Server: Decodable, Identifiable {
        let name: String
        let scope: String
        let enabled: Bool
        let exposure: String
        let transport: String
        let state: String
        let tools: [String]
        let error: String?
        var id: String { name }
    }
    let servers: [Server]
    let errors: Int
}

enum MCPServerPresentationPolicy {
    static func stateTitle(_ state: String) -> String {
        switch state {
        case "connected": "Connected"
        case "needs-auth": "Needs sign-in"
        case "failed": "Failed"
        case "disabled": "Disabled"
        default: state.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        }
    }

    static func includes(_ server: MCPServerList.Server, selectedScope: String) -> Bool {
        selectedScope != "project" || server.scope == "project"
    }

    static func isNeedsAuth(_ state: String) -> Bool { state == "needs-auth" }
    static func shouldDismissTokenSheet(afterError error: String?) -> Bool { error == nil }
}

/// MCP configuration is owned by Pi's mcp.json; this screen is only an
/// explicitly refreshed projection and sends accepted commands through RPC.
struct MCPServersSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    let projectCWD: String?
    @State private var servers: [MCPServerList.Server] = []
    @State private var serverErrorCount = 0
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

    init(projectCWD: String?, initialScope: String = "global") {
        self.projectCWD = projectCWD
        _selectedScope = State(initialValue: initialScope)
    }

    private var cwd: String? { selectedScope == "project" ? projectCWD : nil }
    private var visibleServers: [MCPServerList.Server] {
        servers.filter { MCPServerPresentationPolicy.includes($0, selectedScope: selectedScope) }
    }
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
                    else if visibleServers.isEmpty { TronPlaceholderState(title: "No MCP servers", detail: "Add a stdio or HTTP server to your configuration.", icon: "server.rack") }
                    if serverErrorCount > 0 {
                        Text("\(serverErrorCount) MCP configuration error\(serverErrorCount == 1 ? "" : "s")")
                            .font(TronTypography.caption).foregroundStyle(Color.tronError).padding(12)
                    }
                    ForEach(visibleServers) { server in
                        serverRow(server)
                        if server.id != visibleServers.last?.id { TronSettingsDivider(accent: .tronCyan) }
                    }
                    if !visibleServers.isEmpty { TronSettingsDivider(accent: .tronCyan) }
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
                bearerToken: $token,
                error: error,
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
                    Text("\(MCPServerPresentationPolicy.stateTitle(server.state)) · \(server.tools.count) tools · \(server.exposure)")
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
        }.padding(12)
    }

    private func statusColor(_ server: MCPServerList.Server) -> Color {
        if MCPServerPresentationPolicy.isNeedsAuth(server.state) { return .tronWarning }
        if server.state == "failed" || server.error != nil { return .tronError }
        if server.state == "connected" { return .tronEmerald }
        return .tronTextSecondary
    }

    private func reload() { generation &+= 1 }
    private func load() async {
        guard activity.allowsPresentationPublication else { return }
        let ticket = generation; let identity = model.knowledgePresentationIdentity
        loading = true; error = nil; serverErrorCount = 0
        defer { if current(ticket, identity) { loading = false } }
        do {
            struct Params: Encodable { let scope: String; let cwd: String? }
            let loaded: MCPServerList = try await model.client.request("mcp.list", Params(scope: selectedScope, cwd: cwd))
            guard current(ticket, identity) else { return }; servers = loaded.servers; serverErrorCount = loaded.errors
        } catch {
            guard current(ticket, identity) else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    private func current(_ ticket: Int, _ identity: KnowledgePresentationIdentity) -> Bool {
        !Task.isCancelled && activity.allowsPresentationPublication && generation == ticket && identity == model.knowledgePresentationIdentity
    }
    private func mutate(_ method: String, _ fields: [String: JSONValue]) async {
        guard !working else { return }; working = true; error = nil; defer { working = false }
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
        var fields: [String: JSONValue] = ["server": .string(serverName.trimmingCharacters(in: .whitespacesAndNewlines)), "transport": .string(transport)]
        if transport == "http" { fields["url"] = .string(url.trimmingCharacters(in: .whitespacesAndNewlines)) }
        else { fields["command"] = .string(command.trimmingCharacters(in: .whitespacesAndNewlines)); fields["args"] = .array(args.split(whereSeparator: \.isWhitespace).map { .string(String($0)) }) }
        await mutate("mcp.add", fields)
        guard error == nil else { return }
        let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            await mutate("mcp.token.set", ["server": .string(name), "token": .string(token)])
            guard error == nil else { return }
        }
        serverName = ""; url = ""; command = ""; args = ""; token = ""; showingAdd = false
    }
    private func setToken() async {
        guard let name = tokenServer else { return }
        await mutate("mcp.token.set", ["server": .string(name), "token": .string(token)])
        guard MCPServerPresentationPolicy.shouldDismissTokenSheet(afterError: error) else { return }
        tokenServer = nil; token = ""
    }
    private func startAuth(_ server: String) async {
        do {
            // MCP OAuth is owned by a live Pi session; this screen deliberately
            // reports the missing session rather than inventing a parallel flow.
            guard let session = model.selectedSessionID else { throw GatewayFailure(code: "needs_session", message: "Open the session that uses this MCP server to sign in.", retryable: false, details: nil) }
            let admission = model.beginMCPAuthAdmission()
            do {
                let response = try await model.mutateMCPAdmin("mcp.auth.start", parameters: ["sessionId": .string(session), "server": .string(server)])
                guard let operationID = response.objectValue?["operationId"]?.stringValue else {
                    throw GatewayFailure(code: "invalid_response", message: "The MCP sign-in operation could not be started.", retryable: true, details: nil)
                }
                model.adoptMCPAuthOperation(operationID: operationID, target: .session(id: session), admission: admission)
                authOperationID = operationID
            } catch {
                model.finishMCPAuthAdmission(admission)
                throw error
            }
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
    @Binding var bearerToken: String
    let error: String?
    let working: Bool
    let onAdd: () -> Void

    private var hasServerName: Bool {
        !serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var validationError: String? {
        guard hasServerName else { return nil }
        if transport == "http" {
            guard let endpoint = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
                  endpoint.host?.isEmpty == false else { return "Enter a valid HTTP or HTTPS address." }
        } else if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the command that starts this server."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TronSettingsGroup("Server name", accent: .tronCyan) {
                        TextField("For example, calendar", text: $serverName).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12)
                    }
                    TronSettingsGroup("Transport", accent: .tronCyan) {
                        TronSegmentedControl(options: [("HTTP", "http"), ("stdio", "stdio")], selection: $transport, accent: .tronCyan).padding(12)
                    }
                    TronSettingsGroup(transport == "http" ? "Server address" : "Local command", accent: .tronCyan) {
                        if transport == "http" {
                            TextField("https://server.example", text: $url).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled().padding(12)
                            Text("Enter the address provided by your server host.").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary).padding(.horizontal, 12).padding(.bottom, 10)
                        } else {
                            TextField("Command that starts the server", text: $command).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12)
                            TextField("Arguments, separated by spaces (optional)", text: $args).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12)
                        }
                    }
                    TronSettingsGroup("Bearer token (optional)", accent: .tronCyan) {
                        SecureField("Paste token", text: $bearerToken).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12)
                        Text("Stored securely in your Mac’s Keychain.").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary).padding(.horizontal, 12).padding(.bottom, 10)
                    }
                    if let message = error ?? validationError {
                        Text(message).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronError).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4).accessibilityIdentifier("mcp-add-validation-error")
                    }
                    Button("Add Server", action: onAdd).buttonStyle(TronActionButtonStyle(role: .primary)).disabled(working || !hasServerName || validationError != nil)
                }.padding(18)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Add MCP Server")
            .tronPresentation()
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .tronSettingsVisualTheme(accent: .tronCyan)
    }
}
