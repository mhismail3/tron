import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serverHost") private var serverHost = "localhost"
    @AppStorage("serverPort") private var serverPort = "8080"
    @AppStorage("useTLS") private var useTLS = false
    @AppStorage("workingDirectory") private var workingDirectory = ""
    @AppStorage("defaultModel") private var defaultModel = "claude-opus-4-5-20251101"

    @State private var showingResetAlert = false
    @State private var showLogViewer = false

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
                        // Opus models
                        Text("Claude Opus 4.5").tag("claude-opus-4-5-20251101")
                        Text("Claude Opus 4").tag("claude-opus-4-20250514")
                        // Sonnet models
                        Text("Claude Sonnet 4").tag("claude-sonnet-4-20250514")
                        Text("Claude Sonnet 4 (Thinking)").tag("claude-sonnet-4-20250514-thinking")
                        // Haiku models
                        Text("Claude Haiku 3.5").tag("claude-3-5-haiku-20241022")
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

                // Debug
                Section {
                    Button {
                        showLogViewer = true
                    } label: {
                        HStack {
                            Label("View Logs", systemImage: "doc.text.magnifyingglass")
                            Spacer()
                            Text("Level: \(String(describing: logger.minimumLevel).capitalized)")
                                .font(.caption)
                                .foregroundStyle(.tronTextMuted)
                        }
                    }

                    HStack {
                        Label("Log Level", systemImage: "list.bullet.rectangle")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { logger.minimumLevel },
                            set: { logger.setLevel($0) }
                        )) {
                            Text("Verbose").tag(LogLevel.verbose)
                            Text("Debug").tag(LogLevel.debug)
                            Text("Info").tag(LogLevel.info)
                            Text("Warning").tag(LogLevel.warning)
                            Text("Error").tag(LogLevel.error)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("View real-time logs for debugging connection and message issues.")
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
            .sheet(isPresented: $showLogViewer) {
                LogViewer()
            }
            .scrollContentBackground(.hidden)
            .background(Color.tronBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
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
        defaultModel = "claude-opus-4-5-20251101"
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
