import SwiftUI
import TronMobileCore

enum IntegrationPolicySubmission {
    static func candidate(policy: IntegrationPolicy, paidBudgetDraft: String?) -> IntegrationPolicy? {
        guard let paidBudgetDraft else { return policy }
        guard let paidBudget = TronNumberSettingRow.parse(paidBudgetDraft) else { return nil }
        var candidate = policy
        candidate.paidBudgetCents = paidBudget
        return candidate
    }
}

/// One opened account setup and everything typed into it. The setup sheet only
/// renders this draft: the X client ID and callback, an accepted begin's consent
/// step and an in-flight mutation must outlive the sheet's view state.
@MainActor
@Observable
final class IntegrationSetupDraft {
    let definition: IntegrationDefinition
    let viewID = UUID().uuidString
    var method: String
    var instanceID = "ios-\(UUID().uuidString.lowercased())"
    var accountID = ""
    var scope = ""
    var credentialRef = ""
    var xClientID = ""
    var xRedirectURI = ""
    var xCallbackURL = ""
    var xAuthorizationCode = ""
    var xOAuthState: String?
    var xOAuthOperationID: String?
    var xAuthorizationURL: URL?
    var xOAuthCompleted = false
    var unresolvedOAuth: GatewayFailure?
    var paidBudgetDraft: String?
    var policy = IntegrationPolicy(enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false)
    var mutation: KnowledgeMutation?
    var error: String?

    init(definition: IntegrationDefinition) {
        self.definition = definition
        method = definition.setupMethods.first ?? "token"
    }
}

/// The Connected Services sheet routes: the open setup draft or connection detail.
/// Owned above the presented Connected Services content, which SwiftUI rebuilds
/// while it stays presented when the app returns from the background (#932);
/// the owner resets it once that sheet is actually dismissed.
@MainActor
@Observable
final class IntegrationSheetRoutes {
    var setup: IntegrationSetupDraft?
    /// Kept beside the draft so a dismissal that already cleared `setup` still
    /// records its X setup diagnostics.
    var setupDiagnosticContext: XSetupDiagnosticContext?
    var selectedInstance: IntegrationInstance?

    func presentSetup(_ definition: IntegrationDefinition) {
        setupDiagnosticContext = nil
        setup = IntegrationSetupDraft(definition: definition)
    }

    func reset() {
        setup = nil
        setupDiagnosticContext = nil
        selectedInstance = nil
    }
}

