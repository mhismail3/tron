import SwiftUI

enum ProviderConfigurationPresentation {
    static func isLoginMethod(_ method: String) -> Bool {
        let normalized = method.lowercased().replacingOccurrences(of: "_", with: "-")
        return normalized.contains("oauth") || normalized.contains("login") || normalized.contains("device-code")
    }

    static func actionTitle(method: String, configured: Bool) -> String {
        if isLoginMethod(method) {
            return configured ? "Log In with a Different Account" : "Log In"
        }
        return configured ? "Enter a New API Key" : "Enter API Key"
    }

    static func actionDetail(method: String, configured: Bool) -> String {
        if isLoginMethod(method) {
            return configured
                ? "Replace the current login with another provider account."
                : "Continue with the provider's account login flow."
        }
        return configured
            ? "Store a replacement credential on the paired Mac."
            : "Store the credential on the paired Mac."
    }

    static func automaticallyBegunMethod(for provider: ProviderSummary) -> String? {
        guard !provider.configured,
              provider.authMethods.count == 1,
              let method = provider.authMethods.first else { return nil }
        let normalized = method.lowercased().replacingOccurrences(of: "_", with: "-")
        guard normalized == "oauth" || normalized == "api-key" else { return nil }
        return method
    }

    static func clearTitle(for provider: ProviderSummary) -> String {
        let authority = [provider.authSource, provider.credentialType]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return isLoginMethod(authority) ? "Clear Login Information" : "Clear API Key"
    }

    static func connectionDetail(for provider: ProviderSummary) -> String {
        guard provider.configured else { return "Not configured" }
        return "Connected - \(credentialLabel(for: provider))"
    }

    static func configurationDetail(for provider: ProviderSummary) -> String {
        guard provider.configured else { return "Choose a connection method below." }
        let label = credentialLabel(for: provider)
        return label == "stored credential" ? "Stored credential" : label
    }

    private static func credentialLabel(for provider: ProviderSummary) -> String {
        let source = provider.authSource?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = source?.lowercased().replacingOccurrences(of: "_", with: " ")
        switch normalized {
        case "oauth": return "OAuth"
        case "stored credential", "stored cred", "api key", "credential": return "stored credential"
        default: return (source?.isEmpty == false ? source : nil) ?? "stored credential"
        }
    }
}

struct ProviderSetupRow: View {
    let provider: ProviderSummary
    var sessionID: String? = nil
    @State private var showsConfiguration = false
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var providerTarget: ProviderCatalogTarget {
        sessionID.map(ProviderCatalogTarget.session(id:)) ?? .global
    }

    var body: some View {
        let rowAccent = settingsTheme?.accent
            ?? (provider.configured ? Color.tronEmerald : Color.tronTextSecondary)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: provider.configured ? "checkmark.seal.fill" : "key")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(rowAccent)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(1)
                Text(ProviderConfigurationPresentation.connectionDetail(for: provider))
                    .font(TronTypography.secondaryCodeDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button { showsConfiguration = true } label: {
                Text(provider.configured ? "Configure" : "Connect")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .tronSettingsButtonForeground(settingsTheme?.accent ?? .tronEmerald)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44, alignment: .center)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(provider.configured ? "Configure" : "Connect") \(provider.displayName)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .tronScrollSurface(
            accent: .tronEmerald,
            cornerRadius: 12,
            tintOpacity: provider.configured ? 0.14 : 0.08
        )
        .tronManagedSheet(
            isPresented: $showsConfiguration,
            identity: "onboarding.provider.\(provider.id)"
        ) {
            ProviderConfigurationSheet(provider: provider, target: providerTarget)
        }
    }
}

