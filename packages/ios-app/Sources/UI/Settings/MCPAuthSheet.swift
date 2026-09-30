import SwiftUI

/// Presents the same provider authorization content for Pi's session-bound MCP
/// auth operation; only the owner and cancellation RPC differ.
struct MCPAuthSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let operationID: String
    let onFinished: () -> Void
    @State private var trail = ProviderAuthSelectionTrail()
    @State private var answeringPromptID: String?
    @State private var answeringOptionID: String?
    @State private var error: String?
    @State private var hasPresentedOperation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.authEvent?.operationId == operationID || model.authPrompt?.operationId == operationID {
                        ProviderAuthFlowContent(
                            trail: trail,
                            answeringPromptID: answeringPromptID,
                            answeringOptionID: answeringOptionID,
                            isDisabled: answeringPromptID != nil,
                            onChoose: answer,
                            onChangeStep: { _, _ in }
                        )
                    } else {
                        TronSettingsNotice(message: "Waiting for the MCP server's sign-in request…", accent: .tronCyan)
                    }
                    if let error { TronSettingsNotice(message: error, accent: .tronError) }
                }.padding(18)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle("MCP Sign In", accent: .tronCyan)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { Task { await cancel() } }
                }
            }
            .tronPresentation()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .onChange(of: model.authEvent?.operationId) { oldValue, newValue in
            if newValue == operationID { hasPresentedOperation = true }
            if hasPresentedOperation, oldValue == operationID, newValue != operationID { finish() }
        }
        .onChange(of: model.authPrompt?.operationId) { oldValue, newValue in
            if newValue == operationID { hasPresentedOperation = true }
            if hasPresentedOperation, oldValue == operationID, newValue != operationID { finish() }
        }
    }

    private func answer(_ prompt: ProviderAuthPromptState, _ value: String) {
        guard answeringPromptID == nil else { return }
        answeringPromptID = prompt.id
        answeringOptionID = value
        Task { @MainActor in
            do {
                try await model.answerAuth(value)
                if prompt.kind == .select { trail.record(prompt, chosenID: value) }
            } catch { self.error = error.localizedDescription }
            answeringPromptID = nil
            answeringOptionID = nil
        }
    }

    private func cancel() async {
        do {
            _ = try await model.mutateMCPAdmin("mcp.auth.cancel", parameters: ["operationId": .string(operationID)])
            model.finishMCPAuthOperation(operationID: operationID)
            finish()
        } catch { self.error = error.localizedDescription }
    }

    private func finish() {
        onFinished()
        dismiss()
    }
}
