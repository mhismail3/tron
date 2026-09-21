import SwiftUI

/// Unified presentation over the Gateway connection owner. This view never
/// stores an authority or credential: every instance action carries its opaque
/// connection ID to the owner and every read is fenced to the current Gateway
/// profile, lifecycle generation, and connection epoch.
struct IntegrationsSettingsView: View {
    enum Surface: Hashable {
        case connectedServices
        case mcpServers

        var title: String {
            switch self {
            case .connectedServices: "Connected Services"
            case .mcpServers: "MCP Servers"
            }
        }

        func includes(_ definition: IntegrationDefinition) -> Bool {
            switch self {
            case .connectedServices: definition.implementation != "mcp"
            case .mcpServers: definition.implementation == "mcp"
            }
        }
    }

    let surface: Surface

    init(surface: Surface) {
        self.surface = surface
    }

    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @State private var snapshot: IntegrationSnapshot?
    @State private var loadGeneration = 0
    @State private var isLoading = false
    @State private var error: String?
    @State private var setupDefinition: IntegrationDefinition?
    @State private var selectedInstance: IntegrationInstance?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let snapshot {
                    let definitions = snapshot.definitions.filter(surface.includes)
                    ForEach(definitions) { definition in
                        definitionSection(definition, snapshot: snapshot)
                    }
                    if definitions.isEmpty {
                        TronPlaceholderState(
                            title: "No supported integrations",
                            detail: emptySurfaceDetail,
                            icon: surface == .mcpServers ? "server.rack" : "link"
                        )
                    }
                } else if isLoading {
                    HStack { Spacer(); ProgressView("Loading integrations…"); Spacer() }
                        .padding(.vertical, 28)
                }
                if let error { TronSettingsNotice(message: error, accent: .tronError) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle(surface.title, accent: .tronCyan)
        .tronSettingsLayout()
        .tronSettingsVisualTheme(accent: .tronCyan)
        .task(id: PresentationActivityTaskID(source: "integrations/\(model.knowledgePresentationIdentity)", presentationActive: activity.allowsPresentationPublication)) {
            guard activity.allowsPresentationPublication else { return }
            load()
        }
        .onChange(of: model.knowledgePresentationIdentity) { _, _ in
            loadGeneration &+= 1
            isLoading = false
            snapshot = nil
            selectedInstance = nil
            setupDefinition = nil
            load()
        }
        .onChange(of: activity.allowsPresentationPublication) { _, active in
            if !active { loadGeneration &+= 1; isLoading = false }
        }
        .tronManagedSheet(isPresented: Binding(get: { setupDefinition != nil }, set: { if !$0 { setupDefinition = nil } }), identity: "integrations.setup") {
            if let definition = setupDefinition {
                IntegrationSetupView(definition: definition) {
                    self.setupDefinition = nil
                    load()
                }
                    .environment(model)
            }
        }
        .tronManagedSheet(isPresented: Binding(get: { selectedInstance != nil }, set: { if !$0 { selectedInstance = nil } }), identity: "integrations.instance") {
            if let instance = selectedInstance {
                IntegrationInstanceView(
                    instance: instance,
                    definition: snapshot?.definitions.first { $0.id == instance.definitionId },
                    statuses: snapshot?.capabilities.filter { $0.connectionId == instance.id } ?? []
                ) {
                    self.selectedInstance = nil
                    load()
                }
                .environment(model)
            }
        }
    }

    @ViewBuilder
    private func definitionSection(_ definition: IntegrationDefinition, snapshot: IntegrationSnapshot) -> some View {
        let instances = snapshot.instances.filter { $0.definitionId == definition.id }
        TronSettingsGroup(definition.displayName, accent: .tronBlue) {
            ForEach(instances) { instance in
                instanceRow(instance, definition: definition, snapshot: snapshot)
                if instance.id != instances.last?.id { TronSettingsDivider(accent: .tronBlue) }
            }
            if !instances.isEmpty { TronSettingsDivider(accent: .tronBlue) }
            TronSettingsRow(icon: "plus.circle", title: definition.implementation == "mcp" ? "Add server" : "Add account", subtitle: setupSummary(definition)) {
                Button { setupDefinition = definition } label: { TronInlineActionLabel("Set up") }
                    .buttonStyle(.plain)
            }
        }
        .tronSettingsCaption(capabilityCaption(definition: definition, snapshot: snapshot))
    }

