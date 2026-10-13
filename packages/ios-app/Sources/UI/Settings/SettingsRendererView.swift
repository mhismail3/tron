import SwiftUI
import TronMobileCore

/// The generic settings renderer (gateway docs/settings-model.md F1, 7.1-7.5).
/// Every word, section, order, control and badge is Gateway data from
/// `settings.resolve`; this view decides layout and style only, so a key, a
/// section or a choice the Gateway adds needs no app change. Surfaces adopt it
/// in slices 8 and 11 (#766, #769); `writeLayer` nil renders read-only.
struct SettingsRendererView: View {
    let target: JSONValue
    let writeLayer: String?
    var embedded = false
    /// Ordered from the layer this surface prefers to the next owned layer.
    var ownedLayers: [String] = []
    /// Receipt-aware Chat controls stay in their shared card. Their schema rows
    /// retain provenance/reset actions without creating a second value editor.
    var externalControlKeys: Set<String> = []
    var projectCWD: String? = nil
    var presentation: SettingsRendererPresentation = .sections
    /// `.keys` rows that follow a caller's row get their divider only once loaded,
    /// so a card never shows a dangling separator while the schema loads.
    var dividerBeforeKeys = false
    /// Hand-built account, package and setup flows supplement schema rows, never
    /// replace them. Nil means the section has no hand-built rows.
    var sectionSupplement: ((String) -> AnyView?)? = nil
    /// Pairing/account repair must remain reachable while the schema cannot load.
    var unresolvedSupplement: AnyView? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken

    @State private var resolution: SettingsResolution?
    /// Served options for the rows this presentation shows, by row id. Read and
    /// installed with `resolution`, so the two never disagree.
    @State private var options: [String: SettingsOptionsResponse] = [:]
    @State private var loadError: String?
    @State private var loadGeneration = 0
    @State private var previewGeneration = 0
    @State private var reloadTick = 0
    @State private var sliderPresentation = ConfigurationSliderPresentation()
    /// Gateway refusals of a dry run, shown under their row; nothing was applied.
    @State private var rowErrors: [String: String] = [:]
    @State private var changingID: String?
    @State private var previewingID: String?
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var layerEditor: LayerEditor?

    private enum LayerEditor: String, Identifiable {
        case project, mac
        var id: String { rawValue }
        var title: String { self == .project ? "Edit at Project" : "Edit at Mac" }
    }

    private struct PendingConfirmation {
        let change: JSONValue
        let rowID: String
        let message: String
    }

    private struct LoadID: Hashable {
        let target: JSONValue
        let invalidationGeneration: Int
        let foregroundGeneration: Int
        let reloadTick: Int
    }

