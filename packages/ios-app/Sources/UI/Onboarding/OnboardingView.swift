import SwiftUI

/// Paged first-run sheet. The session shell remains mounted underneath, matching
/// Tron's established onboarding presentation while gateway state changes.
struct OnboardingView: View {
    enum Step: Int, CaseIterable, Hashable {
        case welcome, tailscale, mac, pair, workspace, anthropic, openAI, providers, model

        var title: String {
            switch self {
            case .welcome: "Welcome to Tron"
            case .tailscale: "Install Tailscale"
            case .mac: "Install Tron on Mac"
            case .pair: "Connect your Mac"
            case .workspace: "Default workspace"
            case .anthropic: "Anthropic"
            case .openAI: "OpenAI"
            case .providers: "Other providers"
            case .model: "Default model"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Binding var selectedDetent: PresentationDetent
    let onComplete: () -> Void
    @State private var step: Step = .welcome
    @State private var showScanner = false
    @State private var showManualPairing = false
    @State private var host = ""
    @State private var port = "9847"
    @State private var code = ""
    @State private var pairing = false
    @State private var selectedWorkspace = ""
    @State private var showWorkspace = false
    @State private var trustInspection: JSONValue?
    @State private var selectedModel: ModelRef?
    @State private var finishing = false
    @FocusState private var pairingFieldFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                TabView(selection: $step) {
                    welcomePage.tag(Step.welcome)
                    tailscalePage.tag(Step.tailscale)
                    macPage.tag(Step.mac)
                    pairingPage.tag(Step.pair)
                    if isPaired {
                        workspacePage.tag(Step.workspace)
                        preferredProviderPage(ids: ["anthropic"], name: "Anthropic").tag(Step.anthropic)
                        preferredProviderPage(ids: ["openai-codex", "openai"], name: "OpenAI").tag(Step.openAI)
                        remainingProvidersPage.tag(Step.providers)
                        modelPage.tag(Step.model)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageDots
                    .padding(.horizontal, TronSpacing.xlarge)
                    .padding(.bottom, 10)
            }
            .tronTopBlurSurface()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step != .welcome {
                        Button { goBack() } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(Color.tronEmerald)
                        }
                        .accessibilityLabel("Back")
                    }
                }
                ToolbarItem(placement: .principal) {
                    OnboardingNavigationTitle(text: step.title)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if step == .pair {
                        Button { connectManually() } label: {
                            if pairing {
                                ProgressView().controlSize(.small).tint(.tronEmerald)
                            } else {
                                Text("Connect")
                                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            }
                        }
                        .disabled(!canAttemptPairing)
                        .opacity(canAttemptPairing ? 1 : 0.45)
                        .accessibilityLabel(pairing ? "Connecting" : "Connect to Mac")
                    } else if step != .model {
                        Button { goForward() } label: {
                            Label("Next", systemImage: "chevron.right")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(Color.tronEmerald)
                        }
                        .disabled(!canAdvance || finishing)
                        .accessibilityLabel("Next")
                    }
                }
            }
        }
        .tint(.tronEmerald)
        .gatewayGlobalSheets()
        .providerAuthPresenter()
        .alert("Tron", isPresented: Binding(
            get: { model.onboardingError != nil || model.lastError != nil },
            set: { if !$0 { model.onboardingError = nil; model.lastError = nil } }
        )) {
            Button("OK") { model.onboardingError = nil; model.lastError = nil }
        } message: {
            Text(model.onboardingError ?? model.lastError ?? "")
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRCodeScanner { value in
                    guard let url = URL(string: value), let invitation = PairingInvitationParser.parse(url) else {
                        model.onboardingError = "That QR code is not a Tron Gateway invitation."
                        return
                    }
                    showScanner = false
                    Task { await pair(invitation) }
                }
                .ignoresSafeArea()
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .principal) { TronSheetTitle(title: "Scan Mac") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { showScanner = false } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(Color.tronEmerald)
                        }
                        .accessibilityLabel("Done")
                    }
                }
            }
        }
        .sheet(isPresented: $showWorkspace) {
            WorkspaceBrowser { path in
                selectedWorkspace = path
                showWorkspace = false
                Task { await inspectTrust() }
            }
        }
        .task {
            #if HOSTED_TEST
            selectedWorkspace = ProcessInfo.processInfo.environment["TRON_E2E_WORKSPACE"] ?? model.defaultWorkspace ?? ""
            #else
            selectedWorkspace = model.defaultWorkspace ?? ""
            #endif
            if isPaired && !model.setupComplete {
                step = .workspace
                if !selectedWorkspace.isEmpty { await inspectTrust() }
            } else if model.connectionState == .unauthorized {
                step = .pair
            }
            applyDetent()
        }
        .onChange(of: step) { _, value in
            applyDetent()
            if value == .model, selectedModel == nil {
                Task {
                    await model.refreshSettings()
                    selectedModel = model.configuredDefaultModel ?? model.preferredAvailableModel
                }
            }
        }
        .onChange(of: showManualPairing) { _, visible in
            withAnimation(.snappy(duration: 0.28)) { selectedDetent = visible ? .large : .medium }
        }
        .onChange(of: model.connectionState) { _, state in
            if state == .connected && !model.setupComplete && step.rawValue < Step.workspace.rawValue {
                withAnimation(.snappy(duration: 0.28)) { step = .workspace }
            }
        }
    }

    private var welcomePage: some View {
        OnboardingPage(subtitle: "Pair this iPhone with the Mac running Tron.") {
            OnboardingCard {
                OnboardingInfoRow(icon: "desktopcomputer", title: "Run Tron on Mac", subtitle: "The agent stays private to your machine")
                Divider()
                OnboardingInfoRow(icon: "network", title: "Use your private network", subtitle: "Tailscale links this iPhone to the Mac")
                Divider()
                OnboardingInfoRow(icon: "qrcode.viewfinder", title: "Scan the pairing code", subtitle: "The permanent device token is stored in Keychain")
            }
        }
    }

    private var tailscalePage: some View {
        OnboardingPage(subtitle: "Use the same Tailscale account on this iPhone and the Mac.") {
            OnboardingCard {
                OnboardingInfoRow(icon: "app.badge", title: "Install Tailscale", subtitle: "Open the App Store if it is not installed")
                Divider()
                OnboardingInfoRow(icon: "person.crop.circle", title: "Sign in", subtitle: "Use the account connected to your Mac")
                Divider()
                OnboardingInfoRow(icon: "checkmark.shield", title: "Return connected", subtitle: "Tron verifies the gateway before saving pairing")
            }
            Link(destination: URL(string: "https://tailscale.com/download")!) {
                Label("Open Tailscale in the App Store", systemImage: "app.badge")
            }
            .buttonStyle(TronActionButtonStyle())
        }
    }

    private var macPage: some View {
        OnboardingPage(subtitle: "Install Tron on the Mac, then open Show Pairing Info in the Mac app.") {
            OnboardingCard {
                OnboardingInfoRow(icon: "macbook.and.iphone", title: "Mac installer", subtitle: "The app installs and supervises the always-on Tron Gateway")
            }
            Link(destination: URL(string: "https://github.com/earendil-works/tron/releases")!) {
                Label("Open Releases page", systemImage: "safari")
            }
            .buttonStyle(TronActionButtonStyle())
        }
    }

    private var pairingPage: some View {
        OnboardingPage(subtitle: "Use the pairing screen shown by the Tron Mac app.") {
            OnboardingCard {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scan the Mac QR code")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(Color.tronTextPrimary)
                        Text("This transfers only a short-lived enrollment code.")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { showScanner = true } label: {
                        Image(systemName: "camera.viewfinder")
                    }
                    .buttonStyle(TronIconButtonStyle(size: 64))
                    .accessibilityLabel("Scan QR code")
                }
            }
            Button {
                withAnimation(.snappy(duration: 0.24)) { showManualPairing.toggle() }
            } label: {
                Text(manualPairingButtonTitle)
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(Color.tronAccentText)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            }
            if showManualPairing {
                VStack(alignment: .leading, spacing: 10) {
                    pairingField("Tailscale host", text: $host)
                    pairingField("Port", text: $port, numberPad: true)
                    PairingCodeField(text: $code)
                        .tronField(monospaced: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var workspacePage: some View {
        OnboardingPage(subtitle: "Choose the workspace Tron uses for new sessions.") {
            OnboardingCard {
                OnboardingInfoRow(icon: "folder", title: "Default workspace", subtitle: selectedWorkspace.isEmpty ? "No workspace selected" : selectedWorkspace)
            }
            Button(selectedWorkspace.isEmpty ? "Choose workspace" : "Change workspace", systemImage: "folder.badge.gearshape") { showWorkspace = true }
                .buttonStyle(TronActionButtonStyle())
            if needsTrustDecision {
                OnboardingCard {
                    Text("This project contains executable agent resources.")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    Text("Trust allows them to run with your Mac user authority. It is not a sandbox.")
                        .font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: TronSpacing.sm) { trustActions }
                        VStack(spacing: TronSpacing.sm) { trustActions }
                    }
                }
            }
        }
    }

    private func preferredProviderPage(ids: Set<String>, name: String) -> some View {
        OnboardingPage(subtitle: "Add \(name) credentials now, or skip this and add them later in Settings.") {
            if let provider = model.providers.first(where: { ids.contains($0.id) }) {
                ProviderSetupRow(provider: provider)
            } else {
                OnboardingCard {
                    OnboardingInfoRow(icon: "checkmark.circle", title: "No setup required", subtitle: "This provider is not enabled by the current Tron runtime.")
                }
            }
            Button("Refresh Providers", systemImage: "arrow.clockwise") { Task { await model.refreshProviders() } }
                .buttonStyle(TronActionButtonStyle())
        }
    }

    private var remainingProvidersPage: some View {
        OnboardingPage(subtitle: "Add optional model providers, or leave them for Settings.") {
            let remaining = model.providers.filter { !["anthropic", "openai-codex", "openai"].contains($0.id) }
            if remaining.isEmpty {
                OnboardingCard {
                    OnboardingInfoRow(icon: "checkmark.circle", title: "No additional providers", subtitle: "You can install provider extensions later in Settings.")
                }
            } else {
                ForEach(remaining) { provider in ProviderSetupRow(provider: provider) }
            }
        }
    }

    private var modelPage: some View {
        OnboardingPage(subtitle: "Choose the provider-qualified model Tron should start with.") {
            ModelPicker(selection: $selectedModel, models: model.models.filter(\.available)).frame(minHeight: 260)
            if let error = model.onboardingError {
                Text(error).font(TronTypography.bodySM).foregroundStyle(Color.tronError).fixedSize(horizontal: false, vertical: true)
            }
            TronPrimaryActionButton(
                title: finishing ? "Saving…" : "Finish setup",
                systemImage: "checkmark",
                isBusy: finishing,
                isEnabled: selectedModel != nil && !finishing
            ) { Task { await finish() } }
        }
    }

    @ViewBuilder private var trustActions: some View {
        Button("Trust Project") { Task { await setTrust(true) } }
            .buttonStyle(TronActionButtonStyle(expands: true))
        Button("Open Without Resources") { Task { await setTrust(false) } }
            .buttonStyle(TronActionButtonStyle(role: .destructive, expands: true))
    }

    private var manualPairingButtonTitle: String {
        if dynamicTypeSize.isAccessibilitySize { return "Manual Entry" }
        return showManualPairing ? "Hide Manual Entry" : "Enter Manually"
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { value in
                Capsule().fill(value.rawValue <= step.rawValue ? Color.tronEmerald : Color.tronTextMuted.opacity(0.45))
                    .frame(width: value == step ? 16 : 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.14)), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Onboarding step \(step.rawValue + 1) of \(Step.allCases.count)")
        .accessibilityRespondsToUserInteraction(false)
    }

    private var isPaired: Bool { model.connectionState == .connected || model.connectionState == .connecting || model.connectionState == .reconnecting }
    private var canAttemptPairing: Bool {
        !pairing
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var needsTrustDecision: Bool {
        guard let object = trustInspection?.objectValue else { return false }
        return object["requiresDecision"]?.boolValue == true && object["effectiveDecision"] == .null
    }
    private var canAdvance: Bool {
        switch step {
        case .welcome, .tailscale, .mac, .anthropic, .openAI, .providers: true
        case .pair: false
        case .workspace: !selectedWorkspace.isEmpty && !needsTrustDecision
        case .model: selectedModel != nil
        }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(.snappy(duration: 0.24)) { step = previous }
    }
    private func goForward() {
        guard canAdvance else { return }
        if step == .workspace {
            model.defaultWorkspace = selectedWorkspace
            UserDefaults.standard.set(selectedWorkspace, forKey: "defaultWorkspace.v1")
        }
        if step == .model { Task { await finish() }; return }
        guard let next = Step(rawValue: step.rawValue + 1), next.rawValue <= (isPaired ? Step.model.rawValue : Step.pair.rawValue) else { return }
        withAnimation(.snappy(duration: 0.24)) { step = next }
    }
    private func applyDetent() {
        withAnimation(.snappy(duration: 0.28)) { selectedDetent = step.rawValue < Step.workspace.rawValue ? .medium : .large }
    }
    private func connectManually() {
        pairingFieldFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canonical = PairingInvitationParser.canonicalHost(host),
              let value = Int(port), (1...65_535).contains(value), (8...32).contains(trimmedCode.count) else {
            model.onboardingError = "Enter a valid host, port, and one-time code."
            return
        }
        Task { await pair(PairingInvitation(host: canonical, port: value, code: trimmedCode, machineId: nil, label: nil)) }
    }
    private func pair(_ invitation: PairingInvitation) async {
        pairing = true
        defer { pairing = false }
        do {
            try await model.pair(invitation)
            if !model.setupComplete { withAnimation(.snappy(duration: 0.28)) { step = .workspace } }
        } catch { model.onboardingError = error.localizedDescription }
    }
    private func inspectTrust() async {
        guard !selectedWorkspace.isEmpty else { return }
        do { trustInspection = try await model.inspectTrust(cwd: selectedWorkspace) }
        catch { model.onboardingError = error.localizedDescription }
    }
    private func setTrust(_ decision: Bool) async {
        do { trustInspection = try await model.setTrust(cwd: selectedWorkspace, decision: decision) }
        catch { model.onboardingError = error.localizedDescription }
    }
    private func finish() async {
        guard let selectedModel else { return }
        finishing = true
        defer { finishing = false }
        do {
            model.onboardingError = nil
            try await model.updateSettings(.object(["defaultModel": .object(["provider": .string(selectedModel.provider), "id": .string(selectedModel.id)])]))
            model.setupComplete = true
            onComplete()
        } catch { model.onboardingError = error.localizedDescription }
    }
    @ViewBuilder private func pairingField(_ title: String, text: Binding<String>, numberPad: Bool = false) -> some View {
        TextField(text: text, prompt: Text(title).foregroundStyle(Color.tronTextSecondary)) { Text(title) }
            .keyboardType(numberPad ? .numberPad : .URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .tronField(monospaced: true)
            .focused($pairingFieldFocused).accessibilityLabel(title)
    }
}

private struct OnboardingNavigationTitle: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        let base = TronFontLoader.createUIFont(size: 16, weight: .semibold)
        label.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: base)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.textColor = UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? "#34D399" : "#047857")
        }
        label.accessibilityTraits.insert(.header)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.accessibilityLabel = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        return CGSize(width: min(proposal.width ?? intrinsic.width, intrinsic.width), height: intrinsic.height)
    }
}

