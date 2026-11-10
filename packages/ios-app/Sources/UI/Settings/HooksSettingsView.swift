import SwiftUI
import TronMobileCore

enum HookViewMode: String, CaseIterable, Identifiable {
    case byEvent
    case byExtension
    var id: String { rawValue }
    var title: String { self == .byExtension ? "By Extension" : "By Event" }
}

struct HooksListRequest: Equatable {
    static let method = "hooks.list"
    static let capability = "hooks.v1"
    let cwd: String?

    var params: HooksListParams { HooksListParams(cwd: cwd) }

    static func isSupported(capabilities: [String]) -> Bool {
        capabilities.contains(capability)
    }

    static func make(scope: SettingsScope, projectCWD: String?, capabilities: [String]) -> HooksListRequest? {
        guard isSupported(capabilities: capabilities) else { return nil }
        guard scope == .project, let projectCWD, !projectCWD.isEmpty else { return HooksListRequest(cwd: nil) }
        return HooksListRequest(cwd: projectCWD)
    }
}

struct HooksListParams: Encodable {
    let cwd: String?
}

enum HooksProjectTrustNote {
    static let message = "Project hooks are not loaded until the project is trusted."
    static let linkTitle = "Project Trust"

    static func isRequired(projectCWD: String?, trust: ProjectTrustSummary?) -> Bool {
        guard projectCWD?.isEmpty == false, let trust else { return false }
        return trust.effectiveDecision != true
    }
}

enum HooksSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case omissionsNotice
    case viewMode
    case unregisteredEvents
    case emptyPlaceholder
    case registeredExtensions
    case lifecycleEvents
    case loadIssues
    case caption

    var id: String { rawValue }
}

struct HooksSettingsExtensionRow: Identifiable, Equatable, Sendable {
    let record: HookExtensionRecord
    let label: String
    var id: String { record.id }
}

struct HooksSettingsContent {
    static let unavailable = HooksSettingsContent(
        sections: [],
        extensionRows: [],
        events: [],
        issues: [],
        omissions: nil
    )

    let sections: [HooksSettingsSection]
    let extensionRows: [HooksSettingsExtensionRow]
    let events: [HookEventRecord]
    let issues: [HookLoadIssue]
    let omissions: HookInventoryOmissions?

    var handlerCount: Int { extensionRows.reduce(0) { $0 + $1.record.handlerCount } }
}

enum HooksSettingsPresentation {
    static func content(
        from projection: JSONValue?,
        mode: HookViewMode,
        showsUnregisteredEvents: Bool
    ) -> HooksSettingsContent {
        guard HookInventoryPresentation.hasInventory(projection) else { return .unavailable }
        let records = HookInventoryPresentation.extensions(from: projection)
        let labels = HookInventoryPresentation.extensionLabels(for: records)
        let issues = HookInventoryPresentation.issues(from: projection)
        let omissions = HookInventoryOmissions(resources: projection)
        let showsEmptyPlaceholder = records.isEmpty && issues.isEmpty
            && !(mode == .byEvent && showsUnregisteredEvents)
        var sections: [HooksSettingsSection] = []
        if omissions != nil { sections.append(.omissionsNotice) }
        sections.append(.viewMode)
        if mode == .byEvent { sections.append(.unregisteredEvents) }
        if showsEmptyPlaceholder {
            sections.append(.emptyPlaceholder)
        } else {
            if mode == .byExtension, !records.isEmpty { sections.append(.registeredExtensions) }
            if mode == .byEvent { sections.append(.lifecycleEvents) }
            if !issues.isEmpty { sections.append(.loadIssues) }
        }
        sections.append(.caption)
        return HooksSettingsContent(
            sections: sections,
            extensionRows: records.map { HooksSettingsExtensionRow(record: $0, label: labels[$0.id] ?? $0.friendlyName) },
            events: HookInventoryPresentation.eventRecords(from: records, includeUnregistered: showsUnregisteredEvents),
            issues: issues,
            omissions: omissions
        )
    }
}