/// Unified presentation over the Gateway connection owner. This view never
/// stores an authority or credential: every instance action carries its opaque
/// connection ID to the owner and every read is fenced to the current Gateway
/// profile, lifecycle generation, and connection epoch.
struct IntegrationsSettingsView: View {
    @Environment(AppModel.self) private var model
    /// The opening group's accent (Accounts); cyan only when opened alone (#939).
    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronCyan }
    @Environment(\.tronPresentationActivity) private var activity
    #if HOSTED_TEST
    @Environment(\.hostedIntegrationPresentationTrace) private var hostedTrace
    #endif
    @PresentationState private var snapshot: IntegrationSnapshot?
    @PresentationState private var loadGeneration = 0
    @PresentationState private var isLoading = false
    @PresentationState private var error: String?
    @PresentationState private var credits = IntegrationCreditsReadController()
    let routes: IntegrationSheetRoutes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let snapshot {
                    let definitions = snapshot.definitions
                    let configured = snapshot.instances.filter { instance in definitions.contains { $0.id == instance.definitionId } }
                    let available = definitions.filter { definition in
                        !configured.contains { $0.definitionId == definition.id }
                    }
                    if !configured.isEmpty {
                        TronSettingsGroup("Configured", accent: accent, surfaceStyle: .glass) {
                            ForEach(Array(configured.enumerated()), id: \.element.id) { index, instance in
                                if let definition = definitions.first(where: { $0.id == instance.definitionId }) {
                                    instanceRow(instance, definition: definition, snapshot: snapshot)
                                }
                                if index < configured.count - 1 { TronSettingsDivider(accent: accent) }
                            }
                        }
                    }
                    if !available.isEmpty {
                        TronSettingsGroup("Available", accent: accent, surfaceStyle: .glass) {
                            ForEach(Array(available.enumerated()), id: \.element.id) { index, definition in
                                let action = "Connect"
                                IntegrationConfiguredRow(title: definition.displayName, account: "", status: "Not configured", usage: nil,
                                                         isLoadingUsage: false, configured: false, actionTitle: action,
                                                         accessibilityAction: "\(action) for \(definition.displayName)", accent: accent) {
                                    routes.presentSetup(definition)
                                }
                                if index < available.count - 1 { TronSettingsDivider(accent: accent) }
                            }
                        }
                        .padding(.top, configured.isEmpty ? 0 : TronSpacing.section)
                    }
                    if definitions.isEmpty {
                        TronPlaceholderState(title: "No supported integrations", detail: emptySurfaceDetail,
                                             icon: "link")
                    }
                } else if isLoading {
                    TronSheetLoadingState(label: "Loading integrations…", accent: .tronCyan)
                }
                if let error { TronSettingsNotice(message: error, accent: .tronError) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Connected Services", accent: accent)
        .tronSettingsLayout()
        .tronSettingsVisualTheme(inheriting: .tronCyan)
        .task(id: PresentationActivityTaskID(source: "integrations/\(model.knowledgePresentationIdentity)/\(model.connectionState)", presentationActive: activity.allowsPresentationPublication)) {
            guard activity.allowsPresentationPublication else { return }
            load()
        }
        .onChange(of: model.knowledgePresentationIdentity) { oldIdentity, newIdentity in
            #if HOSTED_TEST
            hostedTrace?.record("integrations.transport old=\(presentationToken(oldIdentity)) new=\(presentationToken(newIdentity)) setupOpen=\(routes.setup != nil)")
            #endif
            loadGeneration &+= 1; isLoading = false
            credits.begin(clear: true); load()
        }
        .onChange(of: model.knowledgeDestinationIdentity) { oldIdentity, newIdentity in
            #if HOSTED_TEST
            hostedTrace?.record("integrations.destination old=\(destinationToken(oldIdentity)) new=\(destinationToken(newIdentity)) setupOpen=\(routes.setup != nil)")
            #endif
            if routes.setup != nil, let context = routes.setupDiagnosticContext {
                XSetupDiagnostic.record(
                    .destinationRetired, context: context, appLog: model.appLog,
                    outcome: .rejected, reason: .destinationChanged,
                    currentGeneration: newIdentity.lifecycleGeneration,
                    currentConnectionID: model.knowledgePresentationIdentity.connectionID
                )
            }
            routes.selectedInstance = nil; routes.setup = nil; snapshot = nil
        }
        .onChange(of: activity.allowsPresentationPublication) { _, active in
            // Covered: retire reads in flight, keep what is shown (the Mac did not change).
            if !active { loadGeneration &+= 1; isLoading = false; credits.begin() }
        }
        .tronManagedSheet(isPresented: Binding(get: { routes.setup != nil }, set: { isPresented in
            guard !isPresented else { return }
            if let context = routes.setupDiagnosticContext {
                XSetupDiagnostic.record(
                    .bindingSetFalse, context: context, appLog: model.appLog,
                    reason: .unknownOrigin
                )
            }
            routes.setup = nil; routes.setupDiagnosticContext = nil
        }), identity: "integrations.setup") {
            if let draft = routes.setup {
                IntegrationSetupView(draft: draft, diagnosticContext: Bindable(routes).setupDiagnosticContext) {
                    routes.setup = nil; load()
                }.environment(model)
            }
        }
        .tronManagedSheet(isPresented: Binding(get: { routes.selectedInstance != nil }, set: { if !$0 { routes.selectedInstance = nil } }), identity: "integrations.instance") {
            if let instance = routes.selectedInstance {
                IntegrationInstanceView(
                    instance: instance,
                    definition: snapshot?.definitions.first { $0.id == instance.definitionId },
                    statuses: snapshot?.capabilities.filter { $0.connectionId == instance.id } ?? [],
                    addAccount: { addAccount(for: instance) }
                ) { routes.selectedInstance = nil; load() }.environment(model)
            }
        }
        #if HOSTED_TEST
        .onAppear { hostedTrace?.record("integrations.appear dest=\(destinationToken(model.knowledgeDestinationIdentity))") }
        .onDisappear { hostedTrace?.record("integrations.disappear dest=\(destinationToken(model.knowledgeDestinationIdentity))") }
        #endif
    }

    @ViewBuilder
    private func instanceRow(_ instance: IntegrationInstance, definition: IntegrationDefinition, snapshot: IntegrationSnapshot) -> some View {
        let usage = credits.balances[instance.id].map { "\(ProviderUsagePresentation.currency($0.totalBalance, code: "USD")) available" }
        IntegrationConfiguredRow(title: definition.displayName, account: instance.displayTitle,
                                 status: connectionStatus(instance, snapshot: snapshot), usage: usage,
                                 isLoadingUsage: credits.loadingIDs.contains(instance.id), configured: true,
                                 actionTitle: "Details", accessibilityAction: "Details for \(definition.displayName)", accent: accent) {
            routes.selectedInstance = instance
        }
    }

    private func addAccount(for instance: IntegrationInstance) {
        guard let definition = snapshot?.definitions.first(where: { $0.id == instance.definitionId }),
              activity.allowsPresentationPublication else { return }
        let identity = model.knowledgePresentationIdentity
        let ticket = loadGeneration
        routes.selectedInstance = nil
        Task { @MainActor in
            await Task.yield()
            guard activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == identity,
                  loadGeneration == ticket else { return }
            routes.presentSetup(definition)
        }
    }

    private func connectionStatus(_ instance: IntegrationInstance, snapshot: IntegrationSnapshot) -> String {
        guard instance.health == "ready" else { return IntegrationHealthPresentation.label(instance.health) }
        let method = snapshot.setupOperations.first { $0.instanceId == instance.id && $0.status == "completed" }?.method
        if method == "oauth" { return "Connected · OAuth" }
        return "Connected · stored credential"
    }

    private func load() {
        guard activity.allowsPresentationPublication, !isLoading,
              model.connectionState == .connected,
              model.knowledgePresentationIdentity.connectionID != nil else { return }
        isLoading = true; error = nil
        let requestIdentity = model.knowledgePresentationIdentity
        let ticket = loadGeneration &+ 1; loadGeneration = ticket
        Task { @MainActor in
            do {
                let loaded = try await model.integrations.snapshot()
                guard IntegrationPresentationAdmission.admits(
                    presentationActive: activity.allowsPresentationPublication,
                    currentIdentity: model.knowledgePresentationIdentity,
                    requestedIdentity: requestIdentity,
                    currentRequest: loadGeneration,
                    requestedRequest: ticket
                ) else { return }
                snapshot = loaded; isLoading = false
                credits.start(instances: loaded.instances, identity: requestIdentity, client: model.integrations,
                              presentationActive: { activity.allowsPresentationPublication },
                              currentIdentity: { model.knowledgePresentationIdentity })
            } catch {
                guard IntegrationPresentationAdmission.admits(
                    presentationActive: activity.allowsPresentationPublication,
                    currentIdentity: model.knowledgePresentationIdentity,
                    requestedIdentity: requestIdentity,
                    currentRequest: loadGeneration,
                    requestedRequest: ticket
                ) else { return }
                isLoading = false
                if !(error is CancellationError) { snapshot = nil; self.error = error.localizedDescription }
            }
        }
    }

    private var emptySurfaceDetail: String { "No supported account-based services are advertised by this Gateway." }

    #if HOSTED_TEST
    private func destinationToken(_ identity: KnowledgeDestinationIdentity) -> String {
        "\(identity.profileID ?? "none"):g\(identity.lifecycleGeneration)"
    }

    private func presentationToken(_ identity: KnowledgePresentationIdentity) -> String {
        "\(identity.profileID ?? "none"):g\(identity.lifecycleGeneration.map(String.init) ?? "none"):c\(identity.connectionID.map(String.init) ?? "none")"
    }
    #endif
}