private struct ProviderConfigurationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    let provider: ProviderSummary
    let target: ProviderCatalogTarget
    @State private var activeOperationID: String?
    @State private var owningProfileID: String?
    @State private var beginningMethod: String?
    @State private var attemptedAutomaticBegin = false
    @State private var clearing = false

    private var currentOperationID: String? {
        model.authPrompt?.operationId ?? model.authEvent?.operationId
    }

    private var isPresentingOwnedAuth: Bool {
        activeOperationID != nil && currentOperationID == activeOperationID
    }

    private var automaticMethod: String? {
        ProviderConfigurationPresentation.automaticallyBegunMethod(for: provider)
    }

    private var isAutomaticallyBeginning: Bool {
        automaticMethod != nil && (!attemptedAutomaticBegin || beginningMethod != nil)
    }

    private var presentationPhase: String {
        if isPresentingOwnedAuth {
            return "auth:\(currentOperationID ?? ""):\(model.authEvent?.kind.rawValue ?? ""):\(model.authPrompt?.id ?? "")"
        }
        return isAutomaticallyBeginning ? "automatic-begin" : "configuration"
    }

    private var revealTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    private var revealAnimation: Animation {
        reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.24)
    }

    var body: some View {
        NavigationStack {
            configurationContent
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: provider.displayName, accent: .tronEmerald)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { close() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(settingsTheme?.accent ?? .tronEmerald)
                    }
                    .disabled(beginningMethod != nil || clearing)
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronPresentation()
        .tronScreenBackground()
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isPresentingOwnedAuth || beginningMethod != nil)
        .onAppear {
            if owningProfileID == nil { owningProfileID = model.profiles.selected?.id }
            beginAutomaticallyIfNeeded()
        }
        .onChange(of: model.profiles.selected?.id) { _, selectedProfileID in
            guard let owningProfileID, selectedProfileID != owningProfileID else { return }
            close()
        }
        .onChange(of: currentOperationID) { previous, current in
            if let previous, previous == activeOperationID, current == nil {
                activeOperationID = nil
                dismiss()
            } else if activeOperationID == nil, beginningMethod != nil, let current {
                activeOperationID = current
            }
        }
        .onDisappear {
            guard let operationID = activeOperationID else { return }
            activeOperationID = nil
            Task { await model.cancelAuth(operationID: operationID) }
        }
    }

    private var configurationContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                TronGlassCard(accent: provider.configured ? .tronEmerald : .tronSlate) {
                    TronSettingsRow(
                        icon: provider.configured ? "checkmark.seal.fill" : "key",
                        title: provider.configured ? "Connected" : "Not Configured",
                        subtitle: ProviderConfigurationPresentation.configurationDetail(for: provider),
                        subtitleRole: .dynamicValue,
                        accent: provider.configured ? .tronEmerald : .tronSlate
                    )
                }

                if isPresentingOwnedAuth {
                    ProviderAuthFlowContent()
                        .transition(revealTransition)
                } else if isAutomaticallyBeginning {
                    TronLoadingState(label: "Loading login options…", accent: .tronEmerald)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(revealTransition)
                } else {
                    connectionControls
                        .transition(revealTransition)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .animation(revealAnimation, value: presentationPhase)
        }
        .tronScrollEdgeChrome()
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var connectionControls: some View {
        if provider.authMethods.isEmpty {
            TronInfoCard(
                icon: "exclamationmark.triangle",
                text: "This provider does not advertise a supported connection method.",
                accent: .tronAmber,
                usesSemanticAccent: true
            )
        } else {
            TronSettingsGroup("Connection Options", accent: .tronEmerald) {
                VStack(spacing: 0) {
                    ForEach(Array(provider.authMethods.enumerated()), id: \.offset) { index, method in
                        if index > 0 { TronSettingsDivider(accent: .tronEmerald) }
                        Button { begin(method) } label: {
                            HStack(spacing: 0) {
                                TronSettingsRow(
                                    icon: ProviderConfigurationPresentation.isLoginMethod(method) ? "person.crop.circle.badge.checkmark" : "key.fill",
                                    title: ProviderConfigurationPresentation.actionTitle(
                                        method: method,
                                        configured: provider.configured
                                    ),
                                    subtitle: ProviderConfigurationPresentation.actionDetail(
                                        method: method,
                                        configured: provider.configured
                                    ),
                                    accent: .tronEmerald
                                )
                                if beginningMethod == method {
                                    TronPulseLoadingIndicator(size: 18)
                                        .padding(.trailing, 14)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(beginningMethod != nil || clearing)
                    }
                }
            }
        }

        if provider.configured {
            TronPrimaryActionButton(
                title: clearing ? "Clearing…" : ProviderConfigurationPresentation.clearTitle(for: provider),
                systemImage: "trash",
                isBusy: clearing,
                isEnabled: beginningMethod == nil && !clearing,
                role: .destructive
            ) { clearCredentials() }
        }
    }

    private func beginAutomaticallyIfNeeded() {
        guard !attemptedAutomaticBegin, let automaticMethod else { return }
        attemptedAutomaticBegin = true
        if let currentOperationID {
            activeOperationID = currentOperationID
            return
        }
        begin(automaticMethod)
    }

    private func begin(_ method: String) {
        guard beginningMethod == nil, !clearing else { return }
        beginningMethod = method
        Task {
            defer { beginningMethod = nil }
            do {
                try await model.beginAuth(providerID: provider.id, authType: method, target: target)
                if let operationID = currentOperationID {
                    activeOperationID = operationID
                } else {
                    dismiss()
                }
            } catch is CancellationError { }
            catch { model.presentError(error) }
        }
    }

    private func clearCredentials() {
        guard !clearing, beginningMethod == nil else { return }
        clearing = true
        Task {
            defer { clearing = false }
            do {
                try await model.logout(providerID: provider.id, target: target)
                dismiss()
            } catch is CancellationError { }
            catch { model.presentError(error) }
        }
    }

    private func close() {
        let operationID = activeOperationID ?? currentOperationID
        activeOperationID = nil
        dismiss()
        guard let operationID else { return }
        Task { await model.cancelAuth(operationID: operationID) }
    }
}

struct ModelPicker: View {
    @Binding var selection: ModelRef?
    let models: [ModelSummary]
    @State private var search = ""
    @State private var showingSearch = false
    @State private var closingSearch = false
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 8) {
                ForEach(filtered, id: \.ref) { model in
                    Button { selection = model.ref } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selection == model.ref ? "checkmark.circle.fill" : "cpu")
                                .foregroundStyle(
                                    settingsTheme?.accent
                                        ?? (selection == model.ref ? Color.tronEmerald : Color.tronSlate)
                                )
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName)
                                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                    .foregroundStyle(Color.tronTextPrimary)
                                Text(model.displayDescription)
                                    .font(TronTypography.secondaryDescription)
                                    .foregroundStyle(Color.tronTextPrimary)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tronScrollSurface(
                        accent: selection == model.ref ? .tronEmerald : .tronSlate,
                        cornerRadius: 14,
                        tintOpacity: selection == model.ref ? 0.18 : 0.08
                    )
                    .accessibilityLabel(model.displayName)
                    .accessibilityValue(selection == model.ref ? "Selected" : "")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 72)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if showingSearch {
                    TronSearchBar(
                        text: $search,
                        prompt: "Search models",
                        focusOnAppear: true,
                        onClose: closeSearch
                    )
                } else {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { showingSearch = true }
                    } label: {
                        Label("Search models", systemImage: "magnifyingglass")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .tronSettingsButtonForeground(settingsTheme?.accent ?? .tronEmerald)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, TronSpacing.inputHorizontal)
                            .contentShape(Capsule())
                            .glassEffect(
                                .regular.tint((settingsTheme?.accent ?? .tronEmerald).opacity(0.16)).interactive(),
                                in: .capsule
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search models")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.clear)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .interactiveDismissDisabled(showingSearch)
        .task(id: closingSearch) {
            guard closingSearch else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.18)) {
                showingSearch = false
                closingSearch = false
            }
        }
    }

    private func closeSearch() {
        guard showingSearch, !closingSearch else { return }
        search = ""
        closingSearch = true
    }

    private var filtered: [ModelSummary] {
        search.isEmpty ? models : models.filter { "\($0.provider) \($0.id) \($0.name)".localizedCaseInsensitiveContains(search) }
    }
}
