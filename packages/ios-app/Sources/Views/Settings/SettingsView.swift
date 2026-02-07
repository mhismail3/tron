import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    #if BETA
    private static let defaultPort = "8082"
    #else
    private static let defaultPort = "8080"
    #endif

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies
    @AppStorage("serverHost") private var serverHost = "localhost"

    // Convenience accessors
    private var rpcClient: RPCClient { dependencies!.rpcClient }
    private var eventStoreManager: EventStoreManager { dependencies!.eventStoreManager }
    private var defaultModelValue: String { dependencies!.defaultModel }
    private var defaultModelBinding: Binding<String> {
        Binding(
            get: { dependencies?.defaultModel ?? "" },
            set: { dependencies?.defaultModel = $0 }
        )
    }
    @AppStorage("serverPort") private var serverPort = ""
    @AppStorage("confirmArchive") private var confirmArchive = true

    @State private var showingResetAlert = false
    @State private var showLogViewer = false
    @State private var showArchiveAllConfirmation = false
    @State private var isArchivingAll = false

    // Server-authoritative settings (loaded via RPC)
    @State private var quickSessionWorkspace = "/Users/moose/Workspace"
    @State private var preserveRecentTurns: Int = 5
    @State private var forceAlwaysCompact: Bool = false
    @State private var triggerTokenThreshold: Double = 0.70
    @State private var defaultTurnFallback: Int = 8
    @State private var webFetchTimeoutMs: Int = 30000
    @State private var webCacheTtlMs: Int = 900000
    @State private var webCacheMaxEntries: Int = 100
    @State private var settingsLoaded = false
    @State private var showQuickSessionWorkspaceSelector = false
    @State private var showModelPicker = false
    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = false

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

    /// Quick session workspace formatted for display (truncates /Users/<user>/ to ~/)
    private var displayQuickSessionWorkspace: String {
        quickSessionWorkspace.replacingOccurrences(
            of: "^/Users/[^/]+/",
            with: "~/",
            options: .regularExpression
        )
    }

    /// Selected model display name
    private var selectedModelDisplayName: String {
        if let model = availableModels.first(where: { $0.id == defaultModelValue }) {
            return model.formattedModelName
        }
        return defaultModelValue.shortModelName
    }

    // MARK: - Fetch Timeout Options

    private static let fetchTimeoutOptions: [(label: String, value: Int)] = [
        ("15s", 15000),
        ("30s", 30000),
        ("60s", 60000),
        ("2min", 120000),
    ]

    // MARK: - Cache Duration Options

    private static let cacheTtlOptions: [(label: String, value: Int)] = [
        ("5min", 300000),
        ("15min", 900000),
        ("30min", 1800000),
        ("1hr", 3600000),
    ]

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
                        .onSubmit {
                            dependencies?.updateServerSettings(host: serverHost, port: effectivePort, useTLS: false)
                        }

                    HStack {
                        TextField("Custom Port", text: $serverPort)
                            .font(TronTypography.subheadline)
                            .keyboardType(.numberPad)
                            .onChange(of: serverPort) { _, newValue in
                                if !newValue.isEmpty {
                                    dependencies?.updateServerSettings(host: serverHost, port: newValue, useTLS: false)
                                }
                            }

                        Picker("", selection: Binding(
                            get: { selectedEnvironment },
                            set: { newValue in
                                let newPort: String
                                switch newValue {
                                case "beta": newPort = "8082"
                                case "prod": newPort = "8080"
                                default: return
                                }
                                serverPort = ""
                                dependencies?.updateServerSettings(host: serverHost, port: newPort, useTLS: false)
                            }
                        )) {
                            Text("Beta").tag("beta")
                            Text("Prod").tag("prod")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 120)
                    }
                } header: {
                    Text("Server")
                        .font(TronTypography.caption)
                } footer: {
                    Text("Default ports: Beta (8082), Prod (8080).")
                        .font(TronTypography.caption2)
                }
                .listSectionSpacing(16)

                // Quick Session Section (for long-press quick create)
                if #available(iOS 26.0, *) {
                    Section {
                        // Workspace Path
                        HStack {
                            Label("Workspace", systemImage: "folder")
                                .font(TronTypography.subheadline)
                            Spacer()
                            Text(displayQuickSessionWorkspace)
                                .font(TronTypography.codeSM)
                                .foregroundStyle(.tronTextSecondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showQuickSessionWorkspaceSelector = true
                        }

                        // Default Model Picker
                        HStack {
                            Label("Model", systemImage: "cpu")
                                .font(TronTypography.subheadline)
                            Spacer()
                            Text(selectedModelDisplayName)
                                .font(TronTypography.codeSM)
                                .foregroundStyle(.tronTextSecondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showModelPicker = true
                        }
                    } header: {
                        Text("Quick Session")
                            .font(TronTypography.caption)
                    } footer: {
                        Text("Long-press the + button to instantly start a session with these defaults.")
                            .font(TronTypography.caption2)
                    }
                    .listSectionSpacing(16)
                }

                // Compaction Section
                compactionSection

                // Web Section
                webSection

                // Font Style Section
                if #available(iOS 26.0, *) {
                    FontStyleSection()
                }

                // Data Section
                Section {
                    Toggle(isOn: $confirmArchive) {
                        Label("Confirm before archiving", systemImage: "questionmark.circle")
                            .font(TronTypography.subheadline)
                    }

                    Button(role: .destructive) {
                        showArchiveAllConfirmation = true
                    } label: {
                        HStack {
                            Label("Archive All Sessions", systemImage: "archivebox")
                                .font(TronTypography.subheadline)
                                .foregroundStyle(.red)
                            Spacer()
                            if isArchivingAll {
                                ProgressView()
                                    .tint(.red)
                            }
                        }
                    }
                    .disabled(eventStoreManager.sessions.isEmpty || isArchivingAll)
                } header: {
                    Text("Data")
                        .font(TronTypography.caption)
                } footer: {
                    Text("Removes all sessions from your device. Session data on the server will remain.")
                        .font(TronTypography.caption2)
                }
                .listSectionSpacing(16)

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
            .sheet(isPresented: $showQuickSessionWorkspaceSelector) {
                WorkspaceSelector(
                    rpcClient: rpcClient,
                    selectedPath: Binding(
                        get: { quickSessionWorkspace },
                        set: { newValue in
                            quickSessionWorkspace = newValue
                            dependencies?.quickSessionWorkspace = newValue
                            updateServerSetting {
                                ServerSettingsUpdate(server: .init(defaultWorkspace: newValue))
                            }
                        }
                    )
                )
            }
            .sheet(isPresented: $showModelPicker) {
                if #available(iOS 26.0, *) {
                    ModelPickerSheet(
                        models: availableModels,
                        currentModelId: defaultModelValue,
                        onSelect: { model in
                            defaultModelBinding.wrappedValue = model.id
                            updateServerSetting {
                                ServerSettingsUpdate(server: .init(defaultModel: model.id))
                            }
                        }
                    )
                }
            }
            .task {
                await loadSettings()
                await loadModels()
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
            .alert("Archive All Sessions?", isPresented: $showArchiveAllConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Archive All", role: .destructive) {
                    archiveAllSessions()
                }
            } message: {
                Text("This will remove \(eventStoreManager.sessions.count) session\(eventStoreManager.sessions.count == 1 ? "" : "s") from your device. Session data on the server will remain.")
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .preferredColorScheme(.dark)
    }

    // MARK: - Compaction Section

    @ViewBuilder
    private var compactionSection: some View {
        // Compaction Threshold slider (50%–95%, step 5%)
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Compaction Threshold", systemImage: "gauge.with.dots.needle.67percent")
                        .font(TronTypography.subheadline)
                    Spacer()
                    Text("\(Int(triggerTokenThreshold * 100))%")
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                }
                Slider(
                    value: $triggerTokenThreshold,
                    in: 0.50...0.95,
                    step: 0.05
                )
                .tint(.tronEmerald)
            }
            .onChange(of: triggerTokenThreshold) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(
                        triggerTokenThreshold: newValue
                    )))
                }
            }
        } header: {
            Text("Compaction")
                .font(TronTypography.caption)
        } footer: {
            Text("Context usage % that triggers compaction. Lower values compact sooner, preserving more headroom.")
                .font(TronTypography.caption2)
        }

        // Max Turns stepper (3–20)
        Section {
            HStack {
                Label("Max Turns", systemImage: "repeat")
                    .font(TronTypography.subheadline)
                Spacer()
                Text("\(defaultTurnFallback)")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .frame(minWidth: 20)
                Stepper("", value: $defaultTurnFallback, in: 3...20)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
            }
            .onChange(of: defaultTurnFallback) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(
                        defaultTurnFallback: newValue
                    )))
                }
            }
        } footer: {
            Text("Maximum turns between compactions, even if the threshold hasn't been reached.")
                .font(TronTypography.caption2)
        }

        // Keep Recent Turns stepper (0–10)
        Section {
            HStack {
                Label("Keep Recent Turns", systemImage: "arrow.counterclockwise.circle")
                    .font(TronTypography.subheadline)
                Spacer()
                Text("\(preserveRecentTurns)")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .frame(minWidth: 20)
                Stepper("", value: $preserveRecentTurns, in: 0...10)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
            }
            .onChange(of: preserveRecentTurns) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(preserveRecentCount: newValue)))
                }
            }
        } footer: {
            Text("Number of recent turns kept verbatim after compaction. The rest is summarized.")
                .font(TronTypography.caption2)
        }

        // Compact Every Cycle toggle (debug — stays last)
        Section {
            Toggle(isOn: $forceAlwaysCompact) {
                Label("Compact Every Cycle", systemImage: "arrow.triangle.2.circlepath")
                    .font(TronTypography.subheadline)
            }
            .onChange(of: forceAlwaysCompact) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(forceAlways: newValue)))
                }
            }
        } footer: {
            Text("Force compaction after every response. Useful for testing compaction behavior.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }

    // MARK: - Web Section

    @ViewBuilder
    private var webSection: some View {
        // Fetch Timeout picker
        Section {
            Picker(selection: $webFetchTimeoutMs) {
                ForEach(Self.fetchTimeoutOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            } label: {
                Label("Fetch Timeout", systemImage: "clock")
                    .font(TronTypography.subheadline)
            }
            .onChange(of: webFetchTimeoutMs) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(tools: .init(web: .init(fetch: .init(timeoutMs: newValue))))
                }
            }
        } header: {
            Text("Web")
                .font(TronTypography.caption)
        } footer: {
            Text("How long to wait for a page to respond before giving up.")
                .font(TronTypography.caption2)
        }

        // Cache Duration picker
        Section {
            Picker(selection: $webCacheTtlMs) {
                ForEach(Self.cacheTtlOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            } label: {
                Label("Cache Duration", systemImage: "timer")
                    .font(TronTypography.subheadline)
            }
            .onChange(of: webCacheTtlMs) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(tools: .init(web: .init(cache: .init(ttlMs: newValue))))
                }
            }
        } footer: {
            Text("How long fetched pages are cached before being re-fetched.")
                .font(TronTypography.caption2)
        }

        // Max Cached Pages stepper (25–500, step 25)
        Section {
            HStack {
                Label("Max Cached Pages", systemImage: "doc.on.doc")
                    .font(TronTypography.subheadline)
                Spacer()
                Text("\(webCacheMaxEntries)")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .frame(minWidth: 30)
                Stepper("", value: $webCacheMaxEntries, in: 25...500, step: 25)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
            }
            .onChange(of: webCacheMaxEntries) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(tools: .init(web: .init(cache: .init(maxEntries: newValue))))
                }
            }
        } footer: {
            Text("Maximum number of pages kept in cache. Oldest entries are evicted first.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
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
        preserveRecentTurns = 5
        forceAlwaysCompact = false
        triggerTokenThreshold = 0.70
        defaultTurnFallback = 8
        webFetchTimeoutMs = 30000
        webCacheTtlMs = 900000
        webCacheMaxEntries = 100
        quickSessionWorkspace = "/Users/moose/Workspace"
        // Reset server-side settings
        updateServerSetting {
            ServerSettingsUpdate(
                server: .init(defaultWorkspace: "/Users/moose/Workspace"),
                context: .init(compactor: .init(
                    preserveRecentCount: 5,
                    forceAlways: false,
                    triggerTokenThreshold: 0.70,
                    defaultTurnFallback: 8
                )),
                tools: .init(web: .init(
                    fetch: .init(timeoutMs: 30000),
                    cache: .init(ttlMs: 900000, maxEntries: 100)
                ))
            )
        }
        // Trigger server reconnection with Beta port
        dependencies?.updateServerSettings(host: "localhost", port: "8082", useTLS: false)
    }

    private func archiveAllSessions() {
        isArchivingAll = true
        Task {
            await eventStoreManager.archiveAllSessions()
            isArchivingAll = false
        }
    }

    private func loadSettings() async {
        guard !settingsLoaded else { return }
        do {
            let settings = try await rpcClient.settings.get()
            preserveRecentTurns = settings.compaction.preserveRecentTurns
            forceAlwaysCompact = settings.compaction.forceAlways
            triggerTokenThreshold = settings.compaction.triggerTokenThreshold
            defaultTurnFallback = settings.compaction.defaultTurnFallback
            webFetchTimeoutMs = settings.tools.web.fetch.timeoutMs
            webCacheTtlMs = settings.tools.web.cache.ttlMs
            webCacheMaxEntries = settings.tools.web.cache.maxEntries
            if let workspace = settings.defaultWorkspace {
                quickSessionWorkspace = workspace
            }
            settingsLoaded = true
        } catch {
            // Use local defaults on failure — server may be unreachable
        }
    }

    private func updateServerSetting(_ build: () -> ServerSettingsUpdate) {
        let update = build()
        Task {
            try? await rpcClient.settings.update(update)
        }
    }

    private func loadModels() async {
        isLoadingModels = true
        do {
            availableModels = try await rpcClient.model.list()
        } catch {
            // Silently fail - user can still type model ID manually if needed
        }
        isLoadingModels = false
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
                Spacer()
                    .frame(height: 2)
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
        .listSectionSpacing(16)
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
    SettingsView()
        .environment(\.dependencies, DependencyContainer())
}
