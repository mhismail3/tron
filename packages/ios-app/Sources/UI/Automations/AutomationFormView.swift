import SwiftUI

private enum AutomationIntervalUnit: String, CaseIterable, Identifiable {
    case seconds = "Seconds"
    case minutes = "Minutes"
    case hours = "Hours"
    case days = "Days"
    case weeks = "Weeks"

    var id: String { rawValue }
    var seconds: Int {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 3_600
        case .days: 86_400
        case .weeks: 604_800
        }
    }
}

struct AutomationFormView: View {
    let selection: AutomationSummarySelection?
    let onSaved: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProfileID = ""
    @State private var name = ""
    @State private var description = ""
    @State private var actionKind: AutomationActionKind = .sessionPrompt
    @State private var actionContent = ""
    @State private var targetSessionID = ""
    @State private var includesResource = false
    @State private var resourceSource: ComposerResourceInvocation.Source = .skill
    @State private var resourceName = ""
    @State private var scheduleKind: AutomationTriggerKind = .once
    @State private var onceDate = Date.now.addingTimeInterval(3_600)
    @State private var intervalAmount = 1
    @State private var intervalUnit: AutomationIntervalUnit = .hours
    @State private var intervalAnchor = Date.now
    @State private var localTime = Date.now
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var timezone = TimeZone.current.identifier
    @State private var misfirePolicy = "latest"
    @State private var overlapPolicy = "skip"
    @State private var deadlineMinutes = 60
    @State private var enabledOnSave = false
    @State private var loadedRevision: Int?
    @State private var loadedActivation: AutomationActivation?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var preview: [String] = []
    @State private var isPreviewing = false
    @State private var initialized = false
    @State private var confirmingSave = false

