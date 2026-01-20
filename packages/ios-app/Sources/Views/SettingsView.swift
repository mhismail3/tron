import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    #if BETA
    private static let defaultPort = "8082"
    #else
    private static let defaultPort = "8080"
    #endif

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let rpcClient: RPCClient
    @AppStorage("serverHost") private var serverHost = "localhost"
    @AppStorage("serverPort") private var serverPort = SettingsView.defaultPort
    @AppStorage("useTLS") private var useTLS = false
    @AppStorage("confirmArchive") private var confirmArchive = true

    @State private var showingResetAlert = false
    @State private var showLogViewer = false

    /// Derives environment selection from current port
    private var selectedEnvironment: String {
        switch serverPort {
        case "8080": return "prod"
        case "8082": return "beta"
        default: return "custom"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Environment Quick Switch
                Section {
                    Picker("Environment", selection: Binding(
                        get: { selectedEnvironment },
                        set: { newValue in
                            let newPort: String
                            switch newValue {
                            case "prod": newPort = "8080"
                            case "beta": newPort = "8082"
                            default: return // Don't change port for custom
                            }
                            // Update via AppState to trigger reconnection
                            appState.updateServerSettings(
                                host: serverHost,
                                port: newPort,
                                useTLS: useTLS
                            )
                            serverPort = newPort
                        }
                    )) {
                        Text("Prod").tag("prod")
                        Text("Beta").tag("beta")
                        if selectedEnvironment == "custom" {
                            Text("Custom").tag("custom")
                        }
                    }
                    .pickerStyle(.segmented)
                    .font(TronTypography.subheadline)
                } header: {
                    Text("Environment")
                        .font(TronTypography.caption)
                } footer: {
                    Text("Quickly switch between production (8080) and beta (8082) servers.")
                        .font(TronTypography.caption2)
                }

                // Server Section
                Section {
                    TextField("Host", text: $serverHost)
                        .font(TronTypography.subheadline)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onSubmit {
                            appState.updateServerSettings(host: serverHost, port: serverPort, useTLS: useTLS)
                        }

                    TextField("Port", text: $serverPort)
                        .font(TronTypography.subheadline)
                        .keyboardType(.numberPad)
                        .onSubmit {
                            appState.updateServerSettings(host: serverHost, port: serverPort, useTLS: useTLS)
                        }

                    Toggle("Use TLS (wss://)", isOn: $useTLS)
                        .font(TronTypography.subheadline)
                        .onChange(of: useTLS) { _, newValue in
                            appState.updateServerSettings(host: serverHost, port: serverPort, useTLS: newValue)
                        }
                } header: {
                    Text("Server")
                        .font(TronTypography.caption)
                } footer: {
                    Text("Connect to your Tron server. Default is localhost:\(SettingsView.defaultPort).")
                        .font(TronTypography.caption2)
                }

                // Preferences Section
                Section {
                    Toggle("Confirm before archiving", isOn: $confirmArchive)
                        .font(TronTypography.subheadline)
                } header: {
                    Text("Preferences")
                        .font(TronTypography.caption)
                } footer: {
                    Text("Show a confirmation dialog when archiving sessions.")
                        .font(TronTypography.caption2)
                }

                // Font Style Section
                if #available(iOS 26.0, *) {
                    FontStyleSection()
                }

                // Advanced Section
                Section {
                    Button(role: .destructive) {
                        showingResetAlert = true
                    } label: {
                        Label("Reset All Settings", systemImage: "arrow.counterclockwise")
                            .font(TronTypography.subheadline)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Advanced")
                        .font(TronTypography.caption)
                }

                // Footer
                Section {
                    EmptyView()
                } footer: {
                    VStack(spacing: 4) {
                        Text("v0.0.1")
                            .font(TronTypography.caption2)
                        Link(destination: URL(string: "https://github.com/yourusername/tron")!) {
                            HStack(spacing: 3) {
                                Text("GitHub")
                                    .font(TronTypography.caption2)
                                Image(systemName: "arrow.up.right")
                                    .font(TronTypography.labelSM)
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
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
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
    }

    // MARK: - Computed Properties

    var serverURL: URL? {
        let scheme = useTLS ? "wss" : "ws"
        return URL(string: "\(scheme)://\(serverHost):\(serverPort)/ws")
    }

    // MARK: - Actions

    private func resetToDefaults() {
        let defaultHost = "localhost"
        let defaultTLS = false
        serverHost = defaultHost
        serverPort = SettingsView.defaultPort
        useTLS = defaultTLS
        confirmArchive = true
        // Trigger server reconnection
        appState.updateServerSettings(host: defaultHost, port: SettingsView.defaultPort, useTLS: defaultTLS)
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

// MARK: - Font Style Section

@available(iOS 26.0, *)
struct FontStyleSection: View {
    @State private var fontSettings = FontSettings.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Preview text showing current font style
                HStack(spacing: 12) {
                    Text("Aa")
                        .font(TronTypography.mono(size: 28, weight: .medium))
                        .foregroundStyle(.tronEmerald)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recursive")
                            .font(TronTypography.headline)
                            .foregroundStyle(.tronTextPrimary)
                        Text(casualLabel)
                            .font(TronTypography.caption)
                            .foregroundStyle(.tronTextSecondary)
                            .contentTransition(.numericText())
                    }

                    Spacer()

                    // Numeric value display
                    Text(String(format: "%.2f", fontSettings.casualAxis))
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextMuted)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                // Native iOS 26 Slider with labels
                Slider(
                    value: Binding(
                        get: { fontSettings.casualAxis },
                        set: { fontSettings.casualAxis = $0 }
                    ),
                    in: 0...1
                ) {
                    Text("Font Style")
                } minimumValueLabel: {
                    Text("Linear")
                        .font(TronTypography.caption2)
                        .foregroundStyle(.tronTextMuted)
                } maximumValueLabel: {
                    Text("Casual")
                        .font(TronTypography.caption2)
                        .foregroundStyle(.tronTextMuted)
                }
                .tint(.tronEmerald)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Font Style")
                .font(TronTypography.caption)
        } footer: {
            Text("Adjust the casual axis of the Recursive font. Linear (0) is precise and geometric, Casual (1) is more playful and hand-drawn.")
                .font(TronTypography.caption2)
        }
    }

    private var casualLabel: String {
        let value = fontSettings.casualAxis
        if value < 0.2 { return "Linear" }
        if value < 0.4 { return "Semi-Linear" }
        if value < 0.6 { return "Balanced" }
        if value < 0.8 { return "Semi-Casual" }
        return "Casual"
    }
}

// MARK: - Preview

#Preview {
    SettingsView(rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!))
}
