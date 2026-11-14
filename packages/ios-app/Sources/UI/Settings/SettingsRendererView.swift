import SwiftUI
import TronMobileCore

struct SettingsRendererView: View {
    let target: JSONValue
    let writeLayer: String?
    var ownedLayers: [String] = []
    var projectCWD: String? = nil
    let presentation: SettingsRendererPresentation
    var embedded = false
    var showsGroupHeadings = false
    var detailedKeys = false
    var modelConfiguration = false
    var liveControl: ((ResolvedSetting) -> AnyView)? = nil
    var resetDisabled = false
    var selection: SettingsKeySelection = .all

    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @Environment(\.configurationSliderPresentation) private var inheritedSliderPresentation

    @PresentationState private var loadError: String?
    @PresentationState private var retryTick = 0
    @PresentationState private var previewGeneration = 0
    @PresentationState private var sliderPresentation = ConfigurationSliderPresentation()
    @PresentationState private var rowErrors: [String: String] = [:]
    @PresentationState private var changingID: String?
    @PresentationState private var previewingID: String?
    @PresentationState private var pendingConfirmation: PendingConfirmation?
    private struct PendingConfirmation: Identifiable {
        let id = UUID().uuidString
        let change: JSONValue
        let rowID: String
        let review: ChangeReview
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
        .environment(\.tronPresentationDependencyRead, PresentationDependencyRead(
            id: .init(target: target, freshness: model.settingsFreshness),
            perform: { try? await model.refreshSettingsSnapshot(for: target) }))
        .tronConfigurationSliderHost(sliderPresentation, inheriting: inheritedSliderPresentation)
        .environment(\.configurationSliderSignposts, model.performanceSignposts)
        .tronManagedSheet(item: $pendingConfirmation, identity: { $0.id }) { pending in
            ChangeReviewSheet(review: pending.review, approve: {
                guard pendingConfirmation?.id == pending.id else { return }
                pendingConfirmation = nil
                commit(pending.change, rowID: pending.rowID, confirmationDigest: pending.review.digest)
            }, cancel: { pendingConfirmation = nil })
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active {
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
            if let snapshot { content(snapshot) } else { Color.clear.frame(height: 0) }
        } else if embedded, let snapshot, sectionHasNoRows(snapshot.resolution) {
            EmptyView()
        } else {
            TronSettingsSections(alignment: .leading, spacing: 20, hidesLoneHeading: true) {
                if let snapshot {
                    content(snapshot)
                } else if let failure = loadError {
                    TronPlaceholderState(title: "Settings Unavailable", detail: failure, icon: "slider.horizontal.3",
                                         accent: .tronAmber, actionTitle: "Reload") { loadError = nil; retryTick &+= 1 }
                        .frame(maxWidth: .infinity)
                } else if embedded {
                    TronLoadingState(label: "Loading settings…")
                } else {
                    TronSheetLoadingState(label: "Loading settings…")
                }
            }
            .padding(embedded ? 0 : 20)
        }
    }

    private func sectionHasNoRows(_ resolution: SettingsResolution) -> Bool {
        guard case .section(let id) = presentation else { return false }
        let ownsDefaultTools = id == "tools" && target.objectValue?["kind"]?.stringValue == "global" && writeLayer != nil
        return !ownsDefaultTools && !resolution.keys.contains { $0.group == id && selection.includes($0) }
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
            let chosen = ids.flatMap { id in
                let candidates = resolution.keys.filter { $0.key == id && selection.includes($0) }
                guard modelConfiguration && id == "model.contextWindow" else { return candidates }
                let ref = resolution.keys.first { $0.key == "model.ref[role=chat]" }?.value?.objectValue
                let modelKey = [ref?["provider"]?.stringValue, ref?["id"]?.stringValue].compactMap { $0 }.joined(separator: "/")
                return Array(candidates.filter { $0.qualifiers?["model"] == modelKey }.prefix(1))
            }
            rows(detailedKeys ? Self.sorted(chosen) : chosen, resolution: resolution, options: snapshot.options, detailed: detailedKeys)
        }
    }

