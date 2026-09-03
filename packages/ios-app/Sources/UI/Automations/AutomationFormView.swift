import SwiftUI

private enum AutomationTargetMode: String, CaseIterable, Identifiable {
    case existingSession, workspace
    var id: String { rawValue }
    var title: String { self == .existingSession ? "Existing Session" : "New Session in Workspace" }
}

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
    @State private var targetMode: AutomationTargetMode = .existingSession
    @State private var targetSessionID = ""
    // Workspace paths are transient form state only. They are sent to the
    // owning Gateway and are never written to iOS preferences or caches.
    @State private var workspacePath = ""
    @State private var workspaceTrustInspection: JSONValue?
    @State private var showingWorkspaceBrowser = false
    @State private var confirmingWorkspaceTrust = false
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
                LazyVStack(alignment: .leading, spacing: 18) {
                    basicsSection
                    actionSection
                    targetSection
                    scheduleSection
                    advancedSection
                    previewSection
                    gatewayAdmission
                    if let errorMessage {
                        TronInfoCard(
                            icon: "exclamationmark.triangle",
                            text: errorMessage,
                            accent: .tronError,
                            usesSemanticAccent: true
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .padding(.bottom, 32)
            }
            .tronScrollEdgeChrome()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronAutomation)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(
                        title: isEditing ? "Edit Automation" : "New Automation",
                        accent: .tronAutomation
                    )
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { requestSave() } label: {
                        TronToolbarTextLabel(saveTitle, systemImage: "checkmark", isWorking: isSaving)
                    }
                    .tronToolbarAction(accent: canSave && ownsMutationGateway ? .tronAutomation : .tronTextMuted)
                    .disabled(isSaving || !canSave || !ownsMutationGateway)
                }
            }
        }
        .tronSettingsVisualTheme(accent: .tronAutomation)
        .tronTopBlur(.sheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task { await loadExisting() }
        .tronManagedSheet(isPresented: $showingWorkspaceBrowser, identity: "automation.workspace-browser") {
            WorkspaceBrowser(shortcuts: recentWorkspaces, initialPath: workspacePath) { value in
                workspacePath = value
                workspaceTrustInspection = nil
                Task { await inspectWorkspaceTrust(value) }
            }
        }
        .tronManagedSheet(isPresented: $confirmingWorkspaceTrust, identity: "automation.workspace-trust") {
            TronConfirmationSheet(
                title: "Trust this project?",
                message: "Trusting allows project-local settings, extensions, skills, prompts, packages, and system prompt files to load when each new session runs. Trust is not a sandbox.",
                confirmTitle: "Trust",
                icon: "checkmark.shield",
                onConfirm: { Task { await setWorkspaceTrust(true) } }
            )
        }
        .task(id: trigger) {
            guard initialized else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await loadPreview()
        }
        .onChange(of: actionKind) { _, next in
            if next == .notification {
                targetMode = .existingSession
                workspacePath = ""
                workspaceTrustInspection = nil
            }
        }
        .onChange(of: targetMode) { _, _ in
            intervalAmount = min(max(intervalAmount, minimumIntervalAmount), maximumIntervalAmount)
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
        section("Basics", detail: "Name the Automation and choose where its definition lives.") {
            VStack(spacing: 0) {
                nameField
                TronSettingsDivider(accent: .tronAutomation)
                descriptionField
                if let profile = selectedEndpoint?.profile {
                    TronSettingsDivider(accent: .tronAutomation)
                    TronValueRow(
                        icon: "desktopcomputer",
                        title: "Gateway",
                        value: profile.label,
                        accent: .tronAutomation
                    ) {
                        if !isEditing, endpoints.count > 1 {
                            TronInlineMenu("Change", accent: .tronAutomation) {
                                ForEach(endpoints) { endpoint in
                                    Button(endpoint.profile.label) {
                                        selectedProfileID = endpoint.profile.id
                                        targetSessionID = sessions.first?.id ?? ""
                                        targetMode = .existingSession
                                        workspacePath = ""
                                        workspaceTrustInspection = nil
                                    }
                                }
                            }
                        }
                    }
                }
                if !isEditing {
                    TronSettingsDivider(accent: .tronAutomation)
                    TronToggleRow(
                        icon: "bolt.circle",
                        title: "Enable immediately",
                        detail: "Otherwise this is saved as a draft.",
                        accent: .tronAutomation,
                        isOn: $enabledOnSave
                    )
                }
            }
        }
    }

    private var actionSection: some View {
        section(
            "Action",
            detail: actionKind == .sessionPrompt
                ? (targetMode == .workspace ? "Send text to a new session in the selected workspace." : "Send text to the selected session.")
                : "Queue a notification associated with the selected session."
        ) {
            VStack(spacing: 0) {
                TronSegmentedControl(
                    options: AutomationActionKind.allCases.map { ($0.label, $0) },
                    selection: $actionKind,
                    accent: .tronAutomation
                )
                .padding(14)
                TronSettingsDivider(accent: .tronAutomation)
                actionEditor
                if actionKind == .sessionPrompt {
                    TronSettingsDivider(accent: .tronAutomation)
                    TronToggleRow(
                        icon: "sparkles",
                        title: "Invoke a resource",
                        detail: "Use an installed skill or prompt.",
                        accent: .tronAutomation,
                        isOn: $includesResource
                    )
                    if includesResource {
                        TronSettingsDivider(accent: .tronAutomation)
                        resourceEditor
                    }
                }
            }
        }
    }

    private var targetSection: some View {
        section(
            actionKind == .notification ? "Associated Session" : "Target",
            detail: actionKind == .notification
                ? "Notifications are associated with an existing persisted session."
                : "Choose an existing session or create a new ordinary session for every run."
        ) {
            VStack(spacing: 0) {
                if actionKind == .sessionPrompt {
                    TronSegmentedControl(
                        options: AutomationTargetMode.allCases.map { ($0.title, $0) },
                        selection: $targetMode,
                        accent: .tronAutomation
                    )
                    .padding(14)
                    TronSettingsDivider(accent: .tronAutomation)
                }
                if targetMode == .existingSession || actionKind == .notification {
                    existingSessionTarget
                } else {
                    workspaceTarget
                }
            }
        }
    }

    private var existingSessionTarget: some View {
        Group {
            if sessions.isEmpty {
                TronSettingsRow(
                    icon: "bubble.left",
                    title: "No sessions available",
                    subtitle: "Create or connect a persisted session before saving.",
                    accent: .tronAutomation
                )
            } else {
                TronValueRow(
                    icon: "bubble.left",
                    title: "Session",
                    value: selectedSessionTitle,
                    accent: .tronAutomation
                ) {
                    TronInlineMenu(targetSessionID.isEmpty ? "Choose" : "Change", accent: .tronAutomation) {
                        ForEach(sessions) { session in
                            Button(session.title) { targetSessionID = session.id }
                        }
                    }
                }
            }
        }
    }

    private var workspaceTarget: some View {
        VStack(alignment: .leading, spacing: 0) {
            TronValueRow(
                icon: "folder",
                title: "Workspace",
                value: workspaceName,
                accent: .tronAutomation
            ) {
                Button(workspacePath.isEmpty ? "Choose" : "Change") {
                    guard ownsMutationGateway else { return }
                    showingWorkspaceBrowser = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.tronAutomation)
            }
            TronSettingsRow(
                icon: "plus.bubble",
                title: "New session per run",
                subtitle: "Every occurrence creates and retains a new ordinary session.",
                accent: .tronAutomation
            )
            if let inspection = workspaceTrustInspection,
               NewSessionTrustPolicy.requiresDecision(inspection) {
                TronSettingsDivider(accent: .tronAutomation)
                Button { confirmingWorkspaceTrust = true } label: {
                    TronSettingsRow(
                        icon: "checkmark.shield",
                        title: "Project Trust",
                        subtitle: "Trust is required before project resources can run.",
                        accent: .tronAmber
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var scheduleSection: some View {
        section("Schedule", detail: "Preview uses the Gateway's canonical timezone and DST rules.") {
            VStack(spacing: 0) {
                TronSegmentedControl(
                    options: AutomationTriggerKind.allCases.map { ($0.label, $0) },
                    selection: $scheduleKind,
                    accent: .tronAutomation
                )
                .padding(14)
                TronSettingsDivider(accent: .tronAutomation)
                switch scheduleKind {
                case .once:
                    dateRow(
                        icon: "calendar.badge.clock",
                        title: "Run at",
                        selection: $onceDate,
                        components: [.date, .hourAndMinute]
                    )
                case .interval:
                    intervalRows
                case .calendar:
                    calendarRows
                }
            }
        }
    }

    private var weekdayPicker: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            Label("Days", systemImage: "calendar")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
            HStack(spacing: TronSpacing.xs) {
                ForEach(1...7, id: \.self) { day in
                    let selected = weekdays.contains(day)
                    Button {
                        if selected { weekdays.remove(day) } else { weekdays.insert(day) }
                    } label: {
                        Text(isoWeekdayLabel(day))
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        .regular.tint(Color.tronAutomation.opacity(selected ? 0.28 : 0.06)).interactive(),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .accessibilityLabel(isoWeekdayName(day))
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(14)
    }

    private var advancedSection: some View {
        section(
            "Behavior",
            detail: "Pausing stops future triggers but does not cancel work already accepted by the Gateway."
        ) {
            VStack(spacing: 0) {
                TronValueRow(
                    icon: "clock.arrow.circlepath",
                    title: "After downtime",
                    value: misfirePolicy == "latest" ? "Run latest" : "Skip missed",
                    accent: .tronAutomation
                ) {
                    TronInlineMenu("Change", accent: .tronAutomation) {
                        Button("Run latest") { misfirePolicy = "latest" }
                        Button("Skip missed") { misfirePolicy = "skip" }
                    }
                }
                TronSettingsDivider(accent: .tronAutomation)
                TronValueRow(
                    icon: "rectangle.stack.badge.play",
                    title: "While running",
                    value: overlapPolicy == "queueLatest" ? "Queue latest" : "Skip",
                    accent: .tronAutomation
                ) {
                    TronInlineMenu("Change", accent: .tronAutomation) {
                        Button("Skip") { overlapPolicy = "skip" }
                        Button("Queue latest") { overlapPolicy = "queueLatest" }
                    }
                }
                TronSettingsDivider(accent: .tronAutomation)
                TronSettingsRow(
                    icon: "timer",
                    title: "Deadline",
                    subtitle: "\(deadlineMinutes) minutes",
                    subtitleRole: .dynamicValue,
                    accent: .tronAutomation
                ) {
                    Stepper("Deadline", value: $deadlineMinutes, in: 5...1_440, step: 5)
                        .labelsHidden()
                }
            }
        }
    }

    private var previewSection: some View {
        section("Next Occurrences") {
            if isPreviewing {
                TronLoadingState(label: "Calculating schedule…", accent: .tronAutomation)
                    .padding(14)
            } else if preview.isEmpty {
                TronSettingsRow(
                    icon: "calendar.badge.minus",
                    title: "No future occurrence",
                    subtitle: "Adjust the schedule to calculate another date.",
                    accent: .tronAutomation
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(preview.enumerated()), id: \.element) { index, occurrence in
                        TronSettingsRow(
                            icon: index == 0 ? "clock.badge.checkmark" : "clock",
                            title: AutomationDateFormatting.date(occurrence),
                            accent: .tronAutomation
                        )
                        if index < preview.count - 1 {
                            TronSettingsDivider(accent: .tronAutomation)
                        }
                    }
                }
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            fieldHeader(
                title: "Name",
                icon: "textformat",
                count: name.utf8.count,
                limit: 256
            )
            TextField("Daily review", text: $name)
                .tronInlineField()
        }
        .padding(14)
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            fieldHeader(
                title: "Description",
                icon: "text.alignleft",
                count: description.utf8.count,
                limit: 2_048
            )
            TextField("Optional context", text: $description, axis: .vertical)
                .lineLimit(2...4)
                .tronInlineField()
        }
        .padding(14)
    }

    private var actionEditor: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            fieldHeader(
                title: actionKind == .sessionPrompt ? "Prompt" : "Notification",
                icon: actionKind.icon,
                count: actionContent.utf8.count,
                limit: actionContentByteLimit
            )
            TextEditor(text: $actionContent)
                .frame(minHeight: 108)
                .tronTextEditor()
        }
        .padding(14)
    }

    private var resourceEditor: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            TronSegmentedControl(
                options: [
                    ("Skill", ComposerResourceInvocation.Source.skill),
                    ("Prompt", ComposerResourceInvocation.Source.prompt),
                ],
                selection: $resourceSource,
                accent: .tronAutomation
            )
            VStack(alignment: .leading, spacing: TronSpacing.sm) {
                Label(
                    resourceSource == .skill ? "Skill name" : "Prompt name",
                    systemImage: "at"
                )
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                TextField(resourceSource == .skill ? "skill-name" : "prompt-name", text: $resourceName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .tronInlineField(monospaced: true)
                Text("Use the exact installed resource name. Shell, webhooks, extension commands, and attachments are not supported.")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private var selectedSessionTitle: String {
        sessions.first(where: { $0.id == targetSessionID })?.title ?? "Choose a session"
    }

    private var workspaceName: String {
        guard !workspacePath.isEmpty else { return "Choose a workspace" }
        let name = URL(fileURLWithPath: workspacePath).lastPathComponent
        return name.isEmpty ? "Workspace" : name
    }

    private var recentWorkspaces: [WorkspaceShortcut] {
        var seen = Set<String>()
        return sessions.compactMap { session in
            guard seen.insert(session.cwd).inserted else { return nil }
            return WorkspaceShortcut(path: session.cwd, title: session.workspaceName, icon: "clock.arrow.circlepath")
        }
    }

    private var target: GatewayAutomationTarget {
        switch targetMode {
        case .existingSession: return .existingSession(sessionID: targetSessionID)
        case .workspace: return .workspace(cwd: workspacePath, sessionPolicy: .newPerRun)
        }
    }

    private func inspectWorkspaceTrust(_ path: String) async {
        guard let trustTarget = TrustTarget(cwd: path), ownsMutationGateway else { return }
        do {
            let inspection = try await model.inspectTrust(target: trustTarget)
            guard workspacePath == path, ownsMutationGateway else { return }
            workspaceTrustInspection = inspection
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? GatewayFailure)?.message ?? "Project trust is unavailable."
        }
    }

    private func setWorkspaceTrust(_ value: Bool) async {
        guard let trustTarget = TrustTarget(cwd: workspacePath), ownsMutationGateway else { return }
        do {
            workspaceTrustInspection = try await model.setTrust(target: trustTarget, decision: value)
        } catch {
            errorMessage = (error as? GatewayFailure)?.message ?? "Unable to update project trust."
        }
    }

    private var intervalRows: some View {
        VStack(spacing: 0) {
            TronSettingsRow(
                icon: "repeat",
                title: "Interval",
                subtitle: "Every \(intervalAmount) \(intervalUnit.rawValue.lowercased())",
                subtitleRole: .dynamicValue,
                accent: .tronAutomation
            ) {
                Stepper(
                    "Interval",
                    value: $intervalAmount,
                    in: minimumIntervalAmount...maximumIntervalAmount
                )
                .labelsHidden()
            }
            TronSettingsDivider(accent: .tronAutomation)
            TronValueRow(
                icon: "clock.arrow.2.circlepath",
                title: "Unit",
                value: intervalUnit.rawValue,
                accent: .tronAutomation
            ) {
                TronInlineMenu("Change", accent: .tronAutomation) {
                    ForEach(AutomationIntervalUnit.allCases) { unit in
                        Button(unit.rawValue) { selectIntervalUnit(unit) }
                    }
                }
            }
            TronSettingsDivider(accent: .tronAutomation)
            dateRow(
                icon: "calendar.badge.clock",
                title: "Anchor",
                selection: $intervalAnchor,
                components: [.date, .hourAndMinute]
            )
        }
    }

    private var calendarRows: some View {
        VStack(spacing: 0) {
            weekdayPicker
            TronSettingsDivider(accent: .tronAutomation)
            dateRow(
                icon: "clock",
                title: "Local time",
                selection: $localTime,
                components: [.hourAndMinute]
            )
            TronSettingsDivider(accent: .tronAutomation)
            timezoneField
            TronSettingsDivider(accent: .tronAutomation)
            Button { timezone = TimeZone.current.identifier } label: {
                TronSettingsRow(
                    icon: "location",
                    title: "Use current timezone",
                    subtitle: TimeZone.current.identifier,
                    accent: .tronAutomation
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var timezoneField: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            Label("IANA timezone", systemImage: "globe")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
            TextField("America/New_York", text: $timezone)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .tronInlineField(monospaced: true)
        }
        .padding(14)
    }

    private func dateRow(
        icon: String,
        title: String,
        selection: Binding<Date>,
        components: DatePickerComponents
    ) -> some View {
        TronSettingsRow(icon: icon, title: title, accent: .tronAutomation) {
            DatePicker("", selection: selection, displayedComponents: components)
                .labelsHidden()
        }
    }

    private func fieldHeader(title: String, icon: String, count: Int, limit: Int) -> some View {
        HStack(spacing: TronSpacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(Color.tronAutomation)
                .frame(width: 22)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
            Spacer(minLength: TronSpacing.md)
            Text("\(count) / \(limit)")
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(count > limit ? Color.tronError : Color.tronTextMuted)
        }
    }

    private func selectIntervalUnit(_ unit: AutomationIntervalUnit) {
        intervalUnit = unit
        intervalAmount = min(max(intervalAmount, minimumIntervalAmount), maximumIntervalAmount)
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
        if targetMode == .workspace && intervalUnit == .seconds { return 86_400 }
        if targetMode == .workspace { return max(1, (86_400 + intervalUnit.seconds - 1) / intervalUnit.seconds) }
        return intervalUnit == .seconds ? 60 : 1
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
        let targetIsValid = switch target {
        case let .existingSession(sessionID): AutomationAdmissionPolicy.validSessionID(sessionID)
        case let .workspace(cwd, _): AutomationAdmissionPolicy.validWorkspacePath(cwd)
        }
        let intervalIsValid = targetMode == .existingSession
            || AutomationAdmissionPolicy.admitsNewSessionInterval(trigger)
        return !trimmedName.isEmpty
            && trimmedName.utf8.count <= 256
            && description.utf8.count <= 2_048
            && !actionContent.isEmpty
            && actionContent.utf8.count <= actionContentByteLimit
            && targetIsValid
            && resourceIsValid
            && scheduleIsValid
            && intervalIsValid
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
            target: target,
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
            switch record.target {
            case let .existingSession(sessionID):
                targetMode = .existingSession
                targetSessionID = sessionID
                workspacePath = ""
            case let .workspace(cwd, _):
                targetMode = .workspace
                workspacePath = cwd
                targetSessionID = ""
                await inspectWorkspaceTrust(cwd)
            }
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
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        TronSettingsGroup(title, detail: detail, accent: .tronAutomation) { content() }
    }
}
