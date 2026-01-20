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
    @AppStorage("serverPort") private var serverPort = ""
    @AppStorage("confirmArchive") private var confirmArchive = true

    @State private var showingResetAlert = false
    @State private var showLogViewer = false

    /// Derives environment selection from current port (or custom port override)
    private var selectedEnvironment: String {
        // If custom port is set, check if it matches standard ports
        if !serverPort.isEmpty {
            switch serverPort {
            case "8082": return "beta"
            case "8080": return "prod"
            default: return "custom"
            }
        }
        // Empty port defaults to Beta
        return "beta"
    }

    /// Effective port to use for connections
    private var effectivePort: String {
        if !serverPort.isEmpty {
            return serverPort
        }
        // Default to Beta (8082)
        return "8082"
    }

    var body: some View {
        NavigationStack {
            List {
                // Environment Toggle (native iOS 26 segmented picker)
                Section {
                    Picker("Environment", selection: Binding(
                        get: { selectedEnvironment },
                        set: { newValue in
                            let newPort: String
                            switch newValue {
                            case "beta": newPort = "8082"
                            case "prod": newPort = "8080"
                            default: return
                            }
                            serverPort = ""  // Clear custom port
                            appState.updateServerSettings(host: serverHost, port: newPort, useTLS: false)
                        }
                    )) {
                        Text("Beta")
                            .tag("beta")
                        Text("Prod")
                            .tag("prod")
                    }
                    .pickerStyle(.segmented)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                } header: {
                    Text("Environment")
                        .font(TronTypography.caption)
                }
                .listRowBackground(Color.clear)
                .listSectionSpacing(8)

                // Server Section
                Section {
                    TextField("Host", text: $serverHost)
                        .font(TronTypography.subheadline)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onSubmit {
                            appState.updateServerSettings(host: serverHost, port: effectivePort, useTLS: false)
                        }

                    TextField("Custom Port (optional)", text: $serverPort)
                        .font(TronTypography.subheadline)
                        .keyboardType(.numberPad)
                        .onChange(of: serverPort) { _, newValue in
                            // Only trigger update if port actually changed to something meaningful
                            if !newValue.isEmpty {
                                appState.updateServerSettings(host: serverHost, port: newValue, useTLS: false)
                            }
                        }
                } header: {
                    Text("Server")
                        .font(TronTypography.caption)
                } footer: {
                    Text("Default ports: Prod (8080), Beta (8082). Only set custom port if using a non-standard port.")
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
        URL(string: "ws://\(serverHost):\(effectivePort)/ws")
    }

    // MARK: - Actions

    private func resetToDefaults() {
        serverHost = "localhost"
        serverPort = ""  // Empty = use Beta (8082) as default
        confirmArchive = true
        // Trigger server reconnection with Beta port
        appState.updateServerSettings(host: "localhost", port: "8082", useTLS: false)
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