private struct IntegrationInstanceView: View {
    @Environment(AppModel.self) private var model
    /// The opening group's accent (Accounts); cyan only when opened alone (#939).
    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronCyan }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    let instance: IntegrationInstance
    let definition: IntegrationDefinition?
    let statuses: [IntegrationCapabilityStatus]
    let addAccount: () -> Void
    let onChanged: () -> Void
    @PresentationState private var policy: IntegrationPolicy
    @PresentationState private var paidBudgetDraft: String?
    @PresentationState private var mutation: KnowledgeMutation?
    @PresentationState private var error: String?

    init(instance: IntegrationInstance, definition: IntegrationDefinition?, statuses: [IntegrationCapabilityStatus], addAccount: @escaping () -> Void, onChanged: @escaping () -> Void) {
        self.instance = instance; self.definition = definition; self.statuses = statuses; self.addAccount = addAccount; self.onChanged = onChanged
        _policy = PresentationState(wrappedValue: instance.policy)
    }

    var body: some View {
        KnowledgeFormSheet(title: definition?.displayName ?? "Connection", accent: accent, isWorking: mutation != nil, onAction: save) {
            TronSettingsGroup("Connection", accent: .tronBlue) {
                TronSettingsRow(icon: "person.crop.circle", title: "Account", subtitle: instance.displayTitle)
                TronSettingsDivider(accent: .tronBlue)
                TronSettingsRow(icon: instance.health == "ready" ? "checkmark.circle" : "exclamationmark.circle",
                                title: "Status", subtitle: IntegrationHealthPresentation.label(instance.health),
                                accent: instance.health == "ready" ? .tronEmerald : .tronAmber)
                if let scope = instance.scope {
                    TronSettingsDivider(accent: .tronBlue)
                    TronSettingsRow(icon: "scope", title: "Scope", subtitle: scope)
                }
            }
            if let mappings = instance.raindropCollections, !mappings.isEmpty {
                TronSettingsGroup("Raindrop collections", accent: accent) {
                    ForEach(Array(mappings.enumerated()), id: \.offset) { index, mapping in
                        if index > 0 { TronSettingsDivider(accent: accent) }
                        TronSettingsRow(icon: "folder", title: "\(mapping.role.capitalized) home", subtitle: "Collection \(mapping.collectionId)")
                    }
                }
            }
            capabilitiesSection
            TronTechnicalMetadataSection(title: "Technical details", items: technicalMetadata, accent: .tronSlate)
            if let definition {
                Button { addAccount() } label: { TronInlineActionLabel("Add another account", accent: accent) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add another account for \(definition.displayName)")
            }
            TronSettingsGroup("Policy", accent: .tronPurple) {
                TronToggleRow(icon: "power", title: "Enabled", isOn: $policy.enabled)
                TronSettingsDivider(accent: .tronPurple)
                TronToggleRow(icon: "arrow.right.arrow.left", title: "Allow writes", isOn: $policy.allowWrites)
                TronSettingsDivider(accent: .tronPurple)
                TronToggleRow(icon: "creditcard", title: "Paid access approved", isOn: $policy.paidAccessApproved)
                if policy.paidAccessApproved {
                    TronSettingsDivider(accent: .tronPurple)
                    TronNumberSettingRow(icon: "creditcard", title: "Paid budget", detail: "Cents; a positive budget is required", value: $policy.paidBudgetCents, accent: .tronPurple, stagedText: $paidBudgetDraft)
                }
                TronSettingsDivider(accent: .tronPurple)
                TronToggleRow(icon: "repeat", title: "Recurring runs approved", isOn: $policy.recurringApproved)
            }
            .tronSettingsCaption("Policy is independent per connection instance. Changing it does not install packages or silently reload a runtime.")
            if let lastError = instance.lastError { TronSettingsNotice(message: lastError, accent: .tronAmber) }
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
            Button(role: .destructive) { disconnect() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "link.badge.minus")
                    Text("Disconnect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TronActionButtonStyle(role: .destructive))
            .disabled(mutation != nil)
        }
        .modifier(KnowledgeMutationObserver(mutation: $mutation, error: $error) {
            onChanged()
            dismiss()
        })
    }

    private var capabilitiesSection: some View {
        TronSettingsGroup("Capabilities", detail: "Each status reflects the owner’s current prerequisites and policy.", accent: accent) {
            if statuses.isEmpty {
                TronSettingsRow(icon: "questionmark.circle", title: "No capabilities reported", subtitle: "The Gateway did not advertise capability details.")
            } else {
                ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                    TronSettingsRow(
                        icon: status.availability == "available" ? "checkmark.circle" : "exclamationmark.triangle",
                        title: definition?.capabilities.first { $0.id == status.id }?.displayName ?? status.id,
                        subtitle: capabilityDetail(status),
                        accent: status.availability == "available" ? .tronEmerald : .tronAmber
                    )
                }
            }
        }
    }

    private var technicalMetadata: [TronTechnicalMetadataItem] {
        [
            TronTechnicalMetadataItem(title: "Connection ID", value: instance.id, icon: "number"),
            TronTechnicalMetadataItem(title: "Provider account ID", value: instance.providerAccountId, icon: "number"),
            TronTechnicalMetadataItem(title: "Implementation", value: instance.implementation, icon: "gearshape"),
            TronTechnicalMetadataItem(title: "Credential", value: instance.credentialConfigured ? "Configured" : "Not configured", icon: "key"),
            TronTechnicalMetadataItem(title: "Credential availability", value: instance.credentialAvailability ?? "unknown", icon: "key"),
            TronTechnicalMetadataItem(title: "Account verification", value: instance.providerIdentity ?? "unknown", icon: "person.crop.circle.badge.checkmark"),
            TronTechnicalMetadataItem(title: "Health", value: instance.health, icon: "heart.text.square")
        ]
    }

    private func capabilityDetail(_ status: IntegrationCapabilityStatus) -> String {
        if let detail = status.detail, !detail.isEmpty { return detail }
        let label: String = switch status.availability {
        case "available": "Available"
        case "requires-setup": "Setup required"
        case "disabled": "Disabled"
        case "unsupported": "Unsupported"
        default: "Unavailable"
        }
        return label + (status.effects.isEmpty ? "" : " · " + status.effects.joined(separator: ", "))
    }

    private func save() {
        guard mutation == nil, activity.allowsPresentationPublication else { return }
        guard let submitted = IntegrationPolicySubmission.candidate(policy: policy, paidBudgetDraft: paidBudgetDraft) else {
            error = TronNumberSettingRow.invalidInputMessage
            return
        }
        guard submitted != instance.policy else { dismiss(); return }
        error = nil
        let identity = model.knowledgeDestinationIdentity
        mutation = KnowledgeMutation(identity: identity, task: Task { @MainActor in
            guard model.knowledgeDestinationIdentity == identity else { throw CancellationError() }
            _ = try await model.integrations.updatePolicy(instanceID: instance.id, expectedSetupRevision: instance.setupRevision, policy: submitted)
        })
    }

    private func disconnect() {
        guard mutation == nil, activity.allowsPresentationPublication else { return }
        error = nil
        let identity = model.knowledgeDestinationIdentity
        mutation = KnowledgeMutation(identity: identity, task: Task { @MainActor in
            guard model.knowledgeDestinationIdentity == identity else { throw CancellationError() }
            _ = try await model.integrations.disconnect(instanceID: instance.id)
        })
    }
}

