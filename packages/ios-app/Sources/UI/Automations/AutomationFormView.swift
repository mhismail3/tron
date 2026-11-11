import SwiftUI
import TronMobileCore

enum AutomationWorkspacePathPolicy {
    static func initialPath(selectedPath: String) -> String? {
        selectedPath.isEmpty ? nil : selectedPath
    }
}

private enum AutomationTargetMode: String, CaseIterable, Identifiable {
    case workspace, existingSession, home
    var id: String { rawValue }
    var title: String {
        switch self { case .workspace: "New Session in Workspace"; case .existingSession: "Existing Session"; case .home: "Home" }
    }
}

enum AutomationDateField: String, Identifiable {
    case once, intervalAnchor, localTime

    var id: String { rawValue }
    var title: String {
        switch self {
        case .once: "Run at"
        case .intervalAnchor: "Anchor"
        case .localTime: "Local time"
        }
    }
}

struct AutomationDateSelection: Identifiable {
    let field: AutomationDateField
    let component: TronDateComponent
    var id: String { "\(field.id).\(component.rawValue)" }
}

struct AutomationSessionPickerSheet: View {
    let sessions: [CatalogSession]
    let selectedID: String
    let onSelect: (CatalogSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @PresentationState private var search = ""

    private var filteredSessions: [CatalogSession] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                TronSettingsSections(alignment: .leading, spacing: 18, lazy: true) {
                    TextField("Search sessions", text: $search).tronInlineField()
                    if filteredSessions.isEmpty {
                        TronPlaceholderState(title: sessions.isEmpty ? "No sessions available" : "No matching sessions", detail: sessions.isEmpty ? "Create or connect a persisted session before saving." : "Try another session or workspace name.", icon: "bubble.left.and.bubble.right")
                            .frame(minHeight: 260)
                    } else {
                        ForEach(SessionListWorkspaceGroup.groups(from: filteredSessions)) { group in
                            TronSettingsGroup(group.name) {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                                        if index > 0 { TronSettingsDivider() }
                                        row(session)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Choose Session", accent: .tronPrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark").tronToolbarAction(accent: .tronPrimary) }.accessibilityLabel("Cancel")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tronSettingsLayout()
        .tronSettingsVisualTheme(accent: .tronPrimary, surfaceAccent: .tronPrimarySurface)
    }

    private func row(_ session: CatalogSession) -> some View {
        let selected = session.id == selectedID
        return Button {
            onSelect(session)
            dismiss()
        } label: {
            TronSettingsRow(icon: "bubble.left", title: session.title,
                            subtitle: URL(fileURLWithPath: session.cwd).lastPathComponent) {
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.tronPrimary) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(session.title)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
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
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.scenePhase) private var scenePhase
    @PresentationState private var selectedProfileID = ""
    @PresentationState private var name = ""
    @PresentationState private var description = ""
    @PresentationState private var actionKind: AutomationActionKind = .sessionPrompt
    @PresentationState private var actionContent = ""
    @PresentationState private var targetMode: AutomationTargetMode = .workspace
    @PresentationState private var targetSessionID = ""
    @PresentationState private var homeTargetStatus: HomeStatus?
    @PresentationState private var savedHomeTarget: GatewayAutomationTarget?
    @PresentationState private var archivedTargetTitle: String?
    @PresentationState private var editingDateField: AutomationDateSelection?
    @PresentationState private var workspacePath = ""
    @PresentationState private var workspaceTrustInspection: JSONValue?
    @PresentationState private var showingWorkspaceBrowser = false
    @PresentationState private var showingSessionPicker = false
    @PresentationState private var confirmingWorkspaceTrust = false
    @PresentationState private var includesResource = false
    @PresentationState private var resourceSource: ComposerResourceInvocation.Source = .skill
    @PresentationState private var resourceName = ""
    @PresentationState private var scheduleKind: AutomationTriggerKind = .once
    @PresentationState private var onceDate = Date.now.addingTimeInterval(3_600)
    @PresentationState private var intervalAmount = 1
    @PresentationState private var intervalUnit: AutomationIntervalUnit = .hours
    @PresentationState private var intervalAnchor = Date.now
    @PresentationState private var localTime = Date.now
    @PresentationState private var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    @PresentationState private var timezone = TimeZone.current.identifier
    @PresentationState private var misfirePolicy = "latest"
    @PresentationState private var overlapPolicy = "skip"
    @PresentationState private var deadlineMinutes = 60
    @PresentationState private var enabledOnSave = false
    @PresentationState private var loadedRevision: Int?
    @PresentationState private var loadedActivation: AutomationActivation?
    @PresentationState private var isSaving = false
    @PresentationState private var errorMessage: String?
    @PresentationState private var preview: [String] = []
    @PresentationState private var isPreviewing = false
    @PresentationState private var previewGeneration = 0
    @PresentationState private var presentationReadGeneration = 0
    @PresentationState private var trustReadGeneration = 0
    @PresentationState private var initialized = false
    @PresentationState private var confirmingSave = false

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
            && !model.isReconcilingForeground
            && selectedEndpoint?.profile.capabilities.contains(AutomationAdmissionPolicy.capability) == true
    }
    private var sessions: [CatalogSession] {
        model.visibleSessions.filter { session in
            session.gatewayProfileID == selectedProfileID
                || (session.gatewayProfileID == nil && selectedProfileID == model.profiles.selected?.id)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                TronSettingsSections(alignment: .leading, spacing: 18) {
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
            .scrollDismissesKeyboard(.interactively)
            .tronScrollEdgeChrome()
            .tronNavigationTitle(
                isEditing ? "Edit Automation" : "New Automation"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: .tronPrimary)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { requestSave() } label: {
                        if isSaving {
                            TronPulseLoadingIndicator(accent: .tronPrimary, size: 18)
                        } else {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                        }
                    }
                    .tronToolbarAction(accent: .tronPrimary)
                    .disabled(isSaving || !canSave || !ownsMutationGateway)
                    .accessibilityLabel(saveTitle)
                }
            }
        }
        .foregroundStyle(Color.tronTextPrimary)
        .tronSettingsLayout()
        .tronSettingsVisualTheme(accent: .tronPrimary)
        .tronTopBlur(.sheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task(id: PresentationActivityTaskID(
            source: "\(selection?.id ?? "new"):\(model.profileRevision):\(model.foregroundReconciliationGeneration):\(scenePhase == .active)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            await loadExisting()
        }
        .tronManagedSheet(isPresented: $showingWorkspaceBrowser, identity: "automation.workspace-browser") {
            WorkspaceBrowser(shortcuts: recentWorkspaces, initialPath: workspaceBrowserInitialPath) { value in
                workspacePath = value
                workspaceTrustInspection = nil
            }
        }
        .tronManagedSheet(isPresented: $showingSessionPicker, identity: "automation.session-picker.\(selectedProfileID)") {
            let profileID = selectedProfileID
            AutomationSessionPickerSheet(sessions: sessions, selectedID: targetSessionID) { session in
                guard selectedProfileID == profileID, selectedEndpoint != nil,
                      sessions.contains(where: { $0.id == session.id }) else { return }
                targetSessionID = session.id
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
        .tronManagedSheet(item: $editingDateField, identity: { "automation.date.\($0.id)" }) { selection in
            TronDatePickerSheet(title: selection.field.title, component: selection.component,
                                date: dateBinding(for: selection.field))
        }
        .task(id: PresentationActivityTaskID(
            source: "\(selectedProfileID):\(trigger):\(initialized):\(model.profileRevision):\(scenePhase == .active)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard initialized,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await loadPreview()
        }
        .task(id: PresentationActivityTaskID(
            source: "\(selectedProfileID):\(workspacePath):\(targetMode):\(initialized):\(ownsMutationGateway):\(scenePhase == .active)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard initialized, presentationActivity.allowsPresentationPublication,
                  scenePhase == .active, targetMode == .workspace else { return }
            await inspectWorkspaceTrust(workspacePath)
        }
        .task(id: PresentationActivityTaskID(
            source: "target:\(selectedProfileID):\(targetSessionID):\(targetMode):\(initialized):"
                + "\(scenePhase == .active):\(sessions.contains { $0.id == targetSessionID })",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard initialized,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            await resolveArchivedTargetTitle()
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, _ in
            presentationReadGeneration &+= 1
            previewGeneration &+= 1
        }
        .onChange(of: actionKind) { _, next in
            if next == .notification {
                targetMode = .existingSession
                workspacePath = ""
                workspaceTrustInspection = nil
            } else if !isEditing {
                targetMode = .workspace
            }
        }
        .task(id: PresentationActivityTaskID(
            source: "home:\(selectedProfileID):\(selectedEndpoint?.profile.connectionID ?? -1):\(targetMode):\(model.foregroundReconciliationGeneration):\(scenePhase == .active)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard targetMode == .home, presentationActivity.allowsPresentationPublication, scenePhase == .active else { return }
            await loadHomeTarget()
        }
        .onChange(of: targetMode) { _, next in
            if next == .home { includesResource = false }
            else { savedHomeTarget = nil }
            intervalAmount = min(max(intervalAmount, minimumIntervalAmount), maximumIntervalAmount)
        }
        .onChange(of: model.profileRevision) { _, _ in
            if !selectedProfileID.isEmpty,
               !model.profiles.profiles.contains(where: { $0.id == selectedProfileID }) {
                dismiss()
            }
        }
        .tronConfirmation(isEditing ? "Save changes?" : "Enable automation?", isPresented: $confirmingSave) {
            Button(isEditing ? "Save" : "Enable") { Task { await save() } }
        } message: {
            Text(isEditing
                 ? "This definition is active. Its revised schedule may become due immediately."
                 : "The first occurrence may become due immediately. Review the action and target before enabling it.")
        }
    }

    private var basicsSection: some View {
        section("Basics", detail: "Name the Automation and choose where its definition lives.") {
            VStack(spacing: 0) {
                nameField
                TronSettingsDivider()
                descriptionField
                if let profile = selectedEndpoint?.profile {
                    TronSettingsDivider()
                    if !isEditing, endpoints.count > 1 {
                        TronSelectionRow(
                            icon: "desktopcomputer",
                            title: "Gateway",
                            value: profile.label
                        ) {
                            ForEach(endpoints) { endpoint in
                                Button(endpoint.profile.label) {
                                    selectedProfileID = endpoint.profile.id
                                    targetSessionID = sessions.first?.id ?? ""
                                    targetMode = actionKind == .notification ? .existingSession : .workspace
                                    workspacePath = ""
                                    workspaceTrustInspection = nil
                                }
                            }
                        }
                    } else {
                        TronValueRow(
                            icon: "desktopcomputer",
                            title: "Gateway",
                            value: profile.label
                        )
                    }
                }
                if !isEditing {
                    TronSettingsDivider()
                    TronToggleRow(
                        icon: "bolt.circle",
                        title: "Enable immediately",
                        detail: "Otherwise this is saved as a draft.",
                        accent: .tronPrimary,
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
                ? (targetMode == .home ? "Send an attributed message to Home, not a maintainer instruction." : targetMode == .workspace ? "Send text to a new session in the selected workspace." : "Send text to the selected session.")
                : "Queue a notification associated with the selected session."
        ) {
            VStack(spacing: 0) {
                TronSegmentedControl(
                    options: AutomationActionKind.allCases.map { ($0.label, $0) },
                    selection: $actionKind
                )
                .padding(14)
                TronSettingsDivider()
                actionEditor
                if actionKind == .sessionPrompt && targetMode != .home {
                    TronSettingsDivider()
                    TronToggleRow(
                        icon: "sparkles",
                        title: "Invoke a resource",
                        detail: "Use an installed skill or prompt.",
                        accent: .tronPrimary,
                        isOn: $includesResource
                    )
                    if includesResource {
                        TronSettingsDivider()
                        resourceEditor
                    }
                }
            }
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            section(
                actionKind == .notification ? "Associated Session" : "Target",
                detail: actionKind == .notification
                    ? "Notifications are associated with an existing persisted session."
                    : "Choose Home, an existing session, or a new ordinary session for every run."
            ) {
                VStack(spacing: 0) {
                    if actionKind == .sessionPrompt {
                        TronSelectionRow(icon: "arrow.turn.down.right", title: "Destination", value: targetMode.title) {
                            ForEach(AutomationTargetMode.allCases.filter { $0 != .home || selectedEndpoint?.profile.capabilities.contains("home.v1") == true }) { mode in
                                Button(mode.title) { targetMode = mode }
                                    .accessibilityIdentifier("automation.destination.\(mode.rawValue)")
                            }
                        }
                        TronSettingsDivider()
                    }
                    if targetMode == .home && actionKind == .sessionPrompt {
                        TronValueRow(icon: "house", title: "Home", value: homeTargetStatus?.phase.rawValue.capitalized ?? "Checking availability")
                        TronSettingsCaption("Every firing stays separate. Busy, paused, disabled or cooling messages wait and batch into one wake. Cooldown: 60 seconds per automation. Messages cannot approve settings, grants, trust or profile changes.")
                    } else if targetMode == .existingSession || actionKind == .notification {
                        existingSessionTarget
                    } else {
                        workspaceTarget
                    }
                }
            }
            if targetMode == .workspace && actionKind == .sessionPrompt {
                TronSettingsCaption("Every occurrence creates and retains a new ordinary session in the selected workspace.").containerValue(\.tronSettingsSection, false)
            }
        }
    }

    private var existingSessionTarget: some View {
        Group {
            if sessions.isEmpty && archivedTargetTitle == nil {
                TronSettingsRow(
                    icon: "bubble.left",
                    title: "No sessions available",
                    subtitle: "Create or connect a persisted session before saving."
                )
            } else {
                TronSettingsRow(
                    icon: "bubble.left",
                    title: "Session",
                    subtitle: archivedTargetHint
                ) {
                    Button { showingSessionPicker = true } label: {
                        TronInlineActionLabel(selectedSessionTitle)
                    }
                    .buttonStyle(.plain)
                    .disabled(sessions.isEmpty)
                    .accessibilityLabel("Choose session")
                    .accessibilityValue(selectedSessionTitle)
                }
            }
        }
    }

    private var workspaceTarget: some View {
        VStack(alignment: .leading, spacing: 0) {
            TronSettingsRow(
                icon: "folder",
                title: "Workspace"
            ) {
                Button {
                    guard ownsMutationGateway else { return }
                    showingWorkspaceBrowser = true
                } label: {
                    TronInlineActionLabel(
                        workspacePath.isEmpty ? "Choose" : workspaceName
                    )
                }
                .buttonStyle(.plain)
            }
            if let inspection = workspaceTrustInspection,
               NewSessionTrustPolicy.requiresDecision(inspection) {
                TronSettingsDivider()
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
                    selection: $scheduleKind
                )
                .padding(14)
                TronSettingsDivider()
                switch scheduleKind {
                case .once:
                    dateRow(
                        icon: "calendar.badge.clock",
                        title: "Run at",
                        field: .once,
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
        VStack(alignment: .leading, spacing: 0) {
            TronSettingsRow(icon: "calendar", title: "Days")
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
                        .regular.tint(Color.tronPrimary.opacity(selected ? 0.28 : 0.06)).interactive(),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .accessibilityLabel(isoWeekdayName(day))
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
            .padding(.bottom, 14)
        }
    }

    private var advancedSection: some View {
        section(
            "Behavior",
            detail: "Pausing stops future triggers but does not cancel work already accepted by the Gateway."
        ) {
            VStack(spacing: 0) {
                TronSelectionRow(
                    icon: "clock.arrow.circlepath",
                    title: "After downtime",
                    value: misfirePolicy == "latest" ? "Run latest" : "Skip missed"
                ) {
                    Button("Run latest") { misfirePolicy = "latest" }
                    Button("Skip missed") { misfirePolicy = "skip" }
                }
                TronSettingsDivider()
                TronSelectionRow(
                    icon: "rectangle.stack.badge.play",
                    title: "While running",
                    value: overlapPolicy == "queueLatest" ? "Queue latest" : "Skip"
                ) {
                    Button("Skip") { overlapPolicy = "skip" }
                    Button("Queue latest") { overlapPolicy = "queueLatest" }
                }
                TronSettingsDivider()
                TronSettingsRow(
                    icon: "timer",
                    title: "Deadline",
                    subtitle: "\(deadlineMinutes) minutes"
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
                TronLoadingState(label: "Calculating schedule…")
                    .padding(14)
            } else if preview.isEmpty {
                TronSettingsRow(
                    icon: "calendar.badge.minus",
                    title: "No future occurrence",
                    subtitle: "Adjust the schedule to calculate another date."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(preview.enumerated()), id: \.element) { index, occurrence in
                        TronSettingsRow(
                            icon: index == 0 ? "clock.badge.checkmark" : "clock",
                            title: AutomationDateFormatting.date(occurrence)
                        )
                        if index < preview.count - 1 {
                            TronSettingsDivider()
                        }
                    }
                }
            }
        }
    }

    private var nameField: some View {
        fieldRow(title: "Name", icon: "textformat", count: name.utf8.count, limit: 256) {
            TextField("Daily review", text: $name)
                .tronInlineField()
        }
    }

    private var descriptionField: some View {
        fieldRow(title: "Description", icon: "text.alignleft", count: description.utf8.count, limit: 2_048) {
            TextField("Optional context", text: $description, axis: .vertical)
                .lineLimit(2...4)
                .tronInlineField()
        }
    }

    private var actionEditor: some View {
        fieldRow(title: actionKind == .sessionPrompt ? "Prompt" : "Notification", icon: actionKind.icon,
                 count: actionContent.utf8.count, limit: actionContentByteLimit) {
            TextEditor(text: $actionContent)
                .frame(minHeight: 108)
                .tronTextEditor()
        }
    }

    private var resourceEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            TronSegmentedControl(
                options: [
                    ("Skill", ComposerResourceInvocation.Source.skill),
                    ("Prompt", ComposerResourceInvocation.Source.prompt),
                ],
                selection: $resourceSource
            )
            .padding(14)
            TronTextSettingRow(icon: "at", title: resourceSource == .skill ? "Skill name" : "Prompt name", value: $resourceName)
            TronSettingsCaption("Use the exact installed resource name. Shell, webhooks, extension commands, and attachments are not supported.",
                                inset: TronSettingsLayoutPolicy.rowHorizontalPadding)
                .padding(.bottom, 14)
        }
    }

    private var workspaceBrowserInitialPath: String? {
        AutomationWorkspacePathPolicy.initialPath(selectedPath: workspacePath)
    }

    private func resolveArchivedTargetTitle() async {
        guard targetMode == .existingSession || actionKind == .notification,
              !targetSessionID.isEmpty,
              sessions.first(where: { $0.id == targetSessionID }) == nil else {
            archivedTargetTitle = nil
            return
        }
        let profileID = selectedProfileID
        let requestedTarget = targetSessionID
        guard model.supportsSessionArchive(profileID: profileID) else {
            archivedTargetTitle = nil
            return
        }
        let requestedGeneration = presentationReadGeneration
        let summary = try? await model.archivedSessionSummary(
            profileID: profileID,
            sessionID: requestedTarget,
            presentationActive: { presentationActivity.allowsPresentationPublication && scenePhase == .active }
        )
        guard !Task.isCancelled,
              requestedGeneration == presentationReadGeneration,
              presentationActivity.allowsPresentationPublication,
              scenePhase == .active,
              selectedProfileID == profileID,
              targetSessionID == requestedTarget else { return }
        archivedTargetTitle = summary?.title
    }

    private var selectedSessionTitle: String {
        sessions.first(where: { $0.id == targetSessionID })?.title
            ?? archivedTargetTitle
            ?? "Choose a session"
    }

    private var archivedTargetHint: String? {
        guard archivedTargetTitle != nil,
              sessions.first(where: { $0.id == targetSessionID }) == nil else { return nil }
        return "Archived · It stays this automation's target, and each run unarchives it."
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
        case .home: return savedHomeTarget ?? .home(homeID: homeTargetStatus?.homeId ?? "", routeGeneration: homeTargetStatus?.routeGeneration ?? 0)
        }
    }

    private func loadHomeTarget() async {
        let profileID = selectedProfileID
        let connectionID = selectedEndpoint?.profile.connectionID
        let generation = presentationReadGeneration
        let foreground = model.foregroundReconciliationGeneration
        homeTargetStatus = nil
        guard let client, selectedEndpoint?.profile.capabilities.contains("home.v1") == true else { return }
        do {
            let value: JSONValue = try await client.request("home.status")
            let status = try HomeStatus.validated(value)
            guard !Task.isCancelled, generation == presentationReadGeneration,
                  foreground == model.foregroundReconciliationGeneration,
                  selectedProfileID == profileID, selectedEndpoint?.profile.connectionID == connectionID,
                  targetMode == .home, presentationActivity.allowsPresentationPublication, scenePhase == .active else { return }
            homeTargetStatus = status
        } catch {
            guard !Task.isCancelled, generation == presentationReadGeneration,
                  foreground == model.foregroundReconciliationGeneration,
                  selectedProfileID == profileID, selectedEndpoint?.profile.connectionID == connectionID,
                  targetMode == .home, presentationActivity.allowsPresentationPublication, scenePhase == .active else { return }
            errorMessage = (error as? GatewayFailure)?.message ?? "Unable to read Home availability."
        }
    }

    private func inspectWorkspaceTrust(_ path: String) async {
        guard let trustTarget = TrustTarget(cwd: path), ownsMutationGateway else { return }
        trustReadGeneration &+= 1
        let generation = trustReadGeneration
        let presentationGeneration = presentationReadGeneration
        do {
            let inspection = try await model.inspectTrust(target: trustTarget)
            guard !Task.isCancelled,
                  generation == trustReadGeneration,
                  presentationGeneration == presentationReadGeneration,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active,
                  workspacePath == path,
                  targetMode == .workspace,
                  ownsMutationGateway else { return }
            if let canonical = inspection.objectValue?["cwd"]?.stringValue,
               AutomationAdmissionPolicy.validWorkspacePath(canonical) {
                workspacePath = canonical
            }
            workspaceTrustInspection = inspection
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  generation == trustReadGeneration,
                  presentationGeneration == presentationReadGeneration,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active,
                  workspacePath == path,
                  targetMode == .workspace,
                  ownsMutationGateway else { return }
            errorMessage = (error as? GatewayFailure)?.message ?? "Project trust is unavailable."
        }
    }

    private func setWorkspaceTrust(_ value: Bool) async {
        guard let trustTarget = TrustTarget(cwd: workspacePath), ownsMutationGateway else { return }
        do {
            let inspection = try await model.setTrust(target: trustTarget, decision: value)
            if let canonical = inspection.objectValue?["cwd"]?.stringValue,
               AutomationAdmissionPolicy.validWorkspacePath(canonical) {
                workspacePath = canonical
            }
            workspaceTrustInspection = inspection
        } catch {
            errorMessage = (error as? GatewayFailure)?.message ?? "Unable to update project trust."
        }
    }

    private var intervalRows: some View {
        VStack(spacing: 0) {
            TronSettingsRow(
                icon: "repeat",
                title: "Interval",
                subtitle: "Every \(intervalAmount) \(intervalUnit.rawValue.lowercased())"
            ) {
                Stepper(
                    "Interval",
                    value: $intervalAmount,
                    in: minimumIntervalAmount...maximumIntervalAmount
                )
                .labelsHidden()
            }
            TronSettingsDivider()
            TronSelectionRow(
                icon: "clock.arrow.2.circlepath",
                title: "Unit",
                value: intervalUnit.rawValue
            ) {
                ForEach(AutomationIntervalUnit.allCases) { unit in
                    Button(unit.rawValue) { selectIntervalUnit(unit) }
                }
            }
            TronSettingsDivider()
            dateRow(
                icon: "calendar.badge.clock",
                title: "Anchor",
                field: .intervalAnchor,
                selection: $intervalAnchor,
                components: [.date, .hourAndMinute]
            )
        }
    }

    private var calendarRows: some View {
        VStack(spacing: 0) {
            weekdayPicker
            TronSettingsDivider()
            dateRow(
                icon: "clock",
                title: "Local time",
                field: .localTime,
                selection: $localTime,
                components: [.hourAndMinute]
            )
            TronSettingsDivider()
            timezoneField
            TronSettingsDivider()
            Button { timezone = TimeZone.current.identifier } label: {
                TronSettingsRow(
                    icon: "location",
                    title: "Use current timezone",
                    subtitle: TimeZone.current.identifier
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var timezoneField: some View {
        TronTextSettingRow(icon: "globe", title: "IANA timezone", value: $timezone)
    }

    private func dateRow(
        icon: String,
        title: String,
        field: AutomationDateField,
        selection: Binding<Date>,
        components: DatePickerComponents
    ) -> some View {
        TronSettingsRow(icon: icon, title: title) {
            HStack(spacing: TronSpacing.sm) {
                if components.contains(.date) {
                    dateValueButton(
                        selection.wrappedValue,
                        field: field, component: .date
                    )
                }
                if components.contains(.hourAndMinute) {
                    dateValueButton(
                        selection.wrappedValue,
                        field: field, component: .time
                    )
                }
            }
        }
    }

    private func dateValueButton(_ date: Date, field: AutomationDateField, component: TronDateComponent) -> some View {
        TronDateValueButton(date: date, component: component) {
            editingDateField = AutomationDateSelection(field: field, component: component)
        }
    }

    private func dateBinding(for field: AutomationDateField) -> Binding<Date> {
        Binding(
            get: {
                switch field {
                case .once: onceDate
                case .intervalAnchor: intervalAnchor
                case .localTime: localTime
                }
            },
            set: { value in
                switch field {
                case .once: onceDate = value
                case .intervalAnchor: intervalAnchor = value
                case .localTime: localTime = value
                }
            }
        )
    }

    private func fieldRow<Field: View>(
        title: String, icon: String, count: Int, limit: Int, @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TronSettingsRow(icon: icon, title: title) {
                Text("\(count.formatted()) / \(limit.formatted())")
                    .font(TronTypography.settingsRowSubtext)
                    .monospacedDigit()
                    .foregroundStyle(count > limit ? Color.tronError : Color.tronTextMuted)
            }
            field()
                .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
                .padding(.bottom, 14)
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
        case let .home(homeID, generation):
            AutomationAdmissionPolicy.admits(target) && homeTargetStatus?.homeId == homeID && homeTargetStatus?.routeGeneration == generation
                && !includesResource && actionKind == .sessionPrompt
        case let .existingSession(sessionID): AutomationAdmissionPolicy.validSessionID(sessionID)
        case let .workspace(cwd, _):
            AutomationAdmissionPolicy.validWorkspacePath(cwd)
                && workspaceTrustInspection != nil
                && !NewSessionTrustPolicy.requiresDecision(workspaceTrustInspection)
        }
        let intervalIsValid = targetMode != .workspace
            || AutomationAdmissionPolicy.admitsNewSessionInterval(trigger)
        return initialized && (!isEditing || loadedRevision != nil)
            && !trimmedName.isEmpty
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
        guard actionKind == .sessionPrompt, targetMode != .home, includesResource else { return nil }
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
        selectedProfileID = selection?.profileID ?? model.profiles.selected?.id ?? endpoints.first?.profile.id ?? ""
        let requestedPresentationGeneration = presentationReadGeneration
        guard let selection else {
            targetMode = actionKind == .notification ? .existingSession : .workspace
            targetSessionID = sessions.first?.id ?? ""
            initialized = true
            return
        }
        guard let client else {
            errorMessage = "This Gateway is unavailable."
            return
        }
        do {
            let record = try await client.get(id: selection.summary.id)
            guard !Task.isCancelled,
                  requestedPresentationGeneration == presentationReadGeneration,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            loadedRevision = record.revision
            loadedActivation = record.activation
            name = record.name
            description = record.description ?? ""
            switch record.target {
            case .home:
                targetMode = .home
                savedHomeTarget = record.target
                targetSessionID = ""
                workspacePath = ""
            case let .existingSession(sessionID):
                targetMode = .existingSession
                targetSessionID = sessionID
                workspacePath = ""
            case let .workspace(cwd, _):
                targetMode = .workspace
                workspacePath = cwd
                targetSessionID = ""
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
            initialized = true
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  requestedPresentationGeneration == presentationReadGeneration,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            errorMessage = (error as? GatewayFailure)?.message ?? "Unable to load automation."
        }
    }

    private func loadPreview() async {
        guard initialized, !Task.isCancelled,
              presentationActivity.allowsPresentationPublication,
              scenePhase == .active else { return }
        guard let client, AutomationAdmissionPolicy.admits(trigger) else {
            preview = []
            isPreviewing = false
            return
        }
        previewGeneration &+= 1
        let generation = previewGeneration
        let requestedTrigger = trigger
        let requestedProfileID = selectedProfileID
        let requestedPresentationGeneration = presentationReadGeneration
        isPreviewing = true
        defer {
            if !Task.isCancelled, generation == previewGeneration,
               requestedPresentationGeneration == presentationReadGeneration,
               presentationActivity.allowsPresentationPublication, scenePhase == .active {
                isPreviewing = false
            }
        }
        do {
            let occurrences = try await client.preview(trigger: requestedTrigger, limit: 5).occurrences
            guard !Task.isCancelled,
                  generation == previewGeneration,
                  requestedTrigger == trigger,
                  requestedProfileID == selectedProfileID,
                  requestedPresentationGeneration == presentationReadGeneration,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            preview = occurrences
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  generation == previewGeneration,
                  requestedTrigger == trigger,
                  requestedProfileID == selectedProfileID,
                  requestedPresentationGeneration == presentationReadGeneration,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
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
        TronSettingsGroup(title, detail: detail) { content() }
    }
}