    @ViewBuilder
    private func sectionDetail(_ id: String, resolution: SettingsResolution, options: [String: SettingsOptionsResponse]) -> some View {
        let section = Self.sections(resolution).first { $0.id == id } ?? SettingsRendererSection(id: id)
        let ownsDefaultTools = id == "tools" && target.objectValue?["kind"]?.stringValue == "global" && writeLayer != nil
        let keys = Self.sorted(resolution.keys.filter {
            $0.group == id && selection.includes($0) && !(ownsDefaultTools && $0.key == "tools.codemode.mode")
        })
        let groups = Self.detailGroups(section, keys: keys)
        if !showsGroupHeadings, !ownsDefaultTools, groups.count == 1, let only = groups.first, only.manyInstances == nil,
           Self.rowsNameGroup(only) || only.keys.count == 1, (only.detail ?? section.note) == nil {
            TronSettingsGroup(nil) {
                VStack(spacing: 0) { rows(only.keys, resolution: resolution, options: options, detailed: true, instanced: only.instanced) }
            }
        } else {
            TronSettingsSections(alignment: .leading, spacing: 20, hidesLoneHeading: !showsGroupHeadings) {
                if ownsDefaultTools {
                    DefaultToolsSettingsSection(projectCWD: target.objectValue?["cwd"]?.stringValue)
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    Group {
                        if let many = group.manyInstances {
                            if groups.count == 1, group.title != section.title {
                                TronSettingsGroup(section.title) { instancesLink(many, count: group.keys.count) }
                            } else {
                                TronGlassCard { instancesLink(many, count: group.keys.count) }
                            }
                        } else {
                            TronSettingsGroup(selection == .sessionOverrides && Self.rowsNameGroup(group) ? nil : group.title,
                                              detail: showsGroupHeadings ? nil : group.detail ?? (index == 0 ? section.note : nil)) {
                                VStack(spacing: 0) {
                                    rows(group.keys, resolution: resolution, options: options, detailed: true, instanced: group.instanced)
                                }
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-section-\(id)-detail")
        }
    }

    @ViewBuilder
    private func instancesDetail(_ key: String, resolution: SettingsResolution, options: [String: SettingsOptionsResponse]) -> some View {
        let instances = resolution.keys.filter { $0.key == key && selection.includes($0) }
        let governed = { (instance: ResolvedSetting) in
            instance.qualifiers?["key"].flatMap { governedKey in resolution.keys.first { $0.key == governedKey } }
        }
        let sections = Self.sections(resolution)
        let groups = Dictionary(grouping: instances) { governed($0)?.group ?? "" }
        TronSettingsSections(alignment: .leading, spacing: 20, hidesLoneHeading: true) {
            if let help = instances.first?.presentation.help { TronSettingsCaption(help).containerValue(\.tronSettingsSection, false) }
            ForEach(sections.map(\.id).filter { groups[$0] != nil } + (groups[""] == nil ? [] : [""]), id: \.self) { group in
                TronSettingsGroup(sections.first { $0.id == group }?.title ?? (instances.first?.presentation.label ?? key)) {
                    VStack(spacing: 0) {
                        let members = (groups[group] ?? []).sorted { (RowTitle.instance($0), $0.id) < (RowTitle.instance($1), $1.id) }
                        ForEach(Array(members.enumerated()), id: \.element.id) { index, instance in
                            if index > 0 { TronSettingsDivider() }
                            row(instance, resolution: resolution, options: options, detailed: true, instanced: true,
                                instanceHelp: governed(instance)?.presentation.help)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-instances-\(key)-detail")
    }

    private func instancesLink(_ setting: ResolvedSetting, count: Int) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: setting.presentation.label,
                                 identity: "settings.instances.\(setting.key)") {
            SettingsRendererView(target: target, writeLayer: writeLayer, ownedLayers: ownedLayers, projectCWD: projectCWD,
                                 presentation: .instances(key: setting.key), selection: selection)
                .tronNavigationTitle(setting.presentation.label)
        } label: {
            TronSettingsRow(icon: SettingsRendererRow.semanticIcon(for: setting.key) ?? "list.bullet.indent", title: setting.presentation.label,
                            subtitle: setting.presentation.help, subtitleColor: .tronTextSecondary)
        }
        .accessibilityIdentifier("settings-instances-\(setting.key)-open")
    }

    @ViewBuilder
    private func rows(_ keys: [ResolvedSetting], resolution: SettingsResolution, options: [String: SettingsOptionsResponse],
                      detailed: Bool, instanced: Bool = false) -> some View {
        let ordered = instanced ? keys.filter { RowTitle.isBase($0) } + keys.filter { !RowTitle.isBase($0) } : keys
        let baseTitle = instanced && keys.contains { $0.qualifiers?["model"] != nil } ? "All models" : nil
        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, setting in
            if index > 0 { TronSettingsDivider() }
            row(setting, resolution: resolution, options: options, detailed: detailed, instanced: instanced, baseInstanceTitle: baseTitle)
        }
    }

    private var modelSelectionAvailability: ModelSelectionAvailability {
        if changingID != nil || previewingID != nil { return .applying }
        if let reason = model.rendererConfigurationLockedReason(target: target) { return .blocked(reason) }
        return .ready
    }

    private func row(_ setting: ResolvedSetting, resolution: SettingsResolution, options: [String: SettingsOptionsResponse],
                     detailed: Bool, instanced: Bool = false, baseInstanceTitle: String? = nil, instanceHelp: String? = nil) -> some View {
        SettingsRendererRow(
            setting: setting,
            target: target,
            editable: writableLayer(for: setting) != nil,
            detailed: detailed,
            modelConfiguration: modelConfiguration,
            modelSelectionAvailability: modelSelectionAvailability,
            instanced: instanced,
            baseInstanceTitle: baseInstanceTitle,
            liveControl: liveControl.map { control in
                AnyView(control(setting).environment(\.configurationSliderPresentation,
                    inheritedSliderPresentation ?? sliderPresentation))
            },
            resetDisabled: resetDisabled || (modelConfiguration && !modelSelectionAvailability.canSelect),
            canReset: writableLayer(for: setting) != nil && setting.overridden == true,
            instanceHelp: instanceHelp,
            options: options[setting.id],
            error: rowErrors[setting.id],
            onChange: { value in
                guard !resetDisabled else { return }
                change(setting, value: value)
            }
        )
        .disabled((changingID != nil && !(modelConfiguration && setting.key == "model.ref[role=chat]")) || previewingID != nil)
    }

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
        guard target.objectValue?["kind"]?.stringValue != "project", setting.projectSetting == nil else { return nil }
        let candidates = ownedLayers.isEmpty ? [writeLayer].compactMap { $0 } : ownedLayers
        return setting.presentation.editable ? candidates.first : nil
    }

    private func change(_ setting: ResolvedSetting, value: JSONValue?) {
        guard let writeLayer = writableLayer(for: setting),
              changingID == nil, previewingID == nil, presentationActivity.allowsDataPublication else { return }
        if let value, setting.value(at: writeLayer) == value {
            rowErrors[setting.id] = nil
            return
        }
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
            if let review = preview.review, review.requiresTap {
                pendingConfirmation = PendingConfirmation(change: change, rowID: setting.id, review: review)
                previewingID = nil
            } else {
                previewingID = nil
                commit(change, rowID: setting.id)
            }
        }
    }

    private func retirePreview() {
        previewGeneration &+= 1
        previewingID = nil
        pendingConfirmation = nil
    }

    private func commit(_ change: JSONValue, rowID: String, confirmationDigest: String? = nil) {
        guard changingID == nil else { return }
        changingID = rowID
        let identity = model.knowledgePresentationIdentity
        let requestTarget = target
        let admittedSurface = surfaceToken
        Task { @MainActor in
            defer { changingID = nil }
            do {
                try await model.changeSetting(target: requestTarget, change: change, confirmationDigest: confirmationDigest)
                guard identity == model.knowledgePresentationIdentity, requestTarget == target,
                      admittedSurface == surfaceToken, presentationActivity.allowsDataPublication else { return }
                model.noteSettingsChanged()
                try? await model.refreshSettingsSnapshot(for: requestTarget)
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