    var body: some View {
        Group {
            if embedded {
                rendererContents
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    rendererContents
                }
                .tronScrollEdgeChrome()
            }
        }
        .tronConfigurationSliderHost(sliderPresentation)
        .environment(\.configurationSliderSignposts, model.performanceSignposts)
        .confirmationDialog(
            "Change this setting?",
            isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { pending in
            Button("Change setting") {
                pendingConfirmation = nil
                commit(pending.change, rowID: pending.rowID)
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: { pending in
            Text(pending.message)
        }
        .tronManagedSheet(item: $layerEditor, identity: { "settings.layer.\($0.id)" }) { editor in
            if editor == .project, let projectCWD, let profileID = model.selectedGatewayProfileID() {
                ProjectSettingsSheet(route: ProjectSettingsRoute(cwd: projectCWD, profileID: profileID))
            } else {
                SettingsView()
            }
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active {
                loadGeneration &+= 1
                retirePreview()
            }
        }
        .onChange(of: model.knowledgePresentationIdentity) { _, _ in retirePreview() }
        .onChange(of: model.foregroundReconciliationGeneration) { _, _ in retirePreview() }
        .onChange(of: target) { _, _ in
            retirePreview()
            resolution = nil
            options = [:]
            rowErrors = [:]
        }
        .onDisappear {
            loadGeneration &+= 1
            retirePreview()
        }
        .task(id: PresentationActivityTaskID(
            source: LoadID(target: target, invalidationGeneration: model.settingsInvalidationGeneration,
                           foregroundGeneration: model.foregroundReconciliationGeneration, reloadTick: reloadTick),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await load()
        }
    }

    @ViewBuilder
    private var rendererContents: some View {
        if case .keys = presentation {
            // Rows inside a caller's card: no states of their own while loading.
            if let resolution { content(resolution) }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if let resolution {
                    content(resolution)
                } else if let failure = loadError {
                    TronPlaceholderState(title: "Settings Unavailable", detail: failure, icon: "slider.horizontal.3",
                                         accent: .tronAmber, actionTitle: "Reload", action: reload)
                        .frame(maxWidth: .infinity)
                } else {
                    TronLoadingState(label: "Loading settings…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if resolution == nil, let unresolvedSupplement {
                    unresolvedSupplement
                }
            }
            .padding(embedded ? 0 : 20)
        }
    }

    @ViewBuilder
    private func content(_ resolution: SettingsResolution) -> some View {
        switch presentation {
        case .sections:
            overview(resolution)
        case .section(let id):
            if let served = Self.sections(resolution).first(where: { $0.id == id }) {
                sectionDetail(served, keys: keys(resolution, in: served.id), resolution: resolution)
            }
        case .overrides(let scope, let allTitle):
            overrides(resolution, scope: scope, allTitle: allTitle)
        case .detail(let id):
            if let setting = resolution.keys.first(where: { $0.id == id }) {
                TronSettingsGroup(setting.presentation?.label ?? setting.key) {
                    SettingsRendererRow(
                        setting: setting, target: target, editable: writableLayer(for: setting) != nil,
                        detailed: true, actionsAsRows: true,
                        externalControl: externalControlKeys.contains(setting.key),
                        options: options[setting.id], error: rowErrors[setting.id],
                        layerEditorTitle: layerEditor(for: setting)?.title,
                        onEditLayer: { if let editor = layerEditor(for: setting) { layerEditor = editor } },
                        onChange: { value in change(setting, value: value) },
                        onApplyAgain: { changeID in applyAgain(changeID, rowID: setting.id) }
                    )
                    .disabled(changingID != nil || previewingID != nil)
                }
            }
        case .keys(let ids):
            let chosen = ids.flatMap { id in resolution.keys.filter { $0.key == id } }
            if dividerBeforeKeys, !chosen.isEmpty { TronSettingsDivider() }
            rows(chosen, resolution: resolution, detailed: false)
        }
    }

    // MARK: Sections

    /// A primary surface groups related sections into one titled card per family,
    /// one previewing row per section. Every key lives on the section's sheet.
    @ViewBuilder
    private func overview(_ resolution: SettingsResolution) -> some View {
        let shown = Self.sections(resolution).filter { section in
            !keys(resolution, in: section.id).isEmpty || sectionSupplement?(section.id) != nil
        }
        ForEach(SettingsFamily.allCases, id: \.self) { family in
            let members = shown.filter { SettingsSectionStyle($0.id).family == family }
            if !members.isEmpty {
                TronSettingsGroup(family.title, accent: family.accent) {
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, section in
                        if index > 0 { TronSettingsDivider(accent: family.accent) }
                        VStack(spacing: 0) { sectionLink(section, keys: keys(resolution, in: section.id)) }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("settings-section-\(section.id)")
                    }
                }
                .tronSettingsVisualTheme(accent: family.accent)
            }
        }
    }

    private func sectionLink(_ section: SettingsRendererSection, keys: [ResolvedSetting]) -> some View {
        let style = SettingsSectionStyle(section.id)
        return TronProgressiveSheetLink(accessibilityLabel: section.title, identity: "settings.section.\(section.id)",
                                        accent: style.accent) {
            SettingsRendererView(target: target, writeLayer: writeLayer, ownedLayers: ownedLayers,
                                 externalControlKeys: externalControlKeys, projectCWD: projectCWD,
                                 presentation: .section(section.id), sectionSupplement: sectionSupplement)
                .tronNavigationTitle(section.title, accent: style.accent)
        } label: {
            TronSettingsRow(icon: style.icon, title: section.title, subtitle: section.description, accent: style.accent,
                            subtitleColor: .tronTextSecondary)
        }
        .accessibilityIdentifier("settings-section-\(section.id)-open")
    }

    /// One section on its own sheet: the essential keys first, then each Gateway
    /// subgroup and the remaining advanced keys as standard titled groups. A key
    /// served once per project or model gets its own group, titled by its label
    /// with its help once, and one row per instance.
    private func sectionDetail(_ section: SettingsRendererSection, keys: [ResolvedSetting],
                               resolution: SettingsResolution) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Hand-built destinations (MCP Servers, Hooks, accounts) lead the sheet.
            if let supplement = sectionSupplement?(section.id) {
                TronGlassCard(accent: SettingsSectionStyle(section.id).accent) { supplement }
                    .tronSettingsVisualTheme(accent: SettingsSectionStyle(section.id).accent)
            }
            ForEach(Array(Self.detailGroups(section, keys: keys).enumerated()), id: \.offset) { index, group in
                TronSettingsGroup(group.title, detail: group.detail ?? (index == 0 ? section.note : nil)) {
                    VStack(spacing: 0) {
                        rows(group.keys, resolution: resolution, detailed: true, instanced: group.instanced)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-detail-\(section.id)-\(index)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-section-\(section.id)-detail")
    }

    private struct DetailGroup {
        let title: String
        var detail: String? = nil
        var instanced = false
        var keys: [ResolvedSetting]
    }

    private static func detailGroups(_ section: SettingsRendererSection, keys: [ResolvedSetting]) -> [DetailGroup] {
        var groups: [DetailGroup] = []
        func add(_ title: String, _ key: ResolvedSetting, detail: String? = nil, instanced: Bool = false) {
            if let index = groups.firstIndex(where: { $0.title == title && $0.instanced == instanced }) { groups[index].keys.append(key) }
            else { groups.append(DetailGroup(title: title, detail: detail, instanced: instanced, keys: [key])) }
        }
        let single = keys.filter { instanceCount($0, in: keys) == 1 }
        for key in single where key.subgroup == nil && key.presentation?.importance == "essential" { add(section.title, key) }
        for key in single { if let subgroup = key.subgroup { add(subgroup, key) } }
        for key in keys where instanceCount(key, in: keys) > 1 {
            add(key.presentation?.label ?? key.key, key, detail: key.presentation?.help, instanced: true)
        }
        for key in single where key.subgroup == nil && key.presentation?.importance != "essential" { add("Advanced", key) }
        return groups
    }

    private static func instanceCount(_ setting: ResolvedSetting, in keys: [ResolvedSetting]) -> Int {
        keys.reduce(0) { $0 + ($1.key == setting.key ? 1 : 0) }
    }

    /// The overrides-first scope view: what this scope itself sets, then one link to
    /// every setting the scope could set. Mac Settings shows the full defaults instead.
    private func overrides(_ resolution: SettingsResolution, scope: String, allTitle: String) -> some View {
        let set = Self.sorted(resolution.keys.filter { setting in
            setting.layer == writeLayer || ownedLayers.contains(setting.layer)
        })
        return TronSettingsGroup("Set for \(scope)") {
            VStack(spacing: 0) {
                if set.isEmpty {
                    TronSettingsRow(icon: "checkmark.circle", title: "Using defaults",
                                    subtitle: "Nothing is set only for \(scope).", subtitleColor: .tronTextSecondary)
                        .accessibilityIdentifier("settings-overrides-empty")
                } else {
                    rows(set, resolution: resolution, detailed: true)
                }
                TronSettingsDivider()
                TronProgressiveSheetLink(accessibilityLabel: "Override a setting", identity: "settings.overrides.\(scope)") {
                    SettingsRendererView(target: target, writeLayer: writeLayer, ownedLayers: ownedLayers,
                                         externalControlKeys: externalControlKeys, projectCWD: projectCWD)
                        .tronNavigationTitle(allTitle)
                } label: {
                    TronSettingsRow(icon: "plus.circle", title: "Override a setting",
                                    subtitle: "Choose any setting to set for \(scope)", subtitleColor: .tronTextSecondary)
                }
                .accessibilityIdentifier("settings-overrides-all")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-overrides")
    }

    private func layerEditor(for setting: ResolvedSetting) -> LayerEditor? {
        writableLayer(for: setting) == nil
            ? setting.layers.compactMap({ LayerEditor(rawValue: $0.layer) }).first(where: { $0 != .project || projectCWD != nil })
            : nil
    }

    /// A row offers one control. A detailed row whose source also offers actions
    /// (reset, Apply again) previews its value and opens its own sheet instead.
    private func detailDestination(_ setting: ResolvedSetting) -> AnyView? {
        guard setting.badges.contains(where: { badge in
            badge.action.map { ["useCurrentDefault", "followDefault", "applyAgain"].contains($0.kind) } ?? false
        }) else { return nil }
        return AnyView(SettingsRendererView(target: target, writeLayer: writeLayer, ownedLayers: ownedLayers,
                                            externalControlKeys: externalControlKeys, projectCWD: projectCWD,
                                            presentation: .detail(setting.id))
            .tronNavigationTitle(setting.presentation?.label ?? setting.key))
    }

    /// Rows in Gateway order. Detailed rows (sub-sheets) carry source tags, help and
    /// the row's actions; primary rows show only the title and its control.
    @ViewBuilder
    private func rows(_ keys: [ResolvedSetting], resolution: SettingsResolution, detailed: Bool,
                      instanced: Bool = false) -> some View {
        ForEach(Array(keys.enumerated()), id: \.element.id) { index, setting in
            if index > 0 { TronSettingsDivider() }
            let editor = layerEditor(for: setting)
            SettingsRendererRow(
                setting: setting,
                target: target,
                editable: writableLayer(for: setting) != nil,
                detailed: detailed,
                instanced: instanced,
                detailDestination: detailed ? detailDestination(setting) : nil,
                externalControl: externalControlKeys.contains(setting.key),
                options: options[setting.id],
                error: rowErrors[setting.id],
                layerEditorTitle: editor?.title,
                onEditLayer: { if let editor { layerEditor = editor } },
                onChange: { value in change(setting, value: value) },
                onApplyAgain: { changeID in applyAgain(changeID, rowID: setting.id) }
            )
            // Keep the presenting control's identity while its accepted change
            // completes; replacing it with read-only would retire its child sheet.
            .disabled(changingID != nil || previewingID != nil)
        }
    }

    // MARK: Ordering

    /// The Gateway's sections, plus any group a key names that no section declares,
    /// so a value is never hidden.
    private static func sections(_ resolution: SettingsResolution) -> [SettingsRendererSection] {
        let declared = resolution.sections.sorted { $0.order < $1.order }
        let known = Set(declared.map(\.id))
        let undeclared = resolution.keys.map(\.group).filter { !known.contains($0) }
        return declared + Array(Set(undeclared)).sorted().map { SettingsRendererSection(id: $0) }
    }

    private func keys(_ resolution: SettingsResolution, in section: String) -> [ResolvedSetting] {
        Self.sorted(resolution.keys.filter { $0.group == section })
    }

    private static func sorted(_ keys: [ResolvedSetting]) -> [ResolvedSetting] {
        keys.sorted { ($0.presentation?.order ?? .max, $0.id) < ($1.presentation?.order ?? .max, $1.id) }
    }

    /// The rows this presentation shows that edit through a served option source.
    /// A primary surface shows section rows only, so it reads none. A change to a
    /// key a source depends on reloads the resolution, and these with it (doc 7.5).
    private func optionReads(_ resolution: SettingsResolution) -> [ResolvedSetting] {
        let shown: [ResolvedSetting]
        switch presentation {
        case .sections: return []
        case .section(let id): shown = resolution.keys.filter { $0.group == id }
        case .overrides: shown = resolution.keys.filter { $0.layer == writeLayer || ownedLayers.contains($0.layer) }
        case .detail(let id): shown = resolution.keys.filter { $0.id == id }
        case .keys(let ids): shown = resolution.keys.filter { ids.contains($0.key) }
        }
        return shown.filter { setting in
            setting.presentation?.optionsSource != nil && writableLayer(for: setting) != nil
                && !externalControlKeys.contains(setting.key)
                && [.choice, .number, .checklist].contains(SettingsRowControl(negotiated: setting.presentation?.control))
        }
    }

    /// One row's options, or none when the source cannot answer: that row then
    /// shows its value read-only, and every other row is unaffected.
    private func readOptions(_ settings: [ResolvedSetting]) async -> [String: SettingsOptionsResponse] {
        await withTaskGroup(of: (String, SettingsOptionsResponse?).self) { group in
            for setting in settings {
                group.addTask { [model, target] in
                    (setting.id, try? await model.settingsOptions(target: target, key: setting.key, qualifiers: setting.qualifiers, query: nil))
                }
            }
            var read: [String: SettingsOptionsResponse] = [:]
            for await (id, response) in group { if let response { read[id] = response } }
            return read
        }
    }

    // MARK: Reads and changes

    private func reload() {
        loadError = nil
        reloadTick &+= 1
    }

    private func load() async {
        let foreground = model.foregroundReconciliationGeneration
        let identity = model.knowledgePresentationIdentity
        let activity = presentationActivity
        guard activity.allowsPresentationPublication, !Task.isCancelled else { return }
        loadGeneration &+= 1
        let ticket = loadGeneration
        func current() -> Bool {
            ticket == loadGeneration && !Task.isCancelled && identity == model.knowledgePresentationIdentity
                && foreground == model.foregroundReconciliationGeneration
                && activity == presentationActivity && activity.allowsPresentationPublication
        }
        do {
            let value = try await model.resolveSettingsForRenderer(target: target)
            guard current() else { return }
            let read = await readOptions(optionReads(value))
            guard current() else { return }
            resolution = value
            options = read
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard current() else { return }
            if resolution == nil { loadError = error.localizedDescription } else { model.presentError(error) }
        }
    }

    private func writableLayer(for setting: ResolvedSetting) -> String? {
        if !ownedLayers.isEmpty {
            return ownedLayers.first { layer in setting.layers.contains(where: { $0.layer == layer }) }
        }
        guard let writeLayer, setting.layers.contains(where: { $0.layer == writeLayer }) else { return nil }
        return writeLayer
    }

    /// A dry run first: the Gateway validates (no client copy of a key's rules),
    /// a refusal shows under the row and nothing is applied, and a change whose
    /// key has confirm text asks before it is made (doc 7.5).
    private func change(_ setting: ResolvedSetting, value: JSONValue?) {
        // A catalog/editor child sends its accepted selection through this mounted
        // ancestor. Its covered presentation reads stop; the user's command must not.
        guard let writeLayer = writableLayer(for: setting),
              changingID == nil, previewingID == nil, presentationActivity.allowsDataPublication else { return }
        var object: [String: JSONValue] = [
            "key": .string(setting.key), "layer": .string(writeLayer), "op": .string(value == nil ? "unset" : "set"),
        ]
        if let qualifiers = setting.qualifiers, !qualifiers.isEmpty {
            object["qualifiers"] = .object(qualifiers.mapValues { JSONValue.string($0) })
        }
        if let value { object["value"] = value }
        let change = JSONValue.object(object)
        let identity = model.knowledgePresentationIdentity
        let admittedSurface = surfaceToken
        let foreground = model.foregroundReconciliationGeneration
        let requestTarget = target
        previewGeneration &+= 1
        let ticket = previewGeneration
        previewingID = setting.id
        Task { @MainActor in
            @MainActor func current() -> Bool {
                ticket == previewGeneration && !Task.isCancelled
                    && identity == model.knowledgePresentationIdentity
                    && foreground == model.foregroundReconciliationGeneration
                    && requestTarget == target
                    && admittedSurface == surfaceToken && presentationActivity.allowsDataPublication
            }
            defer { if ticket == previewGeneration { previewingID = nil } }
            let preview: SettingsChangeResult
            do {
                preview = try await model.previewSettingsChange(target: requestTarget, change: change)
            } catch is CancellationError {
                return
            } catch {
                guard current() else { return }
                model.presentError(error)
                return
            }
            guard current() else { return }
            if let failure = preview.changes.first?.error {
                rowErrors[setting.id] = failure.message
                return
            }
            rowErrors[setting.id] = nil
            if let confirm = preview.changes.first?.confirm {
                pendingConfirmation = PendingConfirmation(change: change, rowID: setting.id, message: confirm)
                previewingID = nil
            } else {
                previewingID = nil
                commit(change, rowID: setting.id)
            }
        }
    }

    /// Apply again is an accepted command like `commit`: unstructured, then a disposable reload.
    private func applyAgain(_ changeID: String, rowID: String) {
        guard changingID == nil, previewingID == nil, presentationActivity.allowsDataPublication else { return }
        changingID = rowID
        let identity = model.knowledgePresentationIdentity
        let requestTarget = target
        let admittedSurface = surfaceToken
        Task { @MainActor in
            defer { changingID = nil }
            do {
                try await model.applySettingsChangeAgain(changeID)
                guard identity == model.knowledgePresentationIdentity, requestTarget == target,
                      admittedSurface == surfaceToken, presentationActivity.allowsDataPublication else { return }
                rowErrors[rowID] = nil
                reloadTick &+= 1
            } catch is CancellationError {
                return
            } catch {
                guard identity == model.knowledgePresentationIdentity, requestTarget == target,
                      admittedSurface == surfaceToken, presentationActivity.allowsDataPublication else { return }
                rowErrors[rowID] = error.localizedDescription
            }
        }
    }

    /// Retirement owns preview cleanup; an accepted command is independent and
    /// must retain its receipt until completion even while this surface is covered.
    private func retirePreview() {
        previewGeneration &+= 1
        previewingID = nil
        pendingConfirmation = nil
    }

    /// The mutation is unstructured so the view cannot cancel it; the reload is a disposable read.
    private func commit(_ change: JSONValue, rowID: String) {
        changingID = rowID
        let identity = model.knowledgePresentationIdentity
        let requestTarget = target
        let admittedSurface = surfaceToken
        Task { @MainActor in
            defer { changingID = nil }
            do {
                try await model.changeSetting(target: requestTarget, change: change)
                guard identity == model.knowledgePresentationIdentity, requestTarget == target,
                      admittedSurface == surfaceToken, presentationActivity.allowsDataPublication else { return }
                reloadTick &+= 1
            } catch is CancellationError {
                return
            } catch {
                guard identity == model.knowledgePresentationIdentity, requestTarget == target,
                      admittedSurface == surfaceToken, presentationActivity.allowsDataPublication else { return }
                rowErrors[rowID] = error.localizedDescription
            }
        }
    }
}

/// What a renderer shows. Surfaces choose; the Gateway still supplies every word.
enum SettingsRendererPresentation: Hashable {
    /// Every section: essential rows inline, then one link to the section's sub-sheet.
    case sections
    /// One section's sub-sheet: every key, grouped, with sources, help and actions.
    case section(String)
    /// What `scope` itself sets ("this project"), then a link to everything it could set.
    case overrides(scope: String, allTitle: String)
    /// Just these keys, as inline rows inside a caller's card.
    case keys([String])
    /// One key on its own sheet: its control, then each action as its own row.
    case detail(String)
}

/// The settings palette (as before the renderer): related sections share one
/// titled card and one accent, on the primary surface and on every sheet they
/// open. Sections this app does not know join More.
enum SettingsFamily: CaseIterable {
    case agent, tools, data, more

    var title: String {
        switch self {
        case .agent: "Agent"
        case .tools: "Tools & Extensions"
        case .data: "Data & Diagnostics"
        case .more: "More"
        }
    }

    var accent: Color {
        switch self {
        case .agent: .tronPurple
        case .tools: .tronCyan
        case .data: .tronBlue
        case .more: .tronEmerald
        }
    }
}

/// A section's glyph and family.
struct SettingsSectionStyle {
    let icon: String
    let family: SettingsFamily
    var accent: Color { family.accent }

    init(_ section: String) {
        switch section {
        case "model": (icon, family) = ("cpu", .agent)
        case "context": (icon, family) = ("rectangle.compress.vertical", .agent)
        case "run": (icon, family) = ("arrow.clockwise", .agent)
        case "accounts": (icon, family) = ("key", .agent)
        case "tools": (icon, family) = ("wrench.and.screwdriver", .tools)
        case "permissions": (icon, family) = ("checkmark.shield", .tools)
        case "sources": (icon, family) = ("shippingbox", .tools)
        case "setup": (icon, family) = ("gearshape.2", .data)
        default: (icon, family) = ("slider.horizontal.3", .more)
        }
    }
}

/// Converts a resolved row into the Gateway's identifier alphabet for UI tests.
func settingsRowIdentifier(_ setting: ResolvedSetting) -> String {
    "settings-row-" + String(setting.id.unicodeScalars.map { scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" ? Character(scalar) : "_"
    })
}