    @ViewBuilder
    private func instanceRow(_ instance: IntegrationInstance, definition: IntegrationDefinition, snapshot: IntegrationSnapshot) -> some View {
        let statuses = snapshot.capabilities.filter { $0.connectionId == instance.id }
        let available = statuses.count { $0.availability == "available" }
        let capabilitySummary = statuses.isEmpty
            ? "No capabilities reported"
            : "\(available) of \(statuses.count) capabilities available"
        TronSettingsRow(
            icon: instance.health == "ready" ? "checkmark.circle" : "exclamationmark.circle",
            title: instance.displayTitle,
            subtitle: "\(healthLabel(instance.health)) · \(capabilitySummary)",
            subtitleLineLimit: 2,
            accent: instance.health == "ready" ? .tronEmerald : .tronAmber
        ) {
            Button { selectedInstance = instance } label: { TronInlineActionLabel("Manage") }.buttonStyle(.plain)
        }
    }

    private func load() {
        guard activity.allowsPresentationPublication, !isLoading else { return }
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

    private var emptySurfaceDetail: String {
        switch surface {
        case .connectedServices: "No supported account-based services are advertised by this Gateway."
        case .mcpServers: "No tools-only MCP server definitions are advertised by this Gateway. OAuth and non-tool MCP features are not supported."
        }
    }

    private func setupSummary(_ definition: IntegrationDefinition) -> String {
        definition.implementation == "mcp"
            ? "Connect a trusted HTTP endpoint or local command; MCP tools only"
            : "Connect using credentials stored on your Mac"
    }

    private func capabilityCaption(definition: IntegrationDefinition, snapshot: IntegrationSnapshot) -> String? {
        let statuses = snapshot.capabilities.filter { $0.definitionId == definition.id && $0.connectionId == nil }
        let unavailable = statuses.filter { $0.availability != "available" && $0.availability != "requires-setup" }
        guard !unavailable.isEmpty else { return nil }
        return unavailable.map { "\($0.id): \($0.detail ?? availabilityLabel($0.availability))" }.joined(separator: " · ")
    }

    private func healthLabel(_ health: String) -> String {
        switch health { case "ready": "Ready"; case "disabled": "Disabled"; case "auth-error": "Authentication error"; case "disconnected": "Disconnected"; case "setup-required": "Setup required"; default: "Unavailable" }
    }
    private func availabilityLabel(_ value: String) -> String {
        switch value { case "available": "Available"; case "requires-setup": "Setup required"; case "disabled": "Disabled"; case "unsupported": "Unsupported"; default: "Unavailable" }
    }
}

/// The receipt executor owns the accepted command. The sheet retains only its
/// task handle; activity-scoped observers may leave/rejoin without replaying it.
struct IntegrationMutation {
    let id = UUID()
    let identity: KnowledgePresentationIdentity
    let task: Task<Void, Error>
}

struct IntegrationMutationObserver: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Binding var mutation: IntegrationMutation?
    @Binding var error: String?
    let completed: () -> Void

    func body(content: Content) -> some View {
        content.task(id: PresentationActivityTaskID(source: mutation?.id, presentationActive: activity.allowsPresentationPublication)) {
            guard activity.allowsPresentationPublication, let accepted = mutation else { return }
            let result = await accepted.task.result
            guard !Task.isCancelled, activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == accepted.identity,
                  mutation?.id == accepted.id else { return }
            mutation = nil
            switch result {
            case .success: completed()
            case .failure(let failure):
                if !(failure is CancellationError) { error = failure.localizedDescription }
            }
        }
    }
}

