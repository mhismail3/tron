import SwiftUI

enum HookViewMode: String, CaseIterable, Identifiable {
    case byEvent
    case byExtension
    var id: String { rawValue }
    var title: String { self == .byExtension ? "By Extension" : "By Event" }
}

struct ProjectHooksView: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var loading = false
    @State private var selected: HookExtensionRecord?
    @State private var selectedEvent: HookEventRecord?
    @State private var mode: HookViewMode = .byEvent
    @State private var showUnregisteredEvents = false
    @State private var loadGeneration = 0

    init(sessionID: String, initialMode: HookViewMode = .byEvent, showsUnregisteredEvents: Bool = false) {
        self.sessionID = sessionID
        _mode = State(initialValue: initialMode)
        _showUnregisteredEvents = State(initialValue: showsUnregisteredEvents)
    }

    private var currentIdentity: SessionPresentationIdentity? {
        model.sessionPresentationIdentity(for: sessionID)
    }
    private var resources: JSONValue? {
        guard currentIdentity != nil else { return nil }
        return model.sessionResources(for: sessionID)
    }
    private var records: [HookExtensionRecord] { HookInventoryPresentation.extensions(from: resources) }
    private var events: [HookEventRecord] { HookInventoryPresentation.eventRecords(from: records, includeUnregistered: showUnregisteredEvents) }
    private var issues: [HookLoadIssue] { HookInventoryPresentation.issues(from: resources) }
    private var recordsWithFriendlyNames: [(HookExtensionRecord, String)] {
        let labels = HookInventoryPresentation.extensionLabels(for: records)
        return records.map { ($0, labels[$0.id] ?? $0.friendlyName) }
    }
    private var omissions: HookInventoryOmissions? { HookInventoryOmissions(resources: resources) }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let resourceError = model.sessionResourcesError(for: sessionID),
                       currentIdentity != nil {
                        TronSettingsNotice(
                            message: "Registered hooks could not be read: \(resourceError)",
                            icon: "exclamationmark.triangle",
                            accent: .tronError,
                            retry: { loadGeneration &+= 1 }
                        )
                    }
                    if let omissions, omissions.hasOmissions {
                        TronSettingsNotice(
                            message: "Hook inventory is bounded; omitted \(omissions.summary). Refresh after reducing the runtime resource set to inspect the complete registration view.",
                            icon: "exclamationmark.triangle",
                            accent: .tronAmber,
                            retry: { loadGeneration &+= 1 }
                        )
                    }
                    if HookInventoryPresentation.hasInventory(resources) {
                        TronSegmentedControl(
                            options: HookViewMode.allCases.map { (label: $0.title, value: $0) },
                            selection: $mode,
                            accent: .tronSessionTeal,
                            foreground: .tronSessionTeal,
                            minimumHeight: 40
                        )
                        .accessibilityLabel("Hook view")
                        if mode == .byEvent {
                            TronToggleRow(
                                icon: "bolt.horizontal.circle",
                                title: "Show unregistered events",
                                detail: "Include supported lifecycle events without registered handlers",
                                accent: .tronSessionTeal,
                                isOn: $showUnregisteredEvents
                            )
                        }
                        if records.isEmpty && issues.isEmpty && !(mode == .byEvent && showUnregisteredEvents) {
                            TronPlaceholderState(
                                title: "No registered hooks",
                                detail: "The selected runtime reported no extension registrations.",
                                icon: "bolt.horizontal.circle",
                                accent: .tronSessionTeal
                            )
                        } else {
                            if mode == .byExtension {
                                extensionList
                            } else {
                                eventList
                            }
                            if !issues.isEmpty {
                                TronSettingsGroup("Load Issues", detail: "Sources that did not produce a registered extension", accent: .tronError, surfaceStyle: .scrollOptimized) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                                            if index > 0 { TronSettingsDivider(accent: .tronError) }
                                            TronSettingsRow(icon: "exclamationmark.triangle", title: issue.path, subtitle: issue.message, subtitleLineLimit: 3, accent: .tronError)
                                        }
                                    }
                                }
                            }
                        }
                        TronSettingsCaption("Registered means the selected runtime exposed handlers now. It does not report recent execution, health, enabled state, or last-run information.")
                    } else if loading {
                        TronLoadingState(label: "Loading registered hooks…", accent: .tronSessionTeal)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 36)
                    } else if model.sessionResourcesError(for: sessionID) == nil {
                        TronPlaceholderState(title: "Hooks Unavailable", detail: "The selected runtime has not provided its registration inventory.", icon: "bolt.horizontal.circle", accent: .tronSessionTeal)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .defaultScrollAnchor(.top)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { loadGeneration &+= 1 } label: {
                        TronToolbarTextLabel("Refresh", systemImage: "arrow.clockwise", isWorking: loading)
                            .tronToolbarAction(accent: .tronSessionTeal)
                    }
                    .disabled(loading)
                    .accessibilityLabel("Refresh registered hooks")
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Project Hooks", accent: .tronSessionTeal) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(Color.tronSessionTeal) }
                        .accessibilityLabel("Done")
                }
            }
            .task(id: PresentationActivityTaskID(
                source: "project-hooks.\(sessionID).\(currentIdentity?.generation ?? 0).\(loadGeneration)",
                presentationActive: presentationActivity.allowsPresentationPublication
            )) {
                await load()
            }
            .onChange(of: currentIdentity) { _, _ in
                selected = nil
            }
            .tronManagedSheet(item: $selected, identity: { "project-hook.\($0.id)" }) { record in
                HookExtensionDetailView(record: record, title: displayName(for: record), accent: .tronSessionTeal)
            }
            .tronManagedSheet(item: $selectedEvent, identity: { "project-hook-event.\($0.id)" }) { event in
                HookEventDetailView(event: event, accent: .tronSessionTeal)
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronSessionTeal)
        .tint(Color.tronSessionTeal)
    }

    @ViewBuilder
    private var extensionList: some View {
        if !records.isEmpty {
            TronSettingsGroup("Registered Extensions", detail: "\(records.reduce(0) { $0 + $1.handlerCount }) registered handlers · grouped by owning extension", accent: .tronSessionTeal, surfaceStyle: .scrollOptimized) {
                VStack(spacing: 0) {
                    ForEach(Array(recordsWithFriendlyNames.enumerated()), id: \.element.0.id) { index, pair in
                        let record = pair.0
                        if index > 0 { TronSettingsDivider(accent: .tronSessionTeal) }
                        Button { selected = record } label: {
                            TronSettingsRow(icon: "bolt.horizontal.circle", title: pair.1, subtitle: record.handlers.isEmpty ? "No registered handlers · tool/command registration only" : "\(record.handlerCount) registered handler\(record.handlerCount == 1 ? "" : "s") · \(record.eventCount) event\(record.eventCount == 1 ? "" : "s")", subtitleLineLimit: 2, accent: .tronSessionTeal) {
                                ComposerResourceBadges(hookProvenance: record.provenance, accent: .tronSessionTeal)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("project-hook-extension-\(index)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var eventList: some View {
        TronSettingsGroup("Lifecycle Events", detail: showUnregisteredEvents ? "Registered and supported events · zero counts are not registrations" : "Registered events grouped by lifecycle", accent: .tronSessionTeal, surfaceStyle: .scrollOptimized) {
            VStack(spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { TronSettingsDivider(accent: .tronSessionTeal) }
                    Button { selectedEvent = event } label: {
                        TronSettingsRow(icon: event.descriptor.isSupported ? "bolt.horizontal.circle" : "questionmark.circle", title: event.descriptor.title, subtitle: event.providers.isEmpty ? "No registered handlers · supported event" : "\(event.handlerCount) handler\(event.handlerCount == 1 ? "" : "s") · \(event.providers.count) provider\(event.providers.count == 1 ? "" : "s")", subtitleLineLimit: 2, accent: event.descriptor.isSupported ? .tronSessionTeal : .tronAmber)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("project-hook-event-\(event.descriptor.identifier)")
                }
            }
        }
    }

    private func displayName(for record: HookExtensionRecord) -> String {
        recordsWithFriendlyNames.first(where: { $0.0.id == record.id })?.1 ?? record.friendlyName
    }

    private func load() async {
        guard presentationActivity.allowsPresentationPublication,
              let expectedIdentity = currentIdentity else { return }
        loading = true
        await model.loadResources(sessionID: sessionID)
        guard !Task.isCancelled,
              expectedIdentity == currentIdentity,
              presentationActivity.allowsPresentationPublication else { return }
        loading = false
    }
}
