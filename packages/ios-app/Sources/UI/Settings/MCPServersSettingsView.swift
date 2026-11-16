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
        let value: JSONValue?
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

    static func isNeedsAuth(_ state: String) -> Bool { state == "needs-auth" }

    static let exposures: [(value: String, title: String)] = [
        ("codemode", "Codemode"),
        ("deferred", "Tool search"), ("direct", "Direct"), ("hidden", "Hidden"),
    ]
    static func exposureChoice(_ value: String) -> String {
        value == "codemode-deferred" ? "codemode" : value
    }
    static func exposureTitle(_ value: String) -> String {
        let choice = exposureChoice(value)
        return exposures.first { $0.value == choice }?.title ?? value
    }

    static func change(server: String, value: JSONValue?) -> JSONValue {
        var change: [String: JSONValue] = [
            "key": .string("tools.mcp.server"), "layer": .string("global"),
            "qualifiers": .object(["server": .string(server)]), "op": .string(value == nil ? "unset" : "set"),
        ]
        if let value { change["value"] = value }
        return .object(change)
    }

    static func value(_ current: JSONValue, enabled: Bool? = nil, exposure: String? = nil, bearer: JSONValue? = nil) -> JSONValue {
        var fields = current.objectValue ?? [:]
        if let enabled { fields["enabled"] = .bool(enabled) }
        if let exposure { fields["exposure"] = .string(exposure) }
        if let bearer { fields["headers"] = .object(["Authorization": bearer]) }
        return .object(fields)
    }
}

private struct MCPPendingChange: Identifiable {
    let id = UUID()
    let change: JSONValue
    let review: ChangeReview
    let draft: MCPAddServerDraft?
}

private struct MCPAddServerDraft: Equatable {
    let serverName: String
    let transport: String
    let url: String
    let command: String
    let args: String
    let bearerToken: String
}

