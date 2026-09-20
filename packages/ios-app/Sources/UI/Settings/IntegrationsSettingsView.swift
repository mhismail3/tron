import SwiftUI

/// Unified presentation over the Gateway connection owner. This view never
/// stores an authority or credential: every instance action carries its opaque
/// connection ID to the owner and every read is fenced to the current Gateway
/// profile, lifecycle generation, and connection epoch.
struct IntegrationsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @State private var snapshot: IntegrationSnapshot?
    @State private var identity: KnowledgePresentationIdentity?
    @State private var loadGeneration = 0
    @State private var isLoading = false
    @State private var error: String?
    @State private var setupDefinition: IntegrationDefinition?
    @State private var selectedInstance: IntegrationInstance?
    @State private var disconnectInstance: IntegrationInstance?
    @State private var actionMessage: String?

    var body: some View {
        KnowledgeFormSheet(title: "Integrations") {
            if let snapshot {
                ForEach(snapshot.definitions) { definition in
                    definitionSection(definition, snapshot: snapshot)
                }
                if snapshot.definitions.isEmpty {
                    TronSettingsNotice(message: "No supported integrations are available on this Gateway.", accent: .tronAmber)
                }
            } else if isLoading {
                HStack { Spacer(); ProgressView("Loading integrations…"); Spacer() }
                    .padding(.vertical, 28)
            }
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
            if let actionMessage { TronSettingsCaption(actionMessage) }
        }
        .task(id: PresentationActivityTaskID(source: "integrations/\(model.knowledgePresentationIdentity)", presentationActive: activity.allowsPresentationPublication)) {
            guard activity.allowsPresentationPublication else { return }
            load()
        }
        .onChange(of: activity.allowsPresentationPublication) { _, active in
            if !active { loadGeneration &+= 1; isLoading = false }
        }
        .tronManagedSheet(isPresented: Binding(get: { setupDefinition != nil }, set: { if !$0 { setupDefinition = nil } }), identity: "integrations.setup") {
            if let definition = setupDefinition {
                IntegrationSetupView(definition: definition) { self.setupDefinition = nil }
                    .environment(model)
            }
        }
        .tronManagedSheet(isPresented: Binding(get: { selectedInstance != nil }, set: { if !$0 { selectedInstance = nil } }), identity: "integrations.instance") {
            if let instance = selectedInstance {
                IntegrationInstanceView(instance: instance, definition: snapshot?.definitions.first { $0.id == instance.definitionId }) {
                    self.selectedInstance = nil
                    load()
                }
                .environment(model)
            }
        }
        .confirmationDialog(
            "Disconnect this account?",
            isPresented: Binding(get: { disconnectInstance != nil }, set: { if !$0 { disconnectInstance = nil } }),
            presenting: disconnectInstance
        ) { instance in
            Button("Disconnect", role: .destructive) { disconnect(instance) }
            Button("Cancel", role: .cancel) {}
        } message: { instance in
            Text("Future calls will be disabled for connection \(instance.id). Existing provider data is not deleted.")
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
            TronSettingsRow(icon: "plus.circle", title: "Add account or server", subtitle: setupSummary(definition)) {
                Button { setupDefinition = definition } label: { TronInlineActionLabel("Set up") }
                    .buttonStyle(.plain)
            }
        }
        .tronSettingsCaption(capabilityCaption(definition: definition, snapshot: snapshot))
    }

    @ViewBuilder
    private func instanceRow(_ instance: IntegrationInstance, definition: IntegrationDefinition, snapshot: IntegrationSnapshot) -> some View {
        let statuses = snapshot.capabilities.filter { $0.connectionId == instance.id }
        TronSettingsRow(
            icon: instance.health == "ready" ? "checkmark.circle" : "exclamationmark.circle",
            title: instance.providerAccountId,
            subtitle: "\(healthLabel(instance.health)) · \(instance.id)",
            subtitleLineLimit: 2,
            accent: instance.health == "ready" ? .tronEmerald : .tronAmber
        ) {
            Button { selectedInstance = instance } label: { TronInlineActionLabel("Manage") }.buttonStyle(.plain)
        }
        ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
            TronSettingsRow(icon: capabilityIcon(status.availability), title: status.id, subtitle: capabilityDetail(status))
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
                identity = requestIdentity; snapshot = loaded; isLoading = false
            } catch is CancellationError {
                if ticket == loadGeneration { isLoading = false }
            } catch {
                guard IntegrationPresentationAdmission.admits(
                    presentationActive: activity.allowsPresentationPublication,
                    currentIdentity: model.knowledgePresentationIdentity,
                    requestedIdentity: requestIdentity,
                    currentRequest: loadGeneration,
                    requestedRequest: ticket
                ) else { return }
                isLoading = false; snapshot = nil; self.error = error.localizedDescription
            }
        }
    }

    private func disconnect(_ instance: IntegrationInstance) {
        disconnectInstance = nil
        let requestIdentity = identity ?? model.knowledgePresentationIdentity
        Task { @MainActor in
            do {
                _ = try await model.integrations.disconnect(instanceID: instance.id)
                guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
                actionMessage = "Disconnected \(instance.providerAccountId)."; load()
            } catch { actionMessage = error.localizedDescription }
        }
    }

    private func setupSummary(_ definition: IntegrationDefinition) -> String {
        definition.implementation == "mcp" ? "Connect a trusted HTTP endpoint or local command" : "Use the Mac-owned credential reference"
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
    private func capabilityIcon(_ availability: String) -> String {
        availability == "available" ? "checkmark.circle" : availability == "unsupported" ? "minus.circle" : "exclamationmark.triangle"
    }
    private func capabilityDetail(_ status: IntegrationCapabilityStatus) -> String {
        if let detail = status.detail, !detail.isEmpty { return detail }
        return availabilityLabel(status.availability) + (status.effects.isEmpty ? "" : " · " + status.effects.joined(separator: ", "))
    }
    private func availabilityLabel(_ value: String) -> String {
        switch value { case "available": "Available"; case "requires-setup": "Setup required"; case "disabled": "Disabled"; case "unsupported": "Unsupported"; default: "Unavailable" }
    }
}

