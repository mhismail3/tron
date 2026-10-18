import SwiftUI
import TronMobileCore

/// The generic settings renderer (gateway docs/settings-model.md F1, 7.1-7.5).
/// Every word, section, order, control and badge is Gateway data from
/// `settings.resolve`; this view decides layout and style only, so a key, a
/// section or a choice the Gateway adds needs no app change. It reads the
/// target's shared `SettingsSnapshot`, so a sheet opened from another surface
/// shows what that surface already has, and only refreshes when it is stale.
/// `writeLayer` nil with no `ownedLayers` renders read-only.
struct SettingsRendererView: View {
    let target: JSONValue
    let writeLayer: String?
    /// Ordered from the layer this surface prefers to the next owned layer.
    var ownedLayers: [String] = []
    var projectCWD: String? = nil
    let presentation: SettingsRendererPresentation
    /// Inside a caller's scroll view (a hand-built sheet that shows a section's keys).
    var embedded = false
    var detailedKeys = false
    var inspecting = false
    /// Restricts this projection, never the underlying settings snapshot or schema.
    var selection: SettingsKeySelection = .all

    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken

    @PresentationState private var loadError: String?
    @PresentationState private var retryTick = 0
    @PresentationState private var previewGeneration = 0
    @PresentationState private var sliderPresentation = ConfigurationSliderPresentation()
    /// Gateway refusals of a dry run, shown under their row; nothing was applied.
    @PresentationState private var rowErrors: [String: String] = [:]
    @PresentationState private var changingID: String?
    @PresentationState private var previewingID: String?
    @PresentationState private var pendingConfirmation: PendingConfirmation?
    private struct PendingConfirmation {
        let change: JSONValue
        let rowID: String
        let message: String
    }

    private struct RefreshID: Hashable {
        let target: JSONValue
        let freshness: SettingsFreshness
        let retryTick: Int
    }

    private var snapshot: SettingsSnapshot? { model.settingsSnapshot(for: target) }