struct MCPServersSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronCyan }
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.colorScheme) private var colorScheme
    let sessionID: String?
    @PresentationState private var servers: [MCPServerList.Server] = []
    @PresentationState private var serverErrorCount = 0
    @PresentationState private var loading = true
    @PresentationState private var error: String?
    @PresentationState private var generation = 0
    @PresentationState private var showingAdd = false
    @PresentationState private var serverName = ""
    @PresentationState private var transport = "http"
    @PresentationState private var url = ""
    @PresentationState private var command = ""
    @PresentationState private var args = ""
    @PresentationState private var tokenServer: String?
    @PresentationState private var token = ""
    @PresentationState private var working = false
    @PresentationState private var authOperationID: String?
    @PresentationState private var pendingChange: MCPPendingChange?
    private static let globalTarget: JSONValue = .object(["kind": .string("global")])

    init(sessionID: String? = nil) {
        self.sessionID = sessionID
    }

    private var requestID: String { "\(model.knowledgePresentationIdentity):\(model.foregroundReconciliationGeneration):\(model.mcpConfigurationRevision):\(generation)" }
    private var addDraft: MCPAddServerDraft {
        MCPAddServerDraft(serverName: serverName, transport: transport, url: url, command: command, args: args, bearerToken: token)
    }

    var body: some View {
        let destination = model.knowledgeDestinationIdentity
        ScrollView {
            TronSettingsSections(alignment: .leading, spacing: 18, lazy: true, hidesLoneHeading: true) {
                if let error { TronSettingsNotice(message: error, accent: .tronError, retry: reload) }
                if serverErrorCount > 0 {
                    TronSettingsNotice(message: "\(serverErrorCount) entr\(serverErrorCount == 1 ? "y" : "ies") in mcp.json could not be read", accent: .tronError)
                }
                TronSettingsGroup(
                    "Servers",
                    detail: "Available in every session.",
                    accent: accent
                ) {
                    if loading && servers.isEmpty {
                        TronLoadingState(label: "Loading MCP servers…", accent: accent)
                            .padding(.vertical, TronSpacing.xl)
                            .frame(maxWidth: .infinity)
                    } else if servers.isEmpty {
                        TronPlaceholderState(title: "No MCP servers", detail: "Add a server that runs on your Mac or one you reach over HTTP.", icon: "server.rack")
                    } else {
                        ForEach(servers) { server in
                            serverRow(server)
                            if server.id != servers.last?.id { TronSettingsDivider(accent: accent) }
                        }
                    }
                }
                .tronSettingsCaption("New and changed servers reach a chat when it starts or after /reload. Sign-ins stay on your Mac; bearer tokens are stored in the Mac Keychain.")
                Button { showingAdd = true } label: {
                    TronSettingsRow(
                        icon: "plus",
                        title: "Add Server",
                        accent: accent,
                        titleColor: TronSettingsButtonContrastPolicy.usesWhiteForeground(in: colorScheme) ? .white : accent
                    )
                }
                .buttonStyle(.plain)
                .tronGlassSurface(accent: accent, interactive: true)
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
        .onChange(of: model.knowledgeDestinationIdentity) { _, _ in
            generation &+= 1; servers = []; error = nil; working = false
            showingAdd = false; tokenServer = nil; authOperationID = nil; pendingChange = nil
            clearAddDraft(); transport = "http"
        }
        .onChange(of: activity.allowsPresentationPublication) { _, active in if !active { generation &+= 1; loading = false } }
        .tronSettingsVisualTheme(accent: accent)
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
                onAdd: {
                    let submitted = addDraft
                    Task { await addServer(submitted, destination: destination) }
                }
            )
            .tronManagedSheet(item: $pendingChange, identity: { "settings.mcp.add.review.\($0.id)" }) { review(for: $0, destination: destination) }
        }
        .tronManagedSheet(item: Binding(get: { showingAdd ? nil : pendingChange }, set: { pendingChange = $0 }),
                          identity: { "settings.mcp.review.\($0.id)" }) { review(for: $0, destination: destination) }
        .tronManagedSheet(isPresented: Binding(get: { authOperationID != nil }, set: { if !$0 { authOperationID = nil } }), identity: "settings.mcp.auth") {
            if let operationID = authOperationID {
                MCPAuthSheet(operationID: operationID) { authOperationID = nil }
                    .environment(model)
                    .tronSettingsVisualTheme(accent: accent)
            }
        }
        .tronManagedSheet(isPresented: Binding(get: { tokenServer != nil }, set: { if !$0 { tokenServer = nil; token = "" } }), identity: "settings.mcp.token") {
            NavigationStack {
                VStack(spacing: 16) {
                    TronSettingsGroup("Bearer Token", accent: accent) {
                        SecureField("Token", text: $token).textContentType(.password).tronTextEntryDone().padding(12)
                    }
                    Button("Store in Keychain") {
                        let submittedToken = token, submittedServer = tokenServer
                        Task { await setToken(submittedToken, server: submittedServer, destination: destination) }
                    }.buttonStyle(TronActionButtonStyle(role: .primary)).disabled(working || token.isEmpty)
                    Spacer(minLength: 0)
                }.padding(18).tronNavigationTitle("MCP Token").tronPresentation().presentationDetents([.medium]).presentationDragIndicator(.hidden)
            }.tronSettingsVisualTheme(accent: accent)
        }
    }

    private func serverRow(_ server: MCPServerList.Server) -> some View {
        let destination = model.knowledgeDestinationIdentity
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
            TronInlineMenu("Manage", accent: accent) {
                if MCPServerPresentationPolicy.isNeedsAuth(server.state) {
                    Button("Sign In", systemImage: "person.badge.key") { Task { await startAuth(server.name, destination: destination) } }
                }
                if let value = server.value {
                    Button(server.enabled ? "Turn Off" : "Turn On", systemImage: "power") {
                        Task { await changeServer(server.name, to: MCPServerPresentationPolicy.value(value, enabled: !server.enabled), destination: destination) }
                    }
                    Picker("Exposure", selection: Binding(
                        get: { MCPServerPresentationPolicy.exposureChoice(server.exposure) },
                        set: { exposure in Task { await changeServer(server.name, to: MCPServerPresentationPolicy.value(value, exposure: exposure), destination: destination) } }
                    )) {
                        ForEach(MCPServerPresentationPolicy.exposures, id: \.value) { Text($0.title).tag($0.value) }
                    }
                    .pickerStyle(.menu)
                    if value.objectValue?["url"] != nil {
                        Button("Set Bearer Token", systemImage: "key") { tokenServer = server.name }
                    }
                }
                if !MCPServerPresentationPolicy.isNeedsAuth(server.state) {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") { Task { if await mutate("mcp.logout", ["server": .string(server.name)], destination: destination) != nil { generation &+= 1 } } }
                }
                if server.value != nil {
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) { Task { await changeServer(server.name, to: nil, destination: destination) } }
                }
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
        if MCPServerPresentationPolicy.isNeedsAuth(server.state) { return .tronAmber }
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
            struct Params: Encodable { let scope = "global" }
            let loaded: MCPServerList = try await model.client.request("mcp.list", Params())
            guard current(ticket, identity) else { return }; servers = loaded.servers; serverErrorCount = loaded.errors
        } catch {
            guard current(ticket, identity) else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    private func current(_ ticket: Int, _ identity: KnowledgePresentationIdentity) -> Bool {
        !Task.isCancelled && activity.allowsPresentationPublication && generation == ticket && identity == model.knowledgePresentationIdentity
    }
    private func review(for pending: MCPPendingChange, destination: KnowledgeDestinationIdentity) -> some View {
        ChangeReviewSheet(review: pending.review, approve: {
            guard pendingChange?.id == pending.id else { return }
            pendingChange = nil
            Task { await apply(pending.change, digest: pending.review.digest, draft: pending.draft, destination: destination) }
        }, cancel: { pendingChange = nil })
        .tronSettingsVisualTheme(accent: accent)
    }
    @discardableResult
    private func mutate(_ method: String, _ fields: [String: JSONValue], destination: KnowledgeDestinationIdentity) async -> JSONValue? {
        guard !working, model.knowledgeDestinationIdentity == destination else { return nil }
        working = true; error = nil
        defer { if model.knowledgeDestinationIdentity == destination { working = false } }
        do {
            let response = try await model.mutateMCPAdmin(method, parameters: fields)
            guard model.knowledgeDestinationIdentity == destination else { return nil }
            return response
        } catch {
            guard model.knowledgeDestinationIdentity == destination else { return nil }
            self.error = error.localizedDescription
            return nil
        }
    }
    private func changeServer(_ server: String, to value: JSONValue?, draft: MCPAddServerDraft? = nil, destination: KnowledgeDestinationIdentity) async {
        guard !working, model.knowledgeDestinationIdentity == destination else { return }
        let change = MCPServerPresentationPolicy.change(server: server, value: value)
        working = true; error = nil
        do {
            let preview = try await model.previewSettingsChange(target: Self.globalTarget, change: change)
            guard model.knowledgeDestinationIdentity == destination else { return }
            working = false
            if let failure = preview.changes.first?.error { error = failure.message; return }
            if let review = preview.review, review.requiresTap {
                pendingChange = MCPPendingChange(change: change, review: review, draft: draft)
                return
            }
            await apply(change, digest: nil, draft: draft, destination: destination)
        } catch {
            guard model.knowledgeDestinationIdentity == destination else { return }
            working = false
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    private func apply(_ change: JSONValue, digest: String?, draft: MCPAddServerDraft?, destination: KnowledgeDestinationIdentity) async {
        guard !working, model.knowledgeDestinationIdentity == destination else { return }
        working = true; error = nil
        defer { if model.knowledgeDestinationIdentity == destination { working = false } }
        do {
            try await model.changeSetting(target: Self.globalTarget, change: change, confirmationDigest: digest)
            guard model.knowledgeDestinationIdentity == destination else { return }
            model.noteSettingsChanged()
            generation &+= 1
            if let draft, addDraft == draft { clearAddDraft(); showingAdd = false }
        } catch {
            guard model.knowledgeDestinationIdentity == destination else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    private func bearerReference(_ server: String, token: String, destination: KnowledgeDestinationIdentity) async -> JSONValue? {
        await mutate("mcp.token.set", ["server": .string(server), "token": .string(token)], destination: destination)?.objectValue?["reference"]
    }
    private func addServer(_ submitted: MCPAddServerDraft, destination: KnowledgeDestinationIdentity) async {
        guard model.knowledgeDestinationIdentity == destination else { return }
        let name = submitted.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        var value: [String: JSONValue] = [:]
        if submitted.transport == "http" {
            value["url"] = .string(submitted.url.trimmingCharacters(in: .whitespacesAndNewlines))
            if !submitted.bearerToken.isEmpty {
                guard let reference = await bearerReference(name, token: submitted.bearerToken, destination: destination) else { return }
                value["headers"] = .object(["Authorization": reference])
            }
        } else {
            value["command"] = .string(submitted.command.trimmingCharacters(in: .whitespacesAndNewlines))
            let args = submitted.args.split(whereSeparator: \.isWhitespace).map { JSONValue.string(String($0)) }
            if !args.isEmpty { value["args"] = .array(args) }
        }
        await changeServer(name, to: .object(value), draft: submitted, destination: destination)
    }
    private func clearAddDraft() { serverName = ""; url = ""; command = ""; args = ""; token = "" }
    private func setToken(_ submittedToken: String, server: String?, destination: KnowledgeDestinationIdentity) async {
        guard let server, let current = servers.first(where: { $0.name == server })?.value,
              let reference = await bearerReference(server, token: submittedToken, destination: destination),
              model.knowledgeDestinationIdentity == destination, tokenServer == server, token == submittedToken else { return }
        tokenServer = nil; token = ""
        if current.objectValue?["headers"] == .object(["Authorization": reference]) { generation &+= 1; return }
        await changeServer(server, to: MCPServerPresentationPolicy.value(current, bearer: reference), destination: destination)
    }
    private func startAuth(_ server: String, destination: KnowledgeDestinationIdentity) async {
        guard model.knowledgeDestinationIdentity == destination else { return }
        do {
            guard let session = sessionID else { throw GatewayFailure(code: "needs_session", message: "Open the session that uses this MCP server to sign in.", retryable: false, details: nil) }
            let admission = model.beginMCPAuthAdmission()
            do {
                let response = try await model.mutateMCPAdmin("mcp.auth.start", parameters: ["sessionId": .string(session), "server": .string(server)])
                guard model.knowledgeDestinationIdentity == destination else { return }
                guard let operationID = response.objectValue?["operationId"]?.stringValue else {
                    throw GatewayFailure(code: "invalid_response", message: "The MCP sign-in operation could not be started.", retryable: true, details: nil)
                }
                model.adoptMCPAuthOperation(operationID: operationID, target: .session(id: session), admission: admission)
                authOperationID = operationID
            } catch {
                model.finishMCPAuthAdmission(admission)
                throw error
            }
        } catch {
            guard model.knowledgeDestinationIdentity == destination else { return }
            self.error = error.localizedDescription
        }
    }
}

struct MCPAddServerForm: View {
    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronCyan }
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
                TronSettingsSections(alignment: .leading, spacing: 16, hidesLoneHeading: true) {
                    TronSettingsGroup("Server name", accent: accent) {
                        TextField("For example, calendar", text: $serverName).textInputAutocapitalization(.never).autocorrectionDisabled().tronTextEntryDone().padding(12)
                    }
                    TronSettingsGroup("Transport", accent: accent) {
                        TronSegmentedControl(options: [("HTTP", "http"), ("stdio", "stdio")], selection: $transport, accent: accent).padding(12)
                    }
                    TronSettingsGroup(transport == "http" ? "Server address" : "Local command", accent: accent) {
                        if transport == "http" {
                            TextField("https://server.example", text: $url).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled().tronTextEntryDone().padding(12)
                            Text("Enter the address provided by your server host.").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary).padding(.horizontal, 12).padding(.bottom, 10)
                        } else {
                            TextField("Command that starts the server", text: $command).textInputAutocapitalization(.never).autocorrectionDisabled().tronTextEntryDone().padding(12)
                            TextField("Arguments, separated by spaces (optional)", text: $args).textInputAutocapitalization(.never).autocorrectionDisabled().tronTextEntryDone().padding(12)
                        }
                    }
                    if transport == "http" {
                        TronSettingsGroup("Bearer token (optional)", accent: accent) {
                            SecureField("Paste token", text: $bearerToken).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().tronTextEntryDone().padding(12)
                            Text("Stored securely in your Mac’s Keychain.").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary).padding(.horizontal, 12).padding(.bottom, 10)
                        }
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
        .tronSettingsVisualTheme(accent: accent)
    }
}