private struct IntegrationInstanceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    let instance: IntegrationInstance
    let definition: IntegrationDefinition?
    let onChanged: () -> Void
    @State private var policy: IntegrationPolicy
    @State private var saving = false
    @State private var error: String?

    init(instance: IntegrationInstance, definition: IntegrationDefinition?, onChanged: @escaping () -> Void) {
        self.instance = instance; self.definition = definition; self.onChanged = onChanged
        _policy = State(initialValue: instance.policy)
    }

    var body: some View {
        KnowledgeFormSheet(title: definition?.displayName ?? "Connection", isWorking: saving, onAction: save) {
            TronSettingsGroup("Connection", accent: .tronBlue) {
                TronSettingsRow(icon: "person.crop.circle", title: "Account", subtitle: instance.providerAccountId)
                if let scope = instance.scope {
                    TronSettingsDivider(accent: .tronBlue)
                    TronSettingsRow(icon: "scope", title: "Scope", subtitle: scope)
                }
                TronSettingsDivider(accent: .tronBlue)
                TronSettingsRow(icon: "number", title: "Connection ID", subtitle: instance.id)
            }
            TronSettingsGroup("Policy", accent: .tronPurple) {
                TronToggleRow(icon: "power", title: "Enabled", isOn: $policy.enabled)
                TronSettingsDivider(accent: .tronPurple)
                TronToggleRow(icon: "arrow.right.arrow.left", title: "Allow writes", isOn: $policy.allowWrites)
                TronSettingsDivider(accent: .tronPurple)
                TronToggleRow(icon: "creditcard", title: "Paid access approved", isOn: $policy.paidAccessApproved)
                TronSettingsDivider(accent: .tronPurple)
                TronToggleRow(icon: "repeat", title: "Recurring runs approved", isOn: $policy.recurringApproved)
            }
            .tronSettingsCaption("Policy is independent per connection instance. Changing it does not install packages or silently reload a runtime.")
            if let lastError = instance.lastError { TronSettingsNotice(message: lastError, accent: .tronAmber) }
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
            Button("Disconnect", role: .destructive) { disconnect() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func save() {
        guard !saving, policy != instance.policy else { dismiss(); return }
        saving = true; error = nil
        let requestIdentity = model.knowledgePresentationIdentity
        Task { @MainActor in
            do {
                _ = try await model.integrations.updatePolicy(instanceID: instance.id, policy: policy)
                guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
                saving = false; onChanged(); dismiss()
            } catch is CancellationError { saving = false }
            catch { saving = false; self.error = error.localizedDescription }
        }
    }

    private func disconnect() {
        saving = true
        Task { @MainActor in
            do { _ = try await model.integrations.disconnect(instanceID: instance.id); saving = false; onChanged(); dismiss() }
            catch { saving = false; self.error = error.localizedDescription }
        }
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
    @State private var operation: IntegrationSetupStarted?
    @State private var saving = false
    @State private var error: String?

    init(definition: IntegrationDefinition, onFinished: @escaping () -> Void) {
        self.definition = definition; self.onFinished = onFinished
        _method = State(initialValue: definition.setupMethods.first ?? "token")
    }

    var body: some View {
        KnowledgeFormSheet(title: "Set up \(definition.displayName)", isWorking: saving, onAction: operation == nil ? { complete() } : nil) {
            if operation == nil {
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
                TronSettingsGroup("Secure credential handoff", accent: .tronPurple) {
                    TronTextSettingRow(icon: "key", title: "Opaque Keychain reference", value: $credentialRef)
                }
                .tronSettingsCaption("Enter only the opaque reference created by the Mac credential owner. Never enter a token or secret here.")
                policySection
            } else {
                TronSettingsNotice(message: "Setup is ready to complete. The credential value remains in the Mac-owned secure store.", accent: .tronEmerald)
                ProgressView("Completing setup…")
            }
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
        }
        .onDisappear { if operation != nil { /* accepted completion remains owner-owned */ } }
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
            TronSettingsDivider(accent: .tronPurple)
            TronToggleRow(icon: "repeat", title: "Recurring runs approved", isOn: $policy.recurringApproved)
        }
    }

    private func complete() {
        guard !saving else { return }
        guard !instanceID.isEmpty, !accountID.isEmpty, !credentialRef.isEmpty else { error = "Instance ID, account/server identity, and an opaque credential reference are required."; return }
        if definition.implementation == "mcp" && method == "local-command" && command.isEmpty { error = "An executable is required for local-command setup."; return }
        if definition.implementation == "mcp" && method != "local-command" && endpoint.isEmpty { error = "An HTTP endpoint is required for remote setup."; return }
        saving = true; error = nil
        let requestIdentity = model.knowledgePresentationIdentity
        Task { @MainActor in
            do {
                let begun = try await model.integrations.beginSetup(instanceID: instanceID, definitionID: definition.id, method: method)
                // Begin accepted the owner operation. Continue the exact
                // operation even if the sheet is dismissed or the Gateway
                // reconnects; only the final presentation publication is
                // fenced below.
                operation = begun
                let configuration: IntegrationSetupConfiguration? = definition.implementation == "mcp"
                    ? IntegrationSetupConfiguration(
                        transport: method == "local-command" ? "stdio" : "http",
                        endpoint: method == "local-command" ? nil : endpoint,
                        command: method == "local-command" ? command : nil,
                        args: method == "local-command" ? args.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) : nil,
                        cwd: nil, env: nil
                    ) : nil
                _ = try await model.integrations.completeSetup(operationID: begun.operationId, instanceID: instanceID, providerAccountID: accountID, scope: scope.nilIfEmpty, credentialRef: credentialRef, policy: policy, configuration: configuration)
                guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
                saving = false; onFinished(); dismiss()
            } catch is CancellationError { saving = false }
            catch { saving = false; self.error = error.localizedDescription }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
