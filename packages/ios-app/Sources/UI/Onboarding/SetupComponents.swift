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

    static func disablesInteractiveDismissal(beginningMethod: String?, clearing: Bool) -> Bool {
        beginningMethod != nil || clearing
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

enum ProviderSetupRowSurfaceStyle {
    case standalone
    case grouped
}

struct ProviderSetupRow: View {
    var surfaceStyle: ProviderSetupRowSurfaceStyle = .standalone
    let provider: ProviderSummary
    var sessionID: String? = nil
    var usageSnapshot: ProviderUsageSnapshot? = nil
    /// True while the bounded usage read is still pending for a supported row.
    var isUsageLoading: Bool = false
    @State private var showsConfiguration = false
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var providerTarget: ProviderCatalogTarget {
        sessionID.map(ProviderCatalogTarget.session(id:)) ?? .global
    }

    var body: some View {
        surfacedRow
        .tronManagedSheet(
            isPresented: $showsConfiguration,
            identity: "onboarding.provider.\(provider.id)"
        ) {
            ProviderConfigurationSheet(
                provider: provider,
                target: providerTarget
            )
        }
    }

    @ViewBuilder
    private var surfacedRow: some View {
        if surfaceStyle == .standalone {
            row
                .tronScrollSurface(
                    accent: .tronEmerald,
                    cornerRadius: 12,
                    tintOpacity: provider.configured ? 0.14 : 0.08
                )
        } else {
            row
        }
    }

    private var row: some View {
        Group {
            if provider.configured {
                Button { showsConfiguration = true } label: {
                    rowContents {
                        detailsPill
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(provider.displayName)")
                .accessibilityValue(usageAccessibilityValue)
            } else {
                rowContents {
                    Button { showsConfiguration = true } label: {
                        TronInlineActionLabel("Connect", accent: settingsTheme?.accent ?? .tronEmerald)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Connect \(provider.displayName)")
                }
            }
        }
        .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? TronSpacing.md : TronSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: TronSettingsLayoutPolicy.rowMinimumHeight, alignment: .leading)
    }

    private var detailsPill: some View {
        TronInlineActionLabel("Details", accent: settingsTheme?.accent ?? .tronEmerald)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func rowContents<Trailing: View>(@ViewBuilder trailing: () -> Trailing) -> some View {
        let rowAccent = settingsTheme?.accent
            ?? (provider.configured ? Color.tronEmerald : Color.tronTextSecondary)
        let stacksTrailing = dynamicTypeSize.isAccessibilitySize
        if stacksTrailing {
            HStack(alignment: .top, spacing: TronSpacing.xl) {
                providerIcon(rowAccent)
                VStack(alignment: .leading, spacing: TronSpacing.md) {
                    providerLabels
                    trailing()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: TronSpacing.xl) {
                    providerIcon(rowAccent)
                    providerLabels.fixedSize(horizontal: true, vertical: true)
                    Spacer(minLength: TronSpacing.md)
                    trailing()
                }
                HStack(alignment: .top, spacing: TronSpacing.xl) {
                    providerIcon(rowAccent)
                    VStack(alignment: .leading, spacing: TronSpacing.md) {
                        providerLabels
                        trailing()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func providerIcon(_ accent: Color) -> some View {
        Image(systemName: provider.configured ? "checkmark.seal.fill" : "key")
            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: TronSettingsLayoutPolicy.iconSize, height: TronSettingsLayoutPolicy.iconSize)
            .accessibilityHidden(true)
    }

    private var providerLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.displayName)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(ProviderConfigurationPresentation.connectionDetail(for: provider))
                .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            usageLine
        }
        // The loading placeholder and the resolved usage line share one slot, so
        // only their opacity changes: the row never animates a height jump.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: usageLineIdentity)
    }

    @ViewBuilder
    private var usageLine: some View {
        if let usageSnapshot {
            Text(ProviderUsagePresentation.summary(usageSnapshot))
                .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                .foregroundStyle(usageSnapshot.status == .available ? Color.tronEmerald : Color.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Account usage: \(ProviderUsagePresentation.summary(usageSnapshot))")
                .transition(.opacity)
        } else if isUsageLoading {
            ProviderUsageLoadingLine()
                .transition(.opacity)
        }
    }

    private var usageLineIdentity: String {
        if let usageSnapshot {
            return "usage:\(usageSnapshot.providerId):\(usageSnapshot.updatedAt ?? "")"
        }
        return isUsageLoading ? "loading" : "none"
    }

    private var usageAccessibilityValue: String {
        if let usageSnapshot {
            return "Account usage: \(ProviderUsagePresentation.summary(usageSnapshot))"
        }
        return isUsageLoading ? "Account usage is loading" : "Account usage unavailable"
    }
}

enum ProviderUsageRefreshPresentation {
    static let visibleDiameter: CGFloat = 26
    static let hitTargetDiameter: CGFloat = 44
    static let iconPointSize: CGFloat = 13
}

struct ProviderConfigurationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.tronPresentationActivity) private var presentationActivity
    let provider: ProviderSummary
    let target: ProviderCatalogTarget
    @State private var activeOperationID: String?
    @State private var owningProfileID: String?
    @State private var beginningMethod: String?
    @State private var attemptedAutomaticBegin = false
    @State private var clearing = false
    @State private var usageController = ProviderUsageReadController()

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

    /// An owned auth operation is cancellable when the detail sheet disappears;
    /// only the request that is still beginning or credential mutation that is
    /// clearing may block an interactive dismissal.
    private var disablesInteractiveDismissal: Bool {
        ProviderConfigurationPresentation.disablesInteractiveDismissal(
            beginningMethod: beginningMethod,
            clearing: clearing
        )
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
        // Keep this detail surface on the standard sheet material. A custom
        // opaque background made the provider detail noticeably darker than
        // the other settings sheets.
        .tronPresentation()
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(disablesInteractiveDismissal)
        .onAppear {
            if owningProfileID == nil { owningProfileID = model.profiles.selected?.id }
            if let operationID = model.activeProviderAuthOperationID(providerID: provider.id, target: target) {
                activeOperationID = operationID
            }
            beginAutomaticallyIfNeeded()
        }
        .onChange(of: model.profiles.selected?.id) { _, selectedProfileID in
            guard let owningProfileID, selectedProfileID != owningProfileID else { return }
            close()
        }
        .onChange(of: model.profileRevision) { _, _ in
            usageController.begin(clear: true)
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
            usageController.begin()
            guard ProviderAuthBrowserPolicy.shouldCancelOperationWhenProviderSheetDisappears(
                sceneIsActive: scenePhase == .active
            ), let operationID = activeOperationID else { return }
            activeOperationID = nil
            Task { await model.cancelAuth(operationID: operationID) }
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            // Dismissing the parent behind this detail sheet retires its read,
            // but keeps the already-authoritative same-provider snapshot in
            // place so the third usage line does not vanish during the cover.
            guard active else { usageController.begin(); return }
        }
        .onChange(of: model.providerInvalidationGeneration) { _, _ in
            usageController.begin(clear: true)
        }
        .task(id: PresentationActivityTaskID(
            source: "provider-usage-detail:\(target):\(provider.id):\(model.profileRevision):\(model.providerInvalidationGeneration):\(model.foregroundReconciliationGeneration):\(usageController.requestGeneration):\(model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) == true)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication, !Task.isCancelled else { return }
            await loadUsage()
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
                        accent: provider.configured ? .tronEmerald : .tronSlate
                    )
                }

                usageSection

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

    @ViewBuilder private var usageSection: some View {
        TronSettingsGroup("Account Usage", accent: .tronEmerald) {
            if model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) != true {
                TronSettingsCaption("Account usage is unavailable on this Gateway. Connection details remain available.")
            } else if let usage = usageController.snapshots[provider.id] {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(ProviderUsagePresentation.summary(usage))
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(Color.tronTextPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Account usage: \(ProviderUsagePresentation.summary(usage))")
                        Spacer(minLength: 4)
                        Button { usageController.begin() } label: {
                            Image(systemName: usageController.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                                .font(.system(size: ProviderUsageRefreshPresentation.iconPointSize, weight: .semibold))
                                .tronSettingsButtonForeground(settingsTheme?.accent ?? .tronEmerald)
                                .frame(width: ProviderUsageRefreshPresentation.visibleDiameter, height: ProviderUsageRefreshPresentation.visibleDiameter)
                                .tronGlassSurface(
                                    accent: settingsTheme?.accent ?? .tronEmerald,
                                    cornerRadius: ProviderUsageRefreshPresentation.visibleDiameter / 2,
                                    tintOpacity: 0.12,
                                    interactive: true
                                )
                        }
                        .buttonStyle(.plain)
                        .frame(
                            width: ProviderUsageRefreshPresentation.hitTargetDiameter,
                            height: ProviderUsageRefreshPresentation.hitTargetDiameter,
                            alignment: .trailing
                        )
                        .contentShape(Rectangle())
                        .disabled(usageController.isLoading)
                        .accessibilityLabel("Refresh account usage")
                    }
                    if ProviderUsagePresentation.hasDetailContent(usage) {
                        ProviderUsageSummaryView(snapshot: usage, detail: true, includeSummary: false)
                    }
                    if usageController.didFail {
                        Text("Refresh unavailable. Showing last known usage.")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.horizontal, 14)
                .padding(.bottom, ProviderUsagePresentation.hasDetailContent(usage) || usageController.didFail ? 14 : 8)
            } else if usageController.isLoading {
                TronLoadingState(label: "Loading account usage…", accent: .tronEmerald)
                    .padding(.top, 8)
            } else if usageController.didFail {
                TronSettingsCaption("Account usage is currently unavailable. Connection details remain available.")
            }
        }
    }

    private func loadUsage() async {
        guard model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) == true,
              presentationActivity.allowsPresentationPublication,
              !Task.isCancelled else { return }
        let identity = ProviderUsageReadIdentity(
            target: target,
            providerID: provider.id,
            profileRevision: model.profileRevision,
            profileID: model.profiles.selected?.id,
            invalidationGeneration: model.providerInvalidationGeneration,
            foregroundGeneration: model.foregroundReconciliationGeneration,
            requestGeneration: usageController.requestGeneration,
            presentationActive: presentationActivity.allowsPresentationPublication
        )
        await usageController.read(
            identity: identity,
            fetch: {
                try await model.client.request(
                    "provider.usage",
                    ProviderUsageRequest(sessionId: target.sessionID, providerId: provider.id)
                )
            },
            current: {
                identity.target == self.target
                    && identity.providerID == self.provider.id
                    && identity.profileRevision == model.profileRevision
                    && identity.profileID == model.profiles.selected?.id
                    && identity.invalidationGeneration == model.providerInvalidationGeneration
                    && identity.foregroundGeneration == model.foregroundReconciliationGeneration
                    && presentationActivity.allowsPresentationPublication
            }
        )
    }

    @ViewBuilder private var connectionControls: some View {
        if provider.authMethods.isEmpty {
            TronSettingsCaption("This provider does not advertise a supported connection method.")
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
        guard activeOperationID == nil, currentOperationID == nil else { return }
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
        // `currentOperationID` may belong to another provider sheet. Only an
        // operation admitted by this view may be retired on close.
        let operationID = activeOperationID
        activeOperationID = nil
        dismiss()
        guard let operationID else { return }
        Task { await model.cancelAuth(operationID: operationID) }
    }
}

enum ModelPickerSearchPolicy {
    static func filtered(_ models: [ModelSummary], query: String) -> [ModelSummary] {
        query.isEmpty
            ? models
            : models.filter { "\($0.provider) \($0.id) \($0.name)".localizedCaseInsensitiveContains(query) }
    }

    static func shouldClose(showingSearch: Bool, query: String) -> Bool {
        showingSearch || !query.isEmpty
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
                        accent: rowAccent(isSelected: selection == model.ref),
                        cornerRadius: 14,
                        tintOpacity: selection == model.ref ? 0.18 : 0.08
                    )
                    .accessibilityLabel(model.displayName)
                    .accessibilityValue(selection == model.ref ? "Selected" : "")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, showingSearch ? 72 : 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showingSearch {
                TronSearchBar(
                    text: $search,
                    prompt: "Search models",
                    focusOnAppear: true,
                    onClose: closeSearch,
                    onFocusChange: { focused in
                        if !focused { closeSearch() }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.clear)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !showingSearch {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { showingSearch = true }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                            .foregroundStyle(settingsTheme?.accent ?? .tronEmerald)
                    }
                    .accessibilityLabel("Search models")
                }
            }
        }
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

    private func rowAccent(isSelected: Bool) -> Color {
        settingsTheme?.accent ?? (isSelected ? .tronEmerald : .tronSlate)
    }

    private func closeSearch() {
        guard ModelPickerSearchPolicy.shouldClose(showingSearch: showingSearch, query: search), !closingSearch else { return }
        search = ""
        closingSearch = true
    }

    private var filtered: [ModelSummary] {
        ModelPickerSearchPolicy.filtered(models, query: search)
    }
}
