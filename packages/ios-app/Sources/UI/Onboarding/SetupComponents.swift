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
        } else if showsLocalUnlimitedIndicator {
            // Local models have no account to report usage for, so the slot
            // states that instead of staying empty.
            Image(systemName: "infinity")
                .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment, weight: .semibold))
                .foregroundStyle(Color.tronEmerald)
                .transition(.opacity)
                .accessibilityLabel("Local models, no usage limits")
        } else if isUsageLoading {
            ProviderUsageLoadingLine()
                .transition(.opacity)
        }
    }

    private var showsLocalUnlimitedIndicator: Bool {
        ProviderUsagePresentation.showsLocalUnlimited(
            configured: provider.configured,
            localOnly: provider.isLocalOnly,
            snapshot: usageSnapshot,
            isLoading: isUsageLoading
        )
    }

    private var usageLineIdentity: String {
        if let usageSnapshot {
            return "usage:\(usageSnapshot.providerId):\(usageSnapshot.updatedAt ?? "")"
        }
        if showsLocalUnlimitedIndicator { return "local" }
        return isUsageLoading ? "loading" : "none"
    }

    private var usageAccessibilityValue: String {
        if let usageSnapshot {
            return "Account usage: \(ProviderUsagePresentation.summary(usageSnapshot))"
        }
        if showsLocalUnlimitedIndicator { return "Local models, no usage limits" }
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
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment
    let provider: ProviderSummary
    let target: ProviderCatalogTarget
    @State private var activeOperationID: String?
    @State private var owningProfileID: String?
    @State private var beginningMethod: String?
    @State private var attemptedAutomaticBegin = false
    @State private var clearing = false
    @State private var trail = ProviderAuthSelectionTrail()
    @State private var answeringPromptID: String?
    @State private var answeringOptionID: String?
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

    /// The method whose login is starting or owned by this sheet. It stays
    /// checked in the always-visible method group so the user can switch.
    private var selectedMethod: String? {
        beginningMethod ?? (isPresentingOwnedAuth
            ? model.activeProviderAuthType(providerID: provider.id, target: target)
            : nil)
    }

    private var isBusy: Bool {
        beginningMethod != nil || clearing || answeringPromptID != nil
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
            if let previous, previous == activeOperationID {
                // Restart replaces this sheet's exact operation; adopt the
                // successor so closing the sheet cancels the live login.
                if let current {
                    activeOperationID = current
                } else {
                    activeOperationID = nil
                    dismiss()
                }
            } else if activeOperationID == nil, beginningMethod != nil, let current {
                activeOperationID = current
            }
            replayIfNeeded()
        }
        .onChange(of: model.authPrompt?.id) { _, _ in replayIfNeeded() }
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

                connectionControls
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .tronScrollEdgeChrome()
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var usageSection: some View {
        TronSettingsGroup("Account Usage", accent: .tronEmerald) {
            if provider.isLocalOnly {
                // Local models have no account, so this status is authoritative
                // without a Gateway usage capability or a provider.usage read.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "infinity")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Unlimited")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(Color.tronTextPrimary)
                        Text("Local models run on this Mac with no account usage limits.")
                            .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                            .foregroundStyle(Color.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Unlimited. Local models run on this Mac with no account usage limits.")
            } else if model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) != true {
                TronSettingsCaption("Account usage is unavailable on this Gateway. Connection details remain available.")
            } else if let usage = usageController.snapshots[provider.id] {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        ProviderUsageSummaryHeader(snapshot: usage)
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
        guard !provider.isLocalOnly,
              model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) == true,
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
            ProviderChoiceGroup(
                title: "Connection Method",
                choices: provider.authMethods.map { method in
                    ProviderChoiceGroup.Choice(
                        id: method,
                        icon: ProviderConfigurationPresentation.isLoginMethod(method) ? "person.crop.circle.badge.checkmark" : "key.fill",
                        title: ProviderConfigurationPresentation.actionTitle(method: method, configured: provider.configured),
                        subtitle: ProviderConfigurationPresentation.actionDetail(method: method, configured: provider.configured)
                    )
                },
                selectedID: selectedMethod,
                busyID: beginningMethod,
                isDisabled: isBusy,
                onSelect: { begin($0) }
            )
        }

        if isPresentingOwnedAuth || beginningMethod != nil {
            ProviderAuthFlowContent(
                trail: trail,
                answeringPromptID: answeringPromptID,
                answeringOptionID: answeringOptionID,
                // A pending replay keeps earlier choices fixed; switching the
                // method above stays available and discards it.
                isDisabled: isBusy || trail.isReplaying,
                onChoose: { prompt, optionID in choose(prompt, optionID) },
                onChangeStep: { index, optionID in changeAnswer(at: index, to: optionID) }
            )
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

    /// Starts `method`, first cancelling a different method this sheet owns,
    /// so the user can move between connection methods at any step.
    private func begin(_ method: String) {
        guard beginningMethod == nil, !clearing else { return }
        let replaced = activeOperationID
        // Release ownership first so the retiring operation cannot dismiss
        // this sheet; the successor is adopted when it appears.
        activeOperationID = nil
        beginningMethod = method
        trail.reset()
        Task {
            defer { beginningMethod = nil }
            if let replaced { await model.cancelAuth(operationID: replaced) }
            do {
                try await model.beginAuth(providerID: provider.id, authType: method, target: target)
                adoptStartedOperation()
            } catch is CancellationError { }
            catch { model.presentError(error) }
        }
    }

    private func choose(_ prompt: ProviderAuthPromptState, _ optionID: String) {
        guard answeringPromptID == nil, !isBusy, model.authPrompt?.id == prompt.id else { return }
        answeringPromptID = prompt.id
        answeringOptionID = optionID
        Task {
            defer { answeringPromptID = nil; answeringOptionID = nil }
            do {
                try await model.answerAuth(optionID)
                trail.record(prompt, chosenID: optionID)
            } catch is CancellationError { }
            catch { model.presentError(error) }
        }
    }

    /// Changing an answered choice restarts the same method; the kept answers
    /// replay onto the successor's prompts as they arrive.
    private func changeAnswer(at index: Int, to optionID: String) {
        guard !isBusy, !trail.isReplaying, let operationID = activeOperationID, let method = selectedMethod else { return }
        trail.change(stepAt: index, to: optionID)
        guard trail.isReplaying else { return }
        activeOperationID = nil
        beginningMethod = method
        Task {
            defer { beginningMethod = nil }
            do {
                try await model.restartAuth(operationID: operationID)
                adoptStartedOperation()
            } catch is CancellationError { trail.reset() }
            catch { trail.reset(); model.presentError(error) }
        }
    }

    private func adoptStartedOperation() {
        if let operationID = currentOperationID {
            activeOperationID = operationID
            replayIfNeeded()
        } else {
            dismiss()
        }
    }

    private func replayIfNeeded() {
        guard trail.isReplaying,
              answeringPromptID == nil,
              let prompt = model.authPrompt,
              prompt.operationId == activeOperationID else { return }
        guard let optionID = trail.consumeReplay(for: prompt) else { return }
        answeringPromptID = prompt.id
        answeringOptionID = optionID
        Task {
            defer {
                answeringPromptID = nil
                answeringOptionID = nil
                replayIfNeeded()
            }
            do { try await model.answerAuth(optionID) }
            catch is CancellationError { trail.reset() }
            catch { trail.reset(); model.presentError(error) }
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
            : models.filter { "\($0.provider) \($0.id) \($0.name) \($0.pickerIdentity)".localizedCaseInsensitiveContains(query) }
    }

    static func shouldClose(showingSearch: Bool, query: String) -> Bool {
        showingSearch || !query.isEmpty
    }
}

enum ModelPickerSectioning {
    static let maximumRecentModels = 12
    static let maximumLatestModels = 10

    struct ProviderSection: Identifiable, Equatable {
        let provider: String
        let displayName: String
        let models: [ModelSummary]

        var id: String { provider }
    }

    struct Sections: Equatable {
        let recent: [ModelSummary]
        let latest: [ModelSummary]
        let providers: [ProviderSection]
    }

    /// Builds the picker's three layers from the available catalog plus the
    /// Gateway's recent history. Any query replaces the Recent and Latest rails
    /// with matching provider sections, so every result stays visible.
    static func sections(
        models: [ModelSummary],
        recent: [RecentModelRef],
        selection: ModelRef?,
        query: String
    ) -> Sections {
        let available = models.filter(\.available)
        let providers = providerSections(
            models: ModelPickerSearchPolicy.filtered(available, query: query),
            selection: selection
        )
        guard query.isEmpty else {
            return Sections(recent: [], latest: [], providers: providers)
        }
        return Sections(
            recent: recentModels(recent, catalog: available),
            latest: latestModels(available),
            providers: providers
        )
    }

    /// Recent order belongs to the Gateway. A ref that has left the available
    /// catalog, or repeats an earlier one, is dropped.
    static func recentModels(_ recent: [RecentModelRef], catalog: [ModelSummary]) -> [ModelSummary] {
        let byRef = Dictionary(catalog.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<ModelRef>()
        return recent.compactMap { entry in
            guard seen.insert(entry.ref).inserted, let model = byRef[entry.ref] else { return nil }
            return model
        }
        .prefix(maximumRecentModels)
        .map { $0 }
    }

    /// Newest release date first. A latest alias and the pinned release its ID
    /// names share that date, and the rail keeps the alias only; both stay
    /// selectable in their provider section.
    static func latestModels(_ catalog: [ModelSummary]) -> [ModelSummary] {
        let dated = catalog.filter { $0.admittedReleaseDate != nil }
        // Provider-scoped: two providers may publish the same model ID, and a
        // pinned release may only collapse against its own provider's alias.
        let byRef = Dictionary(dated.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        let collapsedPinnedRefs = Set(dated.compactMap { pinned -> ModelRef? in
            guard let releaseDate = pinned.admittedReleaseDate,
                  ModelReleaseDate.pinnedReleaseDate(inID: pinned.id) == releaseDate,
                  let alias = byRef[ModelRef(provider: pinned.provider, id: String(pinned.id.dropLast(9)))],
                  alias.admittedReleaseDate == releaseDate else { return nil }
            return pinned.ref
        })
        return dated
            .filter { !collapsedPinnedRefs.contains($0.ref) }
            .sorted { lhs, rhs in
                let left = lhs.admittedReleaseDate ?? ""
                let right = rhs.admittedReleaseDate ?? ""
                if left != right { return left > right }
                let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
            }
            .prefix(maximumLatestModels)
            .map { $0 }
    }

    /// The selected model's provider leads so its section is reachable without
    /// scrolling; the rest follow by provider display name. Model order inside a
    /// section stays the Gateway catalog's.
    static func providerSections(models: [ModelSummary], selection: ModelRef?) -> [ProviderSection] {
        var grouped: [String: [ModelSummary]] = [:]
        var catalogOrder: [String] = []
        for model in models {
            if grouped[model.provider] == nil { catalogOrder.append(model.provider) }
            grouped[model.provider, default: []].append(model)
        }
        return catalogOrder
            .map {
                ProviderSection(
                    provider: $0,
                    displayName: ModelDisplayFormatting.provider($0),
                    models: grouped[$0] ?? []
                )
            }
            .sorted { lhs, rhs in
                let lhsSelected = lhs.provider == selection?.provider
                let rhsSelected = rhs.provider == selection?.provider
                if lhsSelected != rhsSelected { return lhsSelected }
                let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                return nameOrder == .orderedSame ? lhs.provider < rhs.provider : nameOrder == .orderedAscending
            }
    }
}

struct ModelPicker: View {
    @Binding var selection: ModelRef?
    let models: [ModelSummary]
    @State private var search = ""
    @State private var showingSearch = false
    @State private var closingSearch = false
    /// A toggle lands here first so the section repaints immediately; the store
    /// keeps the choice for the next picker over this gateway profile.
    @State private var providerExpansionOverrides: [String: Bool] = [:]
    @State private var providerExpansion = ModelProviderExpansionStore.shared
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 8) {
                if !sections.recent.isEmpty {
                    cardRail(title: "Recent", models: sections.recent)
                }
                if !sections.latest.isEmpty {
                    cardRail(title: "Latest", models: sections.latest)
                }
                ForEach(sections.providers) { section in
                    providerSection(section)
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
                    Button { beginSearch() } label: {
                        Image(systemName: "magnifyingglass")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                            .foregroundStyle(settingsTheme?.accent ?? .tronEmerald)
                    }
                    .accessibilityLabel("Search models")
                    #if HOSTED_TEST
                    .modifier(ModelPickerHostedActionModifier(id: "picker.search", action: beginSearch))
                    #endif
                }
            }
        }
        .interactiveDismissDisabled(showingSearch)
        .task { await model.refreshRecentModels() }
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

    private var sections: ModelPickerSectioning.Sections {
        ModelPickerSectioning.sections(
            models: models,
            recent: model.recentModels,
            selection: selection,
            query: search
        )
    }

    private var accent: Color { settingsTheme?.accent ?? .tronEmerald }

    private func cardRail(title: String, models: [ModelSummary]) -> some View {
        TronCardRail(
            title: title,
            items: models,
            identity: \.ref,
            accent: accent,
            isSelected: { $0.ref == selection },
            accessibilityLabel: { "\($0.displayName), \($0.displayProviderName)" },
            accessibilityValue: { $0.ref == selection ? "Selected" : "" },
            action: { select($0.ref) }
        ) { model in
            TronRailCardLabel(
                primary: model.displayName,
                secondary: model.displayProviderName,
                primaryLineLimit: 2,
                minimumWidth: 132,
                selectionAccent: model.ref == selection ? rowAccent(isSelected: true) : nil
            )
            #if HOSTED_TEST
            .modifier(ModelPickerHostedActionModifier(
                id: "picker.card.\(model.provider)/\(model.id)",
                action: { select(model.ref) }
            ))
            #endif
        }
    }

    @ViewBuilder
    private func providerSection(_ section: ModelPickerSectioning.ProviderSection) -> some View {
        let isExpanded = isSectionExpanded(section.provider)
        VStack(alignment: .leading, spacing: 8) {
            Button { toggleExpansion(section.provider) } label: {
                HStack(spacing: 8) {
                    Text(section.displayName)
                        .font(TronTypography.sheetSectionHeader)
                        .lineLimit(1)
                    Text("\(section.models.count)")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                    Spacer(minLength: 8)
                    TronDisclosureChevron(isExpanded: isExpanded)
                }
                .foregroundStyle(accent)
                .frame(minHeight: 32, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .animation(TronDisclosureLayout.expansionAnimation, value: isExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(section.displayName)
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            .accessibilityHint(isExpanded ? "Double tap to hide models" : "Double tap to show models")
            #if HOSTED_TEST
            .modifier(ModelPickerHostedActionModifier(
                id: "picker.provider.\(section.provider)",
                action: { toggleExpansion(section.provider) }
            ))
            #endif

            if isExpanded {
                ForEach(section.models, id: \.ref) { model in
                    row(model)
                }
            }
        }
    }

    private func row(_ model: ModelSummary) -> some View {
        Button { select(model.ref) } label: {
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
                    Text(model.pickerIdentity)
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
        .accessibilityLabel("\(model.displayName), \(model.pickerIdentity)")
        .accessibilityValue(selection == model.ref ? "Selected" : "")
        #if HOSTED_TEST
        .modifier(ModelPickerHostedActionModifier(
            id: "picker.row.\(model.provider)/\(model.id)",
            action: { select(model.ref) }
        ))
        #endif
    }

    /// A search shows every match, so a result never hides behind a collapsed
    /// section. Clearing the query restores the remembered expansion.
    private func isSectionExpanded(_ provider: String) -> Bool {
        guard search.isEmpty else { return true }
        if let override = providerExpansionOverrides[provider] { return override }
        return providerExpansion.isExpanded(
            profileID: model.profiles.selected?.id,
            provider: provider,
            selectedProvider: selection?.provider
        )
    }

    private func beginSearch() {
        withAnimation(.snappy(duration: 0.18)) { showingSearch = true }
    }

    private func select(_ ref: ModelRef) {
        selection = ref
    }

    private func toggleExpansion(_ provider: String) {
        let expanded = !isSectionExpanded(provider)
        withAnimation(TronDisclosureLayout.expansionAnimation) {
            providerExpansionOverrides[provider] = expanded
        }
        providerExpansion.setExpanded(
            expanded,
            profileID: model.profiles.selected?.id,
            provider: provider
        )
    }

    private func rowAccent(isSelected: Bool) -> Color {
        settingsTheme?.accent ?? (isSelected ? .tronEmerald : .tronSlate)
    }

    private func closeSearch() {
        guard ModelPickerSearchPolicy.shouldClose(showingSearch: showingSearch, query: search), !closingSearch else { return }
        search = ""
        closingSearch = true
    }
}