    private var isEditing: Bool { selection != nil }
    private var endpoints: [AutomationGatewayEndpoint] {
        model.automationCatalog.allEndpoints().filter {
            $0.profile.capabilities.contains(AutomationAdmissionPolicy.capability)
        }
    }
    private var selectedEndpoint: AutomationGatewayEndpoint? {
        model.automationCatalog.endpoint(for: selectedProfileID)
    }
    private var client: AutomationRPCClient? { selectedEndpoint?.client }
    private var ownsMutationGateway: Bool {
        selectedProfileID == model.profiles.selected?.id
            && model.connectionState == .connected
            && selectedEndpoint?.profile.capabilities.contains(AutomationAdmissionPolicy.capability) == true
    }
    private var sessions: [SessionSummary] {
        model.visibleSessions.filter { session in
            session.gatewayProfileID == selectedProfileID
                || (session.gatewayProfileID == nil && selectedProfileID == model.profiles.selected?.id)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TronSpacing.lg) {
                    basicsSection
                    actionSection
                    targetSection
                    scheduleSection
                    advancedSection
                    previewSection
                    gatewayAdmission
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronError)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .padding(.bottom, 32)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle(isEditing ? "Edit Automation" : "New Automation", accent: .tronCoral)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { requestSave() } label: {
                        TronToolbarTextLabel(saveTitle, systemImage: "checkmark", isWorking: isSaving)
                    }
                    .tronToolbarAction(accent: canSave && ownsMutationGateway ? .tronCoral : .tronTextMuted)
                    .disabled(isSaving || !canSave || !ownsMutationGateway)
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task { await loadExisting() }
        .task(id: trigger) {
            guard initialized else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await loadPreview()
        }
        .onChange(of: model.profileRevision) { _, _ in
            if !selectedProfileID.isEmpty,
               !model.profiles.profiles.contains(where: { $0.id == selectedProfileID }) {
                dismiss()
            }
        }
        .alert(isEditing ? "Save changes?" : "Enable automation?", isPresented: $confirmingSave) {
            Button(isEditing ? "Save" : "Enable") { Task { await save() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isEditing
                 ? "This definition is active. Its revised schedule may become due immediately."
                 : "The first occurrence may become due immediately. Review the action and target before enabling it.")
        }
        .tronManagedSystemPresentation(
            isPresented: $confirmingSave,
            identity: "automation.definition-confirmation"
        )
    }

    private var basicsSection: some View {
        section("Basics", icon: "square.and.pencil") {
            TextField("Name", text: $name)
                .tronField()
            Text("\(name.utf8.count) / 256 bytes")
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(name.utf8.count > 256 ? Color.tronError : Color.tronTextMuted)
            TextField("Description (optional)", text: $description, axis: .vertical)
                .lineLimit(2...5)
                .tronField()
            Text("\(description.utf8.count) / 2,048 bytes")
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(description.utf8.count > 2_048 ? Color.tronError : Color.tronTextMuted)
            if !isEditing, endpoints.count > 1 {
                Picker("Gateway", selection: $selectedProfileID) {
                    ForEach(endpoints) { endpoint in
                        Text(endpoint.profile.label).tag(endpoint.profile.id)
                    }
                }
                .onChange(of: selectedProfileID) { _, _ in targetSessionID = sessions.first?.id ?? "" }
            } else if let profile = selectedEndpoint?.profile {
                Label("Gateway: \(profile.label)", systemImage: "desktopcomputer")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
            }
            if !isEditing {
                Toggle("Enable immediately", isOn: $enabledOnSave)
                    .tint(Color.tronCoral)
            }
        }
    }

    private var actionSection: some View {
        section("What happens", icon: "bolt") {
            TronSegmentedControl(
                options: AutomationActionKind.allCases.map { ($0.label, $0) },
                selection: $actionKind
            )
            TextEditor(text: $actionContent)
                .frame(minHeight: 132)
                .tronTextEditor()
            let maximum = actionContentByteLimit
            Text("\(actionContent.utf8.count) / \(maximum) bytes")
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(actionContent.utf8.count > maximum ? Color.tronError : Color.tronTextMuted)
            if actionKind == .sessionPrompt {
                Toggle("Invoke a skill or prompt resource", isOn: $includesResource)
                    .tint(Color.tronCoral)
                if includesResource {
                    TronSegmentedControl(
                        options: [
                            ("Skill", ComposerResourceInvocation.Source.skill),
                            ("Prompt", ComposerResourceInvocation.Source.prompt),
                        ],
                        selection: $resourceSource
                    )
                    TextField(resourceSource == .skill ? "Skill name" : "Prompt name", text: $resourceName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .tronField(monospaced: true)
                    Text("Use the exact installed resource name. Extension commands, shell, webhooks, and attachments cannot be automated.")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextMuted)
                }
            }
        }
    }

    private var targetSection: some View {
        section(actionKind == .notification ? "Associated session" : "Target session", icon: "bubble.left") {
            if sessions.isEmpty {
                Text("No persisted user sessions are available on this Gateway.")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronAmber)
            } else {
                Picker("Session", selection: $targetSessionID) {
                    Text("Choose a session").tag("")
                    if !targetSessionID.isEmpty, !sessions.contains(where: { $0.id == targetSessionID }) {
                        Text("Current target · \(targetSessionID)").tag(targetSessionID)
                    }
                    ForEach(sessions) { session in Text(session.title).tag(session.id) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var scheduleSection: some View {
        section("Schedule", icon: "calendar") {
            TronSegmentedControl(
                options: AutomationTriggerKind.allCases.map { ($0.label, $0) },
                selection: $scheduleKind
            )
            switch scheduleKind {
            case .once:
                DatePicker("Run at", selection: $onceDate, displayedComponents: [.date, .hourAndMinute])
            case .interval:
                HStack {
                    Stepper(
                        "Every \(intervalAmount)",
                        value: $intervalAmount,
                        in: minimumIntervalAmount...maximumIntervalAmount
                    )
                    Picker("Unit", selection: $intervalUnit) {
                        ForEach(AutomationIntervalUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: intervalUnit) { _, _ in
                        intervalAmount = min(max(intervalAmount, minimumIntervalAmount), maximumIntervalAmount)
                    }
                }
                DatePicker("Anchor", selection: $intervalAnchor, displayedComponents: [.date, .hourAndMinute])
            case .calendar:
                weekdayPicker
                DatePicker("Local time", selection: $localTime, displayedComponents: .hourAndMinute)
                TextField("IANA timezone", text: $timezone)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .tronField(monospaced: true)
                Button("Use current timezone") { timezone = TimeZone.current.identifier }
                    .buttonStyle(TronRowButtonStyle(accent: .tronCoral))
            }
        }
    }

    private var weekdayPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Days")
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextMuted)
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    Button {
                        if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                    } label: {
                        Text(isoWeekdayLabel(day)).frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(TronRowButtonStyle(accent: weekdays.contains(day) ? .tronCoral : .tronTextMuted))
                    .accessibilityLabel(isoWeekdayName(day))
                    .accessibilityValue(weekdays.contains(day) ? "Selected" : "Not selected")
                    .accessibilityAddTraits(weekdays.contains(day) ? .isSelected : [])
                }
            }
        }
    }

    private var advancedSection: some View {
        section("Advanced behavior", icon: "slider.horizontal.3") {
            Picker("After downtime", selection: $misfirePolicy) {
                Text("Run latest").tag("latest")
                Text("Skip missed").tag("skip")
            }
            Picker("While already running", selection: $overlapPolicy) {
                Text("Skip").tag("skip")
                Text("Queue latest").tag("queueLatest")
            }
            Stepper("Deadline: \(deadlineMinutes) minutes", value: $deadlineMinutes, in: 5...1_440, step: 5)
            Text("Pausing stops future triggers. It does not cancel work already accepted by the Gateway.")
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextMuted)
        }
    }

    private var previewSection: some View {
        section("Next occurrences", icon: "clock") {
            if isPreviewing {
                TronLoadingState(label: "Calculating schedule…", accent: .tronCoral)
            } else if preview.isEmpty {
                Text("No future occurrence is available for this schedule.")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextMuted)
            } else {
                ForEach(preview, id: \.self) {
                    Text(AutomationDateFormatting.date($0))
                        .font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var gatewayAdmission: some View {
        if !ownsMutationGateway, let profile = model.profiles.profiles.first(where: { $0.id == selectedProfileID }) {
            TronInfoCard(
                icon: "arrow.triangle.2.circlepath",
                text: "Use \(profile.label) before saving. This keeps the command receipt on the exact owning Gateway.",
                accent: .tronAmber
            )
            Button("Use This Gateway") { Task { await model.switchGateway(profile) } }
                .buttonStyle(TronActionButtonStyle(role: .primary))
        }
    }

    private var saveTitle: String {
        if isEditing { return "Save" }
        return enabledOnSave ? "Enable" : "Save Draft"
    }

    private var minimumIntervalAmount: Int {
        intervalUnit == .seconds ? 60 : 1
    }

    private var maximumIntervalAmount: Int {
        max(minimumIntervalAmount, 31_536_000 / intervalUnit.seconds)
    }

    private var actionContentByteLimit: Int {
        if actionKind == .notification { return 512 }
        return includesResource ? ComposerResourceInvocation.maximumArgumentBytes : 65_536
    }

    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceIsValid = !includesResource || (
            actionKind == .sessionPrompt
                && resourceInvocation?.isTransportValid == true
        )
        let scheduleIsValid = scheduleKind != .calendar
            || (!weekdays.isEmpty && TimeZone(identifier: timezone) != nil)
        return !trimmedName.isEmpty
            && trimmedName.utf8.count <= 256
            && description.utf8.count <= 2_048
            && !actionContent.isEmpty
            && actionContent.utf8.count <= actionContentByteLimit
            && !targetSessionID.isEmpty
            && resourceIsValid
            && scheduleIsValid
            && AutomationAdmissionPolicy.admits(trigger)
    }

    private var trigger: GatewayAutomationTrigger {
        switch scheduleKind {
        case .once:
            return GatewayAutomationTrigger(kind: "once", at: GatewayTimestamp.string(from: onceDate))
        case .interval:
            return GatewayAutomationTrigger(
                kind: "interval",
                everySeconds: intervalAmount * intervalUnit.seconds,
                anchorAt: GatewayTimestamp.string(from: intervalAnchor)
            )
        case .calendar:
            let components = Calendar.current.dateComponents([.hour, .minute], from: localTime)
            let value = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
            return GatewayAutomationTrigger(
                kind: "calendar",
                timezone: timezone,
                localTime: value,
                weekdays: weekdays.sorted()
            )
        }
    }

    private var resourceInvocation: ComposerResourceInvocation? {
        guard actionKind == .sessionPrompt, includesResource else { return nil }
        return ComposerResourceInvocation(
            source: resourceSource,
            name: resourceName,
            arguments: actionContent
        )
    }

    private var definition: AutomationDefinitionDraft {
        AutomationDefinitionDraft(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.isEmpty ? nil : description,
            activation: isEditing ? nil : (enabledOnSave ? "enabled" : "draft"),
            targetSessionId: targetSessionID,
            trigger: trigger,
            misfirePolicy: misfirePolicy,
            overlapPolicy: overlapPolicy,
            executionDeadlineSeconds: deadlineMinutes * 60,
            action: GatewayAutomationAction(
                kind: actionKind.rawValue,
                text: actionKind == .sessionPrompt ? actionContent : nil,
                message: actionKind == .notification ? actionContent : nil,
                resourceInvocation: resourceInvocation
            )
        )
    }

    private func requestSave() {
        guard canSave, ownsMutationGateway else { return }
        if enabledOnSave || loadedActivation == .enabled { confirmingSave = true }
        else { Task { await save() } }
    }

    private func loadExisting() async {
        guard !initialized else { return }
        initialized = true
        selectedProfileID = selection?.profileID ?? model.profiles.selected?.id ?? endpoints.first?.profile.id ?? ""
        guard let selection, let client else {
            targetSessionID = sessions.first?.id ?? ""
            await loadPreview()
            return
        }
        do {
            let record = try await client.get(id: selection.summary.id)
            loadedRevision = record.revision
            loadedActivation = record.activation
            name = record.name
            description = record.description ?? ""
            targetSessionID = record.targetSessionId
            actionKind = record.action.typedKind ?? .sessionPrompt
            actionContent = record.action.content
            if let invocation = record.action.resourceInvocation {
                includesResource = true
                resourceSource = invocation.source
                resourceName = invocation.name
            }
            misfirePolicy = record.misfirePolicy
            overlapPolicy = record.overlapPolicy
            deadlineMinutes = max(5, record.executionDeadlineSeconds / 60)
            scheduleKind = record.trigger.typedKind ?? .once
            timezone = record.trigger.timezone ?? TimeZone.current.identifier
            weekdays = Set(record.trigger.weekdays ?? Array(weekdays))
            if let at = record.trigger.at, let date = GatewayTimestamp.parse(at) { onceDate = date }
            if let anchor = record.trigger.anchorAt, let date = GatewayTimestamp.parse(anchor) { intervalAnchor = date }
            setInterval(record.trigger.everySeconds ?? 3_600)
            if let storedTime = record.trigger.localTime { setLocalTime(storedTime) }
            await loadPreview()
        } catch {
            errorMessage = (error as? GatewayFailure)?.message ?? "Unable to load automation."
        }
    }

    private func loadPreview() async {
        guard initialized, let client, AutomationAdmissionPolicy.admits(trigger) else {
            preview = []
            return
        }
        isPreviewing = true
        defer { isPreviewing = false }
        do {
            preview = try await client.preview(trigger: trigger, limit: 5).occurrences
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            preview = []
            errorMessage = (error as? GatewayFailure)?.message ?? "Schedule preview is unavailable."
        }
    }

    private func save() async {
        guard let client, canSave, ownsMutationGateway else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if let selection {
                guard let loadedRevision else { return }
                _ = try await client.update(id: selection.summary.id, revision: loadedRevision, definition: definition)
            } else {
                _ = try await client.create(definition: definition)
            }
            model.automationCatalog.invalidate(profileID: selectedProfileID)
            onSaved()
            dismiss()
        } catch let failure as GatewayFailure where failure.code == "conflict" {
            errorMessage = "This Automation changed elsewhere. Your draft is preserved. Close and reopen it to review the latest definition before saving again."
        } catch {
            errorMessage = (error as? GatewayFailure)?.message ?? "Unable to save automation."
        }
    }

    private func setInterval(_ seconds: Int) {
        for unit in [AutomationIntervalUnit.weeks, .days, .hours, .minutes]
            where seconds.isMultiple(of: unit.seconds) {
            intervalUnit = unit
            intervalAmount = max(1, seconds / unit.seconds)
            return
        }
        intervalUnit = .seconds
        intervalAmount = max(60, seconds)
    }

    private func setLocalTime(_ value: String) {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2,
              let date = Calendar.current.date(from: DateComponents(hour: parts[0], minute: parts[1])) else { return }
        localTime = date
    }

    private func isoWeekdayLabel(_ day: Int) -> String {
        let sundayFirst = Calendar.current.veryShortWeekdaySymbols
        return sundayFirst[(day % 7)]
    }

    private func isoWeekdayName(_ day: Int) -> String {
        let sundayFirst = Calendar.current.weekdaySymbols
        return sundayFirst[(day % 7)]
    }

    private func section<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        TronSettingsGroup(title, accent: .tronCoral) { content() }
    }
}
