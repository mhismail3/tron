import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let rpcClient: RPCClient
    @AppStorage("serverHost") private var serverHost = "localhost"
    @AppStorage("serverPort") private var serverPort = "8080"
    @AppStorage("useTLS") private var useTLS = false
    @AppStorage("confirmArchive") private var confirmArchive = true
    @AppStorage("transcriptionModelId") private var transcriptionModelId = ""

    @State private var showingResetAlert = false
    @State private var showLogViewer = false
    @State private var transcriptionModels: [TranscriptionModelInfo] = []
    @State private var isLoadingTranscriptionModels = false
    @State private var transcriptionModelError: String?

    var body: some View {
        NavigationStack {
            List {
                // Server Section
                Section {
                    TextField("Host", text: $serverHost)
                        .font(.subheadline)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    TextField("Port", text: $serverPort)
                        .font(.subheadline)
                        .keyboardType(.numberPad)

                    Toggle("Use TLS (wss://)", isOn: $useTLS)
                        .font(.subheadline)
                } header: {
                    Text("Server")
                        .font(.caption)
                } footer: {
                    Text("Connect to your Tron server. Default is localhost:8080.")
                        .font(.caption2)
                }

                // Preferences Section
                Section {
                    Toggle("Confirm before archiving", isOn: $confirmArchive)
                        .font(.subheadline)
                } header: {
                    Text("Preferences")
                        .font(.caption)
                } footer: {
                    Text("Show a confirmation dialog when archiving sessions.")
                        .font(.caption2)
                }

                // Transcription Section
                Section {
                    HStack {
                        Text("Transcription Model")
                            .font(.subheadline)
                        Spacer()
                        if isLoadingTranscriptionModels {
                            ProgressView()
                        } else if transcriptionModels.isEmpty {
                            Text("Unavailable")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            if #available(iOS 26.0, *) {
                                TranscriptionModelMenu(
                                    models: transcriptionModels,
                                    selectedModelId: $transcriptionModelId
                                )
                            } else {
                                Picker("", selection: $transcriptionModelId) {
                                    ForEach(transcriptionModels) { model in
                                        Text(model.label).tag(model.id)
                                    }
                                }
                                .labelsHidden()
                                .tint(.tronEmerald)
                            }
                        }
                    }
                } header: {
                    Text("Transcription")
                        .font(.caption)
                } footer: {
                    Text(transcriptionModelError ?? "Select the model used for voice transcription.")
                        .font(.caption2)
                }

                // Advanced Section
                Section {
                    Button(role: .destructive) {
                        showingResetAlert = true
                    } label: {
                        Label("Reset All Settings", systemImage: "arrow.counterclockwise")
                            .font(.subheadline)
                    }
                } header: {
                    Text("Advanced")
                        .font(.caption)
                }

                // Footer
                Section {
                    EmptyView()
                } footer: {
                    VStack(spacing: 4) {
                        Text("v0.0.1")
                            .font(.caption2)
                        Link(destination: URL(string: "https://github.com/yourusername/tron")!) {
                            HStack(spacing: 3) {
                                Text("GitHub")
                                    .font(.caption2)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 40)
            .sheet(isPresented: $showLogViewer) {
                LogViewer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLogViewer = true } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
            .alert("Reset Settings?", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    resetToDefaults()
                }
            } message: {
                Text("This will reset all settings to their default values.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .preferredColorScheme(.dark)
        .task {
            await loadTranscriptionModels()
        }
    }

    // MARK: - Computed Properties

    var serverURL: URL? {
        let scheme = useTLS ? "wss" : "ws"
        return URL(string: "\(scheme)://\(serverHost):\(serverPort)/ws")
    }

    // MARK: - Actions

    private func resetToDefaults() {
        serverHost = "localhost"
        serverPort = "8080"
        useTLS = false
        confirmArchive = true
        transcriptionModelId = ""
    }

    @MainActor
    private func loadTranscriptionModels() async {
        if isLoadingTranscriptionModels {
            return
        }
        isLoadingTranscriptionModels = true
        transcriptionModelError = nil

        if !rpcClient.isConnected {
            await rpcClient.connect()
        }

        do {
            let result = try await rpcClient.listTranscriptionModels()
            transcriptionModels = result.models
            let availableIds = Set(result.models.map { $0.id })
            if transcriptionModelId.isEmpty || !availableIds.contains(transcriptionModelId) {
                transcriptionModelId = result.defaultModelId ?? result.models.first?.id ?? transcriptionModelId
            }
        } catch {
            transcriptionModelError = "Failed to load models: \(error.localizedDescription)"
            transcriptionModels = []
        }

        isLoadingTranscriptionModels = false
    }
}

// MARK: - Transcription Model Menu (iOS 26 Liquid Glass Popup)

@available(iOS 26.0, *)
struct TranscriptionModelMenu: View {
    let models: [TranscriptionModelInfo]
    @Binding var selectedModelId: String

    private var currentModelLabel: String {
        models.first { $0.id == selectedModelId }?.label ?? "Select"
    }

    var body: some View {
        Menu {
            ForEach(models) { model in
                Button(model.label) {
                    selectedModelId = model.id
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentModelLabel)
                    .font(.subheadline)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.tronEmerald)
        }
        .menuStyle(.button)
    }
}

// MARK: - Server URL Builder

struct ServerURLBuilder {
    static func buildURL(
        host: String,
        port: String,
        useTLS: Bool
    ) -> URL? {
        let scheme = useTLS ? "wss" : "ws"
        let urlString = "\(scheme)://\(host):\(port)/ws"
        return URL(string: urlString)
    }
}

// MARK: - Preview

#Preview {
    SettingsView(rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!))
}