private struct PairingCodeField: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.placeholder = "One-time code"
        field.accessibilityLabel = "One-time code"
        field.isSecureTextEntry = true
        field.textContentType = .oneTimeCode
        field.keyboardType = .asciiCapable
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        let base = TronFontLoader.createUIFont(size: TronTypography.sizeBody, weight: .regular, mono: true)
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        field.adjustsFontForContentSizeCategory = true
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text { field.text = text }
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding private var text: String
        init(text: Binding<String>) { _text = text }
        @objc func changed(_ sender: UITextField) { text = sender.text ?? "" }
    }
}

private struct OnboardingPage<Content: View>: View {
    let subtitle: String
    @ViewBuilder let content: Content
    init(subtitle: String, @ViewBuilder content: () -> Content) { self.subtitle = subtitle; self.content = content() }
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                Text(subtitle)
                    .font(TronTypography.body)
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 126)
            .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
        }
        .tronScrollEdgeChrome()
        .scrollDismissesKeyboard(.interactively)
    }
}

struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.12)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.tronEmerald.opacity(0.22), lineWidth: 1))
    }
}

private struct OnboardingInfoRow: View {
    let icon, title, subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold)).foregroundStyle(Color.tronEmerald).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold)).foregroundStyle(Color.tronTextPrimary).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