private struct IntegrationSetupView: View {
    @Environment(AppModel.self) private var model
    /// The opening group's accent (Accounts); cyan only when opened alone (#939).
    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronCyan }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.tronPresentationActivity) private var activity
    #if HOSTED_TEST
    @Environment(\.hostedIntegrationPresentationTrace) private var hostedTrace
    #endif
    /// Owned by the Connected Services routes, not this sheet: the sheet content
    /// can be rebuilt while presented and must not lose the draft (#932).
    @Bindable var draft: IntegrationSetupDraft
    @Binding var diagnosticContext: XSetupDiagnosticContext?
    let onFinished: () -> Void

    private var definition: IntegrationDefinition { draft.definition }

    var body: some View {
        KnowledgeFormSheet(title: "Set up \(definition.displayName)", accent: accent, actionTitle: usesXOAuth ? (draft.unresolvedOAuth != nil ? "Check setup status" : (draft.xOAuthOperationID == nil ? "Authorize X" : "Complete setup")) : "Save", isWorking: draft.mutation != nil, actionDisabled: model.connectionState != .connected, onAction: complete) {
            if draft.mutation == nil {
                if usesXOAuth {
                    TronSettingsGroup("X developer app", accent: .tronBlue) {
                        TronTextSettingRow(icon: "number", title: "Public client ID", value: $draft.xClientID)
                        TronSettingsDivider(accent: .tronBlue)
                        TronTextSettingRow(icon: "link", title: "Registered callback URL", value: $draft.xRedirectURI)
                    }
                    .tronSettingsCaption("Create a public OAuth 2.0 app in the X developer console, enable tweet.read, users.read, bookmark.read, and offline.access, and register this exact HTTPS callback. Tron does not ask for an app secret.")
                    if let xAuthorizationURL = draft.xAuthorizationURL {
                        TronSettingsGroup("Authorize your X account", accent: .tronPurple) {
                            Button { openURL(xAuthorizationURL) } label: {
                                TronSettingsRow(icon: "arrow.up.right.square", title: "Open X consent", accent: .tronPurple) {
                                    Image(systemName: "arrow.up.right")
                                        .font(TronTypography.sans(size: TronTypography.sizeSecondary, weight: .semibold))
                                        .foregroundStyle(Color.tronTextMuted)
                                        .accessibilityHidden(true)
                                }
                            }
                            .buttonStyle(.plain)
                            TronSettingsDivider(accent: .tronPurple)
                            TronTextSettingRow(icon: "doc.on.clipboard", title: "Paste redirected URL", detail: "or enter the code below", value: $draft.xCallbackURL)
                            TronSettingsDivider(accent: .tronPurple)
                            TronTextSettingRow(icon: "number", title: "Authorization code", detail: "Optional alternative", value: $draft.xAuthorizationCode)
                        }
                        .tronSettingsCaption("After consent, copy the complete redirected URL from your browser or paste its one-time code. The selected Mac verifies the state and exchanges the code; tokens stay in its Keychain.")
                    }
                } else {
                    TronSettingsGroup("Account", accent: .tronBlue) {
                        TronTextSettingRow(icon: "number", title: "Instance ID", value: $draft.instanceID)
                        TronSettingsDivider(accent: .tronBlue)
                        TronTextSettingRow(icon: "person.crop.circle", title: "Account or server", value: $draft.accountID)
                        TronSettingsDivider(accent: .tronBlue)
                        TronTextSettingRow(icon: "scope", title: "Scope", detail: "Optional", value: $draft.scope)
                        if definition.setupMethods.count > 1 {
                            TronSettingsDivider(accent: .tronBlue)
                            TronSelectionRow(icon: "slider.horizontal.3", title: "Setup method", value: draft.method) {
                                ForEach(definition.setupMethods, id: \.self) { value in Button(value) { draft.method = value } }
                            }
                        }
                    }
                    TronSettingsGroup("Credential handoff", accent: .tronPurple) {
                        TronTextSettingRow(icon: "key", title: "Credential reference", value: $draft.credentialRef)
                    }
                    .tronSettingsCaption("Use the credential reference supplied by the paired Mac. The secret stays in its secure credential store and is never sent to or retained by this device.")
                }
                policySection
            } else {
                TronSettingsCaption("Completing setup on the selected Mac. Credentials remain in its secure store.")
                TronLoadingState(label: "Completing setup…", accent: .tronCyan)
            }
            if model.connectionState != .connected {
                TronSettingsCaption("Reconnecting to this Mac. Your setup inputs and accepted operation are kept.")
            }
            if let error = draft.error { TronSettingsNotice(message: error, accent: .tronError) }
        }
        .modifier(KnowledgeMutationObserver(mutation: $draft.mutation, error: $draft.error, failed: { failure in
            if let failure = failure as? GatewayFailure, failure.code == "outcome_unknown" {
                draft.unresolvedOAuth = failure
            }
        }) {
            if !usesXOAuth || draft.xOAuthCompleted {
                if usesXOAuth, let context = diagnosticContext {
                    XSetupDiagnostic.record(.explicitFinish, context: context, appLog: model.appLog, outcome: .success)
                }
                onFinished(); dismiss()
            }
        })
        .onAppear {
            if usesXOAuth {
                let context: XSetupDiagnosticContext
                if let existing = diagnosticContext, existing.viewID == draft.viewID {
                    context = existing
                } else {
                    context = currentDiagnosticContext()
                }
                diagnosticContext = context
                XSetupDiagnostic.record(.viewAppeared, context: context, appLog: model.appLog, outcome: .appeared)
            }
            #if HOSTED_TEST
            hostedTrace?.record("xsetup.appear dest=\(destinationToken(model.knowledgeDestinationIdentity)) view=\(draft.viewID)")
            #endif
        }
        .onDisappear {
            if usesXOAuth, let context = diagnosticContext {
                XSetupDiagnostic.record(.viewDisappeared, context: context, appLog: model.appLog, outcome: .disappeared)
            }
            #if HOSTED_TEST
            hostedTrace?.record("xsetup.disappear dest=\(destinationToken(model.knowledgeDestinationIdentity)) view=\(draft.viewID)")
            #endif
        }
    }

    #if HOSTED_TEST
    private func destinationToken(_ identity: KnowledgeDestinationIdentity) -> String {
        "\(identity.profileID ?? "none"):g\(identity.lifecycleGeneration)"
    }
    #endif

    private func currentDiagnosticContext() -> XSetupDiagnosticContext {
        XSetupDiagnosticContext(
            viewID: draft.viewID, actionID: nil,
            lifecycleGeneration: model.knowledgeDestinationIdentity.lifecycleGeneration,
            connectionID: model.knowledgePresentationIdentity.connectionID
        )
    }

    private func newBeginDiagnosticContext() -> XSetupDiagnosticContext {
        let viewContext = currentDiagnosticContext()
        let action = viewContext.action(
            UUID().uuidString,
            lifecycleGeneration: viewContext.lifecycleGeneration,
            connectionID: viewContext.connectionID
        )
        diagnosticContext = action
        return action
    }

    private var usesXOAuth: Bool { definition.id == "knowledge.x" && draft.method == "oauth" }

    private var policySection: some View {
        TronSettingsGroup("Policy", accent: .tronPurple) {
            TronToggleRow(icon: "power", title: "Enabled", isOn: $draft.policy.enabled)
            TronSettingsDivider(accent: .tronPurple)
            if definition.id != "knowledge.x" {
                TronToggleRow(icon: "arrow.right.arrow.left", title: "Allow writes", isOn: $draft.policy.allowWrites)
                TronSettingsDivider(accent: .tronPurple)
            }
            TronToggleRow(icon: "creditcard", title: "Paid access approved", isOn: $draft.policy.paidAccessApproved)
            if draft.policy.paidAccessApproved {
                TronSettingsDivider(accent: .tronPurple)
                TronNumberSettingRow(icon: "creditcard", title: "Paid budget", detail: "Cents; a positive budget is required", value: $draft.policy.paidBudgetCents, accent: .tronPurple, stagedText: $draft.paidBudgetDraft)
            }
            TronSettingsDivider(accent: .tronPurple)
            TronToggleRow(icon: "repeat", title: "Recurring runs approved", isOn: $draft.policy.recurringApproved)
        }
    }

    private func complete() {
        guard draft.mutation == nil, activity.allowsPresentationPublication else { return }
        if usesXOAuth {
            if let unresolvedOAuth = draft.unresolvedOAuth {
                guard let commandID = unresolvedOAuth.details?.objectValue?["commandId"]?.stringValue,
                      let resumedMethod = unresolvedOAuth.details?.objectValue?["method"]?.stringValue else {
                    draft.error = "The original setup outcome is unknown. Do not start another authorization."
                    return
                }
                let destination = model.knowledgeDestinationIdentity
                let diagnostic = resumedMethod == "knowledge.x.oauth.begin" ? newBeginDiagnosticContext() : nil
                if let diagnostic {
                    XSetupDiagnostic.record(.beginAdmitted, context: diagnostic, appLog: model.appLog,
                                            outcome: .admitted)
                }
                draft.mutation = KnowledgeMutation(identity: destination, task: Task { @MainActor in
                    guard model.knowledgeDestinationIdentity == destination else {
                        if let diagnostic {
                            XSetupDiagnostic.record(.beginRejected, context: diagnostic, appLog: model.appLog,
                                                    outcome: .rejected, reason: .destinationUnavailable,
                                                    currentGeneration: model.knowledgeDestinationIdentity.lifecycleGeneration,
                                                    currentConnectionID: model.knowledgePresentationIdentity.connectionID)
                        }
                        throw CancellationError()
                    }
                    if resumedMethod == "knowledge.x.oauth.begin" {
                        do {
                            let started = try await model.integrations.resumeXOAuthBegin(commandID: commandID)
                            if let diagnostic {
                                XSetupDiagnostic.record(.beginReturned, context: diagnostic, appLog: model.appLog,
                                                        outcome: .success, origin: .explicitStatusRecoveryReturn)
                            }
                            guard model.knowledgeDestinationIdentity == destination, started.instanceId == draft.instanceID else {
                                if let diagnostic {
                                    XSetupDiagnostic.record(.beginRejected, context: diagnostic, appLog: model.appLog,
                                                            outcome: .rejected,
                                                            reason: model.knowledgeDestinationIdentity == destination ? .requestFailed : .destinationChanged,
                                                            currentGeneration: model.knowledgeDestinationIdentity.lifecycleGeneration,
                                                            currentConnectionID: model.knowledgePresentationIdentity.connectionID)
                                }
                                throw CancellationError()
                            }
                            draft.xOAuthOperationID = started.operationId; draft.xOAuthState = started.state
                            draft.xAuthorizationURL = URL(string: started.authorizationUrl)
                            if let diagnostic {
                                XSetupDiagnostic.record(.beginStateAssigned, context: diagnostic, appLog: model.appLog,
                                                        outcome: .assigned)
                            }
                        } catch {
                            if let diagnostic, !(error is CancellationError) {
                                XSetupDiagnostic.record(.beginRejected, context: diagnostic, appLog: model.appLog,
                                                        outcome: .rejected, reason: .requestFailed,
                                                        currentGeneration: model.knowledgeDestinationIdentity.lifecycleGeneration,
                                                        currentConnectionID: model.knowledgePresentationIdentity.connectionID)
                            }
                            throw error
                        }
                    } else if resumedMethod == "knowledge.x.oauth.complete" {
                        _ = try await model.integrations.resumeXOAuthComplete(commandID: commandID)
                        guard model.knowledgeDestinationIdentity == destination else { throw CancellationError() }
                        draft.xOAuthCompleted = true
                    } else { throw CancellationError() }
                    draft.unresolvedOAuth = nil
                }, xSetupDiagnostic: diagnostic)
                return
            }
            if let operationID = draft.xOAuthOperationID {
                guard !draft.xCallbackURL.isEmpty || (!draft.xAuthorizationCode.isEmpty && draft.xOAuthState != nil) else { draft.error = "Paste the redirected URL or its authorization code after consent."; return }
                let requestIdentity = model.knowledgeDestinationIdentity
                let operationID = operationID, callbackURL = draft.xCallbackURL.isEmpty ? nil : draft.xCallbackURL
                let code = callbackURL == nil && !draft.xAuthorizationCode.isEmpty ? draft.xAuthorizationCode : nil
                let state = callbackURL == nil ? draft.xOAuthState : nil
                draft.mutation = KnowledgeMutation(identity: requestIdentity, task: Task { @MainActor in
                    guard model.knowledgeDestinationIdentity == requestIdentity,
                          model.knowledgePresentationIdentity.lifecycleGeneration != nil,
                          model.knowledgePresentationIdentity.connectionID != nil else { throw CancellationError() }
                    _ = try await model.integrations.completeXOAuth(operationID: operationID, callbackURL: callbackURL, code: code, state: state)
                    guard model.knowledgeDestinationIdentity == requestIdentity else { throw CancellationError() }
                    draft.xOAuthCompleted = true
                })
            } else {
                let diagnostic = newBeginDiagnosticContext()
                guard !draft.instanceID.isEmpty, !draft.xClientID.isEmpty, !draft.xRedirectURI.isEmpty else {
                    XSetupDiagnostic.record(.beginRejected, context: diagnostic, appLog: model.appLog,
                                            outcome: .rejected, reason: .invalidInput)
                    draft.error = "Instance ID, public X client ID, and registered callback URL are required."
                    return
                }
                guard let submittedPolicy = IntegrationPolicySubmission.candidate(policy: draft.policy, paidBudgetDraft: draft.paidBudgetDraft) else {
                    XSetupDiagnostic.record(.beginRejected, context: diagnostic, appLog: model.appLog,
                                            outcome: .rejected, reason: .invalidInput)
                    draft.error = TronNumberSettingRow.invalidInputMessage
                    return
                }
                draft.error = nil
                let requestIdentity = model.knowledgeDestinationIdentity
                let instanceID = draft.instanceID, clientID = draft.xClientID, redirectURI = draft.xRedirectURI, policy = submittedPolicy
                XSetupDiagnostic.record(.beginAdmitted, context: diagnostic, appLog: model.appLog, outcome: .admitted)
                draft.mutation = KnowledgeMutation(identity: requestIdentity, task: Task { @MainActor in
                    guard model.knowledgeDestinationIdentity == requestIdentity,
                          model.knowledgePresentationIdentity.lifecycleGeneration != nil,
                          model.knowledgePresentationIdentity.connectionID != nil else {
                        XSetupDiagnostic.record(.beginRejected, context: diagnostic, appLog: model.appLog,
                                                outcome: .rejected, reason: .destinationUnavailable,
                                                currentGeneration: model.knowledgeDestinationIdentity.lifecycleGeneration,
                                                currentConnectionID: model.knowledgePresentationIdentity.connectionID)
                        throw CancellationError()
                    }
                    let started: IntegrationXOAuthStarted
                    do {
                        started = try await model.integrations.beginXOAuth(instanceID: instanceID, clientID: clientID,
                                                                           redirectURI: redirectURI, policy: policy)
                    } catch {
                        if !(error is CancellationError) {
                            XSetupDiagnostic.record(.beginRejected, context: diagnostic, appLog: model.appLog,
                                                    outcome: .rejected, reason: .requestFailed,
                                                    currentGeneration: model.knowledgeDestinationIdentity.lifecycleGeneration,
                                                    currentConnectionID: model.knowledgePresentationIdentity.connectionID)
                        }
                        throw error
                    }
                    XSetupDiagnostic.record(.beginReturned, context: diagnostic, appLog: model.appLog,
                                            outcome: .success, origin: .beginExecutorReturn)
                    guard model.knowledgeDestinationIdentity == requestIdentity else {
                        XSetupDiagnostic.record(.beginRejected, context: diagnostic, appLog: model.appLog,
                                                outcome: .rejected, reason: .destinationChanged,
                                                currentGeneration: model.knowledgeDestinationIdentity.lifecycleGeneration,
                                                currentConnectionID: model.knowledgePresentationIdentity.connectionID)
                        throw CancellationError()
                    }
                    #if HOSTED_TEST
                    hostedTrace?.record("xsetup.begin-accepted dest=\(destinationToken(requestIdentity)) view=\(draft.viewID)")
                    #endif
                    draft.xOAuthOperationID = started.operationId
                    draft.xOAuthState = started.state
                    draft.xAuthorizationURL = URL(string: started.authorizationUrl)
                    XSetupDiagnostic.record(.beginStateAssigned, context: diagnostic, appLog: model.appLog,
                                            outcome: .assigned)
                }, xSetupDiagnostic: diagnostic)
            }
            return
        }
        guard !draft.instanceID.isEmpty, !draft.accountID.isEmpty, !draft.credentialRef.isEmpty else { draft.error = "Instance ID, account/server identity, and an opaque credential reference are required."; return }
        guard let submittedPolicy = IntegrationPolicySubmission.candidate(policy: draft.policy, paidBudgetDraft: draft.paidBudgetDraft) else {
            draft.error = TronNumberSettingRow.invalidInputMessage
            return
        }
        draft.error = nil
        let requestIdentity = model.knowledgeDestinationIdentity
        let instanceID = draft.instanceID, accountID = draft.accountID, scope = draft.scope, credentialRef = draft.credentialRef
        let method = draft.method, policy = submittedPolicy
        draft.mutation = KnowledgeMutation(identity: requestIdentity, task: Task { @MainActor in
                guard model.knowledgeDestinationIdentity == requestIdentity else { throw CancellationError() }
                let begun = try await model.integrations.beginSetup(instanceID: instanceID, definitionID: definition.id, method: method)
                // Begin's receipt remains owned even after dismissal. Completion
                // is a separate command: never send it to a replacement Gateway.
                guard model.knowledgeDestinationIdentity == requestIdentity else { throw CancellationError() }
                _ = try await model.integrations.completeSetup(operationID: begun.operationId, instanceID: instanceID, providerAccountID: accountID, scope: scope.nilIfEmpty, credentialRef: credentialRef, policy: policy)
        })
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
