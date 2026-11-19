import SwiftUI
import TronMobileCore

struct MCPSignInCard: View {
    let sessionID: String
    let servers: [MCPServerList.Server]
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @PresentationState private var authOperationID: String?
    @PresentationState private var starting: String?
    @PresentationState private var error: String?

    private var needsSignIn: [MCPServerList.Server] { servers.filter { MCPServerPresentationPolicy.isNeedsAuth($0.state) } }

    var body: some View {
        Group {
            if !needsSignIn.isEmpty {
                TronGlassCard(accent: .tronCyan) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(needsSignIn) { server in
                            Button { Task { await start(server.name) } } label: {
                                TronSettingsRow(icon: "person.badge.key", title: server.name, subtitle: "Needs sign-in", titleIsIdentifier: !dynamicTypeSize.isAccessibilitySize,
                                                accent: .tronCyan) { TronInlineActionLabel("Sign In", accent: .tronCyan) }
                            }
                            .buttonStyle(.plain)
                            .disabled(starting != nil)
                            .accessibilityIdentifier("mcp-sign-in-\(server.name)")
                            if server.id != needsSignIn.last?.id { TronSettingsDivider(accent: .tronCyan) }
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle").font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronError).padding(12)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mcp-sign-in-card")
            }
        }
        .tronManagedSheet(isPresented: Binding(get: { authOperationID != nil }, set: { if !$0 { authOperationID = nil } }), identity: "mcp.sign-in") {
            if let operationID = authOperationID {
                MCPAuthSheet(operationID: operationID) { authOperationID = nil }
                    .environment(model)
                    .tronSettingsVisualTheme(accent: .tronCyan)
            }
        }
    }

    static func load(_ model: AppModel) async -> [MCPServerList.Server]? {
        struct Params: Encodable { let scope = "global" }
        return (try? await model.client.request("mcp.list", Params()) as MCPServerList)?.servers
    }

    private func start(_ server: String) async {
        starting = server
        defer { starting = nil }
        let admission = model.beginMCPAuthAdmission()
        do {
            let response = try await model.mutateMCPAdmin("mcp.auth.start", parameters: ["sessionId": .string(sessionID), "server": .string(server)])
            guard let operationID = response.objectValue?["operationId"]?.stringValue else {
                throw GatewayFailure(code: "invalid_response", message: "The MCP sign-in operation could not be started.", retryable: true, details: nil)
            }
            model.adoptMCPAuthOperation(operationID: operationID, target: .session(id: sessionID), admission: admission)
            error = nil
            authOperationID = operationID
        } catch {
            model.finishMCPAuthAdmission(admission)
            self.error = error.localizedDescription
        }
    }
}
