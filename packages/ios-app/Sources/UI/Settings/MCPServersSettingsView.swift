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

    /// Plain names for Pi's exposure values, in the order the menu offers them.
    static let exposures: [(value: String, title: String)] = [
        ("codemode", "Codemode"), ("codemode-deferred", "Codemode, on demand"),
        ("deferred", "Tool search"), ("direct", "Direct"), ("hidden", "Hidden"),
    ]
    static func exposureTitle(_ value: String) -> String {
        exposures.first { $0.value == value }?.title ?? value
    }
    static func shouldDismissTokenSheet(afterError error: String?) -> Bool { error == nil }
}

/// MCP configuration is owned by Pi's mcp.json; this screen is only an
/// explicitly refreshed projection and sends accepted commands through RPC.
struct MCPServersSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.colorScheme) private var colorScheme
    let projectCWD: String?
    /// The session Settings was opened from. MCP OAuth runs inside a live
    /// session's Pi MCP extension, so sign-in needs one.
    let sessionID: String?
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

    init(projectCWD: String?, sessionID: String? = nil, initialScope: String = "global") {
        self.projectCWD = projectCWD
        self.sessionID = sessionID
        _selectedScope = State(initialValue: initialScope)
    }

    private var cwd: String? { selectedScope == "project" ? projectCWD : nil }
    private var visibleServers: [MCPServerList.Server] {
        servers.filter { MCPServerPresentationPolicy.includes($0, selectedScope: selectedScope) }
    }
    private var requestID: String { "\(model.profileRevision):\(model.foregroundReconciliationGeneration):\(generation):\(selectedScope):\(projectCWD ?? "")" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if projectCWD != nil {
                    TronSegmentedControl(
                        options: [(label: "Global", value: "global"), (label: "Project", value: "project")],
                        selection: $selectedScope,
                        accent: .tronCyan,
                        minimumHeight: 40
                    )
                }
                if let error { TronSettingsNotice(message: error, accent: .tronError, retry: reload) }
                if serverErrorCount > 0 {
                    TronSettingsNotice(message: "\(serverErrorCount) entr\(serverErrorCount == 1 ? "y" : "ies") in mcp.json could not be read", accent: .tronError)
                }
                TronSettingsGroup(
                    "Servers",
                    detail: selectedScope == "global" ? "Available in every session." : "Only in this trusted project.",
                    accent: .tronCyan,
                    surfaceStyle: .scrollOptimized
                ) {
                    if loading && servers.isEmpty {
                        TronLoadingState(label: "Loading MCP servers…", accent: .tronCyan)
                            .padding(.vertical, TronSpacing.xl)
                            .frame(maxWidth: .infinity)
                    } else if visibleServers.isEmpty {
                        TronPlaceholderState(title: "No MCP servers", detail: "Add a server that runs on your Mac or one you reach over HTTP.", icon: "server.rack")
                    } else {
                        ForEach(visibleServers) { server in
                            serverRow(server)
                            if server.id != visibleServers.last?.id { TronSettingsDivider(accent: .tronCyan) }
                        }
                    }
                }
                .tronSettingsCaption("New and changed servers reach a chat when it starts or after /reload. Sign-ins stay on your Mac; bearer tokens are stored in the Mac Keychain.")
                Button { showingAdd = true } label: {
                    TronSettingsRow(
                        icon: "plus",
                        title: "Add Server",
                        accent: .tronCyan,
                        titleColor: TronSettingsButtonContrastPolicy.usesWhiteForeground(in: colorScheme) ? .white : .tronCyan
                    )
                }
                .buttonStyle(.plain)
                .tronGlassSurface(accent: .tronCyan, interactive: true)
                .disabled(working)
            }.padding(.horizontal, 20).padding(.vertical, 18)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronReloadToolbarButton(isReloading: loading, action: reload)
            }
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

    private func serverRow(_ server: MCPServerList.Server) -> some View {
        let summary = "\(MCPServerPresentationPolicy.stateTitle(server.state)) · \(server.tools.count) tool\(server.tools.count == 1 ? "" : "s") · \(MCPServerPresentationPolicy.exposureTitle(server.exposure))"
        return TronSettingsRow(
            icon: statusIcon(server),
            title: server.name,
            subtitle: server.error.map { "\(summary)\n\($0)" } ?? summary,
            subtitleLineLimit: 4,
            titleIsIdentifier: true,
            accent: statusColor(server),
            subtitleColor: statusColor(server)
        ) {
            TronInlineMenu("Manage", accent: .tronCyan) {
                if MCPServerPresentationPolicy.isNeedsAuth(server.state) {
                    Button("Sign In", systemImage: "person.badge.key") { Task { await startAuth(server.name) } }
                }
                Button(server.enabled ? "Turn Off" : "Turn On", systemImage: "power") {
                    Task { await update(server.name, enabled: !server.enabled) }
                }
                Picker("Exposure", selection: Binding(
                    get: { server.exposure },
                    set: { value in Task { await update(server.name, exposure: value) } }
                )) {
                    ForEach(MCPServerPresentationPolicy.exposures, id: \.value) { Text($0.title).tag($0.value) }
                }
                .pickerStyle(.menu)
                Button("Set Bearer Token", systemImage: "key") { tokenServer = server.name }
                if !MCPServerPresentationPolicy.isNeedsAuth(server.state) {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") { Task { await mutate("mcp.logout", ["server": .string(server.name)]) } }
                }
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive) { Task { await mutate("mcp.remove", ["server": .string(server.name)]) } }
            }
            .disabled(working)
        }
    }

    private func statusIcon(_ server: MCPServerList.Server) -> String {
        if !server.enabled || server.state == "disabled" { return "pause.circle" }
        if MCPServerPresentationPolicy.isNeedsAuth(server.state) { return "person.badge.key" }
        if server.state == "failed" || server.error != nil { return "exclamationmark.triangle" }
        if server.state == "connected" { return "checkmark.circle" }
        return "server.rack"
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
            guard let session = sessionID else { throw GatewayFailure(code: "needs_session", message: "Open the session that uses this MCP server to sign in.", retryable: false, details: nil) }
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
