import SwiftUI

// MARK: - New Session Flow

@available(iOS 26.0, *)
struct NewSessionFlow: View {
    let rpcClient: RPCClient
    let defaultModel: String
    let eventStoreManager: EventStoreManager
    /// Callback with (sessionId, workspaceId, model, workingDirectory)
    let onSessionCreated: (String, String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workingDirectory = ""
    @State private var selectedModel: String = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showWorkspaceSelector = false
    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var showModelPicker = false

    // Clone repository sheet
    @State private var showCloneSheet = false
    @State private var showMaxSessionsAlert = false

    private var canCreate: Bool {
        !isCreating && !workingDirectory.isEmpty && !selectedModel.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Workspace section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Workspace")
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)

                        Button {
                            showWorkspaceSelector = true
                        } label: {
                            HStack {
                                if workingDirectory.isEmpty {
                                    Text("Select Workspace")
                                        .font(TronTypography.messageBody)
                                        .foregroundStyle(.tronEmerald)
                                } else {
                                    Text(displayWorkspacePath)
                                        .font(TronTypography.messageBody)
                                        .foregroundStyle(.tronEmerald)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Image(systemName: "folder.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("The directory where the agent will operate")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                    }

                    // Clone from GitHub option
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or clone a repository")
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)

                        Button {
                            showCloneSheet = true
                        } label: {
                            HStack {
                                Text("Clone from GitHub")
                                    .font(TronTypography.messageBody)
                                    .foregroundStyle(.tronEmerald)
                                Spacer()
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("Clone a GitHub repo and start a session")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                    }

                    // Model section - dynamically loaded from server
                    // Extra spacing above to visually separate from workspace/clone group
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Model")
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)

                        Button {
                            showModelPicker = true
                        } label: {
                            HStack {
                                if isLoadingModels && selectedModel.isEmpty {
                                    Text("Loading...")
                                        .font(TronTypography.messageBody)
                                        .foregroundStyle(.tronEmerald.opacity(0.8))
                                } else {
                                    Text(selectedModelDisplayName)
                                        .font(TronTypography.messageBody)
                                        .foregroundStyle(.tronEmerald)
                                }

                                Spacer()

                                Image(systemName: "cpu.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text(modelDescription)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                    }
                    .padding(.top, 8)

                    // Error message
                    if let error = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.tronError)
                            Text(error)
                                .font(TronTypography.subheadline)
                                .foregroundStyle(.tronError)
                        }
                        .padding()
                        .glassEffect(.regular.tint(Color.tronError.opacity(0.3)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("New Session")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isCreating {
                        ProgressView()
                            .tint(.tronEmerald)
                    } else {
                        Button {
                            createSession()
                        } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(canCreate ? .tronEmerald : .tronTextDisabled)
                        }
                        .disabled(!canCreate)
                    }
                }
            }
            .sheet(isPresented: $showWorkspaceSelector) {
                WorkspaceSelector(
                    rpcClient: rpcClient,
                    selectedPath: $workingDirectory
                )
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    models: availableModels,
                    currentModelId: selectedModel,
                    onSelect: { model in
                        selectedModel = model.id
                    }
                )
            }
            .sheet(isPresented: $showCloneSheet) {
                CloneRepoSheet(
                    rpcClient: rpcClient,
                    onCloned: { clonedPath in
                        // Set the cloned path as the workspace
                        workingDirectory = clonedPath
                        // Auto-create session after clone
                        createSession()
                    }
                )
            }
            .task {
                await loadModels()
            }
            .onChange(of: rpcClient.connectionState) { oldState, newState in
                if newState.isConnected && !oldState.isConnected {
                    _ = Task { await loadModels() }
                }
            }
            .onAppear {
                // Don't auto-open workspace selector - let user explicitly tap to select
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .alert("Session Limit Reached", isPresented: $showMaxSessionsAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Maximum concurrent sessions reached. Close an existing session or increase the limit in Settings.")
        }
    }

    // MARK: - Computed Properties

    /// Display name for the selected model - uses ModelInfo.formattedModelName if available
    private var selectedModelDisplayName: String {
        if let model = availableModels.first(where: { $0.id == selectedModel }) {
            return model.formattedModelName
        }
        // Fallback to String extension if models not yet loaded
        return selectedModel.shortModelName
    }

    /// Workspace path formatted for display (truncates /Users/<user>/ to ~/)
    private var displayWorkspacePath: String {
        workingDirectory.replacingOccurrences(
            of: "^/Users/[^/]+/",
            with: "~/",
            options: .regularExpression
        )
    }

    private var modelDescription: String {
        if let model = availableModels.first(where: { $0.id == selectedModel }),
           let desc = model.modelDescription {
            return desc
        }
        return ""
    }

    // MARK: - Actions

    private func loadModels() async {
        isLoadingModels = true

        // Ensure connection is established
        await rpcClient.connect()
        if !rpcClient.isConnected {
            try? await Task.sleep(for: .milliseconds(100))
        }

        do {
            let models = try await rpcClient.model.list()
            await MainActor.run {
                availableModels = models

                // Set default model - prefer the passed defaultModel if valid,
                // otherwise use the first recommended model
                if let defaultMatch = models.first(where: { $0.id == defaultModel }) {
                    selectedModel = defaultMatch.id
                } else if let recommended = models.first(where: { $0.recommended == true && $0.isAnthropic }) {
                    selectedModel = recommended.id
                } else if let first = models.first {
                    selectedModel = first.id
                }

                isLoadingModels = false
            }
        } catch {
            await MainActor.run {
                // On error, set a sensible default that matches server
                // These are the actual server model IDs from core/providers/models.ts
                selectedModel = defaultModel.isEmpty ? (availableModels.first?.id ?? "") : defaultModel
                isLoadingModels = false
            }
        }
    }

    private func createSession() {
        isCreating = true
        errorMessage = nil

        Task {
            do {
                let result = try await rpcClient.session.create(
                    workingDirectory: workingDirectory,
                    model: selectedModel
                )

                await MainActor.run {
                    // Pass session details to callback - EventStoreManager will cache it
                    onSessionCreated(
                        result.sessionId,
                        workingDirectory,  // workspaceId is the workingDirectory
                        result.model,
                        workingDirectory
                    )
                    isCreating = false
                }
            } catch let error as RPCError where error.code == RPCErrorCode.maxSessionsReached.rawValue {
                await MainActor.run {
                    showMaxSessionsAlert = true
                    isCreating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCreating = false
                }
            }
        }
    }

}
