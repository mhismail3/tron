import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    #if BETA
    private static let defaultPort = "8082"
    #else
    private static let defaultPort = "8080"
    #endif

    @Environment(\.dismiss) private var dismiss
    let rpcClient: RPCClient
    @AppStorage("serverHost") private var serverHost = "localhost"
    @AppStorage("serverPort") private var serverPort = SettingsView.defaultPort
    @AppStorage("useTLS") private var useTLS = false
    @AppStorage("confirmArchive") private var confirmArchive = true

    @State private var showingResetAlert = false
    @State private var showLogViewer = false

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
                    Text("Connect to your Tron server. Default is localhost:\(SettingsView.defaultPort).")
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

                // Advanced Section
                Section {
                    Button(role: .destructive) {
                        showingResetAlert = true
                    } label: {
                        Label("Reset All Settings", systemImage: "arrow.counterclockwise")
                            .font(.subheadline)
                            .foregroundStyle(.red)
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
    }

    // MARK: - Computed Properties

    var serverURL: URL? {
        let scheme = useTLS ? "wss" : "ws"
        return URL(string: "\(scheme)://\(serverHost):\(serverPort)/ws")
    }

    // MARK: - Actions

    private func resetToDefaults() {
        serverHost = "localhost"
        serverPort = SettingsView.defaultPort
        useTLS = false
        confirmArchive = true
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
