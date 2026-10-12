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
    /// Hand-built account, package and setup flows supplement schema rows, never replace them.
    var sectionSupplement: ((String) -> AnyView)? = nil
    /// Pairing/account repair must remain reachable while the schema cannot load.
    var unresolvedSupplement: AnyView? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken

    @State private var resolution: SettingsResolution?
    @State private var loadError: String?
    @State private var loadGeneration = 0
    @State private var previewGeneration = 0
    @State private var reloadTick = 0
    @State private var search = ""
    @State private var sliderPresentation = ConfigurationSliderPresentation()
    @State private var expanded: Set<String> = []
    @State private var showsAll = false
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

    private var rendererContents: some View {
        VStack(alignment: .leading, spacing: 20) {
            TronSearchBar(text: $search, prompt: "Search settings")
                .accessibilityIdentifier("settings-renderer-search")
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

    @ViewBuilder
    private func content(_ resolution: SettingsResolution) -> some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            searchResults(resolution, query: query)
        } else {
            ForEach(Self.sections(resolution)) { section in
                sectionView(section, keys: keys(resolution, in: section.id))
            }
            TronToggleRow(icon: "list.bullet", title: "All settings", detail: "Every setting, by section", isOn: $showsAll)
                .tronGlassSurface(accent: .tronEmerald)
                .accessibilityIdentifier("settings-renderer-all")
            if showsAll {
                // One child group: its sections reuse the summary sections' ids.
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Self.sections(resolution)) { section in
                        TronSettingsGroup(section.title, detail: section.note) {
                            rows(keys(resolution, in: section.id), resolution: resolution)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings-all-\(section.id)")
                    }
                }
            }
        }
    }

    // MARK: Sections

    private func sectionView(_ section: SettingsRendererSection, keys: [ResolvedSetting]) -> some View {
        let isExpanded = expanded.contains(section.id)
        let summary = section.summary
        return TronSettingsGroup(section.title, detail: section.note) {
            // The summary row is the section's expand control: calm by default, every key one tap away.
            Button {
                if isExpanded { expanded.remove(section.id) } else { expanded.insert(section.id) }
            } label: {
                TronSettingsRow(
                    icon: nil,
                    title: summary.essential.map(\.display).joined(separator: " · ").nonEmpty ?? (keys.count == 1 ? "1 setting" : "\(keys.count) settings"),
                    subtitle: summary.essential.isEmpty ? nil : summary.essential.map(\.label).joined(separator: " · ")
                ) {
                    TronInlineActionLabel(isExpanded ? "Show less" : "Show all")
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Shows the summary only" : "Shows every setting in \(section.title)")
            .accessibilityIdentifier("settings-section-\(section.id)-expand")
            ForEach(Array(summary.overrides.enumerated()), id: \.offset) { _, override in
                TronSettingsDivider()
                TronSettingsRow(icon: nil, title: override.label, subtitle: override.display) {
                    SettingsBadgeView(badge: SettingsBadge(kind: "layer", label: override.layerLabel, detail: nil))
                }
            }
            if !summary.pending.isEmpty {
                TronSettingsDivider()
                TronSettingsRow(
                    icon: "hourglass",
                    title: summary.pending.count == 1 ? "1 waiting for you" : "\(summary.pending.count) waiting for you",
                    subtitle: summary.pending.map { "\($0.requester): \($0.labels.joined(separator: ", "))" }.joined(separator: "\n"),
                    accent: .tronAmber
                )
                .accessibilityIdentifier("settings-section-\(section.id)-pending")
            }
            ForEach(summary.recent, id: \.changeId) { change in
                TronSettingsDivider()
                TronSettingsRow(icon: "clock.arrow.circlepath", title: "\(change.actor) changed \(change.label)", subtitle: change.reason)
            }
            if summary.moreRecent > 0 {
                TronSettingsDivider()
                TronSettingsRow(icon: nil, title: "+\(summary.moreRecent) more changes")
            }
            if isExpanded {
                TronSettingsDivider()
                expandedRows(keys)
            }
            if let sectionSupplement {
                sectionSupplement(section.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-section-\(section.id)")
    }

    @ViewBuilder
    private func expandedRows(_ keys: [ResolvedSetting]) -> some View {
        let essential = keys.filter { $0.presentation?.importance == "essential" }
        let advanced = keys.filter { $0.presentation?.importance != "essential" }
        if let resolution {
            rows(essential, resolution: resolution)
            if !advanced.isEmpty {
                Text("Advanced")
                    .font(TronTypography.sans(size: TronTypography.sizeSecondary, weight: .semibold))
                    .foregroundStyle(Color.tronTextSecondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
                    .padding(.top, 12)
                rows(advanced, resolution: resolution)
            }
        }
    }

    /// Rows in Gateway order, with each subgroup's heading before its first row.
    @ViewBuilder
    private func rows(_ keys: [ResolvedSetting], resolution: SettingsResolution) -> some View {
        ForEach(Array(keys.enumerated()), id: \.element.id) { index, setting in
            if let subgroup = setting.subgroup, index == 0 || keys[index - 1].subgroup != subgroup {
                Text(subgroup)
                    .font(TronTypography.sans(size: TronTypography.sizeSecondary, weight: .semibold))
                    .foregroundStyle(Color.tronTextSecondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
                    .padding(.top, 12)
            } else if index > 0 {
                TronSettingsDivider()
            }
            SettingsRendererRow(
                setting: setting,
                target: target,
                editable: writableLayer(for: setting) != nil,
                externalControl: externalControlKeys.contains(setting.key),
                dependencyDisplay: Self.dependencyDisplay(setting, in: resolution),
                error: rowErrors[setting.id],
                onChange: { value in change(setting, value: value) },
                onApplyAgain: { changeID in applyAgain(changeID, rowID: setting.id) }
            )
            // Keep the presenting control's identity while its accepted change
            // completes; replacing it with read-only would retire its child sheet.
            .disabled(changingID != nil || previewingID != nil)
            if writableLayer(for: setting) == nil,
               let editor = setting.layers.compactMap({ LayerEditor(rawValue: $0.layer) })
                .first(where: { $0 != .project || projectCWD != nil }) {
                Button { layerEditor = editor } label: { TronInlineActionLabel(editor.title) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(settingsRowIdentifier(setting))-edit-layer")
                    .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
                    .padding(.bottom, 12)
            }
        }
    }

    private func searchResults(_ resolution: SettingsResolution, query: String) -> some View {
        let matches = resolution.keys.filter { setting in
            [setting.presentation?.label, setting.key, setting.presentation?.help, setting.display]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return VStack(alignment: .leading, spacing: 20) {
            if matches.isEmpty {
                TronSettingsCaption("No setting matches \u{201C}\(query)\u{201D}.")
            }
            ForEach(Self.sections(resolution).filter { section in matches.contains { $0.group == section.id } }) { section in
                TronSettingsGroup(section.title) {
                    rows(Self.sorted(matches.filter { $0.group == section.id }), resolution: resolution)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-renderer-results")
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

    /// The displays of the keys an options source depends on: when one changes,
    /// the row asks the Gateway for its options again (doc 7.5).
    private static func dependencyDisplay(_ setting: ResolvedSetting, in resolution: SettingsResolution) -> String {
        (setting.presentation?.optionsSource?.dependsOn ?? []).map { key in
            resolution.keys.first { $0.key == key }?.display ?? ""
        }.joined(separator: "|")
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
            resolution = value
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

/// The same renderer on a managed native sheet; its caller owns the target,
/// never a global/project scope picker.
struct SettingsRendererSheet: View {
    let target: JSONValue
    let writeLayer: String
    var projectCWD: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsRendererView(target: target, writeLayer: writeLayer, projectCWD: projectCWD)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { TronSheetTitle(title: "Settings") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(Color.tronEmerald)
                        }
                        .accessibilityLabel("Done")
                        .accessibilityIdentifier("settings-renderer-done")
                    }
                }
        }
        .tronTopBlur(.sheet)
        .presentationDragIndicator(.hidden)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Converts a resolved row into the Gateway's identifier alphabet for UI tests.
func settingsRowIdentifier(_ setting: ResolvedSetting) -> String {
    "settings-row-" + String(setting.id.unicodeScalars.map { scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" ? Character(scalar) : "_"
    })
}