struct HooksSettingsView: View {
    let projectCWD: String?
    @Environment(AppModel.self) private var model
    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronPrimary }
    @Environment(\.tronPresentationActivity) private var presentationActivity
    private var scope: SettingsScope { projectCWD == nil ? .global : .project }
    @PresentationState private var mode: HookViewMode = .byEvent
    @PresentationState private var showUnregisteredEvents = false
    @PresentationState private var selected: HookExtensionRecord?
    @PresentationState private var selectedEvent: HookEventRecord?
    @PresentationState private var projection: JSONValue?
    @PresentationState private var loadError: String?
    @PresentationState private var loading = true
    @PresentationState private var refreshGeneration = 0
    @PresentationState private var trust: ProjectTrustSummary?

    private struct HooksLoadID: Hashable {
        let scope: SettingsScope
        let profileRevision: Int
        let trustRevision: Int
        let refreshGeneration: Int
        let foregroundGeneration: Int
    }

    private var trustTarget: TrustTarget? { projectCWD.flatMap(TrustTarget.init(cwd:)) }

    private var loadID: HooksLoadID {
        HooksLoadID(
            scope: scope,
            profileRevision: model.profileRevision,
            trustRevision: model.trustRevision,
            refreshGeneration: refreshGeneration,
            foregroundGeneration: model.foregroundReconciliationGeneration
        )
    }

    private var trustLoadID: TrustLoadID {
        TrustLoadID(
            target: trustTarget,
            invalidationGeneration: model.trustRevision,
            foregroundGeneration: model.foregroundReconciliationGeneration
        )
    }

    var body: some View {
        let content = HooksSettingsPresentation.content(
            from: projection,
            mode: mode,
            showsUnregisteredEvents: showUnregisteredEvents
        )
        return ScrollView(.vertical, showsIndicators: true) {
            TronSettingsSections(alignment: .leading, spacing: 18, lazy: true, hidesLoneHeading: true) {
                TronSettingsCaption(scopeExplanation).containerValue(\.tronSettingsSection, false)
                if HooksProjectTrustNote.isRequired(projectCWD: projectCWD, trust: trust) {
                    untrustedProjectRow
                }
                if let loadError {
                    TronSettingsNotice(
                        message: "Registered hooks could not be read: \(loadError)",
                        icon: "exclamationmark.triangle",
                        accent: .tronError,
                        retry: { refreshGeneration &+= 1 }
                    )
                }
                if !content.sections.isEmpty {
                    sections(content)
                } else if loading {
                    TronLoadingState(label: "Loading registered hooks…", accent: accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 36)
                } else if loadError == nil {
                    TronPlaceholderState(
                        title: "Hooks Unavailable",
                        detail: unavailableDetail,
                        icon: "bolt.horizontal.circle",
                        accent: accent
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Hooks")
        .defaultScrollAnchor(.top)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronReloadToolbarButton(isReloading: loading, action: { refreshGeneration &+= 1 })
            }
        }
        .task(id: PresentationActivityTaskID(
            source: loadID,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            await refreshHooks(loadID)
        }
        .task(id: PresentationActivityTaskID(
            source: trustLoadID,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            await refreshTrust(trustLoadID)
        }
        .onChange(of: scope) { _, _ in
            selected = nil
            selectedEvent = nil
            projection = nil
            loadError = nil
        }
        .tronManagedSheet(item: $selected, identity: { "settings.hook-extension.\($0.id)" }) { record in
            HookExtensionDetailView(
                record: record,
                title: displayName(for: record, in: content),
                accent: accent
            )
        }
        .tronManagedSheet(item: $selectedEvent, identity: { "settings.hook-event.\($0.id)" }) { event in
            HookEventDetailView(event: event, accent: accent)
        }
    }

    private var scopeExplanation: String {
        scope == .project
            ? "Lifecycle hooks registered for this project."
            : "Lifecycle hooks registered for every project on this Mac."
    }

    private var untrustedProjectRow: some View {
        TronSettingsRow(
            icon: "checkmark.shield",
            title: HooksProjectTrustNote.message,
            accent: .tronAmber
        ) {
            TronProgressiveSheetLink(
                accessibilityLabel: HooksProjectTrustNote.linkTitle,
                identity: "settings.hooks.project-trust",
                accent: .tronAmber,
                destination: { TrustSettingsView(target: trustTarget) }
            ) {
                TronInlineActionLabel(HooksProjectTrustNote.linkTitle, accent: .tronAmber)
            }
        }
        .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.09, respectsSettingsTheme: false)
    }

    private var unavailableDetail: String {
        HooksListRequest.isSupported(capabilities: model.gatewayInfo?.capabilities ?? [])
            ? "This Gateway has not returned a hook inventory for the selected scope."
            : "This Gateway does not report hook inventory."
    }

    @ViewBuilder
    private func sections(_ content: HooksSettingsContent) -> some View {
        ForEach(content.sections) { section in
            switch section {
            case .omissionsNotice:
                if let omissions = content.omissions {
                    TronSettingsNotice(
                        message: "Hook inventory is bounded; omitted \(omissions.summary). Refresh after reducing the runtime resource set to inspect the complete registration view.",
                        icon: "exclamationmark.triangle",
                        accent: .tronAmber,
                        retry: { refreshGeneration &+= 1 }
                    )
                }
            case .viewMode:
                TronSegmentedControl(
                    options: HookViewMode.allCases.map { (label: $0.title, value: $0) },
                    selection: $mode,
                    accent: accent,
                    foreground: accent,
                    minimumHeight: 40
                )
                .accessibilityLabel("Hook view")
            case .unregisteredEvents:
                TronSettingsGroup("Display", accent: accent, surfaceStyle: .scrollOptimized) {
                    TronToggleRow(
                        icon: "bolt.horizontal.circle",
                        title: "Show unregistered events",
                        detail: "Include supported lifecycle events without registered handlers",
                        accent: accent,
                        isOn: $showUnregisteredEvents
                    )
                }
            case .emptyPlaceholder:
                TronPlaceholderState(
                    title: "No registered hooks",
                    detail: "The selected runtime reported no extension registrations.",
                    icon: "bolt.horizontal.circle",
                    accent: accent
                )
            case .registeredExtensions:
                extensionList(content)
            case .lifecycleEvents:
                eventList(content)
            case .loadIssues:
                loadIssueList(content)
            case .caption:
                TronSettingsCaption("Registered means the selected runtime exposed handlers now. It does not report recent execution, health, enabled state, or last-run information.").containerValue(\.tronSettingsSection, false)
            }
        }
    }

    @ViewBuilder
    private func extensionList(_ content: HooksSettingsContent) -> some View {
        TronSettingsGroup(
            "Registered Extensions",
            detail: "\(content.handlerCount) registered handlers · grouped by owning extension",
            accent: accent,
            surfaceStyle: .scrollOptimized
        ) {
            VStack(spacing: 0) {
                ForEach(Array(content.extensionRows.enumerated()), id: \.element.id) { index, row in
                    let record = row.record
                    if index > 0 { TronSettingsDivider(accent: accent) }
                    Button { selected = record } label: {
                        TronSettingsRow(
                            icon: "bolt.horizontal.circle",
                            title: row.label,
                            subtitle: record.handlers.isEmpty
                                ? "No registered handlers · tool/command registration only"
                                : "\(record.handlerCount) registered handler\(record.handlerCount == 1 ? "" : "s") · \(record.eventCount) event\(record.eventCount == 1 ? "" : "s")",
                            accent: accent
                        ) {
                            ComposerResourceBadges(hookProvenance: record.provenance, accent: accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-hook-extension-\(index)")
                }
            }
        }
    }

    @ViewBuilder
    private func eventList(_ content: HooksSettingsContent) -> some View {
        TronSettingsGroup(
            "Lifecycle Events",
            detail: showUnregisteredEvents
                ? "Registered and supported events · zero counts are not registrations"
                : "Registered events grouped by lifecycle",
            accent: accent,
            surfaceStyle: .scrollOptimized
        ) {
            VStack(spacing: 0) {
                ForEach(Array(content.events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { TronSettingsDivider(accent: accent) }
                    Button { selectedEvent = event } label: {
                        TronSettingsRow(
                            icon: event.descriptor.isSupported ? "bolt.horizontal.circle" : "questionmark.circle",
                            title: event.descriptor.title,
                            subtitle: event.providers.isEmpty
                                ? "No registered handlers · supported event"
                                : "\(event.handlerCount) handler\(event.handlerCount == 1 ? "" : "s") · \(event.providers.count) provider\(event.providers.count == 1 ? "" : "s")",
                            accent: event.descriptor.isSupported ? accent : .tronAmber
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-hook-event-\(event.descriptor.identifier)")
                }
            }
        }
    }

    @ViewBuilder
    private func loadIssueList(_ content: HooksSettingsContent) -> some View {
        TronSettingsGroup(
            "Load Issues",
            detail: "Sources that did not produce a registered extension",
            accent: .tronError,
            surfaceStyle: .scrollOptimized
        ) {
            VStack(spacing: 0) {
                ForEach(Array(content.issues.enumerated()), id: \.element.id) { index, issue in
                    if index > 0 { TronSettingsDivider(accent: .tronError) }
                    TronSettingsRow(
                        icon: "exclamationmark.triangle",
                        title: issue.path,
                        subtitle: issue.message,
                        subtitleLineLimit: 3,
                        accent: .tronError
                    )
                }
            }
        }
    }

    private func displayName(for record: HookExtensionRecord, in content: HooksSettingsContent) -> String {
        content.extensionRows.first { $0.record.id == record.id }?.label ?? record.friendlyName
    }

    private func refreshHooks(_ request: HooksLoadID) async {
        guard hooksReadIsCurrent(request) else { return }
        guard let list = HooksListRequest.make(
            scope: request.scope,
            projectCWD: projectCWD,
            capabilities: model.gatewayInfo?.capabilities ?? []
        ) else {
            projection = nil
            loadError = nil
            loading = false
            return
        }
        loading = projection == nil
        defer { if hooksReadIsCurrent(request) { loading = false } }
        do {
            let loaded: JSONValue = try await model.client.request(HooksListRequest.method, list.params)
            guard hooksReadIsCurrent(request) else { return }
            projection = loaded
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard hooksReadIsCurrent(request) else { return }
            projection = nil
            loadError = error.localizedDescription
        }
    }

    private func hooksReadIsCurrent(_ request: HooksLoadID) -> Bool {
        !Task.isCancelled && presentationActivity.allowsPresentationPublication && request == loadID
    }

    private func refreshTrust(_ request: TrustLoadID) async {
        guard presentationActivity.allowsPresentationPublication, !Task.isCancelled, request == trustLoadID else { return }
        guard let target = request.target else {
            trust = nil
            return
        }
        do {
            let value = try await model.inspectTrust(target: target)
            guard trustReadIsCurrent(request) else { return }
            trust = ProjectTrustSummary(value)
        } catch is CancellationError {
            return
        } catch {
            guard trustReadIsCurrent(request) else { return }
            trust = nil
        }
    }

    private func trustReadIsCurrent(_ request: TrustLoadID) -> Bool {
        !Task.isCancelled && presentationActivity.allowsPresentationPublication && request == trustLoadID
    }
}
