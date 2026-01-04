import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serverHost") private var serverHost = "localhost"
    @AppStorage("serverPort") private var serverPort = "8080"
    @AppStorage("useTLS") private var useTLS = false
    @AppStorage("workingDirectory") private var workingDirectory = ""
    @AppStorage("defaultModel") private var defaultModel = "claude-sonnet-4-20250514"

    @State private var showingResetAlert = false

    var body: some View {
        NavigationStack {
            Form {
                // Server Configuration
                Section {
                    TextField("Host", text: $serverHost)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    TextField("Port", text: $serverPort)
                        .keyboardType(.numberPad)

                    Toggle("Use TLS (wss://)", isOn: $useTLS)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Connect to your Tron server. Default is localhost:8080.")
                }

                // Session Defaults
                Section {
                    TextField("Working Directory", text: $workingDirectory)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    Picker("Default Model", selection: $defaultModel) {
                        Text("Claude Sonnet 4").tag("claude-sonnet-4-20250514")
                        Text("Claude Opus 4").tag("claude-opus-4-20250514")
                        Text("Claude Haiku").tag("claude-3-5-haiku-20241022")
                    }
                } header: {
                    Text("Session Defaults")
                } footer: {
                    Text("Working directory for new sessions. Leave empty to use app documents folder.")
                }

                // About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.tronTextSecondary)
                    }

                    HStack {
                        Text("Protocol")
                        Spacer()
                        Text("JSON-RPC over WebSocket")
                            .foregroundStyle(.tronTextSecondary)
                    }

                    Link(destination: URL(string: "https://github.com/yourusername/tron")!) {
                        HStack {
                            Text("GitHub Repository")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.tronTextMuted)
                        }
                    }
                } header: {
                    Text("About")
                }

                // Advanced
                Section {
                    Button(role: .destructive) {
                        showingResetAlert = true
                    } label: {
                        Text("Reset All Settings")
                    }
                } header: {
                    Text("Advanced")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tronBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.tronSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
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
        .preferredColorScheme(.dark)
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
        workingDirectory = ""
        defaultModel = "claude-sonnet-4-20250514"
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
    SettingsView()
}
