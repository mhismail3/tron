import SwiftUI

struct AutomationFormView: View {
    let selection: AutomationSummarySelection?
    let onSaved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var actionKind: AutomationActionKind = .sessionPrompt
    @State private var actionContent = ""
    @State private var targetSessionID = ""
    @State private var scheduleKind: AutomationTriggerKind = .once
    @State private var onceDate = Date.now.addingTimeInterval(3600)
    @State private var intervalMinutes = 60
    @State private var intervalAnchor = Date.now
    @State private var localTime = Date.now
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var timezone = TimeZone.current.identifier
    @State private var misfirePolicy = "latest"
    @State private var overlapPolicy = "skip"
    @State private var deadlineMinutes = 60
    @State private var enabledOnSave = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var preview: [String] = []
    @State private var isPreviewing = false
    @State private var initialized = false

    private var client: AutomationRPCClient? { model.automationCatalog.endpoint(for: selection?.profileID ?? model.profiles.selected?.id ?? "")?.client }
    private var sessions: [SessionSummary] { model.sessions.sorted { $0.title < $1.title } }
    private var isEditing: Bool { selection != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TronSpacing.lg) {
                    basics
                    action
                    target
                    schedule
                    advanced
                    previewSection
                    if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.triangle").font(TronTypography.bodySM).foregroundStyle(Color.tronError) }
                }.padding(20).padding(.bottom, 32)
            }.tronScrollEdgeChrome().tronNavigationTitle(isEditing ? "Edit Automation" : "New Automation", accent: .tronCoral)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Cancel") }; ToolbarItem(placement: .confirmationAction) { Button { Task { await save() } } label: { if isSaving { ProgressView() } else { Text(enabledOnSave ? "Enable" : "Save") } }.disabled(isSaving || !canSave).foregroundStyle(canSave ? Color.tronCoral : Color.tronTextMuted) } }
        }.tronTopBlur(.sheet).presentationDetents([.large]).presentationDragIndicator(.hidden)
            .task { await loadExisting() }
    }

    private var basics: some View { section("Basics", icon: "square.and.pencil") { TextField("Name", text: $name).tronField(); TextField("Description (optional)", text: $description, axis: .vertical).lineLimit(2...4).tronField(); if let profile = model.profiles.selected { Label("Gateway: \(profile.label)", systemImage: "desktopcomputer").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary) } } }
    private var action: some View { section("What happens", icon: "bolt") { TronSegmentedControl(options: AutomationActionKind.allCases.map { ($0.label, $0) }, selection: $actionKind); TextEditor(text: $actionContent).frame(minHeight: 120).tronTextEditor(); Text("\(actionContent.utf8.count) / \(actionKind == .notification ? 512 : 65_536) bytes").font(TronTypography.secondaryCodeDescription).foregroundStyle(actionContent.utf8.count > (actionKind == .notification ? 512 : 65_536) ? Color.tronError : Color.tronTextMuted); if actionKind == .sessionPrompt { Text("Only persisted prompt/skill resources are supported. Extension commands, shell, webhooks, and attachments are unavailable.").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted) } } }
    private var target: some View { section("Target session", icon: "bubble.left") { if sessions.isEmpty { Text("No persisted user sessions are available on this Gateway.").font(TronTypography.bodySM).foregroundStyle(Color.tronAmber) } else { Picker("Session", selection: $targetSessionID) { Text("Choose a session").tag(""); ForEach(sessions) { Text($0.title).tag($0.id) } }.pickerStyle(.menu) } } }
    private var schedule: some View { section("Schedule", icon: "calendar") { Picker("Pattern", selection: $scheduleKind) { ForEach(AutomationTriggerKind.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented); switch scheduleKind { case .once: DatePicker("Run at", selection: $onceDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute]); case .interval: Stepper("Every \(intervalMinutes) minutes", value: $intervalMinutes, in: 1...525_600); DatePicker("Anchor", selection: $intervalAnchor, displayedComponents: [.date, .hourAndMinute]); case .calendar: weekdayPicker; DatePicker("Local time", selection: $localTime, displayedComponents: .hourAndMinute); TextField("IANA timezone", text: $timezone).tronField() } } }
    private var weekdayPicker: some View { VStack(alignment: .leading, spacing: 8) { Text("Days").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted); HStack { ForEach(1...7, id: \.self) { day in Button { if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) } } label: { Text(Calendar.current.shortWeekdaySymbols[day - 1].prefix(2)).frame(width: 34, height: 34) }.buttonStyle(TronIconButtonStyle(accent: weekdays.contains(day) ? .tronCoral : .tronTextMuted, size: 36)).accessibilityLabel(Calendar.current.weekdaySymbols[day - 1]); }.frame(maxWidth: .infinity) } } }
    private var advanced: some View { section("Advanced behavior", icon: "slider.horizontal.3") { Picker("After downtime", selection: $misfirePolicy) { Text("Run latest").tag("latest"); Text("Skip missed").tag("skip") }; Picker("While running", selection: $overlapPolicy) { Text("Skip").tag("skip"); Text("Queue latest").tag("queueLatest") }; Stepper("Deadline: \(deadlineMinutes) minutes", value: $deadlineMinutes, in: 5...1_440, step: 5) } }
    @ViewBuilder private var previewSection: some View { if !isEditing { section("Next occurrences", icon: "clock") { Button { Task { await loadPreview() } } label: { Label(isPreviewing ? "Calculating…" : "Preview schedule", systemImage: "sparkles") }.buttonStyle(TronActionButtonStyle(role: .standard)); ForEach(preview, id: \.self) { Text(AutomationDateFormatting.date($0)).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextSecondary) } } } }
    private func section(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View { TronSettingsGroup(title, accent: .tronCoral) { content() } }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !actionContent.isEmpty && !targetSessionID.isEmpty && (actionKind == .notification ? actionContent.utf8.count <= 512 : actionContent.utf8.count <= 65_536) && (scheduleKind != .calendar || !weekdays.isEmpty) }
    private var trigger: GatewayAutomationTrigger { switch scheduleKind { case .once: GatewayAutomationTrigger(kind: "once", at: GatewayTimestamp.string(from: onceDate)); case .interval: GatewayAutomationTrigger(kind: "interval", everySeconds: intervalMinutes * 60, anchorAt: GatewayTimestamp.string(from: intervalAnchor)); case .calendar: GatewayAutomationTrigger(kind: "calendar", timezone: timezone, localTime: localTime.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)), weekdays: weekdays.sorted()) } }
    private var definition: AutomationDefinitionDraft { AutomationDefinitionDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines), description: description.isEmpty ? nil : description, targetSessionId: targetSessionID, trigger: trigger, misfirePolicy: misfirePolicy, overlapPolicy: overlapPolicy, executionDeadlineSeconds: deadlineMinutes * 60, action: GatewayAutomationAction(kind: actionKind.rawValue, text: actionKind == .sessionPrompt ? actionContent : nil, message: actionKind == .notification ? actionContent : nil)) }
    private func loadExisting() async {
        guard !initialized else { return }
        initialized = true
        guard let selection, let client else {
            if targetSessionID.isEmpty { targetSessionID = sessions.first?.id ?? "" }
            return
        }
        do {
            let record = try await client.get(id: selection.summary.id)
            name = record.name
            description = record.description ?? ""
            targetSessionID = record.targetSessionId
            actionKind = record.action.typedKind ?? .sessionPrompt
            actionContent = record.action.content
            misfirePolicy = record.misfirePolicy
            overlapPolicy = record.overlapPolicy
            deadlineMinutes = max(5, record.executionDeadlineSeconds / 60)
            scheduleKind = record.trigger.typedKind ?? .once
            timezone = record.trigger.timezone ?? TimeZone.current.identifier
            let storedWeekdays: [Int] = record.trigger.weekdays ?? Array(weekdays)
            weekdays = Set<Int>(storedWeekdays)
            if let at = record.trigger.at, let date = GatewayTimestamp.parse(at) { onceDate = date }
            if let anchor = record.trigger.anchorAt, let date = GatewayTimestamp.parse(anchor) { intervalAnchor = date }
            intervalMinutes = max(1, (record.trigger.everySeconds ?? 3_600) / 60)
        } catch {
            errorMessage = (error as? GatewayFailure)?.message ?? "Unable to load automation."
        }
    }
    private func loadPreview() async { guard let client else { errorMessage = "Gateway is unavailable."; return }; isPreviewing = true; defer { isPreviewing = false }; do { preview = try await client.preview(trigger: trigger).occurrences } catch { errorMessage = (error as? GatewayFailure)?.message ?? "Schedule preview is unavailable." } }
    private func save() async { guard let client, canSave else { return }; isSaving = true; defer { isSaving = false }; do { if let selection { _ = try await client.update(id: selection.summary.id, revision: selection.summary.revision, definition: definition) } else { _ = try await client.create(definition: definition) }; onSaved(); dismiss() } catch { errorMessage = (error as? GatewayFailure)?.message ?? "Unable to save automation. Review the latest definition and try again." } }
}
