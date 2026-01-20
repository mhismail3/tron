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
                        .font(TronTypography.subheadline)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    TextField("Port", text: $serverPort)
                        .font(TronTypography.subheadline)
                        .keyboardType(.numberPad)

                    Toggle("Use TLS (wss://)", isOn: $useTLS)
                        .font(TronTypography.subheadline)
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

// MARK: - Font Style Section

@available(iOS 26.0, *)
struct FontStyleSection: View {
    @State private var fontSettings = FontSettings.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
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
                    }

                    Spacer()
                }
                .padding(.vertical, 4)

                // Liquid glass slider
                VStack(spacing: 8) {
                    HStack {
                        Text("Linear")
                            .font(TronTypography.caption2)
                            .foregroundStyle(.tronTextMuted)
                        Spacer()
                        Text("Casual")
                            .font(TronTypography.caption2)
                            .foregroundStyle(.tronTextMuted)
                    }

                    // Custom slider with glass effect
                    FontStyleSlider(value: Binding(
                        get: { fontSettings.casualAxis },
                        set: { fontSettings.casualAxis = $0 }
                    ))
                }
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
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

// MARK: - Font Style Slider (Liquid Glass)

@available(iOS 26.0, *)
struct FontStyleSlider: View {
    @Binding var value: Double
    @State private var isDragging = false

    private let trackHeight: CGFloat = 8
    private let thumbSize: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let thumbX = CGFloat(value) * (trackWidth - thumbSize) + thumbSize / 2

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: trackHeight)
                    .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.2)), in: .capsule)

                // Filled portion
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.tronPhthaloGreen, .tronEmerald],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(thumbX, 0), height: trackHeight)

                // Thumb
                Circle()
                    .fill(.clear)
                    .frame(width: thumbSize, height: thumbSize)
                    .glassEffect(
                        .regular.tint(Color.tronEmerald.opacity(isDragging ? 0.6 : 0.4)),
                        in: .circle
                    )
                    .overlay {
                        Circle()
                            .stroke(Color.tronEmerald.opacity(0.8), lineWidth: 2)
                    }
                    .scaleEffect(isDragging ? 1.15 : 1.0)
                    .position(x: thumbX, y: geometry.size.height / 2)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let newValue = (gesture.location.x - thumbSize / 2) / (trackWidth - thumbSize)
                        value = min(max(Double(newValue), 0), 1)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: thumbSize)
    }
}

// MARK: - Preview

#Preview {
    SettingsView(rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!))
}