private struct IntegrationInstanceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    let instance: IntegrationInstance
    let definition: IntegrationDefinition?
    let statuses: [IntegrationCapabilityStatus]
    let onChanged: () -> Void
    @State private var policy: IntegrationPolicy
    @State private var mutation: IntegrationMutation?
    @State private var error: String?

    init(instance: IntegrationInstance, definition: IntegrationDefinition?, statuses: [IntegrationCapabilityStatus], onChanged: @escaping () -> Void) {
        self.instance = instance; self.definition = definition; self.statuses = statuses; self.onChanged = onChanged
        _policy = State(initialValue: instance.policy)
    }

    var body: some View {
        KnowledgeFormSheet(title: definition?.displayName ?? "Connection", accent: .tronCyan, isWorking: mutation != nil, onAction: save) {
            TronSettingsGroup("Connection", accent: .tronBlue) {
                TronSettingsRow(icon: "person.crop.circle", title: "Account", subtitle: instance.displayTitle)
                if let scope = instance.scope {
                    TronSettingsDivider(accent: .tronBlue)
                    TronSettingsRow(icon: "scope", title: "Scope", subtitle: scope)
                }
            }
            capabilitiesSection
            TronTechnicalMetadataSection(title: "Technical details", items: technicalMetadata, accent: .tronSlate)
            TronSettingsGroup("Policy", accent: .tronPurple) {
                TronToggleRow(icon: "power", title: "Enabled", isOn: $policy.enabled)
                TronSettingsDivider(accent: .tronPurple)
                TronToggleRow(icon: "arrow.right.arrow.left", title: "Allow writes", isOn: $policy.allowWrites)
                TronSettingsDivider(accent: .tronPurple)
                TronToggleRow(icon: "creditcard", title: "Paid access approved", isOn: $policy.paidAccessApproved)
                if policy.paidAccessApproved {
                    TronSettingsDivider(accent: .tronPurple)
                    TronNumberSettingRow(icon: "creditcard", title: "Paid budget", detail: "Cents; a positive budget is required", value: $policy.paidBudgetCents, accent: .tronPurple)
                }
                TronSettingsDivider(accent: .tronPurple)
                TronToggleRow(icon: "repeat", title: "Recurring runs approved", isOn: $policy.recurringApproved)
            }
            .tronSettingsCaption("Policy is independent per connection instance. Changing it does not install packages or silently reload a runtime.")
            if let lastError = instance.lastError { TronSettingsNotice(message: lastError, accent: .tronAmber) }
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
            Button("Disconnect", role: .destructive) { disconnect() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(mutation != nil)
        }
        .modifier(IntegrationMutationObserver(mutation: $mutation, error: $error) {
            onChanged()
            dismiss()
        })
    }

    private var capabilitiesSection: some View {
        TronSettingsGroup("Capabilities", detail: "Each status reflects the owner’s current prerequisites and policy.", accent: .tronCyan) {
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
        guard policy != instance.policy else { dismiss(); return }
        error = nil
        let identity = model.knowledgePresentationIdentity
        let submitted = policy
        mutation = IntegrationMutation(identity: identity, task: Task { @MainActor in
            guard model.knowledgePresentationIdentity == identity else { throw CancellationError() }
            _ = try await model.integrations.updatePolicy(instanceID: instance.id, expectedSetupRevision: instance.setupRevision, policy: submitted)
        })
    }

    private func disconnect() {
        guard mutation == nil, activity.allowsPresentationPublication else { return }
        error = nil
        let identity = model.knowledgePresentationIdentity
        mutation = IntegrationMutation(identity: identity, task: Task { @MainActor in
            guard model.knowledgePresentationIdentity == identity else { throw CancellationError() }
            _ = try await model.integrations.disconnect(instanceID: instance.id)
        })
    }
}

private struct IntegrationSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    let definition: IntegrationDefinition
    let onFinished: () -> Void
    @State private var method: String
    @State private var instanceID = "ios-\(UUID().uuidString.lowercased())"
    @State private var accountID = ""
    @State private var scope = ""
    @State private var credentialRef = ""
    @State private var endpoint = ""
    @State private var command = ""
    @State private var args = ""
    @State private var policy = IntegrationPolicy(enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false)
    @State private var mutation: IntegrationMutation?
    @State private var error: String?

    init(definition: IntegrationDefinition, onFinished: @escaping () -> Void) {
        self.definition = definition; self.onFinished = onFinished
        _method = State(initialValue: definition.setupMethods.first ?? "token")
    }

    var body: some View {
        KnowledgeFormSheet(title: "Set up \(definition.displayName)", accent: .tronCyan, isWorking: mutation != nil, onAction: complete) {
            if mutation == nil {
                TronSettingsGroup("Account", accent: .tronBlue) {
                    TronTextSettingRow(icon: "number", title: "Instance ID", value: $instanceID)
                    TronSettingsDivider(accent: .tronBlue)
                    TronTextSettingRow(icon: "person.crop.circle", title: "Account or server", value: $accountID)
                    TronSettingsDivider(accent: .tronBlue)
                    TronTextSettingRow(icon: "scope", title: "Scope", detail: "Optional", value: $scope)
                    if definition.setupMethods.count > 1 {
                        TronSettingsDivider(accent: .tronBlue)
                        TronSelectionRow(icon: "slider.horizontal.3", title: "Setup method", value: method) {
                            ForEach(definition.setupMethods, id: \.self) { value in Button(value) { method = value } }
                        }
                    }
                }
                if definition.implementation == "mcp" { mcpConfiguration() }
                TronSettingsGroup("Credential handoff", accent: .tronPurple) {
                    TronTextSettingRow(icon: "key", title: "Credential reference", value: $credentialRef)
                }
                .tronSettingsCaption("Use the credential reference supplied by the paired Mac. The secret stays in its secure credential store and is never sent to or retained by this device.")
                policySection
            } else {
                TronSettingsCaption("Completing setup on the selected Mac. Credentials remain in its secure store.")
                ProgressView("Completing setup…")
            }
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
        }
        .modifier(IntegrationMutationObserver(mutation: $mutation, error: $error) {
            onFinished()
            dismiss()
        })
    }

    @ViewBuilder
    private func mcpConfiguration() -> some View {
        if method == "local-command" {
            TronSettingsGroup("Trusted local command", accent: .tronAmber) {
                TronTextSettingRow(icon: "terminal", title: "Executable", value: $command)
                TronSettingsDivider(accent: .tronAmber)
                TronTextSettingRow(icon: "list.bullet", title: "Arguments", detail: "Optional", value: $args)
            }
            .tronSettingsCaption("The Gateway launches this exact executable without a shell. Local code is trusted separately from provider authentication.")
        } else {
            TronSettingsGroup("Remote endpoint", accent: .tronAmber) {
                TronTextSettingRow(icon: "link", title: "HTTP endpoint", value: $endpoint)
            }
            .tronSettingsCaption("Only the configured endpoint is used; redirects and unsupported MCP features remain unavailable.")
        }
    }

    private var policySection: some View {
        TronSettingsGroup("Policy", accent: .tronPurple) {
            TronToggleRow(icon: "power", title: "Enabled", isOn: $policy.enabled)
            TronSettingsDivider(accent: .tronPurple)
            TronToggleRow(icon: "arrow.right.arrow.left", title: "Allow writes", isOn: $policy.allowWrites)
            TronSettingsDivider(accent: .tronPurple)
            TronToggleRow(icon: "creditcard", title: "Paid access approved", isOn: $policy.paidAccessApproved)
            if policy.paidAccessApproved {
                TronSettingsDivider(accent: .tronPurple)
                TronNumberSettingRow(icon: "creditcard", title: "Paid budget", detail: "Cents; a positive budget is required", value: $policy.paidBudgetCents, accent: .tronPurple)
            }
            TronSettingsDivider(accent: .tronPurple)
            TronToggleRow(icon: "repeat", title: "Recurring runs approved", isOn: $policy.recurringApproved)
        }
    }

    private func complete() {
        guard mutation == nil, activity.allowsPresentationPublication else { return }
        guard !instanceID.isEmpty, !accountID.isEmpty, !credentialRef.isEmpty else { error = "Instance ID, account/server identity, and an opaque credential reference are required."; return }
        if definition.implementation == "mcp" && method == "local-command" && command.isEmpty { error = "An executable is required for local-command setup."; return }
        if definition.implementation == "mcp" && method != "local-command" && endpoint.isEmpty { error = "An HTTP endpoint is required for remote setup."; return }
        error = nil
        let requestIdentity = model.knowledgePresentationIdentity
        let instanceID = instanceID, accountID = accountID, scope = scope, credentialRef = credentialRef
        let method = method, endpoint = endpoint, command = command, args = args, policy = policy
        mutation = IntegrationMutation(identity: requestIdentity, task: Task { @MainActor in
                guard model.knowledgePresentationIdentity == requestIdentity else { throw CancellationError() }
                let begun = try await model.integrations.beginSetup(instanceID: instanceID, definitionID: definition.id, method: method)
                // Begin's receipt remains owned even after dismissal. Completion
                // is a separate command: never send it to a replacement Gateway.
                guard model.knowledgePresentationIdentity == requestIdentity else { throw CancellationError() }
                let configuration: IntegrationSetupConfiguration? = definition.implementation == "mcp"
                    ? IntegrationSetupConfiguration(
                        transport: method == "local-command" ? "stdio" : "http",
                        endpoint: method == "local-command" ? nil : endpoint,
                        command: method == "local-command" ? command : nil,
                        args: method == "local-command" ? args.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) : nil,
                        cwd: nil, env: nil
                    ) : nil
                _ = try await model.integrations.completeSetup(operationID: begun.operationId, instanceID: instanceID, providerAccountID: accountID, scope: scope.nilIfEmpty, credentialRef: credentialRef, policy: policy, configuration: configuration)
        })
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