    var body: some View {
        Group {
            if embedded || isInline {
                rendererContents
            } else {
                ScrollView(.vertical, showsIndicators: true) { rendererContents }
                    .tronScrollEdgeChrome()
            }
        }
        .tronConfigurationSliderHost(sliderPresentation)
        .environment(\.configurationSliderSignposts, model.performanceSignposts)
        .tronConfirmation(
            "Change this setting?",
            isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
            presenting: pendingConfirmation
        ) { pending in
            Button("Change setting") {
                pendingConfirmation = nil
                commit(pending.change, rowID: pending.rowID)
            }
        } message: { pending in
            Text(pending.message)
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active {
                // Our confirmation child must retain its pending accepted
                // choice while only disposable dry-run work is retired.
                previewGeneration &+= 1
                previewingID = nil
                if !presentationActivity.allowsDataPublication { pendingConfirmation = nil }
            }
        }
        .onChange(of: model.knowledgePresentationIdentity) { _, _ in retirePreview() }
        .onChange(of: model.foregroundReconciliationGeneration) { _, _ in retirePreview() }
        .onChange(of: target) { _, _ in
            retirePreview()
            rowErrors = [:]
        }
        .onDisappear { retirePreview() }
        .task(id: PresentationActivityTaskID(
            source: RefreshID(target: target, freshness: model.settingsFreshness, retryTick: retryTick),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await refresh()
        }
    }

    private var isInline: Bool { if case .keys = presentation { true } else { false } }

    @ViewBuilder
    private var rendererContents: some View {
        if isInline {
            // Rows inside a caller's card: no states of their own while loading.
            // Before its rows arrive it is still a (zero-height) view, because an
            // empty one never appears and so would never start its own read.
            if let snapshot { content(snapshot) } else { Color.clear.frame(height: 0) }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if let snapshot {
                    content(snapshot)
                } else if let failure = loadError {
                    TronPlaceholderState(title: "Settings Unavailable", detail: failure, icon: "slider.horizontal.3",
                                         accent: .tronAmber, actionTitle: "Reload") { loadError = nil; retryTick &+= 1 }
                        .frame(maxWidth: .infinity)
                } else if embedded {
                    // A section of an already-visible sheet (Manage Home): a partial load.
                    TronLoadingState(label: "Loading settings…")
                } else {
                    TronSheetLoadingState(label: "Loading settings…")
                }
            }
            .padding(embedded ? 0 : 20)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: SettingsSnapshot) -> some View {
        let resolution = snapshot.resolution
        switch presentation {
        case .section(let id):
            sectionDetail(id, resolution: resolution, options: snapshot.options)
        case .instances(let key):
            instancesDetail(key, resolution: resolution, options: snapshot.options)
        case .keys(let ids):
            let chosen = ids.flatMap { id in resolution.keys.filter { $0.key == id && selection.includes($0) } }
            rows(detailedKeys ? Self.sorted(chosen) : chosen, resolution: resolution, options: snapshot.options, detailed: detailedKeys)
        }
    }

    // MARK: Sheets

    /// One section on its own sheet: the essential keys first, then each Gateway
    /// subgroup and the remaining advanced keys as standard titled groups. A key
    /// served once per project or model gets its own group, titled by its label
    /// with its help once, and one row per instance; a key with many instances
    /// is one row that opens them on their own sheet.
    @ViewBuilder
    private func sectionDetail(_ id: String, resolution: SettingsResolution, options: [String: SettingsOptionsResponse]) -> some View {
        let section = Self.sections(resolution).first { $0.id == id } ?? SettingsRendererSection(id: id)
        let ownsDefaultTools = id == "tools" && ["mac", "project"].contains(target.objectValue?["kind"]?.stringValue ?? "") && writeLayer != nil
        // The moved Default Tools container owns code-mode selection at these
        // scopes; do not expose a second editor for the same setting beside it.
        let keys = Self.sorted(resolution.keys.filter {
            $0.group == id && selection.includes($0) && !(ownsDefaultTools && $0.key == "tools.codemode.mode")
        })
        VStack(alignment: .leading, spacing: 20) {
            if ownsDefaultTools {
                DefaultToolsSettingsSection(projectCWD: target.objectValue?["cwd"]?.stringValue)
            }
            ForEach(Array(Self.detailGroups(section, keys: keys).enumerated()), id: \.offset) { index, group in
                Group {
                    // A key with many instances is one row, titled by the key itself.
                    if let many = group.manyInstances {
                        TronGlassCard { instancesLink(many, count: group.keys.count) }
                    } else {
                        TronSettingsGroup(group.title, detail: group.detail ?? (index == 0 ? section.note : nil)) {
                            VStack(spacing: 0) {
                                rows(group.keys, resolution: resolution, options: options, detailed: true, instanced: group.instanced)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-detail-\(id)-\(index)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-section-\(id)-detail")
    }

    /// Every instance of one key. Instances that each govern another setting are
    /// grouped by that setting's section and described by its help.
    @ViewBuilder
    private func instancesDetail(_ key: String, resolution: SettingsResolution, options: [String: SettingsOptionsResponse]) -> some View {
        let instances = resolution.keys.filter { $0.key == key && selection.includes($0) }
        let governed = { (instance: ResolvedSetting) in
            instance.qualifiers?["key"].flatMap { governedKey in resolution.keys.first { $0.key == governedKey } }
        }
        let sections = Self.sections(resolution)
        let groups = Dictionary(grouping: instances) { governed($0)?.group ?? "" }
        VStack(alignment: .leading, spacing: 20) {
            if let help = instances.first?.presentation?.help { TronSettingsCaption(help) }
            ForEach(sections.map(\.id).filter { groups[$0] != nil } + (groups[""] == nil ? [] : [""]), id: \.self) { group in
                TronSettingsGroup(sections.first { $0.id == group }?.title ?? (instances.first?.presentation?.label ?? key)) {
                    VStack(spacing: 0) {
                        let members = (groups[group] ?? []).sorted { (RowTitle.instance($0), $0.id) < (RowTitle.instance($1), $1.id) }
                        ForEach(Array(members.enumerated()), id: \.element.id) { index, instance in
                            if index > 0 { TronSettingsDivider() }
                            row(instance, resolution: resolution, options: options, detailed: true, instanced: true,
                                instanceHelp: governed(instance)?.presentation?.help)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-instances-\(key)-detail")
    }

    private func instancesLink(_ setting: ResolvedSetting, count: Int) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: setting.presentation?.label ?? setting.key,
                                 identity: "settings.instances.\(setting.key)") {
            SettingsRendererView(target: target, writeLayer: writeLayer, ownedLayers: ownedLayers, projectCWD: projectCWD,
                                 presentation: .instances(key: setting.key), inspecting: inspecting, selection: selection)
                .tronNavigationTitle(setting.presentation?.label ?? setting.key)
        } label: {
            TronSettingsRow(icon: "list.bullet.indent", title: setting.presentation?.label ?? setting.key,
                            subtitle: setting.presentation?.help, subtitleColor: .tronTextSecondary)
        }
        .accessibilityIdentifier("settings-instances-\(setting.key)-open")
    }

    private struct DetailGroup {
        let title: String
        var detail: String? = nil
        var instanced = false
        var keys: [ResolvedSetting]
        /// One key with more instances than a group should list inline.
        var manyInstances: ResolvedSetting? { instanced && keys.count > SettingsRendererView.inlineInstanceLimit ? keys.first : nil }
    }

    static let inlineInstanceLimit = 8

    private static func detailGroups(_ section: SettingsRendererSection, keys: [ResolvedSetting]) -> [DetailGroup] {
        var groups: [DetailGroup] = []
        func add(_ title: String, _ key: ResolvedSetting, detail: String? = nil, instanced: Bool = false) {
            if let index = groups.firstIndex(where: { $0.title == title && $0.instanced == instanced }) { groups[index].keys.append(key) }
            else { groups.append(DetailGroup(title: title, detail: detail, instanced: instanced, keys: [key])) }
        }
        let single = keys.filter { instanceCount($0, in: keys) == 1 }
        // Keep the main group coherent: importance ranks values, not another
        // one-row “Advanced” card. Only multi-row subgroups earn a heading.
        let subgroups = Dictionary(grouping: single.filter { $0.subgroup != nil }, by: { $0.subgroup! })
        for key in single where key.subgroup == nil || key.subgroup == section.title || (subgroups[key.subgroup ?? ""]?.count ?? 0) < 2 {
            add(section.title, key)
        }
        for key in single {
            if let subgroup = key.subgroup, subgroup != section.title, (subgroups[subgroup]?.count ?? 0) >= 2 { add(subgroup, key) }
        }
        for key in keys where instanceCount(key, in: keys) > 1 {
            let many = instanceCount(key, in: keys) > inlineInstanceLimit
            add(key.presentation?.label ?? key.key, key, detail: many ? nil : key.presentation?.help, instanced: true)
        }
        return groups
    }

    private static func instanceCount(_ setting: ResolvedSetting, in keys: [ResolvedSetting]) -> Int {
        keys.reduce(0) { $0 + ($1.key == setting.key ? 1 : 0) }
    }

    private enum RowTitle {
        static func instance(_ setting: ResolvedSetting) -> String {
            SettingsRendererRow.instanceName(setting) ?? setting.id
        }
    }

    // MARK: Rows

    /// Rows in Gateway order. Detailed rows carry help; all schema rows keep
    /// source inspection on the body, beside independent value/reset actions.
    @ViewBuilder
    private func rows(_ keys: [ResolvedSetting], resolution: SettingsResolution, options: [String: SettingsOptionsResponse],
                      detailed: Bool, instanced: Bool = false) -> some View {
        ForEach(Array(keys.enumerated()), id: \.element.id) { index, setting in
            if index > 0 { TronSettingsDivider() }
            row(setting, resolution: resolution, options: options, detailed: detailed, instanced: instanced)
        }
    }

    private func row(_ setting: ResolvedSetting, resolution: SettingsResolution, options: [String: SettingsOptionsResponse],
                     detailed: Bool, instanced: Bool = false, instanceHelp: String? = nil) -> some View {
        SettingsRendererRow(
            setting: setting,
            target: target,
            editable: writableLayer(for: setting) != nil,
            detailed: detailed,
            instanced: instanced,
            inspecting: inspecting,
            canReset: writableLayer(for: setting).map { layer in
                setting.layers.contains { $0.layer == layer && ($0.value != nil || $0.display != nil) }
                    || (setting.layer == layer && setting.badges.contains { ["useCurrentDefault", "followDefault"].contains($0.action?.kind ?? "") })
            } ?? false,
            instanceHelp: instanceHelp,
            options: options[setting.id],
            error: rowErrors[setting.id],
            onChange: { value in change(setting, value: value) },
            onApplyAgain: writableLayer(for: setting) == nil ? nil : { changeID in applyAgain(changeID, rowID: setting.id) }
        )
        // Keep the presenting control's identity while its accepted change
        // completes; replacing it with read-only would retire its child sheet.
        .disabled(changingID != nil || previewingID != nil)
    }

    // MARK: Ordering

    /// The Gateway's sections, plus any group a key names that no section declares,
    /// so a value is never hidden.
    static func sections(_ resolution: SettingsResolution) -> [SettingsRendererSection] {
        let declared = resolution.sections.sorted { $0.order < $1.order }
        let known = Set(declared.map(\.id))
        let undeclared = resolution.keys.map(\.group).filter { !known.contains($0) }
        return declared + Array(Set(undeclared)).sorted().map { SettingsRendererSection(id: $0) }
    }

    private static func sorted(_ keys: [ResolvedSetting]) -> [ResolvedSetting] {
        keys.sorted { ($0.presentation?.order ?? .max, $0.id) < ($1.presentation?.order ?? .max, $1.id) }
    }

    // MARK: Reads and changes

    /// Brings the shared snapshot up to date. A failure shows only while there is
    /// nothing to show; otherwise the current snapshot stays and the error is surfaced.
    private func refresh() async {
        let identity = model.knowledgePresentationIdentity
        let activity = presentationActivity
        do {
            try await model.refreshSettingsSnapshot(for: target)
            guard identity == model.knowledgePresentationIdentity, activity == presentationActivity else { return }
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard identity == model.knowledgePresentationIdentity, activity == presentationActivity,
                  activity.allowsPresentationPublication else { return }
            if snapshot == nil { loadError = error.localizedDescription } else { model.presentError(error) }
        }
    }

    private func writableLayer(for setting: ResolvedSetting) -> String? {
        // Repository configuration is inspectable, never editable through app navigation.
        guard target.objectValue?["kind"]?.stringValue != "project" else { return nil }
        let candidates = ownedLayers.isEmpty ? [writeLayer].compactMap { $0 } : ownedLayers
        return candidates.first { layer in
            layer != "project" && setting.layers.contains(where: { $0.layer == layer })
                && (setting.presentation?.editableLayers?.contains(layer) ?? true)
        }
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
                model.noteSettingsChanged()
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
                model.noteSettingsChanged()
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
    /// One section's sheet: every key, grouped, with sources, help and actions.
    case section(String)
    /// Every instance of one key on its own sheet (per project, per governed setting).
    case instances(key: String)
    /// Just these keys, as inline rows inside a caller's card.
    case keys([String])
}

/// Converts a resolved row into the Gateway's identifier alphabet for UI tests.
func settingsRowIdentifier(_ setting: ResolvedSetting) -> String {
    "settings-row-" + String(setting.id.unicodeScalars.map { scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" ? Character(scalar) : "_"
    })
}
