import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serverHost") private var serverHost = "localhost"
    @AppStorage("serverPort") private var serverPort = "8080"
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

                // Debug Section
                Section {
                    Button {
                        showLogViewer = true
                    } label: {
                        HStack {
                            Label("View Logs", systemImage: "doc.text.magnifyingglass")
                                .font(.subheadline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text("Debug")
                        .font(.caption)
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
            .background(Color.tronSurface)
            .environment(\.defaultMinListRowHeight, 40)
            .sheet(isPresented: $showLogViewer) {
                LogViewer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tronEmerald)
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
        serverPort = "8080"
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
    SettingsView()
}
