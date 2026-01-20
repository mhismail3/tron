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
            case "8080": return "prod"
            case "8082": return "beta"
            default: return "custom"
            }
        }
        // Empty port defaults based on build config
        #if BETA
        return "beta"
        #else
        return "prod"
        #endif
    }

    /// Effective port to use for connections
    private var effectivePort: String {
        if !serverPort.isEmpty {
            return serverPort
        }
        // Default based on build
        #if BETA
        return "8082"
        #else
        return "8080"
        #endif
    }

    var body: some View {
        NavigationStack {
            List {
                // Environment Toggle (no section container)
                Section {
                    HStack(spacing: 0) {
                        environmentButton("Prod", tag: "prod")
                        environmentButton("Beta", tag: "beta")
                    }
                    .padding(3)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } header: {
                    EmptyView()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

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

    // MARK: - Environment Button

    @ViewBuilder
    private func environmentButton(_ title: String, tag: String) -> some View {
        let isSelected = selectedEnvironment == tag

        Button {
            let newPort: String
            switch tag {
            case "prod": newPort = "8080"
            case "beta": newPort = "8082"
            default: return
            }
            // Clear custom port when selecting standard environment
            serverPort = ""
            // Update via AppState to trigger reconnection
            appState.updateServerSettings(host: serverHost, port: newPort, useTLS: false)
        } label: {
            Text(title)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .tronEmerald : .white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color.tronEmerald.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Computed Properties

    var serverURL: URL? {
        URL(string: "ws://\(serverHost):\(effectivePort)/ws")
    }

    // MARK: - Actions

    private func resetToDefaults() {
        serverHost = "localhost"
        serverPort = ""  // Empty = use default based on build
        confirmArchive = true
        // Trigger server reconnection with default port
        appState.updateServerSettings(host: "localhost", port: SettingsView.defaultPort, useTLS: false)
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
